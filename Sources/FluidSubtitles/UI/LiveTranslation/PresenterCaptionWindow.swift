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
    private var boardNextID: UInt64 = 1
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
        self.boardNextID = 1
        self.boardSources = []
        self.boardPending = []
        self.liveDraft = ""
        self.liveSource = ""
        self.model.committed = []
        self.model.committedIDs = []
        self.model.nextCaptionID = 1
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
        nextCaptionID: UInt64 = 1,
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
        self.boardNextID = nextCaptionID
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
        if self.model.nextCaptionID != self.boardNextID { self.model.nextCaptionID = self.boardNextID }
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
        TheaterWindowSharing.apply(
            panel,
            hideFromScreenShare: SettingsStore.shared.theaterHideFromScreenShare
        )
        if let screen = Self.preferredScreen() {
            panel.setFrame(
                TheaterWindowPlacement.resolvedFrame(stored: nil, visible: screen.visibleFrame),
                display: true
            )
        } else {
            panel.setContentSize(TheaterWindowPlacement.legacyDefaultSize)
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
            panel.minSize = NSSize(width: 480, height: TheaterChromeLayout.minimizedHeight)
            var frame = panel.frame
            if frame.height > TheaterChromeLayout.minimizedHeight + 8 {
                SettingsStore.shared.theaterExpandedWindowFrame = NSStringFromRect(frame)
            }
            let height = TheaterChromeLayout.minimizedHeight
            frame.origin.y += frame.height - height
            frame.size.height = height
            panel.setFrame(frame, display: true, animate: true)
        } else {
            panel.minSize = NSSize(width: 640, height: 260)
            let screen = panel.screen ?? Self.preferredScreen()
            let stored = SettingsStore.shared.theaterExpandedWindowFrame
            let storedRect = stored.isEmpty ? nil : NSRectFromString(stored)
            if let screen {
                panel.setFrame(
                    TheaterWindowPlacement.resolvedFrame(
                        stored: storedRect,
                        visible: screen.visibleFrame
                    ),
                    display: true,
                    animate: true
                )
                return
            }
            var frame = panel.frame
            if frame.height < 260 {
                let height = TheaterWindowPlacement.legacyDefaultSize.height
                frame.origin.y -= height - frame.height
                frame.size.height = height
                panel.setFrame(frame, display: true, animate: true)
            }
        }
    }

    private func restoreFrame() {
        let stored = SettingsStore.shared.theaterWindowFrame
        let storedRect = stored.isEmpty ? nil : NSRectFromString(stored)
        let screen = Self.screen(named: SettingsStore.shared.theaterScreenName) ?? Self.preferredScreen()
        if let screen {
            self.panel?.setFrame(
                TheaterWindowPlacement.resolvedFrame(stored: storedRect, visible: screen.visibleFrame),
                display: true
            )
        } else if let storedRect, storedRect.width > 200, storedRect.height > 160 {
            self.panel?.setFrame(storedRect, display: true)
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
    @Published var nextCaptionID: UInt64 = 1
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

enum TheaterLinePrinter {
    enum EmptyTarget {
        /// Keep what is already on screen. Used when ASR flickers blank.
        case hold
        /// Take back one chunk. Used when a translation is withdrawn.
        case retract
    }

    static func extend(
        _ shown: String,
        toward target: String,
        style: TheaterCaptionPrintStyle = .word
    ) -> String {
        if target.isEmpty { return shown }
        if shown.isEmpty {
            return Self.openingChunk(in: target, style: style)
        }
        if shown == target { return target }
        if target.hasPrefix(shown) {
            let rest = String(target.dropFirst(shown.count))
            return shown + Self.nextChunk(in: rest, style: style)
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
        if Self.reprintsLeadingPrintedClause(currentSpoken: currentSpoken, nextSpoken: nextSpoken) {
            return false
        }
        if currentSpoken.isEmpty, nextSpoken.isEmpty,
           Self.reprintsLeadingPrintedClause(
            currentSpoken: currentTranslated,
            nextSpoken: nextTranslated
           )
        {
            return false
        }
        if Self.isAlreadyPeeledTail(current: currentSpoken, incoming: nextSpoken)
            || (
                currentSpoken.isEmpty && nextSpoken.isEmpty
                    && Self.isAlreadyPeeledTail(current: currentTranslated, incoming: nextTranslated)
            )
        {
            return true
        }
        // Before the title starts, English may still correct (shop → store)
        // and the first Korean target may land.
        if currentTranslated.isEmpty {
            if nextSpoken.isEmpty { return false }
            if nextSpoken == currentSpoken { return true }
            if nextSpoken.hasPrefix(currentSpoken) || currentSpoken.hasPrefix(nextSpoken) {
                return true
            }
            return self.isContinuation(currentSpoken, of: nextSpoken)
        }
        let spokenGrows = nextSpoken.hasPrefix(currentSpoken) || currentSpoken.hasPrefix(nextSpoken)
        let translatedGrows = nextTranslated.hasPrefix(currentTranslated)
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
        if Self.reprintsLeadingPrintedClause(currentSpoken: currentSpoken, nextSpoken: nextSpoken) {
            return true
        }
        if currentSpoken.isEmpty, nextSpoken.isEmpty,
           Self.reprintsLeadingPrintedClause(
            currentSpoken: currentTranslated,
            nextSpoken: nextTranslated
           )
        {
            return true
        }
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
        emptyTarget: EmptyTarget = .hold,
        style: TheaterCaptionPrintStyle = .word
    ) -> String {
        if !style.typesIn {
            if target.isEmpty {
                switch emptyTarget {
                case .hold:
                    return shown
                case .retract:
                    return ""
                }
            }
            return target
        }
        if target.isEmpty {
            switch emptyTarget {
            case .hold:
                return shown
            case .retract:
                return shown.isEmpty ? "" : Self.dropLastChunk(shown)
            }
        }
        if shown.isEmpty {
            return Self.openingChunk(in: target, style: style)
        }
        if shown == target { return target }
        if target.hasPrefix(shown) {
            return Self.extend(shown, toward: target, style: style)
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
        emptyTarget: EmptyTarget = .hold,
        style: TheaterCaptionPrintStyle = .word
    ) -> String {
        Self.follow(shown, toward: target, emptyTarget: emptyTarget, style: style)
    }

    /// Cumulative ASR still starts with the clause already on this row.
    /// Extending into sentence two reprints sentence one.
    static func reprintsLeadingPrintedClause(currentSpoken: String, nextSpoken: String) -> Bool {
        let current = currentSpoken.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = nextSpoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty, !next.isEmpty, current != next else { return false }
        if TranslationClauseSegmenter.isSameClause(current, next) { return false }
        let leftover = TranslationClauseSegmenter.leftoverTail(next, already: [current])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let peeledAway = !leftover.isEmpty && leftover != next && leftover.count < next.count
        if peeledAway, self.leftoverIsANewClause(leftover, after: current) {
            return true
        }
        if TranslationClauseSegmenter.shouldReplaceLast(previous: current, incoming: next) {
            return false
        }
        return peeledAway
    }

    /// "the model" after "Today we trained" is the same phrase. "Then we applied
    /// it" after a finished clause is sentence two.
    static func leftoverIsANewClause(_ leftover: String, after current: String) -> Bool {
        let leftover = leftover.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !leftover.isEmpty, !current.isEmpty else { return false }
        let languages = ["en", "ko", "th", "ja"]
        if languages.contains(where: { TranslationClauseSegmenter.looksComplete(current, languageID: $0) }) {
            return true
        }
        if languages.contains(where: { TranslationClauseSegmenter.looksComplete(leftover, languageID: $0) }) {
            return true
        }
        if languages.contains(where: {
            TranslationClauseSegmenter.isPauseFinalizable(leftover, languageID: $0)
                || TranslationClauseSegmenter.shouldFollowAlong(leftover, languageID: $0)
        }) {
            return true
        }
        let leftoverWords = leftover.split { $0.isWhitespace }.filter { !$0.isEmpty }.count
        let currentWords = current.split { $0.isWhitespace }.filter { !$0.isEmpty }.count
        return leftoverWords >= 4 && currentWords >= 4
    }

    static func unreadSpokenTarget(currentSpoken: String, nextSpoken: String) -> String {
        let current = currentSpoken.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = nextSpoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.reprintsLeadingPrintedClause(currentSpoken: current, nextSpoken: next) else {
            return next
        }
        let leftover = TranslationClauseSegmenter.leftoverTail(next, already: [current])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return leftover.isEmpty ? next : leftover
    }

    /// Voice / same-language Theater hides the spoken undertone. The title is
    /// the clause identity, so leftover peel has to run on that field.
    struct IncomingResolution: Equatable {
        var spoken: String
        var translated: String
        var reset: Bool
    }

    static func resolveIncoming(
        currentSpoken: String,
        currentTranslated: String,
        nextSpoken: String,
        nextTranslated: String,
        translationStarted: Bool
    ) -> IncomingResolution {
        let identityCurrent = nextSpoken.isEmpty && currentSpoken.isEmpty
            ? currentTranslated
            : currentSpoken
        let identityNext = nextSpoken.isEmpty ? nextTranslated : nextSpoken

        if self.isAlreadyPeeledTail(current: identityCurrent, incoming: identityNext) {
            return IncomingResolution(
                spoken: currentSpoken,
                translated: currentTranslated,
                reset: false
            )
        }

        if self.reprintsLeadingPrintedClause(currentSpoken: identityCurrent, nextSpoken: identityNext) {
            let unread = self.unreadSpokenTarget(
                currentSpoken: identityCurrent,
                nextSpoken: identityNext
            )
            if nextSpoken.isEmpty {
                return IncomingResolution(spoken: "", translated: unread, reset: true)
            }
            return IncomingResolution(spoken: unread, translated: nextTranslated, reset: true)
        }

        if self.shouldStartNewCaption(
            currentSpoken: currentSpoken,
            currentTranslated: currentTranslated,
            nextSpoken: nextSpoken,
            nextTranslated: nextTranslated
        ) {
            let captionOnly = currentSpoken.isEmpty && nextSpoken.isEmpty
            if !translationStarted || captionOnly {
                return IncomingResolution(
                    spoken: nextSpoken,
                    translated: nextTranslated,
                    reset: true
                )
            }
        }

        return IncomingResolution(
            spoken: nextSpoken,
            translated: nextTranslated,
            reset: false
        )
    }

    /// The live row already shows sentence two. A later restitch of sentence
    /// one plus two must not replace that tail with the whole blob.
    static func isAlreadyPeeledTail(current: String, incoming: String) -> Bool {
        let current = current.trimmingCharacters(in: .whitespacesAndNewlines)
        let incoming = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty, incoming.count > current.count else { return false }
        if incoming.hasPrefix(current) || incoming.hasPrefix(current + " ") { return false }
        if TranslationClauseSegmenter.isSameClause(current, incoming) { return false }
        guard incoming.hasSuffix(current) else { return false }
        let prefix = String(incoming.dropLast(current.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { return false }
        let words = prefix.split { $0.isWhitespace }.filter { !$0.isEmpty }
        return words.count >= 3 || TranslationClauseSegmenter.looksComplete(prefix, languageID: "en")
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

    /// First paint is one chunk. A thin starter stays one word so the title
    /// does not pop in as "It was a long".
    static func openingChunk(
        in target: String,
        style: TheaterCaptionPrintStyle
    ) -> String {
        self.nextChunk(in: target, style: style)
    }

    private static func nextChunk(in rest: String, style: TheaterCaptionPrintStyle) -> String {
        guard let first = rest.first else { return "" }
        if first.isWhitespace {
            let spaces = rest.prefix(while: { $0.isWhitespace })
            let after = rest.drop(while: { $0.isWhitespace })
            return String(spaces) + self.nextChunk(in: String(after), style: style)
        }
        if first.isASCII, first.isLetter || first.isNumber {
            let latin = rest.prefix(while: { $0.isASCII && ($0.isLetter || $0.isNumber) })
            if style == .flow {
                return String(latin.prefix(1))
            }
            return String(latin)
        }
        let compact = style == .flow ? 1 : 3
        return String(rest.prefix(compact))
    }
}

enum TheaterCaptionFlow {
    /// Same id the clause will keep after it commits, so the NSView is not remounted.
    static func liveID(after committedIDs: [UInt64], nextID: UInt64 = 0, pendingCount: Int = 0) -> String {
        let fallback = (committedIDs.max() ?? 0) + 1
        let base = nextID > 0 ? nextID : fallback
        return "c-\(base + UInt64(max(pendingCount, 0)))"
    }

    static func lines(
        committed: [String],
        committedIDs: [UInt64] = [],
        nextCaptionID: UInt64 = 0,
        committedSources: [String] = [],
        draft: String,
        sourceDraft: String = "",
        pendingSources: [String] = [],
        spokenDisplay: TheaterCaptionSpokenDisplay = .isTheCaption
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
        let printedSources = committedSources
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let pending = pendingSources
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { !Self.isAlreadyOnBoard($0, lastText: history.last?.element ?? "", printedSources: printedSources) }
        let lastText = history.last?.element ?? ""
        let alreadyOnBoard = printedSources + pending
        let peeledSpoken = Self.unreadCaption(
            spoken,
            lastText: lastText,
            printedSources: alreadyOnBoard
        )
        let unreadSpoken = !peeledSpoken.isEmpty
            && !Self.isAlreadyOnBoard(
                peeledSpoken,
                lastText: lastText,
                printedSources: alreadyOnBoard
            )
        switch spokenDisplay {
        case .hidden:
            if !draftText.isEmpty, !Self.isSameCaption(draftText, lastText) {
                liveText = Self.freshCaption(
                    draftText,
                    lastText: lastText,
                    printedSources: alreadyOnBoard
                )
            }
        case .paired:
            if !draftText.isEmpty, !Self.isSameCaption(draftText, lastText) {
                liveText = draftText
                if unreadSpoken, peeledSpoken != draftText {
                    liveSource = peeledSpoken
                }
            } else if unreadSpoken {
                liveSource = peeledSpoken
            }
        case .isTheCaption:
            if !draftText.isEmpty, !Self.isSameCaption(draftText, lastText) {
                liveText = Self.freshCaption(
                    draftText,
                    lastText: lastText,
                    printedSources: alreadyOnBoard
                )
                if liveText.isEmpty, unreadSpoken {
                    liveText = peeledSpoken
                }
            } else if unreadSpoken {
                liveText = peeledSpoken
            }
        }

        let freshLive = !liveText.isEmpty || !liveSource.isEmpty
        let visiblePending = spokenDisplay == .hidden ? [] : pending
        let visibleHistory = Array(history.suffix(LiveTranslationTiming.visibleTheaterLines))

        func committedLine(index: Int, text: String, isCurrent: Bool) -> TheaterFlowLine {
            let id = index < committedIDs.count ? "c-\(committedIDs[index])" : "c-\(index + 1)"
            let source = index < committedSources.count ? committedSources[index] : ""
            return TheaterFlowLine(id: id, text: text, source: source, isCurrent: isCurrent, isDraft: false)
        }

        let hasRowsBelow = freshLive || !visiblePending.isEmpty
        var result: [TheaterFlowLine] = visibleHistory.map { index, text in
            committedLine(index: index, text: text, isCurrent: !hasRowsBelow && index == visibleHistory.last?.offset)
        }
        let fallback = (committedIDs.max() ?? 0) + 1
        let pendingBase = nextCaptionID > 0 ? nextCaptionID : fallback
        for (offset, spokenLine) in visiblePending.enumerated() {
            let id = "c-\(pendingBase + UInt64(offset))"
            switch spokenDisplay {
            case .hidden:
                break
            case .paired:
                result.append(TheaterFlowLine(
                    id: id,
                    text: "",
                    source: spokenLine,
                    isCurrent: false,
                    isDraft: true
                ))
            case .isTheCaption:
                result.append(TheaterFlowLine(
                    id: id,
                    text: spokenLine,
                    source: "",
                    isCurrent: false,
                    isDraft: true
                ))
            }
        }
        if freshLive {
            result.append(TheaterFlowLine(
                id: Self.liveID(
                    after: committedIDs,
                    nextID: nextCaptionID,
                    pendingCount: visiblePending.count
                ),
                text: liveText,
                source: liveSource,
                isCurrent: true,
                isDraft: true
            ))
        }
        return result
    }

    static func unreadCaption(
        _ text: String,
        lastText: String,
        printedSources: [String]
    ) -> String {
        let leftover = TranslationClauseSegmenter.leftoverTail(text, already: printedSources)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if leftover.isEmpty { return "" }
        if Self.isSameCaption(leftover, lastText) { return "" }
        return leftover
    }

    /// Next title only. A restitch of sentence one plus two must not fall back
    /// to the whole blob after peel.
    static func freshCaption(
        _ text: String,
        lastText: String,
        printedSources: [String]
    ) -> String {
        let leftover = Self.unreadCaption(
            text,
            lastText: lastText,
            printedSources: printedSources
        )
        if !leftover.isEmpty { return leftover }
        if Self.isSameCaption(text, lastText) { return "" }
        if !lastText.isEmpty {
            let peeled = TranslationClauseSegmenter.leftoverTail(text, already: printedSources)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if peeled != text { return "" }
        }
        return text
    }

    static func isAlreadyOnBoard(
        _ spoken: String,
        lastText: String,
        printedSources: [String]
    ) -> Bool {
        let cleaned = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }
        if Self.isSameCaption(cleaned, lastText) { return true }
        return TranslationClauseSegmenter.isAlreadyPrintedSource(cleaned, already: printedSources)
    }

    static func isSameCaption(_ left: String, _ right: String) -> Bool {
        let a = left.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = right.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty || b.isEmpty { return false }
        if a == b { return true }
        return TranslationClauseSegmenter.isSameClause(a, b)
    }
}

/// Reserved chrome so hover tools and the titlebar do not collide with captions.
private enum TheaterChromeLayout {
    static let titlebarClearance: CGFloat = 36
    static let hoverToolsTop: CGFloat = 88
    static let minimizedHeight: CGFloat = 112
    static let languageHit: CGFloat = 32
}

struct PresenterCaptionView: View {
    @ObservedObject var model: PresenterCaptionModel
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var controller = LiveTranslationController.shared
    @ObservedObject private var asr = AppServices.shared.asr
    @State private var chromeRevealed = false
    @State private var chromePinned = false
    @State private var showClearConfirmation = false
    @State private var lockedWrapWidth: CGFloat = 0
    @State private var liveRevealHeight: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var appearance: TheaterAppearance {
        TheaterAppearance.resolved(self.settings.theaterAppearance)
    }

    private var theme: AppTheme {
        AppTheme.adaptive(accent: self.settings.accentColor, colorScheme: self.appearance.colorScheme)
    }

    private var captionColors: TheaterCaptionVisibility.Colors {
        TheaterCaptionVisibility.colors(
            appearance: self.appearance,
            presentation: self.presentationStyle,
            highContrast: self.settings.theaterHighContrast
        )
    }

    private var spokenNS: NSColor {
        self.captionColors.spoken
    }

    private var translatedNS: NSColor {
        self.captionColors.translated
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
                TheaterReadiness.closeWhileListeningTitle,
                isPresented: self.$model.showCloseConfirmation
            ) {
                Button("Cancel", role: .cancel) {
                    PresenterCaptionController.shared.cancelCloseWhileListening()
                }
                Button(TheaterReadiness.closeWhileListeningButton, role: .destructive) {
                    PresenterCaptionController.shared.confirmCloseWhileListening()
                }
            } message: {
                Text(TheaterReadiness.closeWhileListeningConfirm)
            }
    }

    private var theaterContent: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: self.settings.theaterHideChrome ? 8 : self.theme.metrics.spacing.md) {
                self.primaryChrome
                if !self.settings.theaterMinimized {
                    if !self.settings.theaterHideChrome {
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
            .padding(.top, TheaterChromeLayout.titlebarClearance)
            .padding(.bottom, self.theme.metrics.spacing.md)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if self.showsHoverTools {
                self.hoverTools
                    .padding(.horizontal, self.theme.metrics.spacing.xxl)
                    .padding(.top, TheaterChromeLayout.hoverToolsTop)
                    .transition(.opacity)
            }
        }
        .background(self.theaterFill)
        .background {
            if self.presentationStyle == .popup, !self.settings.theaterHighContrast {
                Rectangle().fill(self.theme.materials.window)
            }
        }
        .animation(.easeOut(duration: 0.12), value: self.showsHoverTools)
    }

    /// Captions-only keeps the Listen row in-flow so hover tools can overlay without moving the board.
    @ViewBuilder
    private var primaryChrome: some View {
        if self.settings.theaterHideChrome {
            self.captionsOnlyChrome
        } else {
            self.persistentChrome
        }
    }

    private var showsHoverTools: Bool {
        self.settings.theaterHideChrome
            && !self.settings.theaterMinimized
            && (self.chromeRevealed || self.chromePinned || self.model.isEditing)
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
                    .foregroundStyle(self.captionColors.chrome)
                    .lineLimit(1)
            }
            self.languageMenu(
                title: "I speak",
                selection: self.sourceLanguageID,
                languages: TranslationLanguageCatalog.all
            )

            if self.settings.theaterSessionMode == .translation {
                Button {
                    PresenterCaptionController.shared.performChromeAction {
                        self.controller.swapDirection()
                    }
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: TheaterChromeLayout.languageHit, height: TheaterChromeLayout.languageHit)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(SpokenLanguageResolver.isSameLanguagePair())
                .help("Swap spoken and translated languages")
                .accessibilityLabel("Swap languages")

                if showsLabels {
                    Text("Show as")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.captionColors.chrome)
                        .lineLimit(1)
                }
                self.languageMenu(
                    title: "Show as",
                    selection: self.targetLanguageID,
                    languages: self.targetLanguages
                )
            }
        }
        .controlSize(.regular)
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
                    .font(self.theme.typography.bodySmallStrong)
                    .foregroundStyle(self.captionColors.chrome)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(self.captionColors.chrome.opacity(0.8))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(minWidth: 108, minHeight: TheaterChromeLayout.languageHit, alignment: .leading)
            .contentShape(Rectangle())
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
        self.captionColors.menuFill
    }

    private var languageMenuStroke: Color {
        self.captionColors.menuStroke
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

    /// Languages stay on one line at 640pt. Mode drops first if the row is still tight.
    @ViewBuilder
    private var persistentChrome: some View {
        ViewThatFits(in: .horizontal) {
            self.persistentChromeRow(showsMode: true)
            self.persistentChromeRow(showsMode: false)
        }
    }

    private func persistentChromeRow(showsMode: Bool) -> some View {
        HStack(alignment: .center, spacing: self.theme.metrics.spacing.md) {
            self.languagePairControls
            if showsMode {
                self.windowModePicker
            }
            Spacer(minLength: self.theme.metrics.spacing.sm)
            self.retryActions
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

    /// Extra chrome for captions-only: sits on top of captions instead of inserting a second row.
    private var hoverTools: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                self.languagePairControls
                self.windowModePicker
                Spacer(minLength: 8)
                self.retryActions
            }
            self.extendedChrome
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.78))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("theater.window.hoverTools")
    }

    @ViewBuilder
    private var retryActions: some View {
        if self.model.canRetryTranslation {
            Button("Retry") {
                PresenterCaptionController.shared.performChromeAction {
                    self.controller.retryFailedTranslation()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .help("Retry the last failed translation.")
            if !SpokenLanguageResolver.isSameLanguagePair() {
                Button(TheaterReadiness.downloadPack) {
                    PresenterCaptionController.shared.performChromeAction {
                        AppleTranslationEngine.shared.requestLanguagePackDownload()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help("Download the language pack for this pair.")
            }
        }
    }

    private var captionsOnlyChrome: some View {
        HStack(alignment: .center, spacing: self.theme.metrics.spacing.sm) {
            if !self.model.compactLatencyReadout.isEmpty {
                Text(self.model.compactLatencyReadout)
                    .font(self.theme.typography.codeCaption)
                    .foregroundStyle(self.captionColors.chrome)
                    .lineLimit(1)
                    .help(TheaterReadiness.latencyHUD)
            }
            Spacer(minLength: self.theme.metrics.spacing.sm)
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
                    self.controller.applyTheaterSessionMode(newMode)
                }
            }
        )) {
            ForEach(TheaterSessionMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.regular)
        .frame(minWidth: 168, minHeight: TheaterChromeLayout.languageHit)
        .help(TheaterReadiness.modeStopsListen)
        .accessibilityLabel("Theater mode")
        .accessibilityIdentifier("theater.window.mode")
    }

    @ViewBuilder
    private var extendedChrome: some View {
        ViewThatFits(in: .horizontal) {
            self.extendedChromeRow(showsTheme: true, showsLatency: true)
            self.extendedChromeRow(showsTheme: false, showsLatency: true)
            self.extendedChromeRow(showsTheme: false, showsLatency: false)
        }
    }

    private func extendedChromeRow(showsTheme: Bool, showsLatency: Bool) -> some View {
        HStack(spacing: self.theme.metrics.spacing.sm) {
            if showsLatency, !self.model.latencyReadout.isEmpty {
                Text(self.model.latencyReadout)
                    .font(self.theme.typography.codeCaption)
                    .foregroundStyle(self.captionColors.chrome)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .help(TheaterReadiness.latencyHUD)
            }
            if !self.model.status.isEmpty {
                Text(self.model.status)
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(
                        self.model.statusKind.usesWarningColor
                            ? self.theme.palette.warning
                            : self.captionColors.chrome
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .accessibilityIdentifier("theater.status")
            }
            Spacer(minLength: self.theme.metrics.spacing.sm)
            if showsTheme {
                self.appearancePicker(compact: true)
            }
            self.typographyControls
                .layoutPriority(1)
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
                    .foregroundStyle(self.captionColors.chrome)
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
        .controlSize(.regular)
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
                                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40)
        }
        .help("More")
        .accessibilityLabel("More")
        .menuIndicator(.hidden)
        .buttonStyle(SquareIconButtonStyle())
        .controlSize(.regular)
    }

    private var minimizeButton: some View {
        Button {
            PresenterCaptionController.shared.performChromeAction {
                PresenterCaptionController.shared.toggleMinimized()
            }
        } label: {
            Image(systemName: self.settings.theaterMinimized ? "arrow.up.left.and.arrow.down.right" : "minus")
                                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40)
        }
        .buttonStyle(SquareIconButtonStyle())
        .controlSize(.regular)
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
                                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40)
        }
        .buttonStyle(SquareIconButtonStyle())
        .controlSize(.regular)
        .help(
            self.settings.theaterHideChrome
                ? "Show all controls"
                : "Captions only. Listen stays. Move the pointer to show languages without moving the captions."
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
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40)
            }
            .help("Caption font. \(self.typeface.displayName).")
            .accessibilityLabel("Caption font")
            .menuIndicator(.hidden)

            Button {
                self.nudgeFontSize(-2)
            } label: {
                Image(systemName: "textformat.size.smaller")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40)
            }
            .disabled(self.settings.presenterFontSize <= SettingsStore.presenterFontSizeRange.lowerBound)
            .help("Smaller spoken line. Translation stays larger. \(self.settings.presenterFontSize) pt.")
            .accessibilityLabel("Smaller spoken line")

            Button {
                self.nudgeFontSize(2)
            } label: {
                Image(systemName: "textformat.size.larger")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40)
            }
            .disabled(self.settings.presenterFontSize >= SettingsStore.presenterFontSizeRange.upperBound)
            .help("Larger spoken line. Translation stays larger. \(self.settings.presenterFontSize) pt.")
            .accessibilityLabel("Larger spoken line")

            Button {
                self.controller.copyCaptionText()
            } label: {
                Image(systemName: "doc.on.doc")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40)
            }
            .disabled(self.deliveryIsEmpty)
            .help("Copy all")
            .accessibilityLabel("Copy all")
            .accessibilityIdentifier("theater.window.copy")

            Button {
                self.controller.insertCaptionText()
            } label: {
                Image(systemName: "text.insert")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40)
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
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40)
            }
            .disabled(!self.controller.hasUndoableCaption || self.model.isEditing)
            .help(TheaterReadiness.undoLastCaption)
            .accessibilityLabel("Undo last caption")
            .accessibilityIdentifier("theater.window.undo")

            Button {
                self.showClearConfirmation = true
            } label: {
                Image(systemName: "trash")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40)
            }
            .disabled(!self.controller.hasClearableBoard)
            .help(TheaterReadiness.clearCaptions)
            .accessibilityLabel("Clear captions")
            .accessibilityIdentifier("theater.window.clear")

            self.boardMenu
            self.moreMenu
        }
        .buttonStyle(SquareIconButtonStyle())
        .controlSize(.regular)
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
                    : "Show what you said under the translation so both rooms can follow."
            )

            Menu("Caption print-in") {
                ForEach(TheaterCaptionPrintStyle.allCases) { style in
                    Button {
                        PresenterCaptionController.shared.performChromeAction {
                            self.settings.theaterCaptionPrintStyle = style
                        }
                    } label: {
                        if style == self.settings.theaterCaptionPrintStyle {
                            Label(style.displayName, systemImage: "checkmark")
                        } else {
                            Text(style.displayName)
                        }
                    }
                    .help(style.help)
                }
            }
            .help("How the live caption appears.")

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
                                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40)
        }
        .help("Board")
        .accessibilityLabel("Board")
        .accessibilityIdentifier("theater.presentationStyle")
        .menuIndicator(.hidden)
        .buttonStyle(SquareIconButtonStyle())
        .controlSize(.regular)
    }

    private var presentationStage: some View {
        let settingSize = CGFloat(self.settings.presenterFontSize)
        let spokenSize = TheaterCaptionScale.spokenSize(setting: settingSize)
        let translatedSize = TheaterCaptionScale.translatedSize(setting: settingSize)
        let spokenDisplay = TheaterCaptionSpokenDisplay.resolved(
            showSpokenLine: self.settings.translationShowSource,
            sameLanguage: SpokenLanguageResolver.isSameLanguagePair()
        )
        let lines = TheaterCaptionFlow.lines(
            committed: self.model.committed,
            committedIDs: self.model.committedIDs,
            nextCaptionID: self.model.nextCaptionID,
            committedSources: self.model.committedSources,
            draft: self.model.draft,
            sourceDraft: self.model.source,
            pendingSources: self.model.pendingSources,
            spokenDisplay: spokenDisplay
        )
        return GeometryReader { geometry in
            let wrapWidth = TheaterBilingualWrap.resolvedWrapWidth(
                proposed: geometry.size.width,
                locked: self.lockedWrapWidth
            )
            let spokenFont = self.typeface.nsFont(size: spokenSize, weight: .semibold)
            let translatedFont = self.typeface.nsFont(size: translatedSize, weight: .semibold)
            let contentHeight = self.boardContentHeight(
                lines: lines,
                spokenFont: spokenFont,
                translatedFont: translatedFont,
                wrapWidth: wrapWidth
            )
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if lines.isEmpty {
                            Text(self.emptyStateText)
                                .font(self.theme.typography.body)
                                .foregroundStyle(self.captionColors.empty)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            ForEach(lines) { line in
                                let spoken = self.spokenLine(for: line)
                                let wrapRows = TheaterBilingualWrap.rows(
                                    spoken: spoken,
                                    translated: line.text,
                                    spokenFont: spokenFont,
                                    translatedFont: translatedFont,
                                    width: wrapWidth
                                )
                                let captionHeight = max(
                                    TheaterBilingualWrap.boardHeight(
                                        rows: wrapRows,
                                        spokenFont: spokenFont,
                                        translatedFont: translatedFont
                                    ),
                                    1
                                )
                                let tracksLiveHeight = line.isCurrent
                                TheaterCaptionLineLabel(
                                    text: line.text,
                                    source: spoken,
                                    isCurrent: line.isCurrent,
                                    prints: line.isDraft,
                                    printStyle: self.reduceMotion
                                        ? .instant
                                        : self.settings.theaterCaptionPrintStyle,
                                    typeface: self.typeface,
                                    spokenFontSize: spokenSize,
                                    translatedFontSize: translatedSize,
                                    spokenColor: self.spokenNS,
                                    translatedColor: self.translatedNS,
                                    shadowColor: self.captionColors.shadowColor,
                                    shadowBlur: self.captionColors.shadowBlur,
                                    onRevealedHeightChange: tracksLiveHeight
                                        ? { height in
                                            if abs(height - self.liveRevealHeight) >= 1 {
                                                self.liveRevealHeight = height
                                            }
                                        }
                                        : nil
                                )
                                .frame(
                                    maxWidth: .infinity,
                                    minHeight: tracksLiveHeight ? max(self.liveRevealHeight, 1) : captionHeight,
                                    alignment: .topLeading
                                )
                                .id(line.id)
                            }
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("theater-bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.top, 4)
                }
                .scrollIndicators(.hidden)
                .onChange(of: geometry.size.width) { _, width in
                    let locked = self.lockedWrapWidth
                    let currentIsTyping = lines.contains { $0.isCurrent && $0.isDraft }
                    if currentIsTyping, locked >= TheaterBilingualWrap.minimumWrapWidth {
                        return
                    }
                    if locked < TheaterBilingualWrap.minimumWrapWidth
                        || abs(width - locked) >= TheaterBilingualWrap.wrapWidthHysteresis
                    {
                        self.lockedWrapWidth = width
                    }
                }
                .onChange(of: lines.map(\.id)) { oldIDs, newIDs in
                    if Set(newIDs).subtracting(oldIDs).isEmpty == false {
                        self.liveRevealHeight = 1
                    }
                    guard Set(newIDs).subtracting(oldIDs).isEmpty == false else { return }
                    guard contentHeight > geometry.size.height else { return }
                    withAnimation(.easeOut(duration: 0.55)) {
                        proxy.scrollTo("theater-bottom", anchor: .bottom)
                    }
                }
                .onChange(of: self.liveRevealHeight) { _, _ in
                    let visible = self.boardContentHeight(
                        lines: lines,
                        spokenFont: spokenFont,
                        translatedFont: translatedFont,
                        wrapWidth: wrapWidth,
                        liveRevealHeight: self.liveRevealHeight
                    )
                    guard visible > geometry.size.height else { return }
                    withAnimation(.easeOut(duration: 0.55)) {
                        proxy.scrollTo("theater-bottom", anchor: .bottom)
                    }
                }
                .onAppear {
                    if self.lockedWrapWidth < TheaterBilingualWrap.minimumWrapWidth {
                        self.lockedWrapWidth = geometry.size.width
                    }
                    if contentHeight > geometry.size.height {
                        proxy.scrollTo("theater-bottom", anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func boardContentHeight(
        lines: [TheaterFlowLine],
        spokenFont: NSFont,
        translatedFont: NSFont,
        wrapWidth: CGFloat,
        liveRevealHeight: CGFloat? = nil
    ) -> CGFloat {
        guard !lines.isEmpty else { return 0 }
        var height: CGFloat = 4
        for (index, line) in lines.enumerated() {
            if index > 0 {
                height += 14
            }
            if line.isCurrent, let liveRevealHeight {
                height += max(liveRevealHeight, 1)
                continue
            }
            let wrapRows = TheaterBilingualWrap.rows(
                spoken: self.spokenLine(for: line),
                translated: line.text,
                spokenFont: spokenFont,
                translatedFont: translatedFont,
                width: wrapWidth
            )
            height += TheaterBilingualWrap.boardHeight(
                rows: wrapRows,
                spokenFont: spokenFont,
                translatedFont: translatedFont
            )
        }
        return height + 1
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
            return TheaterReadiness.pausedStatus
        }
        if self.model.isListening {
            return TheaterReadiness.listeningEmpty
        }
        if !self.readySnapshot.canListen {
            return self.readySnapshot.nextAction
        }
        return TheaterReadiness.pressListen
    }

    private func spokenLine(for line: TheaterFlowLine) -> String {
        switch TheaterCaptionSpokenDisplay.resolved(
            showSpokenLine: self.settings.translationShowSource,
            sameLanguage: SpokenLanguageResolver.isSameLanguagePair()
        ) {
        case .paired:
            return line.source
        case .isTheCaption, .hidden:
            return ""
        }
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
    var printStyle: TheaterCaptionPrintStyle
    var typeface: TheaterTypeface
    var spokenFontSize: CGFloat
    var translatedFontSize: CGFloat
    var spokenColor: NSColor
    var translatedColor: NSColor
    var shadowColor: NSColor?
    var shadowBlur: CGFloat
    var onRevealedHeightChange: ((CGFloat) -> Void)?

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
        nsView.prepare(forWidth: width)
        return CGSize(width: width, height: nsView.captionHeight(forWidth: width))
    }

    private func apply(to view: TheaterCaptionLineNSView) {
        view.setCaption(
            spoken: self.source,
            translated: self.text,
            isCurrent: self.isCurrent,
            prints: self.prints,
            printStyle: self.printStyle,
            typeface: self.typeface,
            spokenFontSize: self.spokenFontSize,
            translatedFontSize: self.translatedFontSize,
            spokenColor: self.spokenColor,
            translatedColor: self.translatedColor,
            shadowColor: self.shadowColor,
            shadowBlur: self.shadowBlur
        )
        view.onRevealedHeightChange = self.onRevealedHeightChange
    }
}

private final class TheaterCaptionLineNSView: NSView {
    private var lineViews: [NSTextField] = []
    private var displayRows: [TheaterBilingualWrap.Row] = []
    private var targetSpoken = ""
    private var targetTranslated = ""
    private var printedSpoken = ""
    private var printedTranslated = ""
    private var printTimer: Timer?
    private var printStyle: TheaterCaptionPrintStyle = .flow
    private var isCurrent = true
    private var spokenFont = NSFont.systemFont(ofSize: 32, weight: .semibold)
    private var translatedFont = NSFont.systemFont(ofSize: 45, weight: .semibold)
    private var spokenColor = NSColor.white.withAlphaComponent(0.58)
    private var translatedColor = NSColor.white
    private var captionShadow: NSShadow?
    private var wrapWidth: CGFloat = 0
    private var lastReportedHeight: CGFloat = 0
    private var isSyncingRows = false
    var onRevealedHeightChange: ((CGFloat) -> Void)?

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

    func prepare(forWidth width: CGFloat) {
        let wrap = self.resolvedWrapWidth(width)
        guard wrap >= TheaterBilingualWrap.minimumWrapWidth else { return }
        if abs(wrap - self.wrapWidth) > 1 || self.displayRows.isEmpty {
            self.syncRows(width: wrap)
        }
    }

    func captionHeight(forWidth width: CGFloat) -> CGFloat {
        let wrap = self.resolvedWrapWidth(width)
        let rows = TheaterBilingualWrap.revealedRows(
            spoken: self.targetSpoken,
            translated: self.targetTranslated,
            printedSpoken: self.printedSpoken,
            printedTranslated: self.printedTranslated,
            spokenFont: self.spokenFont,
            translatedFont: self.translatedFont,
            width: wrap
        )
        return max(
            TheaterBilingualWrap.boardHeight(
                rows: rows,
                spokenFont: self.spokenFont,
                translatedFont: self.translatedFont
            ),
            1
        )
    }

    func setCaption(
        spoken: String,
        translated: String,
        isCurrent: Bool,
        prints: Bool,
        printStyle: TheaterCaptionPrintStyle,
        typeface: TheaterTypeface,
        spokenFontSize: CGFloat,
        translatedFontSize: CGFloat,
        spokenColor: NSColor,
        translatedColor: NSColor,
        shadowColor: NSColor?,
        shadowBlur: CGFloat
    ) {
        if spoken.isEmpty, translated.isEmpty {
            self.printStyle = printStyle
            self.isCurrent = isCurrent
            self.applyChrome(
                typeface: typeface,
                spokenFontSize: spokenFontSize,
                translatedFontSize: translatedFontSize,
                spokenColor: spokenColor,
                translatedColor: translatedColor,
                isCurrent: isCurrent,
                shadowColor: shadowColor,
                shadowBlur: shadowBlur
            )
            if self.printedSpoken.isEmpty, self.printedTranslated.isEmpty {
                self.resetPrintProgress()
                self.applyPrintedText()
            }
            return
        }

        let hasPrint = !self.printedSpoken.isEmpty || !self.printedTranslated.isEmpty
        let translationStarted = !self.printedTranslated.isEmpty
        let incoming = TheaterLinePrinter.resolveIncoming(
            currentSpoken: self.targetSpoken,
            currentTranslated: self.targetTranslated,
            nextSpoken: spoken,
            nextTranslated: translated,
            translationStarted: translationStarted
        )
        if incoming.reset {
            self.resetPrintProgress()
            self.targetSpoken = incoming.spoken
            self.targetTranslated = incoming.translated
        }
        let nextSpoken = incoming.spoken
        let nextTranslated = incoming.translated

        let adopts = TheaterLinePrinter.shouldAdoptPrintedCaption(
            currentSpoken: self.targetSpoken,
            currentTranslated: self.targetTranslated,
            nextSpoken: nextSpoken,
            nextTranslated: nextTranslated
        )
        self.printStyle = printStyle
        self.isCurrent = isCurrent
        self.applyChrome(
            typeface: typeface,
            spokenFontSize: spokenFontSize,
            translatedFontSize: translatedFontSize,
            spokenColor: spokenColor,
            translatedColor: translatedColor,
            isCurrent: isCurrent,
            shadowColor: shadowColor,
            shadowBlur: shadowBlur
        )
        if !hasPrint, printStyle.fadesIn, self.window != nil {
            self.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().alphaValue = 1
            }
        } else {
            self.alphaValue = 1
        }

        if incoming.reset {
            // Targets already set. Keep typing the new clause from a blank line.
        } else if !translationStarted {
            self.targetSpoken = nextSpoken
            self.targetTranslated = nextTranslated
            if !nextTranslated.isEmpty, !nextSpoken.isEmpty {
                self.printedSpoken = nextSpoken
            }
        } else if adopts {
            if nextSpoken.hasPrefix(self.printedSpoken) || self.printedSpoken.hasPrefix(nextSpoken) {
                self.targetSpoken = nextSpoken
            }
            if nextTranslated.hasPrefix(self.printedTranslated)
                || self.printedTranslated.hasPrefix(nextTranslated)
                || nextTranslated.isEmpty
            {
                self.targetTranslated = nextTranslated
            }
        } else if !hasPrint {
            self.targetSpoken = nextSpoken
            self.targetTranslated = nextTranslated
        }

        let unfinished = self.printedSpoken != self.targetSpoken
            || self.printedTranslated != self.targetTranslated
        let titleArrived = !self.targetTranslated.isEmpty && self.printedTranslated.isEmpty
        let shouldType = printStyle.typesIn
            && (isCurrent || (hasPrint && unfinished) || (titleArrived && (isCurrent || prints || hasPrint)))

        if shouldType {
            self.startPrintIfNeeded()
        } else if isCurrent || hasPrint || !prints {
            self.printTimer?.invalidate()
            self.printTimer = nil
            self.printedSpoken = self.targetSpoken
            self.printedTranslated = self.targetTranslated
            self.applyPrintedText()
        }
    }

    private func applyChrome(
        typeface: TheaterTypeface,
        spokenFontSize: CGFloat,
        translatedFontSize: CGFloat,
        spokenColor: NSColor,
        translatedColor: NSColor,
        isCurrent: Bool,
        shadowColor: NSColor?,
        shadowBlur: CGFloat
    ) {
        self.spokenFont = typeface.nsFont(size: spokenFontSize, weight: .semibold)
        self.translatedFont = typeface.nsFont(size: translatedFontSize, weight: .semibold)
        let visible = TheaterCaptionVisibility.appliedAlphas(
            spoken: spokenColor,
            translated: translatedColor,
            isCurrent: isCurrent
        )
        self.spokenColor = visible.spoken
        self.translatedColor = visible.translated
        if let shadowColor, shadowBlur > 0 {
            let shadow = NSShadow()
            shadow.shadowColor = shadowColor
            shadow.shadowBlurRadius = shadowBlur
            shadow.shadowOffset = .zero
            self.captionShadow = shadow
        } else {
            self.captionShadow = nil
        }
    }

    private func resetPrintProgress() {
        self.printTimer?.invalidate()
        self.printTimer = nil
        self.targetSpoken = ""
        self.targetTranslated = ""
        self.printedSpoken = ""
        self.printedTranslated = ""
        self.lastReportedHeight = 0
    }

    private func startPrintIfNeeded() {
        let pending = self.printedSpoken != self.targetSpoken
            || self.printedTranslated != self.targetTranslated
        guard pending else {
            self.printTimer?.invalidate()
            self.printTimer = nil
            self.applyPrintedText()
            return
        }
        if self.printTimer == nil {
            self.advancePrint()
            self.scheduleNextPrintTick()
        }
    }

    private func scheduleNextPrintTick() {
        self.printTimer?.invalidate()
        self.printTimer = nil
        if self.printedSpoken == self.targetSpoken, self.printedTranslated == self.targetTranslated {
            return
        }
        let interval = self.printStyle.printStepSeconds(
            printedSpoken: self.printedSpoken,
            targetSpoken: self.targetSpoken,
            printedTranslated: self.printedTranslated,
            targetTranslated: self.targetTranslated
        )
        let timer = Timer(timeInterval: max(interval, 0.016), repeats: false) { [weak self] _ in
            guard let self else { return }
            self.printTimer = nil
            self.advancePrint()
            self.scheduleNextPrintTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.printTimer = timer
    }

    private func advancePrint() {
        let nextSpoken = TheaterLinePrinter.advance(
            self.printedSpoken,
            toward: self.targetSpoken,
            emptyTarget: .hold,
            style: self.printStyle
        )
        let nextTranslated = TheaterLinePrinter.advance(
            self.printedTranslated,
            toward: self.targetTranslated,
            emptyTarget: .hold,
            style: self.printStyle
        )
        self.printedSpoken = nextSpoken
        self.printedTranslated = nextTranslated
        self.applyPrintedText()
    }

    private func applyPrintedText() {
        self.syncRows(width: self.resolvedWrapWidth(self.bounds.width))
    }

    private func resolvedWrapWidth(_ proposed: CGFloat) -> CGFloat {
        let candidate = max(proposed, 1)
        if candidate < TheaterBilingualWrap.minimumWrapWidth {
            return self.wrapWidth >= TheaterBilingualWrap.minimumWrapWidth
                ? self.wrapWidth
                : candidate
        }
        if self.printTimer != nil, self.wrapWidth >= TheaterBilingualWrap.minimumWrapWidth {
            // A wider lock than the view clips the line. Rewrap rather than cut off.
            if self.wrapWidth - candidate >= TheaterBilingualWrap.wrapWidthHysteresis {
                return candidate
            }
            return self.wrapWidth
        }
        return TheaterBilingualWrap.resolvedWrapWidth(proposed: candidate, locked: self.wrapWidth)
    }

    private func syncRows(width: CGFloat) {
        guard !self.isSyncingRows else { return }
        self.isSyncingRows = true
        defer { self.isSyncingRows = false }

        let wrap = self.resolvedWrapWidth(width)
        let rows = TheaterBilingualWrap.revealedRows(
            spoken: self.targetSpoken,
            translated: self.targetTranslated,
            printedSpoken: self.printedSpoken,
            printedTranslated: self.printedTranslated,
            spokenFont: self.spokenFont,
            translatedFont: self.translatedFont,
            width: wrap
        )
        self.wrapWidth = wrap
        self.displayRows = rows
        self.reportRevealedHeight()

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
            let visible = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if field.stringValue != visible {
                field.stringValue = visible
            }
            field.font = row.isSpoken ? self.spokenFont : self.translatedFont
            field.textColor = visible.isEmpty
                ? .clear
                : (row.isSpoken ? self.spokenColor : self.translatedColor)
            field.shadow = visible.isEmpty ? nil : self.captionShadow
            field.isSelectable = !row.isSpoken && !visible.isEmpty
        }
        self.needsLayout = true
        self.invalidateIntrinsicContentSize()
    }

    private func reportRevealedHeight() {
        let height = max(
            TheaterBilingualWrap.boardHeight(
                rows: self.displayRows,
                spokenFont: self.spokenFont,
                translatedFont: self.translatedFont
            ),
            1
        )
        guard abs(height - self.lastReportedHeight) >= 1 else { return }
        self.lastReportedHeight = height
        let callback = self.onRevealedHeightChange
        DispatchQueue.main.async {
            callback?(height)
        }
    }

    override func layout() {
        super.layout()
        let width = max(self.bounds.width, 1)
        var y: CGFloat = 0
        for (index, view) in self.lineViews.enumerated() {
            let spoken = index < self.displayRows.count ? self.displayRows[index].isSpoken : false
            let lineHeight = TheaterBilingualWrap.lineHeight(
                for: spoken ? self.spokenFont : self.translatedFont
            )
            view.frame = NSRect(x: 0, y: y, width: width, height: lineHeight)
            y += lineHeight + TheaterBilingualWrap.rowSpacing
        }
    }

    override var intrinsicContentSize: NSSize {
        let height = TheaterBilingualWrap.boardHeight(
            rows: self.displayRows,
            spokenFont: self.spokenFont,
            translatedFont: self.translatedFont
        )
        return NSSize(width: NSView.noIntrinsicMetric, height: max(height, 1))
    }

    override var isFlipped: Bool { true }

    private func makeLineField() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = true
        label.textColor = .white
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        label.usesSingleLineMode = true
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
