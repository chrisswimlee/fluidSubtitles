import AppKit
import AVFoundation
import Combine
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class PresenterCaptionController: NSObject, NSWindowDelegate {
    static let shared = PresenterCaptionController()

    private var panel: NSPanel?
    private let model = PresenterCaptionModel()
    private var lastExternalAppPID: pid_t?

    private var isDismissing = false
    private var settingsCancellables = Set<AnyCancellable>()
    private var boardCommitted: [String] = []
    private var boardIDs: [UInt64] = []
    private var boardSources: [String] = []
    private var boardPending: [String] = []
    private var liveDraft = ""
    private var liveSource = ""

    var isEditing: Bool { self.model.isEditing }

    func setVisible(_ visible: Bool) {
        if visible {
            self.show()
        } else {
            self.hide()
        }
    }

    func show() {
        guard TheaterAvailability.isSupported else {
            SettingsStore.shared.theaterWindowEnabled = false
            LiveTranslationController.shared.reportListenFailure(TheaterAvailability.unsupportedCopy)
            return
        }
        SettingsStore.shared.theaterWindowEnabled = true
        LiveTranslationController.shared.restoreBoardIfNeeded()
        if self.panel == nil {
            self.panel = Self.makePanel(model: self.model)
            self.panel?.delegate = self
        }
        self.observeSettings()
        self.applyWindowSharing()
        self.applyPresentationStyle()
        self.restoreFrame()
        self.rememberExternalApp()
        self.applyMinimizedLayout()
        if self.model.isEditing {
            self.panel?.makeKeyAndOrderFront(nil)
        } else {
            self.panel?.orderFront(nil)
        }
        LiveTranslationController.shared.syncTheater()
    }

    func hide() {
        self.panel?.orderOut(nil)
        self.dismissCaptions()
    }

    func orderOutIfClosed() {
        guard !SettingsStore.shared.theaterWindowEnabled else { return }
        self.panel?.orderOut(nil)
    }

    func clearDisplay() {
        self.boardCommitted = []
        self.boardIDs = []
        self.boardSources = []
        self.boardPending = []
        self.liveDraft = ""
        self.liveSource = ""
        self.model.committed = []
        self.model.committedIDs = []
        self.model.source = ""
        self.model.draft = ""
        self.model.status = ""
        self.model.statusKind = .idle
        self.model.isEditing = false
        self.model.editedText = ""
        self.model.committedSources = []
        self.model.pendingSources = []
        self.model.canRetryTranslation = false
        self.model.approachingLineLimit = false
        self.model.latencyReadout = ""
        self.model.compactLatencyReadout = ""
    }

    func update(
        source: String,
        draft: String,
        committed: [String],
        committedIDs: [UInt64] = [],
        committedSources: [String] = [],
        pendingSources: [String] = [],
        pairLabel: String,
        status: String,
        statusKind: TheaterStatusKind = .idle,
        isListening: Bool,
        isPaused: Bool = false,
        canRetryTranslation: Bool = false,
        approachingLineLimit: Bool = false,
        latencyReadout: String = "",
        compactLatencyReadout: String = ""
    ) {
        self.boardCommitted = committed
        self.boardIDs = committedIDs
        self.boardSources = committedSources
        self.boardPending = pendingSources
        self.liveDraft = draft
        self.liveSource = source
        if self.model.pairLabel != pairLabel { self.model.pairLabel = pairLabel }
        if self.model.status != status { self.model.status = status }
        if self.model.statusKind != statusKind { self.model.statusKind = statusKind }
        if self.model.isListening != isListening { self.model.isListening = isListening }
        if self.model.isPaused != isPaused { self.model.isPaused = isPaused }
        if self.model.canRetryTranslation != canRetryTranslation {
            self.model.canRetryTranslation = canRetryTranslation
        }
        if self.model.approachingLineLimit != approachingLineLimit {
            self.model.approachingLineLimit = approachingLineLimit
        }
        if self.model.latencyReadout != latencyReadout {
            self.model.latencyReadout = latencyReadout
        }
        if self.model.compactLatencyReadout != compactLatencyReadout {
            self.model.compactLatencyReadout = compactLatencyReadout
        }
        if !self.model.isEditing {
            let document = Self.captionDocument(committed: committed, draft: draft)
            if self.model.editedText != document {
                self.model.editedText = document
            }
        }
        self.applyPresentedBoard()
    }

    func documentTextForDelivery() -> String {
        if self.model.isEditing {
            return self.model.editedText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Self.captionDocument(committed: self.boardCommitted, draft: self.liveDraft)
    }

    /// Same answer as `documentTextForDelivery().isEmpty` without joining the board.
    var hasDeliverableText: Bool {
        if self.model.isEditing {
            return !self.model.editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if self.boardCommitted.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return true
        }
        return !self.liveDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func commitEdits() {
        guard self.model.isEditing else { return }
        LiveTranslationController.shared.applyEditedDocument(self.model.editedText)
        self.model.isEditing = false
        self.applyPresentedBoard()
    }

    func cancelEditing() {
        guard self.model.isEditing else { return }
        self.model.isEditing = false
        self.model.editedText = ""
        self.applyPresentedBoard()
    }

    func makeKeyForInteraction() {
        self.rememberExternalApp()
        self.panel?.makeKeyAndOrderFront(nil)
    }

    func releaseKeyToExternalApp() {
        guard TheaterKeyPolicy.shouldRestoreExternalApp(isEditing: self.model.isEditing) else { return }
        self.panel?.resignKey()
        if let pid = self.lastExternalAppPID {
            TypingService.activateApp(pid: pid)
        }
    }

    func performChromeAction(_ action: () -> Void) {
        self.makeKeyForInteraction()
        action()
        self.scheduleReleaseKeyToExternalApp()
    }

    func scheduleReleaseKeyToExternalApp() {
        guard TheaterKeyPolicy.shouldRestoreExternalApp(isEditing: self.model.isEditing) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.releaseKeyToExternalApp()
        }
    }

    func requestClose() {
        if self.shouldConfirmCloseWhileListening {
            self.model.showCloseConfirmation = true
            self.makeKeyForInteraction()
            return
        }
        self.setVisible(false)
    }

    func confirmCloseWhileListening() {
        self.model.showCloseConfirmation = false
        self.setVisible(false)
    }

    func cancelCloseWhileListening() {
        self.model.showCloseConfirmation = false
        self.scheduleReleaseKeyToExternalApp()
    }

    var shouldConfirmCloseWhileListening: Bool {
        LiveTranslationController.shared.isSessionActive
            && LiveTranslationController.shared.listenKind == .captions
    }

    func toggleMinimized() {
        if self.model.isEditing {
            self.commitEdits()
            self.scheduleReleaseKeyToExternalApp()
        }
        let settings = SettingsStore.shared
        if let panel = self.panel, panel.isVisible, !settings.theaterMinimized {
            settings.theaterExpandedWindowFrame = NSStringFromRect(panel.frame)
            settings.theaterWindowFrame = NSStringFromRect(panel.frame)
        }
        settings.theaterMinimized.toggle()
        self.applyMinimizedLayout()
    }

    func preferredInsertTargetPID() -> pid_t? {
        if let pid = self.lastExternalAppPID, pid > 0 { return pid }
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
            return front?.processIdentifier
        }
        return nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if self.shouldConfirmCloseWhileListening {
            self.model.showCloseConfirmation = true
            self.makeKeyForInteraction()
            return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        self.persistFrame()
        self.dismissCaptions()
    }

    func windowDidMove(_ notification: Notification) {
        self.persistFrame()
    }

    func windowDidResize(_ notification: Notification) {
        self.persistFrame()
    }

    private func dismissCaptions() {
        guard !self.isDismissing else { return }
        self.isDismissing = true
        SettingsStore.shared.theaterWindowEnabled = false
        self.model.isEditing = false
        LiveTranslationController.shared.theaterWasClosed()
        self.isDismissing = false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        self.rememberExternalApp()
    }

    static func captionDocument(committed: [String], draft: String) -> String {
        var lines = committed
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let current = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty, lines.last != current {
            lines.append(current)
        }
        return lines.joined(separator: "\n")
    }

    private func applyPresentedBoard() {
        if self.model.committed != self.boardCommitted { self.model.committed = self.boardCommitted }
        if self.model.committedIDs != self.boardIDs { self.model.committedIDs = self.boardIDs }
        if self.model.committedSources != self.boardSources { self.model.committedSources = self.boardSources }
        if self.model.pendingSources != self.boardPending { self.model.pendingSources = self.boardPending }
        if self.model.draft != self.liveDraft { self.model.draft = self.liveDraft }
        if self.model.source != self.liveSource { self.model.source = self.liveSource }
    }

    private func rememberExternalApp() {
        let front = NSWorkspace.shared.frontmostApplication
        if let pid = front?.processIdentifier,
           front?.bundleIdentifier != Bundle.main.bundleIdentifier
        {
            self.lastExternalAppPID = pid
        }
    }

    private func observeSettings() {
        guard self.settingsCancellables.isEmpty else { return }
        SettingsStore.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.applyWindowSharing()
                    self?.applyPresentationStyle()
                }
            }
            .store(in: &self.settingsCancellables)
    }

    private func applyWindowSharing() {
        guard let panel = self.panel else { return }
        TheaterWindowSharing.apply(
            panel,
            hideFromScreenShare: SettingsStore.shared.theaterHideFromScreenShare
        )
    }

    private func applyPresentationStyle() {
        guard let panel = self.panel else { return }
        let transparent = SettingsStore.shared.theaterPresentation == .transparent
        panel.hasShadow = !transparent
        panel.isOpaque = false
        panel.backgroundColor = .clear
    }

    private static func makePanel(model: PresenterCaptionModel) -> NSPanel {
        let view = PresenterCaptionView(model: model)
        let hosting = NSHostingController(rootView: view)
        let panel = NSPanel(
            contentRect: NSRect(x: 80, y: 80, width: 1100, height: 440),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "\(FluidProduct.displayName) Theater"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentViewController = hosting
        panel.minSize = NSSize(width: 640, height: 260)
        panel.setContentSize(NSSize(width: 1100, height: 440))
        TheaterWindowSharing.apply(
            panel,
            hideFromScreenShare: SettingsStore.shared.theaterHideFromScreenShare
        )
        if let screen = Self.preferredScreen() {
            let frame = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.minY + 48
            ))
        }
        return panel
    }

    private func persistFrame() {
        guard let panel = self.panel, panel.isVisible else { return }
        SettingsStore.shared.theaterScreenName = panel.screen?.localizedName ?? ""
        if SettingsStore.shared.theaterMinimized {
            return
        }
        let frame = NSStringFromRect(panel.frame)
        SettingsStore.shared.theaterWindowFrame = frame
        SettingsStore.shared.theaterExpandedWindowFrame = frame
    }

    private func applyMinimizedLayout() {
        guard let panel = self.panel else { return }
        let minimized = SettingsStore.shared.theaterMinimized
        if minimized {
            panel.minSize = NSSize(width: 480, height: 88)
            var frame = panel.frame
            if frame.height > 120 {
                SettingsStore.shared.theaterExpandedWindowFrame = NSStringFromRect(frame)
            }
            let height: CGFloat = 88
            frame.origin.y += frame.height - height
            frame.size.height = height
            panel.setFrame(frame, display: true, animate: true)
        } else {
            panel.minSize = NSSize(width: 640, height: 260)
            let stored = SettingsStore.shared.theaterExpandedWindowFrame
            if !stored.isEmpty {
                var restored = NSRectFromString(stored)
                if restored.height > 160 {
                    restored.origin.x = panel.frame.origin.x
                    restored.origin.y = panel.frame.maxY - restored.height
                    panel.setFrame(restored, display: true, animate: true)
                    return
                }
            }
            var frame = panel.frame
            if frame.height < 260 {
                let height: CGFloat = 440
                frame.origin.y -= height - frame.height
                frame.size.height = height
                panel.setFrame(frame, display: true, animate: true)
            }
        }
    }

    private func restoreFrame() {
        let stored = SettingsStore.shared.theaterWindowFrame
        guard !stored.isEmpty else { return }
        let frame = NSRectFromString(stored)
        guard frame.width > 200, frame.height > 160 else { return }
        let screen = Self.screen(named: SettingsStore.shared.theaterScreenName) ?? Self.preferredScreen()
        if let screen {
            let visible = screen.visibleFrame
            var placed = frame
            placed.size.width = max(placed.width, 640)
            placed.size.height = max(placed.height, 260)
            if !visible.intersects(placed) {
                placed.origin.x = visible.midX - placed.width / 2
                placed.origin.y = visible.minY + 48
            }
            self.panel?.setFrame(placed, display: true)
        } else {
            var placed = frame
            placed.size.width = max(placed.width, 640)
            placed.size.height = max(placed.height, 260)
            self.panel?.setFrame(placed, display: true)
        }
    }

    private static func preferredScreen() -> NSScreen? {
        if let named = Self.screen(named: SettingsStore.shared.theaterScreenName) {
            return named
        }
        return NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private static func screen(named name: String) -> NSScreen? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return NSScreen.screens.first { $0.localizedName == trimmed }
    }

    func exportCaptions(format: TheaterExportFormat) {
        let pairs = LiveTranslationController.shared.subscriber.exportCaptionPairs
        let text: String
        let ext: String
        switch format {
        case .bilingualText:
            text = TheaterCaptionExport.bilingualText(pairs: pairs)
            ext = "txt"
        case .srt:
            text = TheaterCaptionExport.srt(pairs: pairs)
            ext = "srt"
        case .vtt:
            text = TheaterCaptionExport.vtt(pairs: pairs)
            ext = "vtt"
        }
        guard !text.isEmpty else { return }
        self.makeKeyForInteraction()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = TheaterCaptionExport.savePanelName(extension: ext)
        panel.begin { response in
            if response == .OK, let url = panel.url {
                try? text.write(to: url, atomically: true, encoding: .utf8)
            }
            PresenterCaptionController.shared.scheduleReleaseKeyToExternalApp()
        }
    }
}

enum TheaterExportFormat {
    case bilingualText
    case srt
    case vtt
}

@MainActor
final class PresenterCaptionModel: ObservableObject {
    @Published var committed: [String] = []
    @Published var committedIDs: [UInt64] = []
    @Published var committedSources: [String] = []
    @Published var pendingSources: [String] = []
    @Published var source: String = ""
    @Published var draft: String = ""
    @Published var pairLabel: String = ""
    @Published var status: String = ""
    @Published var statusKind: TheaterStatusKind = .idle
    @Published var isListening: Bool = false
    @Published var isPaused: Bool = false
    @Published var isEditing: Bool = false
    @Published var editedText: String = ""
    @Published var canRetryTranslation: Bool = false
    @Published var approachingLineLimit: Bool = false
    @Published var latencyReadout: String = ""
    @Published var compactLatencyReadout: String = ""
    @Published var showCloseConfirmation: Bool = false
}

enum TheaterTypeface: String, CaseIterable, Identifiable {
    case system
    case helveticaNeue = "Helvetica Neue"
    case avenirNext = "Avenir Next"
    case georgia = "Georgia"
    case palatino = "Palatino"
    case menlo = "Menlo"
    case gothicNeo = "Apple SD Gothic Neo"
    case thonburi = "Thonburi"

    var id: String { self.rawValue }

    var displayName: String {
        self == .system ? "System" : self.rawValue
    }

    static func resolved(_ stored: String) -> TheaterTypeface {
        Self(rawValue: stored.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .system
    }

    var postScriptName: String? {
        switch self {
        case .system:
            return nil
        case .helveticaNeue:
            return "HelveticaNeue"
        case .avenirNext:
            return "AvenirNext-DemiBold"
        case .georgia:
            return "Georgia"
        case .palatino:
            return "Palatino-Roman"
        case .menlo:
            return "Menlo-Regular"
        case .gothicNeo:
            return "AppleSDGothicNeo-SemiBold"
        case .thonburi:
            return "Thonburi"
        }
    }

    func font(size: CGFloat, weight: Font.Weight) -> Font {
        if let name = self.postScriptName {
            return .custom(name, size: size)
        }
        return .system(size: size, weight: weight)
    }

    func nsFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        if let name = self.postScriptName, let named = NSFont(name: name, size: size) {
            return named
        }
        if self != .system, let family = NSFontManager.shared.font(
            withFamily: self.rawValue,
            traits: [],
            weight: 7,
            size: size
        ) {
            return family
        }
        return .systemFont(ofSize: size, weight: weight)
    }
}

private struct TheaterBoardHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct TheaterFlowLine: Equatable, Identifiable {
    let id: String
    let text: String
    let source: String
    let isCurrent: Bool
    let isDraft: Bool
}

enum TheaterPresentationStyle: String, CaseIterable, Identifiable {
    case popup
    case transparent

    var id: String { self.rawValue }

    var displayName: String {
        switch self {
        case .popup: return "Pop-up"
        case .transparent: return "Transparent"
        }
    }

    var symbol: String {
        switch self {
        case .popup: return "rectangle.on.rectangle"
        case .transparent: return "rectangle.dashed"
        }
    }

    var help: String {
        switch self {
        case .popup: return TheaterReadiness.popupStyle
        case .transparent: return TheaterReadiness.transparentStyle
        }
    }

    var toggled: TheaterPresentationStyle {
        self == .popup ? .transparent : .popup
    }

    static func resolved(_ stored: String?) -> TheaterPresentationStyle {
        let trimmed = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Self(rawValue: trimmed) ?? .popup
    }
}

enum TheaterAppearance: String, CaseIterable, Identifiable {
    case dark
    case light

    var id: String { self.rawValue }

    var displayName: String {
        switch self {
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }

    var toggleSymbol: String {
        switch self {
        case .dark: return "sun.max.fill"
        case .light: return "moon.fill"
        }
    }

    var toggleHelp: String {
        switch self {
        case .dark: return "Light mode"
        case .light: return "Dark mode"
        }
    }

    var colorScheme: ColorScheme {
        self == .light ? .light : .dark
    }

    var toggled: TheaterAppearance {
        self == .dark ? .light : .dark
    }

    static func resolved(_ stored: String?) -> TheaterAppearance {
        let trimmed = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Self(rawValue: trimmed) ?? .dark
    }
}

private struct TheaterWindowAppearanceBridge: NSViewRepresentable {
    var appearance: TheaterAppearance

    func makeNSView(context: Context) -> TheaterAppearanceHostView {
        let view = TheaterAppearanceHostView()
        view.apply(self.appearance)
        return view
    }

    func updateNSView(_ view: TheaterAppearanceHostView, context: Context) {
        view.apply(self.appearance)
    }
}

private final class TheaterAppearanceHostView: NSView {
    private var appearanceName: NSAppearance.Name = .darkAqua

    func apply(_ appearance: TheaterAppearance) {
        self.appearanceName = appearance == .light ? .aqua : .darkAqua
        self.applyToWindow()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.applyToWindow()
    }

    private func applyToWindow() {
        self.window?.appearance = NSAppearance(named: self.appearanceName)
        self.window?.isOpaque = false
        self.window?.backgroundColor = .clear
    }
}

enum TheaterCaptionPalette {
    static let spoken = Color(red: 1.0, green: 0.76, blue: 0.42)
    static let spokenNS = NSColor(calibratedRed: 1.0, green: 0.76, blue: 0.42, alpha: 1)
}

enum TheaterLinePrinter {
    /// One chunk per tick. Slow enough to read as a visual aid.
    static let printStepSeconds: TimeInterval = 0.15

    enum EmptyTarget {
        /// Keep what is already on screen. Used when ASR flickers blank.
        case hold
        /// Take back one chunk. Used when a translation is withdrawn.
        case retract
    }

    static func extend(_ shown: String, toward target: String) -> String {
        if target.isEmpty { return shown }
        if shown.isEmpty {
            return Self.openingChunk(in: target)
        }
        if shown == target { return target }
        if target.hasPrefix(shown) {
            let rest = String(target.dropFirst(shown.count))
            return shown + Self.nextChunk(in: rest)
        }
        return shown
    }

    /// Once a caption is on screen, only grow it. A later ASR or polish
    /// ending must not retract the line the audience is already reading.
    static func shouldAdoptPrintedCaption(
        currentSpoken: String,
        currentTranslated: String,
        nextSpoken: String,
        nextTranslated: String
    ) -> Bool {
        if nextSpoken.isEmpty, nextTranslated.isEmpty {
            return currentSpoken.isEmpty && currentTranslated.isEmpty
        }
        if currentSpoken.isEmpty, currentTranslated.isEmpty { return true }
        if nextSpoken == currentSpoken, nextTranslated == currentTranslated { return true }
        let spokenGrows = nextSpoken.hasPrefix(currentSpoken) || currentSpoken.hasPrefix(nextSpoken)
        let translatedGrows = nextTranslated.isEmpty
            || currentTranslated.isEmpty
            || nextTranslated.hasPrefix(currentTranslated)
            || currentTranslated.hasPrefix(nextTranslated)
        return spokenGrows && translatedGrows
    }

    /// The live row reuses one NSView. A new clause must start a fresh print
    /// instead of holding the previous sentence. A revision of the same line
    /// still stays on screen.
    static func shouldStartNewCaption(
        currentSpoken: String,
        currentTranslated: String,
        nextSpoken: String,
        nextTranslated: String
    ) -> Bool {
        if nextSpoken.isEmpty, nextTranslated.isEmpty { return false }
        if currentSpoken.isEmpty, currentTranslated.isEmpty { return false }
        if self.shouldAdoptPrintedCaption(
            currentSpoken: currentSpoken,
            currentTranslated: currentTranslated,
            nextSpoken: nextSpoken,
            nextTranslated: nextTranslated
        ) {
            return false
        }
        if !nextSpoken.isEmpty, self.isContinuation(currentSpoken, of: nextSpoken) { return false }
        if !nextTranslated.isEmpty, !currentTranslated.isEmpty,
           self.isContinuation(currentTranslated, of: nextTranslated)
        {
            return false
        }
        return true
    }

    /// Grow or correct one chunk. Never replace the line with a different clause.
    static func follow(
        _ shown: String,
        toward target: String,
        emptyTarget: EmptyTarget = .hold
    ) -> String {
        if target.isEmpty {
            switch emptyTarget {
            case .hold:
                return shown
            case .retract:
                return shown.isEmpty ? "" : Self.dropLastChunk(shown)
            }
        }
        if shown.isEmpty {
            return Self.openingChunk(in: target)
        }
        if shown == target { return target }
        if target.hasPrefix(shown) {
            return Self.extend(shown, toward: target)
        }
        if shown.hasPrefix(target) {
            return Self.retract(shown, downTo: target)
        }
        if let shared = Self.stableSharedPrefix(shown, target) {
            return Self.retract(shown, downTo: shared)
        }
        return shown
    }

    static func advance(
        _ shown: String,
        toward target: String,
        emptyTarget: EmptyTarget = .hold
    ) -> String {
        Self.follow(shown, toward: target, emptyTarget: emptyTarget)
    }

    static func isContinuation(_ shown: String, of target: String) -> Bool {
        if shown.isEmpty || target.isEmpty { return true }
        if target.hasPrefix(shown) || shown.hasPrefix(target) { return true }
        return Self.stableSharedPrefix(shown, target) != nil
    }

    static func stableSharedPrefix(_ shown: String, _ target: String) -> String? {
        let shared = shown.commonPrefix(with: target)
        if shared.count >= 4 { return shared }
        let shownWord = shown.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        let targetWord = target.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        if shownWord.count >= 2, shownWord == targetWord {
            return shownWord
        }
        return nil
    }

    static func retract(_ shown: String, downTo prefix: String) -> String {
        if shown == prefix { return prefix }
        if prefix.isEmpty { return Self.dropLastChunk(shown) }
        if !shown.hasPrefix(prefix) { return shown }
        let next = Self.dropLastChunk(shown)
        if next.count < prefix.count || !next.hasPrefix(prefix) {
            return prefix
        }
        return next
    }

    static func dropLastChunk(_ shown: String) -> String {
        guard let last = shown.last else { return "" }
        if last.isWhitespace {
            return Self.dropLast(shown) { $0.isWhitespace }
        }
        if last.isASCII, last.isLetter || last.isNumber {
            let withoutWord = Self.dropLast(shown) { $0.isASCII && ($0.isLetter || $0.isNumber) }
            return Self.dropLast(withoutWord) { $0.isWhitespace }
        }
        return String(shown.dropLast())
    }

    private static func dropLast(_ shown: String, while shouldDrop: (Character) -> Bool) -> String {
        var end = shown.endIndex
        while end > shown.startIndex {
            let previous = shown.index(before: end)
            guard shouldDrop(shown[previous]) else { break }
            end = previous
        }
        return String(shown[..<end])
    }

    /// Do not land the first paint on "It" / "The" / "So" alone.
    private static func openingChunk(in target: String) -> String {
        let first = self.nextChunk(in: target)
        guard !first.isEmpty else { return "" }
        let isLatinWord = first.contains { $0.isASCII && ($0.isLetter || $0.isNumber) }
        guard isLatinWord, TranslationClauseSegmenter.isThinEnglishStarter(first) else {
            return first
        }
        var shown = first
        var remaining = String(target.dropFirst(first.count))
        var words = 1
        while words < 4, !remaining.isEmpty {
            let next = self.nextChunk(in: remaining)
            if next.isEmpty { break }
            shown += next
            remaining = String(remaining.dropFirst(next.count))
            if next.contains(where: { $0.isASCII && ($0.isLetter || $0.isNumber) }) {
                words += 1
            }
        }
        return shown
    }

    private static func nextChunk(in rest: String) -> String {
        guard let first = rest.first else { return "" }
        if first.isWhitespace {
            let spaces = rest.prefix(while: { $0.isWhitespace })
            let after = rest.drop(while: { $0.isWhitespace })
            let word = after.prefix(while: { !$0.isWhitespace })
            return String(spaces + word)
        }
        if first.isASCII, first.isLetter || first.isNumber {
            let latin = rest.prefix(while: { $0.isASCII && ($0.isLetter || $0.isNumber) })
            return String(latin)
        }
        return String(first)
    }
}

enum TheaterCaptionFlow {
    static let currentLineID = "live"

    static func lines(
        committed: [String],
        committedIDs: [UInt64] = [],
        committedSources: [String] = [],
        draft: String,
        sourceDraft: String = "",
        pendingSources _: [String] = [],
        separateSpokenLine: Bool = false
    ) -> [TheaterFlowLine] {
        let history = committed
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .enumerated()
            .filter { !$0.element.isEmpty }
        let draftText = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let spoken = sourceDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastSource = committedSources.last {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var liveText = ""
        var liveSource = ""
        let unreadSpoken = !spoken.isEmpty
            && spoken != history.last?.element
            && spoken != lastSource
        if !draftText.isEmpty, history.last?.element != draftText {
            liveText = draftText
            if unreadSpoken, spoken != draftText {
                liveSource = spoken
            }
        } else if unreadSpoken {
            if separateSpokenLine {
                liveSource = spoken
            } else {
                liveText = spoken
            }
        }

        let hasLive = !liveText.isEmpty || !liveSource.isEmpty
        let room = max(LiveTranslationTiming.visibleTheaterLines - (hasLive ? 1 : 0), 1)
        let visibleHistory = Array(history.suffix(room))

        var result: [TheaterFlowLine] = visibleHistory.map { index, text in
            let id = index < committedIDs.count ? "c-\(committedIDs[index])" : "c-\(index)"
            let source = index < committedSources.count ? committedSources[index] : ""
            return TheaterFlowLine(id: id, text: text, source: source, isCurrent: false, isDraft: false)
        }

        if hasLive {
            result.append(TheaterFlowLine(
                id: Self.currentLineID,
                text: liveText,
                source: liveSource,
                isCurrent: true,
                isDraft: true
            ))
        } else if var last = result.popLast() {
            last = TheaterFlowLine(
                id: Self.currentLineID,
                text: last.text,
                source: last.source,
                isCurrent: true,
                isDraft: last.isDraft
            )
            result.append(last)
        }
        return result
    }
}

struct PresenterCaptionView: View {
    @ObservedObject var model: PresenterCaptionModel
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var controller = LiveTranslationController.shared
    @ObservedObject private var asr = AppServices.shared.asr
    @State private var chromeRevealed = false
    @State private var chromePinned = false
    @State private var showClearConfirmation = false

    private var appearance: TheaterAppearance {
        TheaterAppearance.resolved(self.settings.theaterAppearance)
    }

    private var theme: AppTheme {
        AppTheme.adaptive(accent: self.settings.accentColor, colorScheme: self.appearance.colorScheme)
    }

    private var spokenNS: NSColor {
        NSColor(self.theme.palette.accent)
    }

    private var translatedNS: NSColor {
        NSColor(self.theme.palette.primaryText)
    }

    var body: some View {
        self.theaterContent
            .appTheme(self.theme)
            .preferredColorScheme(self.appearance.colorScheme)
            .tint(self.theme.palette.accent)
            .background(TranslationSessionHost())
            .background(TheaterWindowAppearanceBridge(appearance: self.appearance))
            .onHover { hovering in
                self.chromeRevealed = hovering
            }
            .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
                self.chromePinned = true
            }
            .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
                self.chromePinned = false
                PresenterCaptionController.shared.releaseKeyToExternalApp()
            }
            .alert("Clear captions?", isPresented: self.$showClearConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Clear", role: .destructive) {
                    self.controller.clearBoard()
                }
            } message: {
                Text(TheaterReadiness.clearCaptionsConfirm)
            }
            .alert(
                "Stop Listen and close Theater?",
                isPresented: self.$model.showCloseConfirmation
            ) {
                Button("Cancel", role: .cancel) {
                    PresenterCaptionController.shared.cancelCloseWhileListening()
                }
                Button("Close", role: .destructive) {
                    PresenterCaptionController.shared.confirmCloseWhileListening()
                }
            } message: {
                Text(TheaterReadiness.closeWhileListeningConfirm)
            }
    }

    private var theaterContent: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
            self.persistentChrome
            if !self.settings.theaterMinimized {
                if self.showsChrome {
                    self.extendedChrome
                }
                if self.model.isEditing {
                    TheaterTextEditor(
                        text: self.$model.editedText,
                        typeface: self.typeface,
                        fontSize: CGFloat(self.settings.presenterFontSize),
                        textColor: self.translatedNS
                    )
                    .padding(.top, self.theme.metrics.spacing.xs)
                } else {
                    self.presentationStage
                }
            }
        }
        .padding(.horizontal, self.theme.metrics.spacing.xxl)
        .padding(.top, 36)
        .padding(.bottom, self.theme.metrics.spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(self.theaterFill)
        .background {
            if self.presentationStyle == .popup, !self.settings.theaterHighContrast {
                Rectangle().fill(self.theme.materials.window)
            }
        }
    }

    private var presentationStyle: TheaterPresentationStyle {
        self.settings.theaterPresentation
    }

    private var theaterFill: Color {
        switch self.presentationStyle {
        case .transparent:
            return Color.clear
        case .popup:
            return self.theme.palette.windowBackground.opacity(self.settings.theaterHighContrast ? 1 : 0.94)
        }
    }

    private var showsChrome: Bool {
        !self.settings.theaterHideChrome
            || self.chromeRevealed
            || self.chromePinned
            || self.model.isEditing
    }

    private var typeface: TheaterTypeface {
        TheaterTypeface.resolved(self.settings.presenterFontFamily)
    }

    private var languagePairControls: some View {
        ViewThatFits(in: .horizontal) {
            self.languagePairRow(showsLabels: true)
            self.languagePairRow(showsLabels: false)
        }
        .layoutPriority(2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("theater.window.languages")
    }

    private func languagePairRow(showsLabels: Bool) -> some View {
        HStack(spacing: self.theme.metrics.spacing.sm) {
            if showsLabels {
                Text("I speak")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .lineLimit(1)
            }
            self.languageMenu(
                title: "I speak",
                selection: self.sourceLanguageID,
                languages: TranslationLanguageCatalog.all
            )

            Button {
                PresenterCaptionController.shared.performChromeAction {
                    self.controller.swapDirection()
                }
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(SpokenLanguageResolver.isSameLanguagePair())
            .help("Swap spoken and translated languages")
            .accessibilityLabel("Swap languages")

            if showsLabels {
                Text("Show as")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .lineLimit(1)
            }
            self.languageMenu(
                title: "Show as",
                selection: self.targetLanguageID,
                languages: self.targetLanguages
            )
        }
        .controlSize(.small)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func languageMenu(
        title: String,
        selection: Binding<String>,
        languages: [TranslationLanguage]
    ) -> some View {
        let selectedName = languages.first(where: { $0.id == selection.wrappedValue })?.displayName
            ?? TranslationLanguageCatalog.language(id: selection.wrappedValue)?.displayName
            ?? selection.wrappedValue
        return Menu {
            ForEach(languages) { language in
                Button(language.displayName) {
                    PresenterCaptionController.shared.performChromeAction {
                        selection.wrappedValue = language.id
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(selectedName)
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(self.theme.palette.primaryText)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(minWidth: 96, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm, style: .continuous)
                    .fill(self.languageMenuFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm, style: .continuous)
                            .stroke(self.languageMenuStroke, lineWidth: 1)
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(selectedName)
    }

    private var languageMenuFill: Color {
        if self.appearance == .light {
            return self.theme.palette.cardBackground.opacity(0.96)
        }
        return Color.white.opacity(0.16)
    }

    private var languageMenuStroke: Color {
        if self.appearance == .light {
            return Color.black.opacity(0.28)
        }
        return Color.white.opacity(0.42)
    }

    private var sourceLanguageID: Binding<String> {
        Binding(
            get: { SpokenLanguageResolver.sourceLanguage().id },
            set: { id in
                PresenterCaptionController.shared.performChromeAction {
                    self.controller.applySourceLanguage(id)
                }
            }
        )
    }

    private var targetLanguageID: Binding<String> {
        Binding(
            get: { SpokenLanguageResolver.targetLanguage().id },
            set: { id in
                PresenterCaptionController.shared.performChromeAction {
                    self.controller.applyTargetLanguage(id)
                }
            }
        )
    }

    private var targetLanguages: [TranslationLanguage] {
        TranslationLanguageCatalog.targets(excluding: SpokenLanguageResolver.sourceLanguage())
    }

    private var persistentChrome: some View {
        ViewThatFits(in: .horizontal) {
            self.persistentChromeRow(showsTheme: true, compactTheme: false)
            self.persistentChromeRow(showsTheme: true, compactTheme: true)
            self.persistentChromeRow(showsTheme: false, compactTheme: true)
        }
    }

    private func persistentChromeRow(showsTheme: Bool, compactTheme: Bool) -> some View {
        HStack(alignment: .center, spacing: self.theme.metrics.spacing.md) {
            self.languagePairControls
            self.windowModePicker
            if self.settings.theaterSessionMode == .watch {
                WatchSourcePicker(
                    compact: true,
                    showsCheckCapture: true,
                    accessibilityIdentifier: "theater.window.watchSource"
                )
                .fixedSize()
            }
            Spacer(minLength: self.theme.metrics.spacing.sm)
            if self.model.canRetryTranslation {
                Button("Retry") {
                    PresenterCaptionController.shared.performChromeAction {
                        self.controller.retryFailedTranslation()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Retry the last failed translation.")
                if !SpokenLanguageResolver.isSameLanguagePair() {
                    Button("Download pack") {
                        PresenterCaptionController.shared.performChromeAction {
                            AppleTranslationEngine.shared.requestLanguagePackDownload()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Download the Apple Translation pack for this pair.")
                }
            }
            if !self.showsChrome, !self.model.compactLatencyReadout.isEmpty {
                Text(self.model.compactLatencyReadout)
                    .font(self.theme.typography.codeCaption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .lineLimit(1)
                    .help(TheaterReadiness.latencyHUD)
            }
            if showsTheme {
                self.appearancePicker(compact: compactTheme)
            }
            TheaterListenButton(
                usesChromeKey: true,
                listenIdentifier: "theater.window.listen",
                stopIdentifier: "theater.window.stop",
                pauseIdentifier: "theater.pause"
            )
            .layoutPriority(1)
            self.captionsOnlyButton
            self.minimizeButton
        }
    }

    private var windowModePicker: some View {
        Picker("Theater mode", selection: Binding(
            get: { self.settings.theaterSessionMode },
            set: { newMode in
                PresenterCaptionController.shared.performChromeAction {
                    if self.settings.theaterSessionMode != newMode,
                       self.controller.isSessionActive,
                       self.controller.listenKind == .captions
                    {
                        self.controller.stopListening()
                    }
                    self.settings.theaterSessionMode = newMode
                }
            }
        )) {
            ForEach(TheaterSessionMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.small)
        .frame(width: 150)
        .help(TheaterReadiness.modeStopsListen)
        .accessibilityLabel("Theater mode")
        .accessibilityIdentifier("theater.window.mode")
    }

    private var extendedChrome: some View {
        HStack(spacing: self.theme.metrics.spacing.sm) {
            if !self.model.latencyReadout.isEmpty {
                Text(self.model.latencyReadout)
                    .font(self.theme.typography.codeCaption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .lineLimit(1)
                    .help(TheaterReadiness.latencyHUD)
            }
            if !self.model.status.isEmpty {
                Text(self.model.status)
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(
                        self.model.statusKind.usesWarningColor
                            ? self.theme.palette.warning
                            : self.theme.palette.secondaryText
                    )
                    .lineLimit(1)
                    .accessibilityIdentifier("theater.status")
            }
            Spacer(minLength: self.theme.metrics.spacing.sm)
            self.typographyControls
        }
    }

    private var appearanceBinding: Binding<TheaterAppearance> {
        Binding(
            get: { self.appearance },
            set: { newValue in
                PresenterCaptionController.shared.performChromeAction {
                    self.settings.theaterAppearance = newValue.rawValue
                }
            }
        )
    }

    private func appearancePicker(compact: Bool) -> some View {
        HStack(spacing: self.theme.metrics.spacing.sm) {
            if !compact {
                Text("Theme")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
            Picker("Theme", selection: self.appearanceBinding) {
                ForEach(TheaterAppearance.allCases) { appearance in
                    Text(appearance.displayName).tag(appearance)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 140)
            .help("Theater theme. Dark or Light, independent of the main window.")
            .accessibilityLabel("Theater theme")
            .accessibilityIdentifier("theater.appearance")
        }
        .controlSize(.small)
        .fixedSize()
        .layoutPriority(0)
    }

    private var moreMenu: some View {
        Menu {
            Button(self.model.isEditing ? "Done" : "Edit captions") {
                self.toggleEditing()
            }
            Menu("Export") {
                Button("Bilingual text") {
                    PresenterCaptionController.shared.exportCaptions(format: .bilingualText)
                }
                Button("SRT") {
                    PresenterCaptionController.shared.exportCaptions(format: .srt)
                }
                .help(TheaterReadiness.timedExportHonesty)
                Button("VTT") {
                    PresenterCaptionController.shared.exportCaptions(format: .vtt)
                }
                .help(TheaterReadiness.timedExportHonesty)
            }
            .disabled(self.model.committed.isEmpty)
            Divider()
            Button("Close Theater") {
                PresenterCaptionController.shared.requestClose()
            }
            .help(TheaterReadiness.closeWhileListening)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
        }
        .help("More")
        .accessibilityLabel("More")
        .menuIndicator(.hidden)
        .buttonStyle(SquareIconButtonStyle())
        .controlSize(.small)
    }

    private var minimizeButton: some View {
        Button {
            PresenterCaptionController.shared.performChromeAction {
                PresenterCaptionController.shared.toggleMinimized()
            }
        } label: {
            Image(systemName: self.settings.theaterMinimized ? "arrow.up.left.and.arrow.down.right" : "minus")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(SquareIconButtonStyle())
        .controlSize(.small)
        .help(self.settings.theaterMinimized ? "Show the caption board" : "Minimize to a pill. The session stays.")
        .accessibilityLabel(self.settings.theaterMinimized ? "Expand Theater" : "Minimize Theater")
        .accessibilityIdentifier("theater.minimize")
    }

    private var captionsOnlyButton: some View {
        Button {
            PresenterCaptionController.shared.performChromeAction {
                self.settings.theaterHideChrome.toggle()
            }
        } label: {
            Image(systemName: self.settings.theaterHideChrome ? "rectangle.inset.filled" : "rectangle")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(SquareIconButtonStyle())
        .controlSize(.small)
        .help(
            self.settings.theaterHideChrome
                ? "Show all controls"
                : "Captions only. Languages, Listen, and this control stay visible. Move the pointer to reveal the rest."
        )
        .accessibilityLabel(self.settings.theaterHideChrome ? "Show all controls" : "Captions only")
        .accessibilityIdentifier("theater.window.captionsOnly")
    }

    private var typographyControls: some View {
        HStack(spacing: self.theme.metrics.spacing.xs) {
            Menu {
                ForEach(TheaterTypeface.allCases) { face in
                    Button {
                        PresenterCaptionController.shared.performChromeAction {
                            self.settings.presenterFontFamily = face.rawValue
                        }
                    } label: {
                        if face == self.typeface {
                            Label(face.displayName, systemImage: "checkmark")
                        } else {
                            Text(face.displayName)
                        }
                    }
                }
            } label: {
                Image(systemName: "textformat")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .help("Caption font. \(self.typeface.displayName).")
            .accessibilityLabel("Caption font")
            .menuIndicator(.hidden)

            Button {
                self.nudgeFontSize(-2)
            } label: {
                Image(systemName: "textformat.size.smaller")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .disabled(self.settings.presenterFontSize <= SettingsStore.presenterFontSizeRange.lowerBound)
            .help("Smaller captions. \(self.settings.presenterFontSize) pt.")
            .accessibilityLabel("Smaller captions")

            Button {
                self.nudgeFontSize(2)
            } label: {
                Image(systemName: "textformat.size.larger")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .disabled(self.settings.presenterFontSize >= SettingsStore.presenterFontSizeRange.upperBound)
            .help("Larger captions. \(self.settings.presenterFontSize) pt.")
            .accessibilityLabel("Larger captions")

            Button {
                self.controller.copyCaptionText()
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .disabled(self.deliveryIsEmpty)
            .help("Copy all")
            .accessibilityLabel("Copy all")
            .accessibilityIdentifier("theater.window.copy")

            Button {
                self.controller.insertCaptionText()
            } label: {
                Image(systemName: "text.insert")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .disabled(self.insertIsEmpty)
            .help(TheaterReadiness.insertHelp)
            .accessibilityLabel("Type into app")
            .accessibilityIdentifier("theater.window.insert")

            Button {
                PresenterCaptionController.shared.performChromeAction {
                    self.controller.undoLastCaption()
                }
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .disabled(!self.controller.hasUndoableCaption || self.model.isEditing)
            .help(TheaterReadiness.undoLastCaption)
            .accessibilityLabel("Undo last caption")
            .accessibilityIdentifier("theater.window.undo")

            Button {
                self.showClearConfirmation = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .disabled(!self.controller.hasClearableBoard)
            .help(TheaterReadiness.clearCaptions)
            .accessibilityLabel("Clear captions")
            .accessibilityIdentifier("theater.window.clear")

            self.boardMenu
            self.moreMenu
        }
        .buttonStyle(SquareIconButtonStyle())
        .controlSize(.small)
    }

    private var boardMenu: some View {
        Menu {
            Button {
                PresenterCaptionController.shared.performChromeAction {
                    self.settings.translationShowSource.toggle()
                }
            } label: {
                if self.settings.translationShowSource {
                    Label("Show the spoken line", systemImage: "checkmark")
                } else {
                    Text("Show the spoken line")
                }
            }
            .disabled(SpokenLanguageResolver.isSameLanguagePair())
            .help(
                SpokenLanguageResolver.isSameLanguagePair()
                    ? TheaterReadiness.spokenLineSameLanguage
                    : "Show what you said above the translation so both rooms can follow."
            )

            Button {
                PresenterCaptionController.shared.performChromeAction {
                    self.settings.theaterHighContrast.toggle()
                }
            } label: {
                if self.settings.theaterHighContrast {
                    Label("High contrast", systemImage: "checkmark")
                } else {
                    Text("High contrast")
                }
            }

            Divider()

            Button {
                PresenterCaptionController.shared.performChromeAction {
                    self.settings.theaterPresentationStyle = TheaterPresentationStyle.popup.rawValue
                }
            } label: {
                if self.presentationStyle == .popup {
                    Label(TheaterPresentationStyle.popup.displayName, systemImage: "checkmark")
                } else {
                    Text(TheaterPresentationStyle.popup.displayName)
                }
            }
            .help(TheaterReadiness.popupStyle)

            Button {
                PresenterCaptionController.shared.performChromeAction {
                    self.settings.theaterPresentationStyle = TheaterPresentationStyle.transparent.rawValue
                }
            } label: {
                if self.presentationStyle == .transparent {
                    Label(TheaterPresentationStyle.transparent.displayName, systemImage: "checkmark")
                } else {
                    Text(TheaterPresentationStyle.transparent.displayName)
                }
            }
            .help(TheaterReadiness.transparentStyle)

            Button {
                PresenterCaptionController.shared.performChromeAction {
                    self.settings.theaterHideFromScreenShare.toggle()
                }
            } label: {
                if self.settings.theaterHideFromScreenShare {
                    Label("Hide from screen share", systemImage: "checkmark")
                } else {
                    Text("Hide from screen share")
                }
            }
            .help(TheaterReadiness.hideFromScreenShare)
            .accessibilityIdentifier("theater.hideFromScreenShare")
        } label: {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
        }
        .help("Board")
        .accessibilityLabel("Board")
        .accessibilityIdentifier("theater.presentationStyle")
        .menuIndicator(.hidden)
    }

    private var presentationStage: some View {
        let fontSize = CGFloat(self.settings.presenterFontSize)
        let lines = TheaterCaptionFlow.lines(
            committed: self.model.committed,
            committedIDs: self.model.committedIDs,
            committedSources: self.model.committedSources,
            draft: self.model.draft,
            sourceDraft: self.model.source,
            pendingSources: self.model.pendingSources,
            separateSpokenLine: self.settings.translationShowSource
                && !SpokenLanguageResolver.isSameLanguagePair()
        )
        return GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if lines.isEmpty {
                            Text(self.emptyStateText)
                                .font(self.theme.typography.body)
                                .foregroundStyle(self.theme.palette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            ForEach(lines) { line in
                                TheaterCaptionLineLabel(
                                    text: line.text,
                                    source: self.spokenLine(for: line),
                                    isCurrent: line.isCurrent,
                                    prints: line.isDraft,
                                    typeface: self.typeface,
                                    fontSize: fontSize,
                                    spokenColor: self.spokenNS,
                                    translatedColor: self.translatedNS,
                                    highContrast: self.settings.theaterHighContrast
                                        || self.presentationStyle == .transparent,
                                    lightBackground: self.appearance == .light
                                        && self.presentationStyle == .popup
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                            }
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("theater-bottom")
                    }
                    .frame(width: geometry.size.width, alignment: .leading)
                    .padding(.top, 4)
                    .background {
                        GeometryReader { board in
                            Color.clear.preference(
                                key: TheaterBoardHeightKey.self,
                                value: board.size.height
                            )
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .onChange(of: lines.map(\.id)) { _, _ in
                    withAnimation(.easeInOut(duration: 0.28)) {
                        proxy.scrollTo("theater-bottom", anchor: .bottom)
                    }
                }
                .onChange(of: lines.last?.text) { _, _ in
                    withAnimation(.easeInOut(duration: 0.28)) {
                        proxy.scrollTo("theater-bottom", anchor: .bottom)
                    }
                }
                .onChange(of: lines.last?.source) { _, _ in
                    withAnimation(.easeInOut(duration: 0.28)) {
                        proxy.scrollTo("theater-bottom", anchor: .bottom)
                    }
                }
                .onPreferenceChange(TheaterBoardHeightKey.self) { _ in
                    proxy.scrollTo("theater-bottom", anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var readySnapshot: TheaterReadyGate.Snapshot {
        TheaterReadyGate.liveSnapshot(
            pack: self.controller.packAvailability,
            microphone: self.asr.micStatus,
            firstCaptionPrinted: self.settings.theaterListenUsed
        )
    }

    private var emptyStateText: String {
        if !self.model.status.isEmpty { return self.model.status }
        if self.model.isPaused {
            return "Paused"
        }
        if self.model.isListening {
            return self.settings.theaterSessionMode == .watch
                ? TheaterReadiness.watchListeningCopy(
                    sourceTitle: WatchSourceSettings.displayTitle(self.settings)
                )
                : TheaterReadiness.listeningEmpty
        }
        if !self.readySnapshot.canListen {
            return self.readySnapshot.nextAction
        }
        return TheaterReadiness.pressListen
    }

    private func spokenLine(for line: TheaterFlowLine) -> String {
        if SpokenLanguageResolver.isSameLanguagePair() { return "" }
        if self.settings.translationShowSource {
            return line.source
        }
        return ""
    }

    private func nudgeFontSize(_ delta: Int) {
        PresenterCaptionController.shared.performChromeAction {
            self.settings.presenterFontSize += delta
        }
    }

    // Both run on every body pass, so they must not rebuild the whole document.
    private var deliveryIsEmpty: Bool {
        !PresenterCaptionController.shared.hasDeliverableText
    }

    private var insertIsEmpty: Bool {
        if self.model.isEditing {
            return self.deliveryIsEmpty
        }
        return !self.controller.subscriber.hasPendingInsertText
    }

    private func toggleEditing() {
        if self.model.isEditing {
            PresenterCaptionController.shared.commitEdits()
            PresenterCaptionController.shared.scheduleReleaseKeyToExternalApp()
            return
        }
        PresenterCaptionController.shared.makeKeyForInteraction()
        self.model.editedText = PresenterCaptionController.shared.documentTextForDelivery()
        self.model.isEditing = true
    }
}

private struct TheaterCaptionLineLabel: NSViewRepresentable {
    var text: String
    var source: String
    var isCurrent: Bool
    var prints: Bool
    var typeface: TheaterTypeface
    var fontSize: CGFloat
    var spokenColor: NSColor
    var translatedColor: NSColor
    var highContrast: Bool
    var lightBackground: Bool

    func makeNSView(context: Context) -> TheaterCaptionLineNSView {
        let view = TheaterCaptionLineNSView()
        self.apply(to: view)
        return view
    }

    func updateNSView(_ view: TheaterCaptionLineNSView, context: Context) {
        self.apply(to: view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TheaterCaptionLineNSView, context: Context) -> CGSize {
        let width = max(proposal.width ?? nsView.bounds.width, 1)
        nsView.frame.size.width = width
        nsView.needsLayout = true
        nsView.layoutSubtreeIfNeeded()
        return CGSize(width: width, height: nsView.intrinsicContentSize.height)
    }

    private func apply(to view: TheaterCaptionLineNSView) {
        view.setCaption(
            spoken: self.source,
            translated: self.text,
            isCurrent: self.isCurrent,
            prints: self.prints,
            typeface: self.typeface,
            fontSize: self.fontSize,
            spokenColor: self.spokenColor,
            translatedColor: self.translatedColor,
            highContrast: self.highContrast,
            lightBackground: self.lightBackground
        )
    }
}

private final class TheaterCaptionLineNSView: NSView {
    private var lineViews: [NSTextField] = []
    private var targetSpoken = ""
    private var targetTranslated = ""
    private var printedSpoken = ""
    private var printedTranslated = ""
    private var printTimer: Timer?
    private var isCurrent = true
    private var captionFont = NSFont.systemFont(ofSize: 32, weight: .semibold)
    private var spokenColor = TheaterCaptionPalette.spokenNS
    private var translatedColor = NSColor.white
    private var captionShadow: NSShadow?
    private var lastWrapWidth: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.printTimer?.invalidate()
    }

    func setCaption(
        spoken: String,
        translated: String,
        isCurrent: Bool,
        prints: Bool,
        typeface: TheaterTypeface,
        fontSize: CGFloat,
        spokenColor: NSColor,
        translatedColor: NSColor,
        highContrast: Bool,
        lightBackground: Bool
    ) {
        if TheaterLinePrinter.shouldAdoptPrintedCaption(
            currentSpoken: self.targetSpoken,
            currentTranslated: self.targetTranslated,
            nextSpoken: spoken,
            nextTranslated: translated
        ) {
            self.targetSpoken = spoken
            self.targetTranslated = translated
        } else if TheaterLinePrinter.shouldStartNewCaption(
            currentSpoken: self.targetSpoken,
            currentTranslated: self.targetTranslated,
            nextSpoken: spoken,
            nextTranslated: translated
        ) {
            self.targetSpoken = spoken
            self.targetTranslated = translated
            self.printedSpoken = ""
            self.printedTranslated = ""
        }
        self.isCurrent = isCurrent
        let size = isCurrent ? fontSize : max(20, fontSize * 0.9)
        let weight: NSFont.Weight = isCurrent ? .semibold : .medium
        self.captionFont = typeface.nsFont(size: size, weight: weight)
        self.spokenColor = spokenColor.withAlphaComponent(isCurrent ? 1 : 0.72)
        self.translatedColor = translatedColor.withAlphaComponent(isCurrent ? 1 : 0.72)
        if highContrast {
            let shadow = NSShadow()
            shadow.shadowColor = lightBackground ? NSColor.white.withAlphaComponent(0.8) : .black
            shadow.shadowBlurRadius = 2
            self.captionShadow = shadow
        } else {
            self.captionShadow = nil
        }
        self.applyEmphasis()
        if prints || isCurrent {
            self.startPrintIfNeeded()
        } else {
            self.printTimer?.invalidate()
            self.printTimer = nil
            self.printedSpoken = self.targetSpoken
            self.printedTranslated = self.targetTranslated
            self.applyPrintedText()
        }
    }

    private func startPrintIfNeeded() {
        let pending = self.printedSpoken != self.targetSpoken
            || self.printedTranslated != self.targetTranslated
        guard pending else {
            self.printTimer?.invalidate()
            self.printTimer = nil
            return
        }
        if self.printTimer == nil {
            self.advancePrint()
            self.startTimerIfNeeded()
        }
    }

    private func applyEmphasis() {
        let target: CGFloat = self.isCurrent ? 1 : 0.72
        guard abs(self.alphaValue - target) > 0.01 else { return }
        if self.window == nil {
            self.alphaValue = target
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().alphaValue = target
        }
    }

    private func startTimerIfNeeded() {
        if self.printedSpoken == self.targetSpoken, self.printedTranslated == self.targetTranslated {
            self.printTimer?.invalidate()
            self.printTimer = nil
            return
        }
        guard self.printTimer == nil else { return }
        let timer = Timer(timeInterval: TheaterLinePrinter.printStepSeconds, repeats: true) { [weak self] _ in
            self?.advancePrint()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.printTimer = timer
    }

    private func advancePrint() {
        let nextSpoken = TheaterLinePrinter.advance(
            self.printedSpoken,
            toward: self.targetSpoken,
            emptyTarget: .hold
        )
        let nextTranslated = TheaterLinePrinter.advance(
            self.printedTranslated,
            toward: self.targetTranslated,
            emptyTarget: .retract
        )
        let changed = nextSpoken != self.printedSpoken || nextTranslated != self.printedTranslated
        self.printedSpoken = nextSpoken
        self.printedTranslated = nextTranslated
        self.applyPrintedText()
        if changed {
            self.invalidateIntrinsicContentSize()
            self.needsLayout = true
        }
        if self.printedSpoken == self.targetSpoken, self.printedTranslated == self.targetTranslated {
            self.printTimer?.invalidate()
            self.printTimer = nil
        }
    }

    private func applyPrintedText() {
        self.lastWrapWidth = 0
        self.rebuildLineViews()
        self.invalidateIntrinsicContentSize()
        self.needsLayout = true
    }

    private func rebuildLineViews() {
        let width = max(self.bounds.width, 1)
        self.lastWrapWidth = width
        let rows = TheaterBilingualWrap.revealedRows(
            spoken: self.targetSpoken,
            translated: self.targetTranslated,
            printedSpoken: self.printedSpoken,
            printedTranslated: self.printedTranslated,
            font: self.captionFont,
            width: width
        )
        while self.lineViews.count < rows.count {
            let field = self.makeLineField()
            self.addSubview(field)
            self.lineViews.append(field)
        }
        while self.lineViews.count > rows.count {
            self.lineViews.removeLast().removeFromSuperview()
        }
        for (index, row) in rows.enumerated() {
            let field = self.lineViews[index]
            let visible = Self.displayText(row.text)
            if field.stringValue != visible {
                field.stringValue = visible
            }
            field.font = self.captionFont
            field.textColor = row.isSpoken ? self.spokenColor : self.translatedColor
            field.shadow = self.captionShadow
            field.isSelectable = !row.isSpoken
            field.preferredMaxLayoutWidth = width
        }
    }

    override func layout() {
        super.layout()
        let width = max(self.bounds.width, 1)
        if abs(width - self.lastWrapWidth) > 0.5 {
            self.rebuildLineViews()
        }
        var y: CGFloat = 0
        for view in self.lineViews {
            view.preferredMaxLayoutWidth = width
            let height = view.intrinsicContentSize.height
            view.frame = NSRect(x: 0, y: y, width: width, height: height)
            y += height
            if view !== self.lineViews.last {
                y += 2
            }
        }
    }

    override var intrinsicContentSize: NSSize {
        let width = max(self.bounds.width, 1)
        if abs(width - self.lastWrapWidth) > 0.5 {
            self.rebuildLineViews()
        }
        var height: CGFloat = 0
        for view in self.lineViews {
            view.preferredMaxLayoutWidth = width
            height += view.intrinsicContentSize.height
        }
        if self.lineViews.count > 1 {
            height += CGFloat(self.lineViews.count - 1) * 2
        }
        return NSSize(width: NSView.noIntrinsicMetric, height: max(height, 1))
    }

    override var isFlipped: Bool { true }

    private static func displayText(_ text: String) -> String {
        String(text.drop(while: { $0.isWhitespace }).reversed().drop(while: { $0.isWhitespace }).reversed())
    }

    private func makeLineField() -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = true
        label.textColor = .white
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
}

/// AppKit editor so Theater can keep caption-colored text. SwiftUI TextEditor ignores foreground on macOS.
private struct TheaterTextEditor: NSViewRepresentable {
    @Binding var text: String
    var typeface: TheaterTypeface
    var fontSize: CGFloat
    var textColor: NSColor

    func makeCoordinator() -> Coordinator {
        Coordinator(text: self.$text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = self.textColor
        textView.insertionPointColor = self.textColor
        textView.font = self.typeface.nsFont(size: self.fontSize, weight: .semibold)
        textView.string = self.text
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineBreakMode = .byWordWrapping
        textView.textContainerInset = NSSize(width: 0, height: 4)

        scroll.documentView = textView
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        textView.font = self.typeface.nsFont(size: self.fontSize, weight: .semibold)
        textView.textColor = self.textColor
        textView.insertionPointColor = self.textColor
        if textView.string != self.text, context.coordinator.isEditing == false {
            textView.string = self.text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        weak var textView: NSTextView?
        var isEditing = false

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidBeginEditing(_ notification: Notification) {
            self.isEditing = true
        }

        func textDidEndEditing(_ notification: Notification) {
            self.isEditing = false
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            self.text.wrappedValue = textView.string
        }
    }
}
