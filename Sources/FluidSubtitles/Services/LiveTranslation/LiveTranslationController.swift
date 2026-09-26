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
    /// Bumps when Copy writes the pasteboard, so chrome can say Copied.
    @Published private(set) var copyFlashToken = 0
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
    private var isStartingListen = false
    @Published private(set) var isFinishingSession = false
    private var presenterRefreshPending = false
    private(set) var alignSpokenEngineCallCountForTesting = 0
    private var sessionTrace: LiveTranslationSessionTrace?

    var shouldHandleTranslationStop: Bool {
        self.isSessionActive || self.abandonCaptionSession
    }

    private init() {
        self.subscriber.objectWillChange
            .sink { [weak self] _ in
                guard let self else { return }
                if self.presenterRefreshPending { return }
                self.presenterRefreshPending = true
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.presenterRefreshPending = false
                    self.performRefreshPresenter()
                    if self.isSessionActive, self.listenKind != .captions {
                        self.objectWillChange.send()
                    }
                }
            }
            .store(in: &self.cancellables)
        NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.subscriber.refreshThermal()
                self?.noteThermalStateChanged()
                self?.refreshPresenter()
            }
            .store(in: &self.cancellables)
    }

    /// Insert notch text. The Theater board paints accepted clauses instead.
    var overlayText: String {
        guard self.isSessionActive else { return self.subscriber.sourceDraft }
        let target = self.subscriber.liveCaptionText
        let source = self.subscriber.liveSpokenText
        if !SpokenLanguageResolver.isSameLanguagePair() {
            return target
        }
        return target.isEmpty ? source : target
    }

    func beginSession(kind: TranslationListenKind) {
        if kind == .captions, SettingsStore.shared.theaterPresentation == .transparent {
            // They found Listen in Overlay; the coach line has done its job.
            SettingsStore.shared.theaterOverlayCoachSeen = true
        }
        self.isStartingListen = false
        self.isFinishingSession = false
        if self.sessionTrace != nil {
            self.endSessionTrace(outcome: "replaced")
        }
        self.sessionToken += 1
        self.abandonCaptionSession = false
        self.isSessionActive = true
        self.isPaused = false
        self.listenKind = kind
        let trace = LiveTranslationSessionTrace(
            token: self.sessionToken,
            kind: kind.rawValue,
            startedUptime: ProcessInfo.processInfo.systemUptime
        )
        self.sessionTrace = trace
        self.trace(trace.beginLine(
            mode: SettingsStore.shared.theaterSessionMode.rawValue,
            pair: self.pairTrace(),
            model: SettingsStore.shared.selectedSpeechModel.rawValue,
            thermal: LiveTranslationThermalReadout.label(ProcessInfo.processInfo.thermalState)
        ))
        if kind == .captions {
            self.startFreshTheaterBoard()
        }
        self.subscriber.startSessionRecord()
        self.subscriber.beginListening()
        self.warmAppleTranslation()
        TheaterHaptics.alignment()
        // A minimized (hidden) panel must come back for a new talk.
        if kind == .captions,
           !SettingsStore.shared.theaterWindowEnabled || SettingsStore.shared.theaterMinimized
        {
            PresenterCaptionController.shared.setVisible(true)
        }
        self.refreshPresenter()
    }

    func markFirstBuffer() {
        guard self.isSessionActive else { return }
        self.subscriber.noteFirstBuffer()
        self.updateTrace { trace in
            guard !trace.loggedFirstBuffer else { return }
            trace.loggedFirstBuffer = true
            self.trace(
                LiveTranslationTrace.event("session firstBuffer", token: trace.token),
                level: .debug
            )
        }
    }

    func markSpeechStart(hostTime: UInt64) {
        guard self.isSessionActive else { return }
        self.subscriber.noteSpeechStart(hostTime: hostTime)
        self.updateTrace { trace in
            guard !trace.loggedSpeechStart else { return }
            trace.loggedSpeechStart = true
            self.trace(
                LiveTranslationTrace.event("session speech", token: trace.token),
                level: .debug
            )
        }
    }

    func markSilenceHold() {
        guard self.isSessionActive else { return }
        self.subscriber.noteSilenceHold()
        self.updateTrace { $0.silenceHolds += 1 }
        self.applyPendingThermalDowngradeIfNeeded()
    }

    func handleEndOfUtterance() {
        guard self.isSessionActive else { return }
        self.subscriber.handleEndOfUtterance()
        self.updateTrace { $0.utteranceEnds += 1 }
        self.refreshPresenter()
    }

    func handlePartial(_ text: String) {
        guard self.isSessionActive else { return }
        self.updateTrace { $0.partials += 1 }
        self.subscriber.handlePartial(text)
        if self.listenKind == .insert {
            NotchOverlayManager.shared.updateTranscriptionText(self.overlayText)
        }
    }

    func finishSession(finalSource: String) async -> String {
        let token = self.stopToken
        guard token == self.sessionToken else {
            self.trace(
                LiveTranslationTrace.event(
                    "session drop",
                    token: self.sessionToken,
                    "reason=staleStop stopToken=\(token)"
                ),
                level: .warning
            )
            if !self.isSessionActive {
                self.abandonCaptionSession = false
                self.listenKind = nil
            }
            self.isFinishingSession = false
            return ""
        }
        if self.abandonCaptionSession {
            self.endSessionTrace(outcome: "abandoned")
            self.abandonCaptionSession = false
            self.isSessionActive = false
            self.listenKind = nil
            self.clearThermalEngineOverride()
            await self.subscriber.awaitAcceptedCommits()
            self.subscriber.dropUnacceptedSpeech()
            self.subscriber.endListening()
            self.persistBoard()
            self.isFinishingSession = false
            return ""
        }
        // Captions: accept real leftover clauses, drop a fragment.
        // Insert: type the whole listen, including a trailing fragment.
        let kind = self.listenKind
        let translated = await self.subscriber.translateFinal(
            finalSource,
            drainRemainder: kind == .insert
        )
        guard token == self.sessionToken, !self.abandonCaptionSession else {
            if self.abandonCaptionSession {
                self.endSessionTrace(outcome: "abandonedDuringTranslate")
                self.abandonCaptionSession = false
                self.isSessionActive = false
                self.listenKind = nil
                self.clearThermalEngineOverride()
                await self.subscriber.awaitAcceptedCommits()
                self.subscriber.dropUnacceptedSpeech()
                self.subscriber.endListening()
                self.persistBoard()
            } else {
                self.trace(
                    LiveTranslationTrace.event(
                        "session drop",
                        token: self.sessionToken,
                        "reason=staleDuringTranslate stopToken=\(token)"
                    ),
                    level: .warning
                )
            }
            self.isFinishingSession = false
            return ""
        }
        self.isSessionActive = false
        self.isPaused = false
        self.listenKind = nil
        self.clearThermalEngineOverride()
        self.subscriber.endListening()
        self.isFinishingSession = false
        let text = kind == .insert
            ? self.subscriber.consumePendingInsertDocument()
            : translated
        self.endSessionTrace(outcome: "finished chars=\(text.count)")
        self.refreshPresenter()
        return text
    }

    func cancelSession() {
        let stoppingListen = self.isSessionActive && !self.isFinishingSession
        self.endSessionTrace(outcome: "cancelled")
        self.abandonCaptionSession = false
        self.isStartingListen = false
        self.isFinishingSession = false
        self.isSessionActive = false
        self.isPaused = false
        self.listenKind = nil
        self.clearThermalEngineOverride()
        TheaterSpeechSession.shared.clear(asr: AppServices.shared.asr)
        self.subscriber.endListening()
        if stoppingListen {
            TheaterHaptics.alignment()
        }
        self.refreshPresenter()
    }

    func theaterWasClosed() {
        self.trace(LiveTranslationTrace.event(
            "theater closed",
            token: self.sessionToken,
            "kind=\(self.listenKind?.rawValue ?? "none") listening=\(self.isSessionActive)"
        ))
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
            PresenterCaptionController.shared.clearDisplay()
            return
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

    /// Either way is a later product. The setting stays so a later release can restore the toggle.
    func applyDynamicPairing(_ enabled: Bool) {
        SettingsStore.shared.theaterDynamicPairing = enabled
        self.finishLanguageChange()
    }

    private func finishLanguageChange() {
        self.trace(LiveTranslationTrace.event(
            "pair now",
            token: self.sessionTrace?.token,
            "pair=\(self.pairTrace()) stopListen=\(self.isSessionActive)"
        ))
        let shouldWait = self.isSessionActive || AppServices.shared.asr.isRunningOrStarting
        if self.isSessionActive {
            Task {
                await self.stopListeningAndAwaitFinish()
                self.applyLanguagePairChange(shouldWait: true)
            }
            return
        }
        self.applyLanguagePairChange(shouldWait: shouldWait)
    }

    private func applyLanguagePairChange(shouldWait: Bool) {
        self.subscriber.noteLanguagePairChanged()
        let source = SpokenLanguageResolver.sourceLanguage()
        let target = SpokenLanguageResolver.targetLanguage()
        self.warmAppleTranslation(source: source, target: target)
        Task { @MainActor in
            if shouldWait {
                await self.awaitASRIdle()
            }
            self.alignSpokenEngineWithTheater()
            if let mismatch = SpokenLanguageResolver.voiceEngineMismatchMessage() {
                self.subscriber.reportFailure(mismatch)
            }
            self.refreshPresenter()
        }
    }

    /// Language change stops Listen asynchronously. Wait so the next Listen
    /// is not a no-op while ASR is still shutting down.
    func awaitASRIdle(timeoutSeconds: TimeInterval = 3) async {
        let asr = AppServices.shared.asr
        let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
        while asr.isRunningOrStarting, ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 40_000_000)
            if Task.isCancelled { return }
        }
    }

    /// I speak owns the Voice Engine listening language. Leftover locales crash
    /// Speech Analyzer / Apple Translation when Translate starts on a new pair.
    func alignSpokenEngineWithTheater() {
        self.alignSpokenEngineCallCountForTesting += 1
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
        self.trace("voice engine reload pair=\(self.pairTrace())")
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
            await self.warmTranslationPair(source: source, target: target)
            await self.refreshPackAvailability(source: source, target: target)
        }
    }

    private var didAwaitInitialTranslationWarmup = false

    /// `warmAppleTranslation` is fire-and-forget, so a session's first commit
    /// can race a cold Apple Translation session start (model load, first
    /// `.translationTask` attach). That race is what causes the choppy,
    /// retry-heavy first few seconds of a fresh Listen — captions repeating,
    /// translations landing on the wrong sentence. Call this once, before the
    /// very first Listen of the process, to absorb that cold start up front
    /// instead of during the session.
    func awaitInitialTranslationWarmupIfNeeded() async {
        let source = SpokenLanguageResolver.sourceLanguage()
        let target = SpokenLanguageResolver.targetLanguage()
        // Voice / same-language Listen must not consume the one-shot. Translate
        // after Voice still needs the cold Apple Translation start absorbed
        // here, not on the first committed clause.
        guard source.id != target.id else { return }
        guard !self.didAwaitInitialTranslationWarmup else { return }
        self.didAwaitInitialTranslationWarmup = true
        let started = ProcessInfo.processInfo.systemUptime
        self.trace("translation warm start pair=\(source.id)>\(target.id)")
        TranslationSessionHostController.install()
        self.appleEngine.prepare(source: source, target: target)
        await self.appleEngine.warm(source: source, target: target, timeoutSeconds: 10)
        let elapsedMs = Int(((ProcessInfo.processInfo.systemUptime - started) * 1000).rounded())
        self.trace("translation warm done pair=\(source.id)>\(target.id) elapsedMs=\(elapsedMs)")
    }

    func startCaptionListening() {
        if self.isSessionActive, self.listenKind == .captions {
            self.trace(LiveTranslationTrace.event("listen skip", token: self.sessionToken, "reason=alreadyActive kind=captions"), level: .debug)
            return
        }
        guard !self.isStartingListen else {
            self.trace("listen skip reason=starting kind=captions", level: .debug)
            return
        }
        self.isStartingListen = true
        guard self.onStartCaptionListening != nil else {
            self.isStartingListen = false
            self.trace("listen failed reason=noStartHandler kind=captions", level: .warning)
            return
        }
        self.onStartCaptionListening?()
    }

    /// Hold capture and drop an unaccepted fragment. In-flight accepted
    /// translation may still land. Resume must not resurrect the drop.
    func pauseListening() {
        guard self.isSessionActive, self.listenKind == .captions, !self.isPaused else { return }
        self.isPaused = true
        self.trace(LiveTranslationTrace.event("session pause", token: self.sessionToken))
        self.subscriber.holdUnacceptedForPause()
        AppServices.shared.asr.setCapturePaused(true)
        self.refreshPresenter()
    }

    func resumeListening() {
        guard self.isSessionActive, self.isPaused else { return }
        self.isPaused = false
        self.trace(LiveTranslationTrace.event("session resume", token: self.sessionToken))
        self.subscriber.releasePauseHold()
        AppServices.shared.asr.setCapturePaused(false)
        self.refreshPresenter()
    }

    func startInsertListening() {
        if self.isSessionActive, self.listenKind == .insert {
            self.trace(LiveTranslationTrace.event("listen skip", token: self.sessionToken, "reason=alreadyActive kind=insert"), level: .debug)
            return
        }
        guard !self.isStartingListen else {
            self.trace("listen skip reason=starting kind=insert", level: .debug)
            return
        }
        self.isStartingListen = true
        guard self.onStartInsertListening != nil else {
            self.isStartingListen = false
            self.trace("listen failed reason=noStartHandler kind=insert", level: .warning)
            return
        }
        self.onStartInsertListening?()
    }

    func toggleCaptionListening() {
        if self.isFinishingSession {
            self.trace(LiveTranslationTrace.event("listen skip", token: self.sessionToken, "reason=finishing"), level: .debug)
            return
        }
        if self.isSessionActive, self.listenKind == .captions {
            self.stopListening()
            return
        }
        guard TheaterAvailability.isSupported else {
            self.trace("listen failed reason=unsupported", level: .warning)
            self.subscriber.reportFailure(TheaterAvailability.unsupportedCopy)
            self.refreshPresenter()
            return
        }
        PresenterCaptionController.shared.setVisible(true)
        self.startCaptionListening()
    }

    func ensureReadyToListen() async -> Bool {
        guard TheaterAvailability.isSupported else {
            self.trace("listen blocked reason=unsupported", level: .warning)
            self.subscriber.reportFailure(TheaterAvailability.unsupportedCopy)
            self.refreshPresenter()
            return false
        }
        let source = SpokenLanguageResolver.sourceLanguage()
        let target = SpokenLanguageResolver.targetLanguage()
        if !SpokenLanguageResolver.voiceEngineSupportsSource() {
            self.trace("listen blocked reason=voiceEngine pair=\(self.pairTrace())", level: .warning)
            self.subscriber.reportFailure(
                SpokenLanguageResolver.voiceEngineMismatchMessage()
                    ?? "Switch Voice Engine to hear \(source.displayName)."
            )
            self.refreshPresenter()
            return false
        }
        let model = SettingsStore.shared.selectedSpeechModel
        if !model.isInstalled {
            self.trace("listen blocked reason=modelMissing model=\(model.rawValue)", level: .warning)
            self.subscriber.reportFailure(
                "Download \(model.displayName) before Listen. Apple Speech works without a download."
            )
            self.refreshPresenter()
            return false
        }
        self.applyThermalDowngradeIfNeeded(immediate: true)
        let granted = await MicrophoneAccess.authorize(updating: AppServices.shared.asr)
        if !granted {
            self.trace("listen blocked reason=microphone", level: .warning)
            self.subscriber.reportFailure(MicrophoneAccess.deniedCopy)
            self.refreshPresenter()
            return false
        }
        if SettingsStore.shared.theaterSessionMode == .transcription || source.id == target.id {
            self.notePack(.installed)
            self.trace("listen ready pair=\(self.pairTrace()) pack=installed")
            return true
        }
        await self.warmTranslationPair(source: source, target: target)
        var resolved = await self.resolvePairPacks(source: source, target: target)
        if resolved.availability == .unknown {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            resolved = await self.resolvePairPacks(source: source, target: target)
        }
        self.notePack(resolved.availability)
        switch TheaterPackListenGate.decision(
            availability: resolved.availability,
            mailboxReady: self.appleEngine.isMailboxReady
        ) {
        case .allow:
            self.trace("listen ready pair=\(self.pairTrace()) pack=\(LiveTranslationTrace.packLabel(resolved.availability))")
            await self.appleEngine.warm(source: source, target: target)
            return true
        case .needDownload:
            self.trace("listen blocked gate=needDownload pair=\(self.pairTrace())", level: .warning)
            self.subscriber.reportFailure("Download the language pack before Listen.")
            self.refreshPresenter()
            await self.presentPackDownload(resolved)
            return false
        case .unsupported:
            self.trace("listen blocked gate=unsupported pair=\(self.pairTrace())", level: .warning)
            self.subscriber.reportFailure("This pair is not supported by Apple Translation.")
            self.refreshPresenter()
            return false
        case .notReady:
            self.trace("listen blocked gate=notReady pair=\(self.pairTrace())", level: .warning)
            self.subscriber.reportFailure("Apple Translation is not ready yet.")
            self.refreshPresenter()
            return false
        }
    }

    func reportListenFailure(_ message: String) {
        self.trace("listen failed \(message)", level: .warning)
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
            self.trace("thermal defer model=\(SettingsStore.shared.selectedSpeechModel.rawValue)")
            return
        }
        let fallback = LiveTranslationThermalEngine.fallbackModel()
        self.trace("thermal swap to=\(fallback.rawValue) from=\(SettingsStore.shared.selectedSpeechModel.rawValue)")
        asr.applyThermalSpeechOverride(fallback)
        self.pendingThermalDowngrade = false
        self.subscriber.reportStatus(LiveTranslationThermalEngine.statusCopy, kind: .info)
        self.refreshPresenter()
    }

    func clearThermalEngineOverride() {
        let hadOverride = AppServices.shared.asr.hasThermalSpeechOverride
        self.pendingThermalDowngrade = false
        AppServices.shared.asr.clearThermalSpeechOverride()
        if hadOverride {
            self.trace("thermal restore")
        }
    }

    func persistBoard() {
        self.subscriber.flushArchive()
        let snapshot = self.subscriber.snapshot()
        SettingsStore.shared.theaterBoardSnapshot = snapshot.entries.isEmpty ? nil : snapshot
        self.subscriber.persistLastLatency()
    }

    /// Stamp this Listen so `finishSession` can accept it. Shortcut release
    /// stops through `stopTheaterListening`.
    func markListeningStop() {
        let stoppingListen = (self.isSessionActive || self.listenKind != nil) && !self.isFinishingSession
        self.stopToken = self.sessionToken
        self.isFinishingSession = true
        if stoppingListen {
            self.isSessionActive = false
            TheaterHaptics.alignment()
        }
    }

    func stopListening() {
        guard !self.isFinishingSession else {
            self.trace(LiveTranslationTrace.event("session stop ignored", token: self.sessionToken, "reason=alreadyFinishing"), level: .debug)
            return
        }
        self.trace(LiveTranslationTrace.event("session stop", token: self.sessionToken))
        self.markListeningStop()
        Task { await self.onStopListening?() }
    }

    func stopListeningAndAwaitFinish() async {
        guard !self.isFinishingSession else { return }
        self.markListeningStop()
        await self.onStopListening?()
    }

    func listenStartFailed() {
        self.isStartingListen = false
        self.trace(LiveTranslationTrace.event("listen failed", token: self.sessionToken, "reason=startFailed"), level: .warning)
    }

    var isFinishingSessionForTesting: Bool { self.isFinishingSession }

    /// Opens the same Accessibility guide onboarding uses.
    var onAccessibilityNeeded: (() -> Void)?

    func insertCaptionText() {
        // Check first: consuming marks lines typed, and a failed insert would
        // otherwise lose them and disable the button.
        guard AXIsProcessTrusted() else {
            self.trace("insert blocked reason=accessibility", level: .warning)
            self.onAccessibilityNeeded?()
            return
        }
        let text = self.subscriber.consumePendingInsertDocument()
        guard !text.isEmpty else {
            self.trace("insert skipped reason=empty", level: .debug)
            return
        }
        self.trace("insert chars=\(text.count)")
        self.onInsertCaption?(text)
    }

    func copyCaptionText() {
        let text = PresenterCaptionController.shared.documentTextForDelivery()
        guard !text.isEmpty else { return }
        self.trace("copy chars=\(text.count)")
        ClipboardService.copyToClipboard(text)
        TheaterHaptics.alignment()
        self.copyFlashToken += 1
    }

    var hasClearableBoard: Bool {
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
        self.trace("board undo lines=\(self.subscriber.committedLines.count)")
        self.subscriber.removeLastCommittedLine()
        self.persistBoard()
        self.refreshPresenter()
        TheaterHaptics.alignment()
        self.objectWillChange.send()
    }

    func clearBoard() {
        self.trace(LiveTranslationTrace.event("board clear", token: self.sessionTrace?.token, "listening=\(self.isSessionActive)"))
        self.startFreshTheaterBoard()
        if self.isSessionActive {
            self.subscriber.beginListening(preserveSuppressed: true)
        }
        self.objectWillChange.send()
    }

    /// Empty Theater. A leftover file from an older build must not come back
    /// on launch or a new caption Listen.
    func startFreshTheaterBoard() {
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
            self.notePack(.installed)
            return
        }
        let resolved = await self.resolvePairPacks(source: source, target: target)
        self.notePack(resolved.availability)
    }

    /// Warms the I speak → Show as pack, then attaches the download sheet.
    /// Both-direction warm is a later Either way product.
    func requestNeededLanguagePackDownload(
        source: TranslationLanguage? = nil,
        target: TranslationLanguage? = nil
    ) async {
        let source = source ?? SpokenLanguageResolver.sourceLanguage()
        let target = target ?? SpokenLanguageResolver.targetLanguage()
        guard source.id != target.id else { return }
        await self.warmTranslationPair(source: source, target: target)
        let resolved = await self.resolvePairPacks(source: source, target: target)
        self.notePack(resolved.availability)
        self.trace("pack download pair=\(source.id)>\(target.id) availability=\(LiveTranslationTrace.packLabel(resolved.availability))")
        await self.presentPackDownload(resolved)
    }

    func pairAvailabilityCopy(
        source: TranslationLanguage? = nil,
        target: TranslationLanguage? = nil
    ) async -> String {
        let source = source ?? SpokenLanguageResolver.sourceLanguage()
        let target = target ?? SpokenLanguageResolver.targetLanguage()
        await self.warmTranslationPair(source: source, target: target)
        let resolved = await self.resolvePairPacks(source: source, target: target)
        self.notePack(resolved.availability)
        return await self.appleEngine.checkAvailability(
            source: resolved.downloadSource,
            target: resolved.downloadTarget
        )
    }

    private struct PairPackResolution {
        let availability: TranslationPackAvailability
        let downloadSource: TranslationLanguage
        let downloadTarget: TranslationLanguage
    }

    private func resolvePairPacks(
        source: TranslationLanguage,
        target: TranslationLanguage
    ) async -> PairPackResolution {
        let forward = await self.appleEngine.packAvailability(source: source, target: target)
        let bidirectional = SpokenLanguageResolver.isDynamicPairingEnabled() && source.id != target.id
        let reverse: TranslationPackAvailability? = bidirectional
            ? await self.appleEngine.packAvailability(source: target, target: source)
            : nil
        let pair = TheaterPairPacks.downloadPair(
            source: source,
            target: target,
            forward: forward,
            reverse: reverse,
            bidirectional: bidirectional
        )
        return PairPackResolution(
            availability: TheaterPairPacks.combined(
                forward: forward,
                reverse: reverse,
                bidirectional: bidirectional
            ),
            downloadSource: pair.source,
            downloadTarget: pair.target
        )
    }

    private func warmTranslationPair(
        source: TranslationLanguage,
        target: TranslationLanguage
    ) async {
        await self.appleEngine.warm(source: source, target: target)
        if SpokenLanguageResolver.isDynamicPairingEnabled(), source.id != target.id {
            await self.appleEngine.warm(source: target, target: source)
            await self.appleEngine.warm(source: source, target: target)
        }
    }

    private func presentPackDownload(_ resolved: PairPackResolution) async {
        await self.appleEngine.warm(
            source: resolved.downloadSource,
            target: resolved.downloadTarget
        )
        self.appleEngine.requestLanguagePackDownload()
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
        SettingsStore.shared.theaterWindowEnabled = false
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
        guard !self.presenterRefreshPending else { return }
        self.presenterRefreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.presenterRefreshPending = false
            self.performRefreshPresenter()
        }
    }

    private func performRefreshPresenter() {
        guard SettingsStore.shared.theaterWindowEnabled else { return }
        guard self.listenKind != .insert else { return }
        var status = self.subscriber.statusText
        var statusKind = self.subscriber.statusKind
        if self.isPaused {
            status = "Paused"
            statusKind = .info
        }
        var board = self.subscriber.boardState
        board.oldestInFlightWaitMs = self.subscriber.oldestInFlightWaitMilliseconds
        PresenterCaptionController.shared.update(
            board: board,
            pairLabel: SpokenLanguageResolver.pairLabel(),
            status: status,
            statusKind: statusKind,
            isListening: self.isSessionActive,
            isPaused: self.isPaused,
            canRetryTranslation: self.subscriber.canRetryTranslation,
            latencyReadout: self.subscriber.lastLatencySample.displayText,
            compactLatencyReadout: self.subscriber.lastLatencySample.compactText,
            paceCue: TheaterPaceCue.snapshot(
                isTranslating: SettingsStore.shared.theaterSessionMode.showsTranslation
                    && !SpokenLanguageResolver.isSameLanguagePair(),
                isListening: self.isSessionActive,
                isPaused: self.isPaused,
                liveSpoken: "",
                lastTranslation: self.subscriber.committedLines.last ?? "",
                pendingWaitMilliseconds: board.oldestInFlightWaitMs
            )
        )
    }

    private func trace(_ message: String, level: DebugLogger.LogLevel = .info) {
        DebugLogger.shared.log(message, level: level, source: LiveTranslationTrace.source)
    }

    private func pairTrace() -> String {
        "\(SpokenLanguageResolver.sourceLanguage().id)>\(SpokenLanguageResolver.targetLanguage().id)"
    }

    private func notePack(_ next: TranslationPackAvailability) {
        guard next != self.packAvailability else { return }
        let previous = LiveTranslationTrace.packLabel(self.packAvailability)
        self.packAvailability = next
        self.trace("pack \(previous)>\(LiveTranslationTrace.packLabel(next)) pair=\(self.pairTrace())")
    }

    private func updateTrace(_ body: (inout LiveTranslationSessionTrace) -> Void) {
        guard var trace = self.sessionTrace else { return }
        body(&trace)
        self.sessionTrace = trace
    }

    private func endSessionTrace(outcome: String) {
        let lines = self.subscriber.committedLines.count
        if let trace = self.sessionTrace {
            self.trace(trace.endLine(
                outcome: outcome,
                now: ProcessInfo.processInfo.systemUptime,
                lines: lines
            ))
        } else {
            self.trace("session \(outcome) token=\(self.sessionToken) lines=\(lines)")
        }
        self.sessionTrace = nil
    }
}

/// Strips a trailing mark so a restitch can grow a clause. The mark arrives
/// with the accepted sentence.
enum TheaterLiveRow {
    static func openText(_ text: String) -> String {
        var open = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = open.last, ".…?!。！？".contains(last) {
            open.removeLast()
        }
        return open.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum TheaterSpokenEngineReload {
    /// Language change stops Listen asynchronously. Wait until ASR is idle
    /// or the next Listen returns immediately.
    static func shouldWaitForIdle(sessionWasActive: Bool, asrBusy: Bool) -> Bool {
        sessionWasActive || asrBusy
    }

    static func canReload(asrBusy: Bool) -> Bool { !asrBusy }
}
