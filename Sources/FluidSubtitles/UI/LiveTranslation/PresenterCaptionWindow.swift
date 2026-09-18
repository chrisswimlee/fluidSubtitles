import AppKit
import Combine
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
    private var appliedWindowStyle: (hide: Bool, presentation: String)?
    private var persistFrameWork: DispatchWorkItem?
    private var boardCommitted: [String] = []
    private var boardIDs: [UInt64] = []
    private var boardNextID: UInt64 = 1
    private var boardSources: [String] = []
    private var boardPending: [String] = []
    private var boardInFlight = 0
    private var liveDraft = ""
    private var liveSource = ""
    private var spokenStabilizer = TheaterStableText()
    private var revealTailWork: DispatchWorkItem?
    /// No newer guess this long means the speaker paused; show the whole line.
    private static let revealTailDelay: TimeInterval = 0.6

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
        SettingsStore.shared.theaterMinimized = false
        self.observeSettings()
        self.applyWindowSharing()
        self.applyPresentationStyle()
        self.restoreFrame()
        self.rememberExternalApp()
        self.applyMinimizedLayout()
        if TheaterMinimize.shouldOrderFront(minimized: SettingsStore.shared.theaterMinimized) {
            if self.model.isEditing {
                self.panel?.makeKeyAndOrderFront(nil)
            } else {
                self.panel?.orderFront(nil)
            }
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
        self.boardInFlight = 0
        self.liveDraft = ""
        self.liveSource = ""
        self.spokenStabilizer.reset()
        self.revealTailWork?.cancel()
        self.revealTailWork = nil
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
        self.model.inFlightCount = 0
        self.model.canRetryTranslation = false
        self.model.approachingLineLimit = false
        self.model.latencyReadout = ""
        self.model.compactLatencyReadout = ""
        self.model.paceCueLabel = ""
        self.model.paceCueCompactLabel = ""
        self.model.paceCueKind = ""
    }

    func update(
        source: String,
        draft: String,
        committed: [String],
        committedIDs: [UInt64] = [],
        nextCaptionID: UInt64 = 1,
        committedSources: [String] = [],
        pendingSources: [String] = [],
        inFlightCount: Int = 0,
        pairLabel: String,
        status: String,
        statusKind: TheaterStatusKind = .idle,
        isListening: Bool,
        isPaused: Bool = false,
        canRetryTranslation: Bool = false,
        approachingLineLimit: Bool = false,
        latencyReadout: String = "",
        compactLatencyReadout: String = "",
        paceCue: TheaterPaceCue.Snapshot? = nil
    ) {
        self.boardCommitted = committed
        self.boardIDs = committedIDs
        self.boardNextID = nextCaptionID
        self.boardSources = committedSources
        self.boardPending = pendingSources
        self.boardInFlight = inFlightCount
        self.liveDraft = draft
        self.liveSource = self.stableSpoken(source, isLive: isListening && !isPaused)
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
        let paceLabel = paceCue?.label ?? ""
        let paceCompact = paceCue?.compactLabel ?? ""
        let paceKind = paceCue?.kind.rawValue ?? ""
        if self.model.paceCueLabel != paceLabel {
            self.model.paceCueLabel = paceLabel
        }
        if self.model.paceCueCompactLabel != paceCompact {
            self.model.paceCueCompactLabel = paceCompact
        }
        if self.model.paceCueKind != paceKind {
            self.model.paceCueKind = paceKind
        }
        if !self.model.isEditing {
            let document = Self.captionDocument(committed: committed, draft: draft)
            if self.model.editedText != document {
                self.model.editedText = document
            }
        }
        self.applyPresentedBoard()
    }

    /// Type only words recognition has settled on. Stop or pause shows all.
    private func stableSpoken(_ source: String, isLive: Bool) -> String {
        let previous = self.spokenStabilizer.hypothesis
        let shown = self.spokenStabilizer.ingest(source)
        guard isLive else {
            self.revealTailWork?.cancel()
            self.revealTailWork = nil
            return self.spokenStabilizer.revealAll()
        }
        // Only a new guess restarts the pause clock; status or latency
        // refreshes must not keep the tail hidden.
        let isNewGuess = self.spokenStabilizer.hypothesis != previous
        if isNewGuess {
            self.revealTailWork?.cancel()
            self.revealTailWork = nil
        }
        if isNewGuess, self.spokenStabilizer.hasHiddenTail {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.revealTailWork = nil
                self.liveSource = self.spokenStabilizer.revealAll()
                self.applyPresentedBoard()
            }
            self.revealTailWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.revealTailDelay, execute: work)
        }
        return shown
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
        if TheaterMinimize.shouldOrderFront(minimized: settings.theaterMinimized) {
            if self.model.isEditing {
                self.panel?.makeKeyAndOrderFront(nil)
            } else {
                self.panel?.orderFront(nil)
            }
        }
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
        self.schedulePersistFrame()
    }

    func windowDidResize(_ notification: Notification) {
        guard !(self.panel?.inLiveResize ?? false) else { return }
        self.schedulePersistFrame()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        self.schedulePersistFrame()
    }

    /// Drags fire many move events; write settings once the window settles.
    private func schedulePersistFrame() {
        self.persistFrameWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persistFrame() }
        self.persistFrameWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func dismissCaptions() {
        guard !self.isDismissing else { return }
        self.isDismissing = true
        SettingsStore.shared.theaterWindowEnabled = false
        SettingsStore.shared.theaterMinimized = false
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
        if self.model.inFlightCount != self.boardInFlight { self.model.inFlightCount = self.boardInFlight }
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
                    self?.applyWindowStyleIfChanged()
                }
            }
            .store(in: &self.settingsCancellables)
        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refitAfterScreenChange()
            }
            .store(in: &self.settingsCancellables)
    }

    private func applyWindowStyleIfChanged() {
        let settings = SettingsStore.shared
        let current = (hide: settings.theaterHideFromScreenShare, presentation: "\(settings.theaterPresentation)")
        if let applied = self.appliedWindowStyle, applied == current { return }
        self.applyWindowSharing()
        self.applyPresentationStyle()
    }

    /// A projector unplugged mid-talk must not strand captions off-screen.
    private func refitAfterScreenChange() {
        guard let panel = self.panel, panel.isVisible else { return }
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(panel.frame) }
        let screen = onScreen ? (panel.screen ?? Self.preferredScreen()) : Self.preferredScreen()
        guard let screen else { return }
        if let preset = SettingsStore.shared.theaterPositionPreset {
            panel.setFrame(preset.frame(in: screen.visibleFrame), display: true)
            return
        }
        let stored = onScreen ? panel.frame : nil
        panel.setFrame(
            TheaterWindowPlacement.resolvedFrame(stored: stored, visible: screen.visibleFrame),
            display: true
        )
    }

    private func applyWindowSharing() {
        guard let panel = self.panel else { return }
        TheaterWindowSharing.apply(
            panel,
            hideFromScreenShare: SettingsStore.shared.theaterHideFromScreenShare
        )
        self.appliedWindowStyle = (
            hide: SettingsStore.shared.theaterHideFromScreenShare,
            presentation: "\(SettingsStore.shared.theaterPresentation)"
        )
    }

    private func applyPresentationStyle() {
        guard let panel = self.panel else { return }
        self.appliedWindowStyle = (
            hide: SettingsStore.shared.theaterHideFromScreenShare,
            presentation: "\(SettingsStore.shared.theaterPresentation)"
        )
        let transparent = SettingsStore.shared.theaterPresentation == .transparent
        panel.hasShadow = !transparent
        panel.isOpaque = false
        panel.backgroundColor = .clear
    }

    private final class TheaterCaptionPanel: NSPanel {
        override func miniaturize(_ sender: Any?) {
            PresenterCaptionController.shared.toggleMinimized()
        }
    }

    private static func makePanel(model: PresenterCaptionModel) -> NSPanel {
        let view = PresenterCaptionView(model: model)
        let hosting = NSHostingController(rootView: view)
        let panel = TheaterCaptionPanel(
            contentRect: NSRect(x: 80, y: 80, width: 1100, height: 440),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
                .fullSizeContentView,
                .nonactivatingPanel,
            ],
            backing: .buffered,
            defer: false
        )
        panel.title = "\(FluidProduct.displayName) Theater"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        // .floating keeps captions above normal app windows without
        // competing with the menu bar / status items the way .statusBar did.
        panel.level = .floating
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
        SettingsStore.shared.theaterScreenName = panel.screen.map(Self.screenKey) ?? ""
        if SettingsStore.shared.theaterMinimized {
            return
        }
        if let preset = SettingsStore.shared.theaterPositionPreset,
           let screen = panel.screen,
           !Self.isClose(panel.frame, preset.frame(in: screen.visibleFrame))
        {
            SettingsStore.shared.theaterPositionPreset = nil
        }
        let frame = NSStringFromRect(panel.frame)
        SettingsStore.shared.theaterWindowFrame = frame
        SettingsStore.shared.theaterExpandedWindowFrame = frame
    }

    private func applyMinimizedLayout() {
        guard let panel = self.panel else { return }
        if SettingsStore.shared.theaterMinimized {
            if panel.isVisible {
                SettingsStore.shared.theaterExpandedWindowFrame = NSStringFromRect(panel.frame)
                SettingsStore.shared.theaterWindowFrame = NSStringFromRect(panel.frame)
            }
            panel.orderOut(nil)
            return
        }
        panel.minSize = NSSize(width: 640, height: 260)
        let screen = panel.screen ?? Self.preferredScreen()
        let stored = SettingsStore.shared.theaterExpandedWindowFrame
        let storedRect = stored.isEmpty ? nil : NSRectFromString(stored)
        if let screen, let preset = SettingsStore.shared.theaterPositionPreset {
            panel.setFrame(preset.frame(in: screen.visibleFrame), display: true)
            return
        }
        if let screen {
            panel.setFrame(
                TheaterWindowPlacement.resolvedFrame(
                    stored: storedRect,
                    visible: screen.visibleFrame
                ),
                display: true
            )
            return
        }
        var frame = panel.frame
        if frame.height < 260 {
            let height = TheaterWindowPlacement.legacyDefaultSize.height
            frame.origin.y -= height - frame.height
            frame.size.height = height
            panel.setFrame(frame, display: true)
        }
    }

    private func restoreFrame() {
        let stored = SettingsStore.shared.theaterWindowFrame
        let storedRect = stored.isEmpty ? nil : NSRectFromString(stored)
        let screen = Self.screen(named: SettingsStore.shared.theaterScreenName) ?? Self.preferredScreen()
        if let screen, let preset = SettingsStore.shared.theaterPositionPreset {
            self.panel?.setFrame(preset.frame(in: screen.visibleFrame), display: true)
        } else if let screen {
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

    /// Snap the board to a preset on the display it is on now.
    func applyPositionPreset(_ preset: TheaterPositionPreset) {
        guard let panel = self.panel else { return }
        guard let screen = panel.screen ?? Self.preferredScreen() else { return }
        SettingsStore.shared.theaterPositionPreset = preset
        panel.setFrame(preset.frame(in: screen.visibleFrame), display: true, animate: true)
        self.schedulePersistFrame()
    }

    private static func isClose(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 2 && abs(lhs.minY - rhs.minY) < 2
            && abs(lhs.width - rhs.width) < 2 && abs(lhs.height - rhs.height) < 2
    }

    /// "Name|displayID" so two identical monitors stay distinct. Older
    /// values are a bare name and still match by name.
    private static func screenKey(_ screen: NSScreen) -> String {
        guard let id = Self.displayID(screen) else { return screen.localizedName }
        return "\(screen.localizedName)|\(id)"
    }

    private static func displayID(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private static func screen(named key: String) -> NSScreen? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: "|", maxSplits: 1).map(String.init)
        if parts.count == 2, let id = UInt32(parts[1]),
           let match = NSScreen.screens.first(where: { Self.displayID($0) == id })
        {
            return match
        }
        let name = parts.first ?? trimmed
        return NSScreen.screens.first { $0.localizedName == name }
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
