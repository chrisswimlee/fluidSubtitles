//
//  OnboardingFlowView.swift
//  fluid
//
//  First-run Theater onboarding container.
//

import AppKit
import AVFoundation
import SwiftUI

struct OnboardingFlowView: View {
    @EnvironmentObject var appServices: AppServices
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var asr: ASRService {
        self.appServices.asr
    }

    @ObservedObject var settings = SettingsStore.shared
    @ObservedObject var translationController = LiveTranslationController.shared

    @Binding var currentStep: Int
    let accessibilityEnabled: Bool
    let accessibilitySetupInProgress: Bool
    let finishOnboarding: () -> Void
    var finishOnboardingAtTranslate: () -> Void = {}
    let openAccessibilitySettings: () -> Void
    let restartApp: () -> Void
    var startCaptionListening: () -> Void = {}
    let stopAndProcessTranscription: () async -> Void
    let menuBarManager: MenuBarManager
    @Binding var activeShortcutRecordingTarget: ShortcutRecordingTarget?
    @Binding var shortcutRecordingMessage: String?
    let theme: AppTheme

    @State var selectedLanguageID = SettingsStore.shared.onboardingSelectedLanguageID
    @State var selectedModelRouteID: String?
    @State var hoveredModelRouteID: String?
    @State var hoveredModelActionButtonID: String?
    @State var hoveredPermissionButtonID: String?
    @State var onboardingInputDevices: [AudioDevice.Device] = []
    @State var selectedOnboardingInputUID = ""
    @State var previewedOnboardingInputUID: String?
    @State var onboardingMicrophoneLevel: CGFloat = 0
    @State var lastOnboardingMicrophoneLevelUpdate: TimeInterval = 0
    @State var microphonePreviewTask: Task<Void, Never>?
    @State var microphonePreviewGeneration: UInt64 = 0
    @State var onboardingMicrophoneRefreshGeneration: UInt64 = 0
    @State var isOnboardingFlowVisible = false
    @State var hoveredFooterButton: OnboardingFooterButton?
    @State var isShowingOtherModelRoutes = false
    @State var preparingModelRouteID: String?
    @State var uninstallingModelRouteID: String?
    @State var modelPreparationTask: Task<Void, Never>?
    @State var hasPlayedLandingWelcomeSound = false
    @State var landingGlowCenter = UnitPoint(x: 0.5, y: 0.18)
    @State var lastLandingGlowLocation = CGPoint(x: -1000, y: -1000)
    @State var languagePackAvailability = ""
    @State var languagePackIsInstalled = false
    @State var isFinishingOnboarding = false
    let landingGlowMovementThreshold: CGFloat = 24

    enum OnboardingFooterButton {
        case back
        case skip
        case next
    }

    enum OnboardingPillButtonTone {
        case primary
        case secondary
        case destructive
    }

    struct OnboardingPillButtonConfiguration {
        let title: String
        let systemImage: String?
        let tone: OnboardingPillButtonTone
        let width: CGFloat?
        let height: CGFloat
        let fontSize: CGFloat
        let iconSize: CGFloat
        let isHovered: Bool
        let isEnabled: Bool
    }

    enum Step: Int, CaseIterable {
        case landing = 0
        case language = 1
        case voiceModel = 2
        case permissions = 3
        case playground = 4

        var title: String {
            switch self {
            case .landing:
                return "Welcome"
            case .language:
                return "Choose Language"
            case .voiceModel:
                return "Choose Voice Engine"
            case .permissions:
                return "Enable Access"
            case .playground:
                return "Try Theater"
            }
        }

        var subtitle: String {
            switch self {
            case .landing:
                return FluidProduct.tagline
            case .language:
                return "Pick the language you speak, then the one you want."
            case .voiceModel:
                return "Apple Speech is ready on this Mac. Other engines stay under Show other models."
            case .permissions:
                return "Microphone is required. Accessibility is only if you want a translation typed into other apps."
            case .playground:
                return TheaterReadiness.openTheaterPressListen
            }
        }
    }

    var step: Step {
        Step(rawValue: self.currentStep) ?? .voiceModel
    }

    var progressValue: Double {
        Double(self.step.rawValue) / Double(Step.allCases.count - 1)
    }

    var compactProgressValue: Double {
        Double(self.step.rawValue + 1) / Double(Step.allCases.count)
    }

    var selectedOnboardingLanguage: VoiceEngineLanguage {
        VoiceEngineLanguageCatalog.language(id: self.selectedLanguageID)
            ?? VoiceEngineLanguageCatalog.language(id: "en")
            ?? VoiceEngineLanguage(id: "en", displayName: "English", aliases: [], isPopular: true)
    }

    var selectedLanguageRoutes: [VoiceEngineLanguageRoute] {
        VoiceEngineLanguageCatalog.routes(for: self.selectedOnboardingLanguage)
            .filter { SettingsStore.SpeechModel.availableModels.contains($0.model) }
    }

    func preferredRoute(in routes: [VoiceEngineLanguageRoute]) -> VoiceEngineLanguageRoute? {
        VoiceEngineLanguageCatalog.preferredOnboardingRoute(among: routes)
    }

    var preferredOnboardingRoute: VoiceEngineLanguageRoute? {
        self.preferredRoute(in: self.selectedLanguageRoutes)
    }

    var selectedOnboardingRoute: VoiceEngineLanguageRoute? {
        if let selectedModelRouteID,
           let selectedRoute = self.selectedLanguageRoutes.first(where: { $0.id == selectedModelRouteID })
        {
            return selectedRoute
        }

        if let selectedRoute = self.selectedLanguageRoutes.first(where: { self.isRouteSelectedInSettings($0) }) {
            return selectedRoute
        }

        return self.preferredOnboardingRoute
    }

    var defaultDisplayedModelRoutes: [VoiceEngineLanguageRoute] {
        if let selectedOnboardingRoute {
            return [selectedOnboardingRoute]
        }
        return []
    }

    var otherModelRoutes: [VoiceEngineLanguageRoute] {
        let defaultRouteIDs = Set(self.defaultDisplayedModelRoutes.map(\.id))
        return self.selectedLanguageRoutes.filter { !defaultRouteIDs.contains($0.id) }
    }

    var recommendedOnboardingModel: SettingsStore.SpeechModel {
        self.selectedOnboardingRoute?.model ?? SettingsStore.SpeechModel.defaultModel
    }

    var recommendedModelReasonText: String {
        let model = self.preferredOnboardingRoute?.model ?? .appleSpeech
        let name = self.onboardingModelTitle(for: model)
        switch model {
        case .appleSpeech, .appleSpeechAnalyzer:
            return "\(name) is ready on this Mac. Other engines are under Show other models."
        default:
            return "\(name) hears the language you speak. Other engines are under Show other models."
        }
    }

    var playgroundContinueTitle: String {
        if self.isPlaygroundReady {
            return "Done"
        }
        if self.playgroundListenIsActive {
            return "Listening"
        }
        return "Continue"
    }

    var playgroundContinueEnabled: Bool {
        if self.playgroundListenIsActive, !self.isPlaygroundReady {
            return false
        }
        return self.canContinue
    }

    var showsSetupBlock: Bool {
        self.asr.errorTitle == "Setup isn't complete" && !self.asr.errorMessage.isEmpty
    }

    var playgroundListenIsActive: Bool {
        self.asr.isRunning || self.asr.isStarting || (
            self.translationController.isSessionActive && self.translationController.listenKind == .captions
        )
    }

    var isOnboardingTranslationPackReady: Bool {
        SpokenLanguageResolver.isSameLanguagePair() || self.languagePackIsInstalled
    }

    var canOpenOnboardingTheater: Bool {
        TheaterAvailability.isSupported && self.isOnboardingTranslationPackReady
    }

    var playgroundCaptionHint: String {
        if !TheaterAvailability.isSupported {
            return TheaterAvailability.unsupportedCopy
        }
        if !self.isOnboardingTranslationPackReady {
            return "Download the language pack, then press Listen."
        }
        if self.isPlaygroundReady {
            return "That sentence is on screen. Press Done."
        }
        if self.playgroundListenIsActive {
            return "Say a sentence."
        }
        return TheaterReadiness.pressListen
    }

    var isRecommendedModelDownloaded: Bool {
        self.isOnboardingModelDownloaded(self.recommendedOnboardingModel)
    }

    var isPreparingRecommendedModel: Bool {
        self.isPreparingOnboardingModel(self.recommendedOnboardingModel)
    }

    var isRecommendedModelReady: Bool {
        self.isOnboardingModelReady(self.recommendedOnboardingModel)
    }

    var isVoiceModelReady: Bool {
        guard let route = self.selectedOnboardingRoute else {
            return false
        }
        return self.isOnboardingRouteReady(route)
    }

    var isModelPreparationInProgress: Bool {
        guard self.step == .voiceModel else {
            return false
        }
        return self.preparingModelRouteID != nil
            || self.asr.hasActiveModelPreparation
            || self.asr.isCancellingModelPreparation
            || self.asr.isDownloadingModel
            || (self.asr.isLoadingModel && !self.asr.isAsrReady)
    }

    var isMicrophoneReady: Bool {
        self.asr.micStatus == .authorized
    }

    var isAccessibilityReady: Bool {
        self.accessibilityEnabled
    }

    var isPermissionsReady: Bool {
        self.isMicrophoneReady
    }

    var isPlaygroundReady: Bool {
        if !TheaterAvailability.isSupported { return true }
        return self.settings.onboardingPlaygroundValidated || self.settings.onboardingPlaygroundSkipped
    }

    var onboardingShortcutDisplay: String {
        let display = self.settings.primaryDictationShortcutDisplayString.trimmingCharacters(in: .whitespacesAndNewlines)
        return display.isEmpty ? "your shortcut" : display
    }

    var isRecordingAnyShortcut: Bool {
        self.activeShortcutRecordingTarget != nil
    }

    var isRecordingPrimaryShortcut: Bool {
        self.activeShortcutRecordingTarget?.isPrimaryDictation == true
    }

    var canContinue: Bool {
        guard !self.isModelPreparationInProgress else {
            return false
        }

        switch self.step {
        case .landing:
            return true
        case .language:
            return !self.selectedLanguageRoutes.isEmpty
        case .voiceModel:
            return self.isVoiceModelReady
        case .permissions:
            return self.isPermissionsReady
        case .playground:
            return self.isPlaygroundReady && !self.isFinishingOnboarding && !self.isRecordingAnyShortcut
        }
    }

    var primaryButtonTitle: String {
        switch self.step {
        case .landing:
            return "Next"
        case .language:
            return "Continue"
        case .playground:
            return "Continue"
        default:
            return "Continue"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            self.stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .background {
            ZStack {
                self.theme.palette.windowBackground
                    .opacity(0.98)
                    .ignoresSafeArea()

                Rectangle()
                    .fill(self.theme.materials.window)
                    .opacity(0.75)
                    .ignoresSafeArea()
            }
        }
        .onAppear {
            self.isOnboardingFlowVisible = true
            self.syncOnboardingSelectionFromSettings()
            self.playLandingWelcomeSoundIfNeeded()
            self.refreshOnboardingMicrophoneAuthorization(checkModels: true)
        }
        .onChange(of: self.currentStep) { _, _ in
            if self.step != .voiceModel {
                self.cancelOnboardingModelPreparation()
            }
            if self.step == .permissions, self.isMicrophoneReady {
                self.refreshOnboardingMicrophones(startPreview: true)
            } else {
                self.stopOnboardingMicrophonePreview()
            }
            self.playLandingWelcomeSoundIfNeeded()
        }
        .onChange(of: self.isMicrophoneReady) { _, isReady in
            guard self.step == .permissions else { return }
            if isReady {
                self.refreshOnboardingMicrophones(startPreview: true)
            } else {
                self.stopOnboardingMicrophonePreview()
            }
        }
        .onChange(of: self.asr.isStarting) { _, isStarting in
            guard self.isOnboardingFlowVisible,
                  self.step == .permissions,
                  self.isMicrophoneReady
            else { return }
            if isStarting {
                self.suspendOnboardingMicrophonePreviewForDictation()
            }
        }
        .onReceive(self.asr.audioCaptureStateDidSettle) {
            guard self.isOnboardingFlowVisible,
                  self.step == .permissions,
                  self.isMicrophoneReady
            else { return }
            if self.asr.isRunning || self.asr.isStarting {
                self.suspendOnboardingMicrophonePreviewForDictation()
            } else {
                self.refreshOnboardingMicrophones(startPreview: true)
            }
        }
        .onDisappear {
            self.isOnboardingFlowVisible = false
            self.onboardingMicrophoneRefreshGeneration &+= 1
            self.cancelOnboardingModelPreparation()
            self.stopOnboardingMicrophonePreview()
        }
        .onReceive(self.asr.audioLevelPublisher) { level in
            guard self.step == .permissions,
                  self.isMicrophoneReady,
                  self.asr.isMicrophonePreviewActive,
                  self.asr.isRunning == false,
                  self.asr.isStarting == false
            else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard level == 0 || now - self.lastOnboardingMicrophoneLevelUpdate >= 0.05 else {
                return
            }
            self.lastOnboardingMicrophoneLevelUpdate = now
            self.onboardingMicrophoneLevel = level
        }
        .onChange(of: self.appServices.audioObserver.changeTick) { _, _ in
            guard self.step == .permissions, self.isMicrophoneReady else { return }
            self.refreshOnboardingMicrophones(startPreview: true)
        }
        .onChange(of: self.appServices.audioObserver.inputAvailabilityTick) { _, _ in
            guard self.step == .permissions, self.isMicrophoneReady else { return }
            self.refreshOnboardingMicrophones(startPreview: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            self.syncOnboardingSelectionFromSettings()
            self.refreshOnboardingMicrophoneAuthorization()
        }
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Welcome to \(FluidProduct.displayName)")
                .font(self.theme.typography.title)
                .foregroundStyle(self.theme.palette.primaryText)

            Text(FluidProduct.creditShort)
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)

            Text(self.step.subtitle)
                .font(self.theme.typography.bodySmall)
                .foregroundStyle(self.theme.palette.secondaryText)

            HStack {
                Text("Step \(self.step.rawValue + 1) of \(Step.allCases.count)")
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(self.step.title)
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(self.theme.palette.accent)
            }

            ProgressView(value: self.progressValue)
                .tint(self.theme.palette.accent)
        }
        .padding(24)
    }

    @ViewBuilder
    var stepContent: some View {
        switch self.step {
        case .landing:
            self.landingStep
        case .language:
            self.languageStep
        case .voiceModel:
            self.voiceModelStep
        case .permissions:
            self.permissionsStep
        case .playground:
            self.playgroundStep
        }
    }

    func setHoveredModelActionButton(_ buttonID: String?) {
        guard self.hoveredModelActionButtonID != buttonID else { return }
        if self.reduceMotion {
            self.hoveredModelActionButtonID = buttonID
        } else {
            withAnimation(.easeOut(duration: 0.14)) {
                self.hoveredModelActionButtonID = buttonID
            }
        }
    }

    func setHoveredPermissionButton(_ buttonID: String?) {
        guard self.hoveredPermissionButtonID != buttonID else { return }
        if self.reduceMotion {
            self.hoveredPermissionButtonID = buttonID
        } else {
            withAnimation(.easeOut(duration: 0.14)) {
                self.hoveredPermissionButtonID = buttonID
            }
        }
    }

    func togglePrimaryShortcutRecording() {
        guard !self.asr.isRunning else { return }
        if self.isRecordingPrimaryShortcut {
            self.activeShortcutRecordingTarget = nil
            self.shortcutRecordingMessage = nil
        } else {
            self.shortcutRecordingMessage = nil
            self.activeShortcutRecordingTarget = .primaryDictation(.replace(0))
        }
    }

    func resetTryoutValidationForSetupChange() {
        self.settings.onboardingPlaygroundValidated = false
        self.settings.onboardingPlaygroundSkipped = false
        self.settings.playgroundUsed = false
        self.asr.finalText = ""
    }

    func handleMicrophoneAction() {
        if self.asr.micStatus == .notDetermined {
            self.asr.requestMicAccess()
        } else {
            self.asr.openSystemSettingsForMic()
        }
    }

    func goBack() {
        self.activeShortcutRecordingTarget = nil
        self.shortcutRecordingMessage = nil
        self.currentStep = max(0, self.currentStep - 1)
    }

    func goNext() {
        self.activeShortcutRecordingTarget = nil
        self.shortcutRecordingMessage = nil
        self.currentStep = min(Step.allCases.count - 1, self.currentStep + 1)
    }

    func handlePrimaryAction() {
        guard !self.isModelPreparationInProgress else {
            return
        }

        if self.step == .language, let route = self.selectedOnboardingRoute {
            self.selectOnboardingRoute(route)
        }

        if self.step == .playground {
            guard self.isPlaygroundReady, !self.isFinishingOnboarding else { return }
            self.finishSetupFromPlayground()
            return
        }
        self.goNext()
    }

    func finishSetupFromPlayground() {
        guard !self.isFinishingOnboarding else { return }
        if !self.isVoiceModelReady || !self.isMicrophoneReady || !self.isPlaygroundReady {
            var missing: [String] = []
            if !self.isVoiceModelReady { missing.append("Voice Engine") }
            if !self.isMicrophoneReady { missing.append("microphone") }
            if !self.isPlaygroundReady { missing.append("Try Theater") }
            self.asr.errorTitle = "Setup isn't complete"
            self.asr.errorMessage = "Finish \(missing.joined(separator: ", ")) to continue."
            self.asr.showError = false
            return
        }
        self.asr.showError = false
        self.isFinishingOnboarding = true
        Task { @MainActor in
            if self.asr.isRunning || self.asr.isStarting || self.translationController.isSessionActive {
                await self.stopAndProcessTranscription()
            }
            self.finishOnboardingAtTranslate()
            self.isFinishingOnboarding = false
        }
    }

    func refreshOnboardingLanguagePack() async {
        let differs = SpokenLanguageResolver.sourceLanguage().id != SpokenLanguageResolver.targetLanguage().id
        await self.refreshLanguagePackAvailability()
        if differs, !self.languagePackIsInstalled {
            await self.refreshLanguagePackAvailability(requestDownload: true)
        }
    }

    func refreshLanguagePackAvailability(requestDownload: Bool = false) async {
        let source = SpokenLanguageResolver.sourceLanguage()
        let target = SpokenLanguageResolver.targetLanguage()
        await AppleTranslationEngine.shared.warm(source: source, target: target)
        if requestDownload {
            AppleTranslationEngine.shared.requestLanguagePackDownload()
        }
        let status = await AppleTranslationEngine.shared.packAvailability(
            source: source,
            target: target
        )
        self.languagePackIsInstalled = status.isReady
        self.languagePackAvailability = await AppleTranslationEngine.shared.checkAvailability(
            source: source,
            target: target
        )
    }
}

extension OnboardingFlowView {
    var orderedOnboardingInputDevices: [AudioDevice.Device] {
        let devicesByUID = Dictionary(
            self.onboardingInputDevices.map { ($0.uid, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        var ordered = self.settings.microphonePriority.compactMap { devicesByUID[$0.uid] }
        let knownUIDs = Set(ordered.map(\.uid))
        ordered.append(contentsOf: self.onboardingInputDevices.filter { !knownUIDs.contains($0.uid) })
        return ordered
    }

    func isOnboardingRouteSelected(_ route: VoiceEngineLanguageRoute) -> Bool {
        self.selectedOnboardingRoute?.id == route.id || self.isRouteSelectedInSettings(route)
    }

    func isRouteSelectedInSettings(_ route: VoiceEngineLanguageRoute) -> Bool {
        guard route.model == self.settings.selectedSpeechModel else {
            return false
        }

        switch route.binding {
        case .automatic, .whisper:
            return self.settings.onboardingSelectedLanguageID == route.language.id
        case let .appleSpeech(localeIdentifier):
            return self.settings.selectedAppleSpeechLocaleIdentifier == localeIdentifier
        case let .cohere(language):
            return self.settings.selectedCohereLanguage == language
        case let .nemotron(language):
            return self.settings.selectedNemotronLanguage == language
        }
    }

    func refreshOnboardingMicrophoneAuthorization(checkModels: Bool = false) {
        Task { @MainActor in
            await AudioStartupGate.shared.scheduleOpenAfterInitialUISettled()
            await AudioStartupGate.shared.waitUntilOpen()
            guard self.isOnboardingFlowVisible else { return }

            self.asr.micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            if self.step == .permissions, self.isMicrophoneReady {
                self.refreshOnboardingMicrophones(startPreview: true)
            }
            if checkModels {
                await self.asr.checkIfModelsExistAsync()
            }
        }
    }

    func refreshOnboardingMicrophones(startPreview: Bool) {
        guard self.isOnboardingFlowVisible else { return }
        self.onboardingMicrophoneRefreshGeneration &+= 1
        let generation = self.onboardingMicrophoneRefreshGeneration
        let suppressedUIDs = self.settings.suppressedMicrophoneUIDs

        Task { @MainActor in
            await AudioStartupGate.shared.scheduleOpenAfterInitialUISettled()
            await AudioStartupGate.shared.waitUntilOpen()
            guard generation == self.onboardingMicrophoneRefreshGeneration,
                  self.isOnboardingFlowVisible,
                  self.step == .permissions,
                  self.isMicrophoneReady
            else { return }

            DispatchQueue.global(qos: .userInitiated).async {
                let inputs = AudioDevice.listInputDevicesRefreshingLiveness()
                let defaultInputUID = AudioDevice.getDefaultInputDevice()?.uid
                let usableInputs = inputs.filter { device in
                    suppressedUIDs.contains(device.uid) == false && AudioDevice.isInputDeviceUsable(device)
                }

                DispatchQueue.main.async {
                    guard generation == self.onboardingMicrophoneRefreshGeneration,
                          self.isOnboardingFlowVisible,
                          self.step == .permissions,
                          self.isMicrophoneReady
                    else { return }

                    let selectedInput = self.appServices.microphonePreferenceCoordinator
                        .reconcileMicrophoneSelection(
                            availableInputs: inputs,
                            defaultInputUID: defaultInputUID
                        )
                    self.onboardingInputDevices = usableInputs
                    self.selectedOnboardingInputUID = selectedInput?.uid ?? usableInputs.first?.uid ?? ""

                    if startPreview {
                        self.startOnboardingMicrophonePreviewIfNeeded()
                    }
                }
            }
        }
    }

    func selectOnboardingMicrophone(uid: String) {
        guard let device = self.onboardingInputDevices.first(where: { $0.uid == uid }) else {
            return
        }

        self.settings.recordInputDeviceSelection(device.uid, name: device.name)
        self.selectedOnboardingInputUID = device.uid
        self.onboardingMicrophoneLevel = 0
        self.lastOnboardingMicrophoneLevelUpdate = 0
        self.startOnboardingMicrophonePreviewIfNeeded(forceRestart: true)
    }

    func startOnboardingMicrophonePreviewIfNeeded(forceRestart: Bool = false) {
        guard self.step == .permissions,
              self.isOnboardingFlowVisible,
              self.isMicrophoneReady,
              self.selectedOnboardingInputUID.isEmpty == false
        else { return }
        if forceRestart == false,
           self.previewedOnboardingInputUID == self.selectedOnboardingInputUID,
           self.asr.isMicrophonePreviewActive || self.microphonePreviewTask != nil
        {
            return
        }

        let selectedUID = self.selectedOnboardingInputUID
        self.microphonePreviewGeneration &+= 1
        let generation = self.microphonePreviewGeneration
        self.microphonePreviewTask?.cancel()
        self.previewedOnboardingInputUID = selectedUID
        self.microphonePreviewTask = Task { @MainActor in
            await self.asr.stopMicrophonePreview(retainPreparedCapture: false)
            guard generation == self.microphonePreviewGeneration,
                  Task.isCancelled == false,
                  self.step == .permissions,
                  self.isMicrophoneReady,
                  self.selectedOnboardingInputUID == selectedUID
            else {
                if generation == self.microphonePreviewGeneration {
                    self.microphonePreviewTask = nil
                }
                return
            }

            await self.asr.startMicrophonePreview()
            guard generation == self.microphonePreviewGeneration,
                  Task.isCancelled == false,
                  self.step == .permissions,
                  self.selectedOnboardingInputUID == selectedUID
            else {
                if generation == self.microphonePreviewGeneration {
                    await self.asr.stopMicrophonePreview()
                    self.microphonePreviewTask = nil
                }
                return
            }
            if self.asr.isMicrophonePreviewActive == false {
                self.previewedOnboardingInputUID = nil
            }
            self.microphonePreviewTask = nil
        }
    }

    func stopOnboardingMicrophonePreview() {
        self.microphonePreviewGeneration &+= 1
        let generation = self.microphonePreviewGeneration
        self.microphonePreviewTask?.cancel()
        self.microphonePreviewTask = Task { @MainActor in
            await self.asr.stopMicrophonePreview()
            guard generation == self.microphonePreviewGeneration else { return }
            self.onboardingMicrophoneLevel = 0
            self.lastOnboardingMicrophoneLevelUpdate = 0
            self.previewedOnboardingInputUID = nil
            self.microphonePreviewTask = nil
        }
    }

    func suspendOnboardingMicrophonePreviewForDictation() {
        self.microphonePreviewGeneration &+= 1
        self.microphonePreviewTask?.cancel()
        self.microphonePreviewTask = nil
        self.onboardingMicrophoneLevel = 0
        self.lastOnboardingMicrophoneLevelUpdate = 0
        self.previewedOnboardingInputUID = nil
    }
}

struct OnboardingMicrophoneSetupPanel: View {
    let devices: [AudioDevice.Device]
    let selectedUID: String
    let level: CGFloat
    let errorMessage: String?
    let onSelect: (String) -> Void

    var status: (text: String, color: Color) {
        if let errorMessage, errorMessage.isEmpty == false {
            return ("Microphone unavailable", Color.orange)
        }
        return ("Input level", Color.white.opacity(0.52))
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let activeBarCount = min(16, max(0, Int(ceil(self.level * 16))))

        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text("Select your microphone")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.58))

                Spacer(minLength: 12)

                if self.devices.isEmpty {
                    Text("No microphone available")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.orange.opacity(0.9))
                } else {
                    Picker(
                        "Input microphone",
                        selection: Binding(
                            get: { self.selectedUID },
                            set: self.onSelect
                        )
                    ) {
                        ForEach(self.devices) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 248)
                    .tint(.white)
                    .accessibilityHint("Moves the selected microphone to first in \(FluidProduct.displayName) priority")
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 62)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
                .padding(.horizontal, 18)

            HStack(spacing: 12) {
                Circle()
                    .fill(self.status.color)
                    .frame(width: 6, height: 6)

                Text(self.status.text)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(self.status.color)

                Spacer()

                HStack(spacing: 0) {
                    ForEach(0..<16, id: \.self) { index in
                        Capsule()
                            .fill(
                                index < activeBarCount
                                    ? FluidOnboardingLandingColors.blue.opacity(0.92)
                                    : Color.white.opacity(0.14)
                            )
                            .frame(width: 5, height: 15)

                        if index < 15 {
                            Spacer(minLength: 0)
                        }
                    }
                }
                .frame(width: 248)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Microphone input level")
                .accessibilityValue("\(Int((self.level * 100).rounded())) percent")
            }
            .padding(.horizontal, 18)
            .frame(height: 50)
        }
        .background(
            shape
                .fill(Color.white.opacity(0.040))
                .overlay(shape.stroke(Color.white.opacity(0.10), lineWidth: 1))
        )
    }
}
