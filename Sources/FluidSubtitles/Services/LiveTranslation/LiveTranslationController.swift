import AppKit
import AVFoundation
import Combine
import Foundation

@MainActor
final class LiveTranslationController: ObservableObject {
    static let shared = LiveTranslationController()

    @Published private(set) var isSessionActive = false
    @Published private(set) var isPaused = false
    @Published private(set) var listenKind: TranslationListenKind?
    @Published private(set) var packAvailability: TranslationPackAvailability = .unknown
    let subscriber = LiveTranslationSubscriber()
    let appleEngine = AppleTranslationEngine.shared

    var onStartCaptionListening: (() -> Void)?
    var onStartInsertListening: (() -> Void)?
    var onStopListening: (() async -> Void)?
    var onInsertCaption: ((String) -> Void)?

    private var abandonCaptionSession = false
    private var sessionToken: UInt64 = 0
    private var stopToken: UInt64 = 0
    private var cancellables: Set<AnyCancellable> = []
    private var pendingThermalDowngrade = false
    private var didStartFreshThisProcess = false
    private var needsSpokenEngineReload = false

    var shouldHandleTranslationStop: Bool {
        self.isSessionActive || self.abandonCaptionSession
    }

    private init() {
        self.subscriber.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.refreshPresenter()
                    if self.isSessionActive, self.listenKind != .captions {
                        self.objectWillChange.send()
                    }
                }
            }
            .store(in: &self.cancellables)
        NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .sink { [weak self] _ in
                self?.subscriber.refreshThermal()
                self?.noteThermalStateChanged()
                self?.refreshPresenter()
            }
            .store(in: &self.cancellables)
    }

    var overlayText: String {
        guard self.isSessionActive else { return self.subscriber.sourceDraft }
        let target = self.subscriber.liveCaptionText
        let source = self.subscriber.liveSpokenText
        if SettingsStore.shared.translationShowSource, !source.isEmpty, target != source {
            if target.isEmpty { return source }
            return "\(source)\n\(target)"
        }
        return target.isEmpty ? source : target
    }

    func beginSession(kind: TranslationListenKind) {
        self.alignSpokenEngineWithTheater()
        self.sessionToken += 1
        self.abandonCaptionSession = false
        self.isSessionActive = true
        self.isPaused = false
        self.listenKind = kind
        PresenterCaptionController.shared.commitEdits()
        if kind == .captions {
            self.startFreshTheaterBoard()
        }
        self.subscriber.beginListening()
        self.warmAppleTranslation()
        if kind == .captions, !SettingsStore.shared.theaterWindowEnabled {
            PresenterCaptionController.shared.setVisible(true)
        }
        self.refreshPresenter()
    }

    func markFirstBuffer() {
        guard self.isSessionActive else { return }
        self.subscriber.noteFirstBuffer()
    }

    func markSpeechStart(hostTime: UInt64) {
        guard self.isSessionActive else { return }
        self.subscriber.noteSpeechStart(hostTime: hostTime)
    }

    func markSilenceHold() {
        guard self.isSessionActive else { return }
        self.subscriber.noteSilenceHold()
        self.applyPendingThermalDowngradeIfNeeded()
    }

    func handleEndOfUtterance() {
        guard self.isSessionActive else { return }
        self.subscriber.handleEndOfUtterance()
        self.refreshPresenter()
    }

    func handlePartial(_ text: String) {
        guard self.isSessionActive else { return }
        self.subscriber.handlePartial(text)
        self.refreshPresenter()
        if self.listenKind == .insert {
            NotchOverlayManager.shared.updateTranscriptionText(self.overlayText)
        }
    }

    func finishSession(finalSource: String) async -> String {
        let token = self.stopToken
        guard token == self.sessionToken else {
            if !self.isSessionActive {
                self.abandonCaptionSession = false
                self.listenKind = nil
            }
            return ""
        }
        if self.abandonCaptionSession {
            self.abandonCaptionSession = false
            self.isSessionActive = false
            self.listenKind = nil
            self.clearThermalEngineOverride()
            self.subscriber.endListening()
            self.persistBoard()
            return ""
        }
        let kind = self.listenKind
        let translated = await self.subscriber.translateFinal(finalSource)
        guard token == self.sessionToken, !self.abandonCaptionSession else {
            if self.abandonCaptionSession {
                self.abandonCaptionSession = false
                self.isSessionActive = false
                self.listenKind = nil
                self.clearThermalEngineOverride()
                self.subscriber.endListening()
                self.persistBoard()
            }
            return ""
        }
        self.isSessionActive = false
        self.isPaused = false
        self.listenKind = nil
        self.clearThermalEngineOverride()
        let text = kind == .insert
            ? self.subscriber.consumePendingInsertDocument()
            : translated
        self.refreshPresenter()
        return text
    }

    func cancelSession() {
        self.abandonCaptionSession = false
        self.isSessionActive = false
        self.isPaused = false
        self.listenKind = nil
        self.clearThermalEngineOverride()
        self.subscriber.endListening()
        self.refreshPresenter()
    }

    func theaterWasClosed() {
        self.persistBoard()
        if self.listenKind == .insert {
            PresenterCaptionController.shared.clearDisplay()
            return
        }
        if self.listenKind == .captions {
            self.abandonCaptionSession = true
            self.stopToken = self.sessionToken
            self.isSessionActive = false
            self.isPaused = false
            self.stopListening()
        }
        self.subscriber.endListening()
        PresenterCaptionController.shared.clearDisplay()
    }

    func syncTheater() {
        self.refreshPresenter()
    }

    func swapDirection() {
        let settings = SettingsStore.shared
        let currentSource = SpokenLanguageResolver.sourceLanguage(settings: settings)
        let currentTarget = SpokenLanguageResolver.targetLanguage(settings: settings)
        if currentSource.id == currentTarget.id { return }
        SpokenLanguageResolver.setSourceLanguage(currentTarget, settings: settings)
        settings.translationTargetLanguageID = currentSource.id
        self.finishLanguageChange()
    }

    func applyTheaterSessionMode(_ mode: TheaterSessionMode) {
        let settings = SettingsStore.shared
        let current = settings.theaterSessionMode
        if current == mode { return }
        if current == .translation, mode == .transcription {
            settings.theaterLastTranslateTargetLanguageID = SpokenLanguageResolver.targetLanguage(
                settings: settings
            ).id
            settings.translationTargetLanguageID = SpokenLanguageResolver.sourceLanguage(settings: settings).id
        }
        if current == .transcription, mode == .translation {
            let remembered = settings.theaterLastTranslateTargetLanguageID
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !remembered.isEmpty, remembered != SpokenLanguageResolver.sourceLanguage(settings: settings).id {
                settings.translationTargetLanguageID = remembered
            }
        }
        settings.theaterSessionMode = mode
        if self.isSessionActive, self.listenKind == .captions {
            self.stopListening()
        }
        self.finishLanguageChange()
    }

    func applySourceLanguage(_ id: String) {
        guard let language = TranslationLanguageCatalog.language(id: id) else { return }
        SpokenLanguageResolver.setSourceLanguage(language)
        if SettingsStore.shared.theaterSessionMode == .transcription {
            SettingsStore.shared.translationTargetLanguageID = language.id
        }
        self.finishLanguageChange()
    }

    func applyTargetLanguage(_ id: String) {
        guard let language = TranslationLanguageCatalog.language(id: id) else { return }
        SettingsStore.shared.translationTargetLanguageID = language.id
        self.finishLanguageChange()
    }

    private func finishLanguageChange() {
        if self.isSessionActive {
            self.stopListening()
        }
        self.alignSpokenEngineWithTheater()
        let source = SpokenLanguageResolver.sourceLanguage()
        let target = SpokenLanguageResolver.targetLanguage()
        self.warmAppleTranslation(source: source, target: target)
        self.subscriber.noteLanguagePairChanged()
        if let mismatch = SpokenLanguageResolver.voiceEngineMismatchMessage() {
            self.subscriber.reportFailure(mismatch)
        }
        self.refreshPresenter()
    }

    /// I speak owns the Voice Engine listening language. Leftover locales crash
    /// Speech Analyzer / Apple Translation when Translate starts on a new pair.
    func alignSpokenEngineWithTheater() {
        let changed = SpokenLanguageResolver.syncSpokenEngineToTheater()
        VoiceEngineLanguageCatalog.ensureCompatibleEngine(
            forLanguageID: SpokenLanguageResolver.sourceLanguage().id
        )
        self.reloadSpokenEngineIfNeeded(changed)
    }

    private func reloadSpokenEngineIfNeeded(_ changed: Bool) {
        if changed {
            self.needsSpokenEngineReload = true
        }
        guard self.needsSpokenEngineReload else { return }
        let asr = AppServices.shared.asr
        guard !asr.isRunningOrStarting else { return }
        asr.resetTranscriptionProvider()
        self.needsSpokenEngineReload = false
    }

    /// Starts Apple Translation before the first clause: pair change and Listen both hit this.
    private func warmAppleTranslation(
        source: TranslationLanguage? = nil,
        target: TranslationLanguage? = nil
    ) {
        let source = source ?? SpokenLanguageResolver.sourceLanguage()
        let target = target ?? SpokenLanguageResolver.targetLanguage()
        TranslationSessionHostController.install()
        self.appleEngine.prepare(source: source, target: target)
        Task {
            await self.appleEngine.warm(source: source, target: target)
            await self.refreshPackAvailability(source: source, target: target)
        }
    }

    func applyEditedDocument(_ text: String) {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        self.subscriber.applyEditedLines(lines)
        self.refreshPresenter()
    }

    func startCaptionListening() {
        PresenterCaptionController.shared.commitEdits()
        Task {
            let ready = await self.ensureReadyToListen()
            guard ready else { return }
            self.onStartCaptionListening?()
        }
    }

    func pauseListening() {
        guard self.isSessionActive, self.listenKind == .captions, !self.isPaused else { return }
        self.isPaused = true
        AppServices.shared.asr.setCapturePaused(true)
        self.refreshPresenter()
    }

    func resumeListening() {
        guard self.isSessionActive, self.isPaused else { return }
        self.isPaused = false
        AppServices.shared.asr.setCapturePaused(false)
        self.refreshPresenter()
    }

    func handleWatchCaptureStopped(_ message: String) {
        guard self.isSessionActive, self.listenKind == .captions else { return }
        self.subscriber.reportFailure(WatchCaptureStop.userFacingStatus(message))
        self.subscriber.endListening()
        self.abandonCaptionSession = true
        self.stopToken = self.sessionToken
        self.isSessionActive = false
        self.isPaused = false
        self.stopListening()
        self.refreshPresenter()
    }

    func startInsertListening() {
        Task {
            let ready = await self.ensureReadyToListen()
            guard ready else { return }
            self.onStartInsertListening?()
        }
    }

    func toggleCaptionListening() {
        if self.isSessionActive, self.listenKind == .captions {
            self.stopListening()
            return
        }
        guard TheaterAvailability.isSupported else {
            self.subscriber.reportFailure(TheaterAvailability.unsupportedCopy)
            self.refreshPresenter()
            return
        }
        PresenterCaptionController.shared.setVisible(true)
        self.startCaptionListening()
    }

    func ensureReadyToListen() async -> Bool {
        guard TheaterAvailability.isSupported else {
            self.subscriber.reportFailure(TheaterAvailability.unsupportedCopy)
            self.refreshPresenter()
            return false
        }
        let source = SpokenLanguageResolver.sourceLanguage()
        let target = SpokenLanguageResolver.targetLanguage()
        self.alignSpokenEngineWithTheater()
        if !SpokenLanguageResolver.voiceEngineSupportsSource() {
            self.subscriber.reportFailure(
                SpokenLanguageResolver.voiceEngineMismatchMessage()
                    ?? "Switch Voice Engine to hear \(source.displayName)."
            )
            self.refreshPresenter()
            return false
        }
        let model = SettingsStore.shared.selectedSpeechModel
        if !model.isInstalled {
            self.subscriber.reportFailure(
                "Download \(model.displayName) before Listen. Apple Speech works without a download."
            )
            self.refreshPresenter()
            return false
        }
        self.applyThermalDowngradeIfNeeded(immediate: true)
        let granted = await MicrophoneAccess.authorize(updating: AppServices.shared.asr)
        if !granted {
            self.subscriber.reportFailure(MicrophoneAccess.deniedCopy)
            self.refreshPresenter()
            return false
        }
        if SettingsStore.shared.theaterSessionMode == .transcription || source.id == target.id {
            self.packAvailability = .installed
            return true
        }
        await self.appleEngine.warm(source: source, target: target)
        let availability = await self.appleEngine.packAvailability(source: source, target: target)
        self.packAvailability = availability
        switch availability {
        case .installed:
            return true
        case .supported:
            self.subscriber.reportFailure("Download the language pack before Listen.")
            self.refreshPresenter()
            self.appleEngine.requestLanguagePackDownload()
            return false
        case .unsupported:
            self.subscriber.reportFailure("This pair is not supported by Apple Translation.")
            self.refreshPresenter()
            return false
        case .unknown:
            self.subscriber.reportFailure("Apple Translation is not ready yet.")
            self.refreshPresenter()
            return false
        }
    }

    func reportListenFailure(_ message: String) {
        self.subscriber.reportFailure(message)
        self.refreshPresenter()
    }

    func reportListenStatus(_ message: String, kind: TheaterStatusKind) {
        self.subscriber.reportStatus(message, kind: kind)
        self.refreshPresenter()
    }

    func retryFailedTranslation() {
        self.subscriber.retryFailedTranslation()
        self.refreshPresenter()
    }

    func flushArchive() {
        self.subscriber.flushArchive()
    }

    func noteThermalStateChanged() {
        guard self.isSessionActive else { return }
        guard LiveTranslationSilenceGate.shouldDowngradeEngine(ProcessInfo.processInfo.thermalState)
        else { return }
        self.pendingThermalDowngrade = true
    }

    func applyPendingThermalDowngradeIfNeeded() {
        guard self.pendingThermalDowngrade else { return }
        self.applyThermalDowngradeIfNeeded(immediate: true)
    }

    func applyThermalDowngradeIfNeeded(immediate: Bool) {
        let asr = AppServices.shared.asr
        let thermal = ProcessInfo.processInfo.thermalState
        guard LiveTranslationThermalEngine.shouldApply(
            current: SettingsStore.shared.selectedSpeechModel,
            thermal: thermal,
            alreadyOverridden: asr.hasThermalSpeechOverride
        ) else { return }
        if immediate == false, self.isSessionActive {
            self.pendingThermalDowngrade = true
            return
        }
        let fallback = LiveTranslationThermalEngine.fallbackModel()
        asr.applyThermalSpeechOverride(fallback)
        self.pendingThermalDowngrade = false
        self.subscriber.reportStatus(LiveTranslationThermalEngine.statusCopy, kind: .info)
        self.refreshPresenter()
    }

    func clearThermalEngineOverride() {
        self.pendingThermalDowngrade = false
        AppServices.shared.asr.clearThermalSpeechOverride()
    }

    func persistBoard() {
        self.subscriber.flushArchive()
        let snapshot = self.subscriber.snapshot()
        SettingsStore.shared.theaterBoardSnapshot = snapshot.entries.isEmpty ? nil : snapshot
        self.subscriber.persistLastLatency()
    }

    func stopListening() {
        self.stopToken = self.sessionToken
        Task { await self.onStopListening?() }
    }

    func insertCaptionText() {
        let text: String
        if PresenterCaptionController.shared.isEditing {
            text = PresenterCaptionController.shared.documentTextForDelivery()
            self.subscriber.markAllPosted()
        } else {
            text = self.subscriber.consumePendingInsertDocument()
        }
        guard !text.isEmpty else { return }
        self.onInsertCaption?(text)
    }

    func copyCaptionText() {
        let text = PresenterCaptionController.shared.documentTextForDelivery()
        guard !text.isEmpty else { return }
        ClipboardService.copyToClipboard(text)
    }

    var hasClearableBoard: Bool {
        if self.subscriber.archivedLineCount > 0 { return true }
        if self.subscriber.committedLines.contains(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            return true
        }
        return PresenterCaptionController.shared.hasDeliverableText
    }

    var hasUndoableCaption: Bool {
        self.subscriber.committedLines.contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    func undoLastCaption() {
        guard self.hasUndoableCaption else { return }
        self.subscriber.removeLastCommittedLine()
        self.persistBoard()
        self.refreshPresenter()
        self.objectWillChange.send()
    }

    func clearBoard() {
        self.startFreshTheaterBoard()
        if self.isSessionActive {
            self.subscriber.beginListening()
        }
        self.objectWillChange.send()
    }

    /// Empty Theater and the session archive. A crash leftover or last talk
    /// must not come back on launch or a new caption Listen.
    func startFreshTheaterBoard() {
        PresenterCaptionController.shared.cancelEditing()
        self.subscriber.reset(clearArchive: true)
        self.persistBoard()
        PresenterCaptionController.shared.clearDisplay()
        self.refreshPresenter()
    }

    func refreshPackAvailability(
        source: TranslationLanguage? = nil,
        target: TranslationLanguage? = nil
    ) async {
        let source = source ?? SpokenLanguageResolver.sourceLanguage()
        let target = target ?? SpokenLanguageResolver.targetLanguage()
        if source.id == target.id {
            self.packAvailability = .installed
            return
        }
        self.packAvailability = await self.appleEngine.packAvailability(source: source, target: target)
    }

    func restoreTheaterIfNeeded() {
        if !TheaterAvailability.isSupported {
            SettingsStore.shared.theaterWindowEnabled = false
            PresenterCaptionController.shared.orderOutIfClosed()
            Task { await self.refreshPackAvailability() }
            return
        }
        self.alignSpokenEngineWithTheater()
        TranslationSessionHostController.install()
        let wasEnabled = SettingsStore.shared.theaterWindowEnabled
        if wasEnabled {
            SettingsStore.shared.theaterWindowEnabled = false
        }
        if !self.didStartFreshThisProcess {
            self.didStartFreshThisProcess = true
            self.startFreshTheaterBoard()
        }
        self.subscriber.recountArchive()
        PresenterCaptionController.shared.orderOutIfClosed()
        Task { await self.refreshPackAvailability() }
    }

    func restoreBoardIfNeeded() {
        self.subscriber.recountArchive()
    }

    private func refreshPresenter() {
        guard SettingsStore.shared.theaterWindowEnabled else { return }
        var status = self.subscriber.statusText
        var statusKind = self.subscriber.statusKind
        if self.isPaused {
            status = "Paused"
            statusKind = .info
        } else if status.isEmpty, let window = self.subscriber.lineWindowStatus {
            status = window
            statusKind = .info
        }
        PresenterCaptionController.shared.update(
            source: self.subscriber.liveSpokenText,
            draft: self.subscriber.liveCaptionText,
            committed: self.subscriber.committedLines,
            committedIDs: self.subscriber.committedLineIDs,
            nextCaptionID: self.subscriber.nextCaptionID,
            committedSources: self.subscriber.committedSourceLines,
            pendingSources: self.subscriber.pendingSpokenLines,
            pairLabel: SpokenLanguageResolver.pairLabel(),
            status: status,
            statusKind: statusKind,
            isListening: self.isSessionActive,
            isPaused: self.isPaused,
            canRetryTranslation: self.subscriber.canRetryTranslation,
            approachingLineLimit: self.subscriber.isApproachingLineLimit,
            latencyReadout: self.subscriber.lastLatencySample.displayText,
            compactLatencyReadout: self.subscriber.lastLatencySample.compactText
        )
    }
}
