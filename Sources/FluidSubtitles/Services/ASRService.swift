import Accelerate
import AVFoundation
import Combine
import Darwin
import Foundation
#if arch(arm64)
import FluidAudio
#endif
import AppKit
import AudioToolbox
import CoreAudio

@MainActor
final class ASRService: ObservableObject {
    static let finalTranscriptionStatusDelayNanoseconds: UInt64 = 100_000_000
    static let streamingDrainTimeoutNanoseconds: UInt64 = 30_000_000_000

    nonisolated static func shouldAssessShortAudioSilence(
        isEnabled: Bool,
        useDictionaryTrainingPath: Bool,
        hasRecognizedStreamingPreview: Bool,
        keepShortUtterances: Bool = false
    ) -> Bool {
        isEnabled
            && !useDictionaryTrainingPath
            && !hasRecognizedStreamingPreview
            && !keepShortUtterances
    }

    nonisolated static func assessShortAudioSilence(
        _ samples: [Float],
        sampleRate: Int = 16_000
    ) -> ShortAudioSilenceAssessment {
        let durationMilliseconds = sampleRate > 0
            ? Int((Double(samples.count) / Double(sampleRate) * 1000).rounded())
            : 0
        let maximumSampleCount = max(sampleRate, 0) * 4
        guard !samples.isEmpty, sampleRate > 0, samples.count <= maximumSampleCount else {
            return ShortAudioSilenceAssessment(
                durationMilliseconds: durationMilliseconds,
                isEligible: false,
                shouldSkipTranscription: false,
                peakAmplitude: 0,
                rmsAmplitude: 0,
                maximumFrameRMS: 0
            )
        }

        let frameSize = max(sampleRate / 50, 1) // 20 ms
        var peak: Float = 0
        var totalSquareSum = 0.0
        var frameSquareSum = 0.0
        var frameSampleCount = 0
        var maximumFrameRMS: Float = 0

        for sample in samples {
            guard sample.isFinite else {
                return ShortAudioSilenceAssessment(
                    durationMilliseconds: durationMilliseconds,
                    isEligible: true,
                    shouldSkipTranscription: false,
                    peakAmplitude: peak,
                    rmsAmplitude: 0,
                    maximumFrameRMS: maximumFrameRMS
                )
            }

            let magnitude = abs(sample)
            peak = max(peak, magnitude)
            let square = Double(sample) * Double(sample)
            totalSquareSum += square
            frameSquareSum += square
            frameSampleCount += 1

            if frameSampleCount == frameSize {
                maximumFrameRMS = max(
                    maximumFrameRMS,
                    Float(sqrt(frameSquareSum / Double(frameSampleCount)))
                )
                frameSquareSum = 0
                frameSampleCount = 0
            }
        }

        if frameSampleCount > 0 {
            maximumFrameRMS = max(
                maximumFrameRMS,
                Float(sqrt(frameSquareSum / Double(frameSampleCount)))
            )
        }
        let rms = Float(sqrt(totalSquareSum / Double(samples.count)))

        // Calibrated conservatively against real captures. Requiring
        // all three conditions keeps quiet speech and short words on the ASR path.
        let shouldSkip = peak < 0.01 && rms < 0.002 && maximumFrameRMS < 0.0045
        return ShortAudioSilenceAssessment(
            durationMilliseconds: durationMilliseconds,
            isEligible: true,
            shouldSkipTranscription: shouldSkip,
            peakAmplitude: peak,
            rmsAmplitude: rms,
            maximumFrameRMS: maximumFrameRMS
        )
    }

    @Published var isRunning: Bool = false
    @Published var finalText: String = ""
    @Published var partialTranscription: String = ""
    @Published var wordBoostStatusText: String = "Word boost: off"
    @Published var micStatus: AVAuthorizationStatus = .notDetermined
    @Published var isAsrReady: Bool = false
    @Published var isDownloadingModel: Bool = false
    @Published var isLoadingModel: Bool = false // True when loading cached model into memory (not downloading)
    @Published var isCancellingModelPreparation: Bool = false
    @Published var modelsExistOnDisk: Bool = false
    @Published var downloadProgress: Double? = nil
    @Published var modelPreparationPhase: ModelPreparationPhase? = nil
    @Published var downloadingModelId: String? = nil // Tracks which model is currently being downloaded
    @Published var isCancellingModelDownload: Bool = false
    @Published var isDictionaryTrainingCaptureActive: Bool = false
    @Published var isMicrophonePreviewActive: Bool = false
    @Published var microphonePreviewError: String?
    /// Narrow lifecycle event used only by onboarding microphone preview.
    /// This must not invalidate every ASR-observing view after each capture.
    let audioCaptureStateDidSettle = PassthroughSubject<Void, Never>()
    let deferredStopUIInvalidationDidFlush = PassthroughSubject<Void, Never>()
    var stopUIInvalidationGate = ASRStopUIInvalidationGate()
    var stopUIInvalidationTimeoutTask: Task<Void, Never>?
    var stopUIInvalidationHoldGeneration: UInt64 = 0
    var activeStopUIInvalidationHold: UInt64?
    var isStoppingFinalTranscription = false
    var defersStopUIInvalidation: Bool {
        self.stopUIInvalidationGate.isDeferring
    }

    var isFinalTranscriptionReady: Bool {
        self.isAsrReady && self.transcriptionProvider.isReady
    }

    var microphonePreviewOperationGeneration: UInt64 = 0
    var isMicrophonePreviewRequested = false
    var lastDictionaryTrainingResult: ASRTranscriptionResult?
    var lastStopOutcome: ASRStopOutcome = .empty
    var lastFinalTranscriptionDurationMs: Int?
    private(set) var dictionaryTrainingAudioGeneration = 0

    @Published var isStarting: Bool = false // Guard against re-entrant start() calls
    var audioCaptureStartWaiters: [CheckedContinuation<Void, Never>] = []
    var isRunningOrStarting: Bool {
        self.isRunning || self.isStarting
    }

    let audioCaptureReadinessGate = AudioCaptureReadinessGate()
    let firstPCMTimeoutNanoseconds: UInt64 = 2_000_000_000
    var audioCaptureStartGeneration: UInt64 = 0
    var audioCaptureAttemptID: UInt64 = 0
    var isTerminating = false
    var hasCompletedFirstTranscription: Bool = false // Track if model has warmed up with first transcription
    var lastBoostHitTerm: String?
    var hasPendingParakeetVocabularyReload: Bool = false
    var vocabularyChangeObserver: NSObjectProtocol?
    var settingsBackupRestoreObserver: NSObjectProtocol?
    var clamshellStateChangeObserver: NSObjectProtocol?
    var inputDeviceAvailabilityChangeObserver: NSObjectProtocol?
    var deviceListListenerInstalled = false
    var deviceListListenerToken: AudioObjectPropertyListenerBlock?
    var monitoredDeviceID: AudioObjectID?
    var monitoredDeviceIsAliveListenerToken: AudioObjectPropertyListenerBlock?
    var cachedDeviceUIDs: Set<String> = []
    var cachedInputDeviceIDsByUID: [String: AudioObjectID] = [:]
    var cachedInputLivenessByUID: [String: Bool] = [:]
    let typingService = TypingService()
    /// Session-only Voice Engine swap for critical thermal. Never persisted.
    var thermalSpeechModelOverride: SettingsStore.SpeechModel?

    var effectiveSpeechModel: SettingsStore.SpeechModel {
        self.thermalSpeechModelOverride ?? SettingsStore.shared.selectedSpeechModel
    }

    var hasThermalSpeechOverride: Bool { self.thermalSpeechModelOverride != nil }

    func applyThermalSpeechOverride(_ model: SettingsStore.SpeechModel) {
        guard self.thermalSpeechModelOverride != model else { return }
        self.thermalSpeechModelOverride = model
        self.resetTranscriptionProvider()
        Task { try? await self.ensureAsrReady() }
    }

    func clearThermalSpeechOverride() {
        guard self.thermalSpeechModelOverride != nil else { return }
        self.thermalSpeechModelOverride = nil
        if self.isRunning == false {
            self.resetTranscriptionProvider()
        }
    }
    var defaultInputListenerInstalled = false
    var defaultInputListenerToken: AudioObjectPropertyListenerBlock?
    var defaultOutputListenerToken: AudioObjectPropertyListenerBlock?

    // MARK: - Error Handling

    @Published var errorTitle: String = "Error"
    @Published var errorMessage: String = ""
    @Published var showError: Bool = false

    /// Returns a user-friendly status message for model loading state
    var modelStatusMessage: String {
        if self.isAsrReady { return "Model ready" }
        if self.isCancellingModelPreparation { return "Cancelling model preparation..." }
        if self.isCancellingModelDownload { return "Cancelling model download..." }
        if self.downloadingModelId != nil || self.isDownloadingModel || self.isLoadingModel {
            return self.modelPreparationStatusText
        }
        if self.modelsExistOnDisk { return "Model cached, needs loading" }
        return "Model not downloaded"
    }

    var modelPreparationStatusText: String {
        switch self.modelPreparationPhase {
        case .preparingDownload:
            return "Preparing download..."
        case .downloading:
            if let progress = self.downloadProgress {
                return "Downloading \(Int(progress * 100))%"
            }
            return "Downloading model..."
        case .optimizing:
            return "Optimizing model..."
        case .loading:
            return "Loading voice engine..."
        case nil:
            if self.isDownloadingModel { return "Preparing model..." }
            if self.isLoadingModel { return "Loading voice engine..." }
            return "Preparing model..."
        }
    }

    // MARK: - Transcription Provider (Settable)

    /// Cached providers to avoid re-instantiation
    var fluidAudioProvider: FluidAudioProvider?
    var parakeetRealtimeProvider: ParakeetRealtimeProvider?
    var externalCoreMLProvider: ExternalCoreMLTranscriptionProvider?
    var nemotronProviders: [NemotronProvider.Mode: NemotronProvider] = [:]
    var whisperProvider: WhisperProvider?
    var appleSpeechProvider: AppleSpeechProvider?
    /// Stored as Any? because @available cannot be applied to stored properties
    var _appleSpeechAnalyzerProvider: Any?

    /// Prevent concurrent provider.prepare() calls (download/load) from overlapping.
    /// Subsequent callers await the in-flight task.
    var ensureReadyTask: Task<Void, Error>?
    var ensureReadyTaskID: UUID?
    var ensureReadyProviderKey: String?
    var ensureReadyOperationID: UUID?
    var modelDownloadTask: Task<Void, Error>?
    var modelDownloadOperationID: UUID?
    var modelExistenceCheckID: UUID?

    var hasActiveModelPreparation: Bool {
        self.ensureReadyTask != nil
    }

    var hasActiveModelDownload: Bool {
        self.modelDownloadTask != nil
    }

    func cancelModelPreparation() {
        guard let task = self.ensureReadyTask else { return }

        DebugLogger.shared.info("Cancelling ASR model preparation", source: "ASRService")
        self.isCancellingModelPreparation = true
        task.cancel()
    }

    func cancelModelDownload() {
        guard let task = self.modelDownloadTask else { return }
        self.isCancellingModelDownload = true
        task.cancel()
    }

    func shutdownForTermination() async {
        self.isTerminating = true
        let routeRecoveryShutdownStartedAt = Date().timeIntervalSince1970
        await self.cancelAudioRouteRecoveryAndWait()
        self.benchmarkLog(
            "route_recovery_shutdown elapsedMs=\(self.elapsedMilliseconds(since: routeRecoveryShutdownStartedAt))"
        )
        if self.isStarting, self.isRunning == false {
            await self.cancelPendingAudioCaptureStart(reason: "app_termination")
        }
        if self.isRunning {
            await self.stopWithoutTranscription()
        }
        let audioEngineShutdownStartedAt = Date().timeIntervalSince1970
        await self.retireAudioEngineAndWait(reason: "app_termination")
        self.benchmarkLog(
            "audio_engine_shutdown elapsedMs=\(self.elapsedMilliseconds(since: audioEngineShutdownStartedAt))"
        )
        let directCaptureShutdownStartedAt = Date().timeIntervalSince1970
        await self.directAudioLifecycleController.shutdown(reason: "app_termination")
        self.benchmarkLog(
            "direct_capture_shutdown phase=\(self.directAudioLifecycleController.snapshot.phase.rawValue) " +
                "elapsedMs=\(self.elapsedMilliseconds(since: directCaptureShutdownStartedAt))"
        )

        let preparationTask = self.ensureReadyTask
        let downloadTask = self.modelDownloadTask
        preparationTask?.cancel()
        downloadTask?.cancel()
        _ = await preparationTask?.result
        _ = await downloadTask?.result
        await self.providerResetDrain?.task.value
        self.streamingWorkState.invalidateProvider()
        await self.transcriptionExecutor.cancelAndAwaitPending()

        self.fluidAudioProvider = nil
        self.parakeetRealtimeProvider = nil
        self.externalCoreMLProvider = nil
        self.nemotronProviders.removeAll()
        self.whisperProvider = nil
        self.appleSpeechProvider = nil
        self._appleSpeechAnalyzerProvider = nil
        self.isAsrReady = false
        self.isLoadingModel = false
        self.isDownloadingModel = false
    }

    /// The transcription provider, selected based on the unified SpeechModel setting.
    /// Uses the new SettingsStore.selectedSpeechModel instead of old TranscriptionProviderOption.
    var transcriptionProvider: TranscriptionProvider {
        let model = self.effectiveSpeechModel

        switch model {
        case .appleSpeechAnalyzer:
            if #available(macOS 26.0, *) {
                return self.getAppleSpeechAnalyzerProvider()
            } else {
                // Fallback to legacy Apple Speech on older macOS
                return self.getAppleSpeechProvider()
            }
        case .appleSpeech:
            return self.getAppleSpeechProvider()
        case .parakeetTDT, .parakeetTDTv2:
            return self.getFluidAudioProvider()
        case .parakeetRealtime:
            return self.getParakeetRealtimeProvider()
        case .cohereTranscribeSixBit:
            return self.getExternalCoreMLProvider()
        case .nemotronOffline, .nemotronStreaming, .nemotronStreaming320:
            return self.getNemotronProvider(mode: model.nemotronProviderMode)
        case .qwen3Asr:
            return self.getFluidAudioProvider()
        default:
            return self.getWhisperProvider()
        }
    }

    func getFluidAudioProvider() -> FluidAudioProvider {
        if let existing = fluidAudioProvider {
            return existing
        }
        let provider = FluidAudioProvider(
            configureWordBoosting: SettingsStore.shared.vocabularyBoostingEnabled
        )
        self.fluidAudioProvider = provider
        DebugLogger.shared.info(
            "ASRService: Created FluidAudio provider [vocabBoosting=\(SettingsStore.shared.vocabularyBoostingEnabled)]",
            source: "ASRService"
        )
        return provider
    }

    func getParakeetRealtimeProvider() -> ParakeetRealtimeProvider {
        if let existing = parakeetRealtimeProvider {
            return existing
        }
        let provider = ParakeetRealtimeProvider()
        self.parakeetRealtimeProvider = provider
        DebugLogger.shared.info("ASRService: Created Parakeet real-time provider", source: "ASRService")
        return provider
    }

    func getExternalCoreMLProvider() -> ExternalCoreMLTranscriptionProvider {
        if let existing = externalCoreMLProvider {
            return existing
        }
        let provider = ExternalCoreMLTranscriptionProvider()
        self.externalCoreMLProvider = provider
        DebugLogger.shared.info("ASRService: Created external CoreML provider", source: "ASRService")
        return provider
    }

    func getNemotronProvider(mode: NemotronProvider.Mode) -> NemotronProvider {
        if let existing = self.nemotronProviders[mode] { return existing }
        let provider = NemotronProvider(mode: mode)
        self.nemotronProviders[mode] = provider
        DebugLogger.shared.info("ASRService: Created \(provider.name) provider", source: "ASRService")
        return provider
    }

    func getWhisperProvider() -> WhisperProvider {
        if let existing = whisperProvider {
            return existing
        }
        let provider = WhisperProvider()
        self.whisperProvider = provider
        DebugLogger.shared.info("ASRService: Created Whisper provider", source: "ASRService")
        return provider
    }

    func getAppleSpeechProvider() -> AppleSpeechProvider {
        if let existing = appleSpeechProvider {
            return existing
        }
        let provider = AppleSpeechProvider()
        self.appleSpeechProvider = provider
        DebugLogger.shared.info("ASRService: Created AppleSpeech provider", source: "ASRService")
        return provider
    }

    @available(macOS 26.0, *)
    func getAppleSpeechAnalyzerProvider() -> AppleSpeechAnalyzerProvider {
        if let existing = _appleSpeechAnalyzerProvider as? AppleSpeechAnalyzerProvider {
            return existing
        }
        let provider = AppleSpeechAnalyzerProvider()
        self._appleSpeechAnalyzerProvider = provider
        DebugLogger.shared.info("ASRService: Created AppleSpeechAnalyzer provider", source: "ASRService")
        return provider
    }

    /// Returns the user-friendly name of the engine currently hearing speech.
    var activeProviderName: String {
        self.effectiveSpeechModel.displayName
    }

    func currentSpeechModelDimensions() -> (provider: String, model: String) {
        let selectedModel = self.effectiveSpeechModel
        return (
            provider: selectedModel.provider.rawValue.lowercased(),
            model: selectedModel.rawValue
        )
    }

    func elapsedMilliseconds(since start: TimeInterval?) -> Int {
        guard let start else { return -1 }
        return Int(((Date().timeIntervalSince1970 - start) * 1000).rounded())
    }

    func benchmarkLog(_ message: String) {
        DebugLogger.shared.benchmark("ASR_BENCH", message: "session=\(self.benchmarkSessionID) \(message)", source: "ASRBenchmark")
    }

    /// Gets a provider for a specific model (without changing the active selection)
    /// Used for downloading models without switching the active model.
    func getProvider(for model: SettingsStore.SpeechModel) -> TranscriptionProvider {
        switch model {
        case .appleSpeechAnalyzer:
            if #available(macOS 26.0, *) {
                return AppleSpeechAnalyzerProvider()
            } else {
                return AppleSpeechProvider()
            }
        case .appleSpeech:
            return AppleSpeechProvider()
        case .parakeetTDT, .parakeetTDTv2:
            // Create a new provider configured for the specific model
            return FluidAudioProvider(modelOverride: model, configureWordBoosting: false)
        case .parakeetRealtime:
            return ParakeetRealtimeProvider()
        case .cohereTranscribeSixBit:
            return ExternalCoreMLTranscriptionProvider(modelOverride: model)
        case .nemotronOffline, .nemotronStreaming, .nemotronStreaming320:
            return NemotronProvider(mode: model.nemotronProviderMode)
        case .qwen3Asr:
            // Qwen support removed; route legacy requests to Parakeet v3.
            return FluidAudioProvider(modelOverride: .parakeetTDT, configureWordBoosting: false)
        default:
            // Whisper models - create provider with specific model override
            return WhisperProvider(modelOverride: model)
        }
    }

    /// Downloads a specific model without changing the active selection.
    /// - Parameters:
    ///   - model: The model to download
    ///   - progressHandler: Optional callback for download progress (0.0 to 1.0)
    func downloadModel(
        _ model: SettingsStore.SpeechModel,
        progressHandler: ((Double) -> Void)?
    ) async throws {
        guard self.modelDownloadTask == nil, self.ensureReadyTask == nil else {
            throw NSError(
                domain: "ASRService",
                code: -2001,
                userInfo: [NSLocalizedDescriptionKey: "Another model operation is already in progress."]
            )
        }

        let operationID = UUID()
        let provider = self.getProvider(for: model)
        self.modelDownloadOperationID = operationID
        self.downloadingModelId = model.id
        self.downloadProgress = nil
        self.modelPreparationPhase = .preparingDownload
        self.isCancellingModelDownload = false

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                DebugLogger.shared.info("Downloading model: \(model.displayName) (without changing active selection)", source: "ASRService")
                try await provider.prepare(progressHandler: { progress in
                    Task { @MainActor in
                        guard
                            self.modelDownloadOperationID == operationID,
                            !self.isCancellingModelDownload
                        else {
                            return
                        }
                        self.applyModelPreparationProgress(
                            progress,
                            updatesActiveModelState: false,
                            externalProgressHandler: progressHandler
                        )
                    }
                })
                try Task.checkCancellation()
                DebugLogger.shared.info("Model download completed: \(model.displayName)", source: "ASRService")
            } catch {
                let wasCancelled = Task.isCancelled || Self.isModelPreparationCancellation(error)
                if wasCancelled,
                   provider.shouldClearCacheAfterCancellation,
                   provider.modelsExistOnDisk() == false
                {
                    try? await provider.clearCache()
                }
                if wasCancelled {
                    throw CancellationError()
                }
                throw error
            }
        }
        self.modelDownloadTask = task

        defer {
            if self.modelDownloadOperationID == operationID {
                self.modelDownloadTask = nil
                self.modelDownloadOperationID = nil
                self.downloadingModelId = nil
                self.downloadProgress = nil
                self.modelPreparationPhase = nil
                self.isCancellingModelDownload = false
            }
        }

        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw error
        }
    }

    /// Call this when the transcription provider setting changes to reset state
    func resetTranscriptionProvider() {
        guard !self.recordingBufferHandoffGate.isRecovering else {
            self.resetProviderAfterStreamingRecovery = true
            return
        }
        let newModel = self.effectiveSpeechModel
        DebugLogger.shared.info("ASRService: Switching to '\(newModel.displayName)', resetting provider state...", source: "ASRService")

        // Any in-flight preview belongs to the provider being retired. Its operation
        // still drains through the executor, but must not publish into this session.
        self.streamingWorkState.invalidateProvider()
        self.isAsrReady = false
        self.modelsExistOnDisk = false
        self.isLoadingModel = false
        self.isDownloadingModel = false
        if !self.hasActiveModelDownload {
            self.downloadProgress = nil
            self.modelPreparationPhase = nil
        }
        self.hasCompletedFirstTranscription = false // Reset warm-up state when switching models
        let retiringTask = self.ensureReadyTask
        if let task = retiringTask {
            self.isCancellingModelPreparation = true
            task.cancel()
        }
        let resetDrainID = UUID()
        let executor = self.transcriptionExecutor
        let resetDrainTask = Task { await executor.cancelAndAwaitPending() }
        self.providerResetDrain = (resetDrainID, resetDrainTask)
        // Keep the task handle until its provider has stopped and cancellation cleanup has
        // completed. The next ensureAsrReady call waits for it before touching the same cache.
        self.ensureReadyProviderKey = nil
        self.ensureReadyOperationID = nil
        self.lastBoostHitTerm = nil
        self.wordBoostStatusText = "Word boost: off"

        // Reset cached providers to force re-initialization with new settings
        self.fluidAudioProvider = nil
        self.parakeetRealtimeProvider = nil
        self.externalCoreMLProvider = nil
        self.whisperProvider = nil
        self.appleSpeechProvider = nil
        self._appleSpeechAnalyzerProvider = nil

        // CRITICAL FIX: Check if the NEW model's files exist on disk
        // This prevents UI from showing "Download" when model is already downloaded
        // Use Task for async check to support providers like AppleSpeechAnalyzerProvider
        Task { [weak self] in
            guard let self = self else { return }
            _ = await retiringTask?.result
            guard self.effectiveSpeechModel == newModel else { return }
            await self.checkIfModelsExistAsync()
            await MainActor.run {
                self.refreshWordBoostStatus()
            }
            DebugLogger.shared.info("ASRService: Provider reset complete, will initialize '\(newModel.displayName)' on next use", source: "ASRService")
        }
    }

    // CRITICAL FIX (launch-time crash mitigation):
    // Combine's default ObservableObject.objectWillChange implementation uses Swift reflection to walk *stored*
    // properties. If we store an AVFoundation ObjC class type (like AVAudioEngine) directly, the reflection
    // path can trigger Objective-C class lookup for "AVAudioEngine" during SwiftUI/AttributeGraph's early
    // metadata processing window. On some systems this manifests as an EXC_BAD_ACCESS at 0x0 inside
    // swift_getTypeByMangledName / AttributeGraph (very similar to the crash reports we've been seeing).
    //
    // To reduce risk:
    // - We do NOT store AVAudioEngine as a stored property.
    // - We store it as AnyObject? and expose it through a computed property.
    // This keeps initialization lazy *and* keeps AVAudioEngine out of the reflected stored layout.
    var engineStorage: AnyObject?
    var engine: AVAudioEngine {
        if let existing = engineStorage as? AVAudioEngine {
            return existing
        }
        let created = AVAudioEngine()
        self.engineStorage = created
        return created
    }

    var hasWarmAudioEngine: Bool {
        self.engineStorage is AVAudioEngine
    }

    enum AudioCaptureBackend {
        case none
        case directCoreAudio
        case audioEngine
        case systemAudio
    }

    struct AudioRouteRecoveryRequest {
        let generation: UInt64
        let reason: String
        let requiresIdlePrewarm: Bool
        let reconcilesInputSelection: Bool
    }

    lazy var directAudioLifecycleController: DirectCoreAudioLifecycleController = {
        let pipeline = self.audioCapturePipeline
        return DirectCoreAudioLifecycleController(
            packetHandler: { samples, frameCount, sampleRate, inputHostTime, inputSampleTime in
                pipeline.handle(
                    samples: samples,
                    frameCount: frameCount,
                    sampleRate: sampleRate,
                    inputHostTime: inputHostTime,
                    inputSampleTime: inputSampleTime
                )
            },
            onFormatInvalidated: { [weak self] invalidation in
                Task { @MainActor [weak self] in
                    await self?.handleDirectCaptureFormatInvalidation(invalidation)
                }
            }
        )
    }()

    var activeAudioCaptureBackend: AudioCaptureBackend = .none
    let systemAudioCapture = SystemAudioCapture()
    var audioStartAttemptInputUID: String?
    var audioStartAttemptInputName: String?
    var audioStartAttemptIsBluetooth = false
    var audioStartAttemptIsInternalMicrophone = false
    var deferredBluetoothStartupRouteRecovery =
        AudioCaptureIdlePolicy.DeferredBluetoothRouteRecovery()
    var silentPCMRecoveryWatchdog = AudioCaptureIdlePolicy.SilentPCMRecoveryWatchdog()

    var hasPreparedAudioCapture: Bool {
        self.directAudioLifecycleController.snapshot.isPrepared || self.hasWarmAudioEngine
    }

    /// Detaches the current engine from main-actor state and returns a token that
    /// owns its final strong reference. The token must be handed to
    /// `audioEngineRetirementDrain`; dropping it directly would put deallocation
    /// back on the caller's actor.
    func detachAudioEngineForRetirement(reason: String) -> AudioEngineRetirementToken? {
        self.audioEngineStandbyTask?.cancel()
        self.audioEngineStandbyTask = nil

        self.activeAudioCaptureBackend = .none

        if self.isEngineTapInstalled {
            if let engine = self.engineStorage as? AVAudioEngine {
                engine.inputNode.removeTap(onBus: 0)
            }
            self.isEngineTapInstalled = false
        }
        if let engine = self.engineStorage as? AVAudioEngine, engine.isRunning {
            engine.stop()
        }
        self.audioCapturePipeline.clearPreroll()

        let retirementToken = self.engineStorage.map(AudioEngineRetirementToken.init)
        self.engineStorage = nil
        DebugLogger.shared.debug("Audio engine retired (\(reason))", source: "ASRService")
        return retirementToken
    }

    /// Fire-and-forget retirement for paths that do not construct a replacement.
    /// All releases still share the serial drain, and capture startup waits on a
    /// drain barrier before it may create another engine.
    func retireAudioEngine(reason: String) {
        guard let token = self.detachAudioEngineForRetirement(reason: reason) else { return }
        self.audioEngineRetirementDrain.schedule(token)
    }

    /// Route recovery and engine retry paths use this completion barrier so the
    /// old AVAudioEngine and its AVAudioIOUnit are fully deallocated before a
    /// replacement can touch Core Audio.
    func retireAudioEngineAndWait(reason: String) async {
        if let token = self.detachAudioEngineForRetirement(reason: reason) {
            await self.audioEngineRetirementDrain.releaseAndWait(token)
        } else {
            await self.audioEngineRetirementDrain.waitForScheduledReleases()
        }
    }

    func scheduleAudioEngineStandbyRetirement() {
        self.audioEngineStandbyTask?.cancel()
        let delay = self.audioEngineStandbyNanoseconds
        self.audioEngineStandbyTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            await self?.retireWarmAudioEngineIfIdle()
        }
    }

    func retireWarmAudioEngineIfIdle() async {
        guard self.isRunning == false, self.isStarting == false else { return }
        await self.coolDownAudioEngineStandby(reason: "standby_timeout")
    }

    func coolDownAudioEngineStandby(reason: String) async {
        self.audioEngineStandbyTask?.cancel()
        self.audioEngineStandbyTask = nil

        await self.directAudioLifecycleController.invalidate(reason: reason)
        await self.retireAudioEngineAndWait(reason: reason)
        self.benchmarkLog("audio_engine_standby retired=true reason=\(reason)")
        DebugLogger.shared.debug("Audio engine fully retired from standby (\(reason))", source: "ASRService")
    }

    func prewarmConfiguredAudioCaptureIfPossible(
        reason: String,
        allowDuringRouteRecovery: Bool = false
    ) async {
        guard self.isTerminating == false else {
            DebugLogger.shared.debug("Audio capture prewarm skipped - app is terminating", source: "ASRService")
            return
        }
        guard self.micStatus == .authorized else {
            DebugLogger.shared.debug("Audio engine prewarm skipped - mic not authorized", source: "ASRService")
            return
        }
        guard self.isRunning == false,
              self.isStarting == false || allowDuringRouteRecovery
        else {
            DebugLogger.shared.debug("Audio engine prewarm skipped - capture active", source: "ASRService")
            return
        }
        guard allowDuringRouteRecovery || self.isRecoveringAudioRoute == false else {
            DebugLogger.shared.debug("Audio engine prewarm skipped - route recovery active", source: "ASRService")
            return
        }
        guard AudioCaptureIdlePolicy.shouldPrewarmCapture(
            experimentalDirectAudioCaptureEnabled: SettingsStore.shared.experimentalDirectAudioCaptureEnabled
        ) else {
            // Constructing AVAudioEngine while idle instantiates its input and
            // output audio units. Bluetooth headsets can then remain in the
            // low-bandwidth HFP route even though no recording is active.
            if self.hasWarmAudioEngine {
                await self.retireAudioEngineAndWait(reason: "legacy_idle_prewarm_suppressed")
            }
            DebugLogger.shared.debug(
                "Legacy AVAudioEngine idle prewarm skipped to preserve playback quality",
                source: "ASRService"
            )
            return
        }
        guard self.hasPreparedAudioCapture == false else {
            DebugLogger.shared.debug("Audio capture prewarm skipped - backend already prepared", source: "ASRService")
            return
        }

        // A legacy stop releases AVAudioEngine on the serial retirement drain.
        // Do not register a direct Core Audio backend until that teardown has
        // completed, then recheck state because this await yields the main actor.
        await self.audioEngineRetirementDrain.waitForScheduledReleases()
        guard self.isTerminating == false,
              self.isRunning == false,
              self.isStarting == false || allowDuringRouteRecovery,
              self.hasPreparedAudioCapture == false
        else {
            DebugLogger.shared.debug(
                "Audio capture prewarm skipped - state changed while waiting for engine retirement",
                source: "ASRService"
            )
            return
        }

        let startedAt = Date().timeIntervalSince1970
        do {
            _ = try await self.prepareDirectAudioInput(reason: reason)
            self.benchmarkLog("direct_audio_prewarm reason=\(reason) elapsedMs=\(self.elapsedMilliseconds(since: startedAt))")
        } catch {
            DebugLogger.shared.warning(
                "Direct Core Audio prewarm failed: \(error.localizedDescription)",
                source: "ASRService"
            )
        }
    }

    func resolvedInputDeviceForCapture(
        availableInputs: [AudioDevice.Device] = AudioDevice.listInputDevices(),
        defaultInputUID: String? = AudioDevice.getDefaultInputDevice()?.uid,
        excluding excludedUIDs: Set<String> = []
    ) -> AudioDevice.Device? {
        return AppServices.shared.microphonePreferenceCoordinator.inputDeviceForCapture(
            availableInputs: availableInputs,
            defaultInputUID: defaultInputUID,
            excluding: excludedUIDs
        )
    }

    func directCoreAudioDeviceSelection(
        excluding excludedUIDs: Set<String> = []
    ) -> DirectCoreAudioDeviceSelection? {
        if let inputUID = self.resolvedInputDeviceForCapture(excluding: excludedUIDs)?.uid {
            return .preferredUID(inputUID)
        }
        return nil
    }

    /// Prepares the direct device callback without starting hardware IO. This
    /// keeps the default idle state privacy-friendly while removing device and
    /// ring allocation from the hotkey path.
    func prepareDirectAudioInput(
        reason: String
    ) async throws -> DirectCoreAudioLifecycleController.Snapshot {
        guard self.micStatus == .authorized else {
            throw NSError(
                domain: "ASRService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Microphone access is not authorized."]
            )
        }
        guard let selection = self.directCoreAudioDeviceSelection() else {
            throw NSError(
                domain: "ASRService",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "No usable microphone is available."]
            )
        }
        let device = try await self.directAudioLifecycleController.resolveDevice(
            selection: selection,
            reason: "prepare:\(reason)"
        )
        let snapshot = try await self.directAudioLifecycleController.prepare(
            deviceID: device.id,
            deviceName: device.name,
            reason: reason
        )
        DebugLogger.shared.info(
            "Prepared direct Core Audio input '\(device.name)' " +
                "(\(Int((snapshot.sampleRate ?? 0).rounded()))Hz, " +
                "\(snapshot.bufferFrameSize ?? 0) frames, generation=\(snapshot.generation), " +
                "reason=\(reason))",
            source: "ASRService"
        )
        return snapshot
    }

    func startConfiguredAudioCapture(
        excluding excludedInputUIDs: Set<String> = [],
        forcingInputUID: String? = nil
    ) async throws {
        let previousAttemptIdentity = self.audioStartAttemptInputUID.map {
            AudioCaptureIdlePolicy.CaptureAttemptIdentity(
                uid: $0,
                name: self.audioStartAttemptInputName,
                isBluetooth: self.audioStartAttemptIsBluetooth,
                isInternalMicrophone: self.audioStartAttemptIsInternalMicrophone
            )
        }
        self.audioStartAttemptInputUID = nil
        self.audioStartAttemptInputName = nil
        self.audioStartAttemptIsBluetooth = false
        self.audioStartAttemptIsInternalMicrophone = false
        if SettingsStore.shared.experimentalDirectAudioCaptureEnabled {
            // A non-route path may have scheduled a fire-and-forget retirement.
            // Do not let direct capture startup overlap a queued AVAudioEngine
            // release.
            await self.audioEngineRetirementDrain.waitForScheduledReleases()
            do {
                let deviceSnapshot = await Task.detached(priority: .userInitiated) {
                    let allDevices = AudioDevice.listAllDevices()
                    return (
                        allDevices: allDevices,
                        defaultInputUID: AudioDevice.getDefaultInputDevice(from: allDevices)?.uid
                    )
                }.value
                let allDevices = deviceSnapshot.allDevices
                let availableInputs = allDevices.filter(\.hasInput)
                let selectedInput: AudioDevice.Device?
                if let forcingInputUID {
                    selectedInput = availableInputs.first { $0.uid == forcingInputUID }
                } else {
                    let resolvedInput = self.resolvedInputDeviceForCapture(
                        availableInputs: availableInputs,
                        defaultInputUID: deviceSnapshot.defaultInputUID,
                        excluding: excludedInputUIDs
                    )
                    selectedInput = AudioCaptureIdlePolicy.bluetoothInputAwaitingAvailability(
                        priorityInputUIDs: SettingsStore.shared.microphonePriority.map(\.uid),
                        preferredInputUID: SettingsStore.shared.preferredInputDeviceUID,
                        resolvedInputUID: resolvedInput?.uid,
                        allDevices: allDevices,
                        excluding: excludedInputUIDs
                    ) ?? resolvedInput
                }
                guard let attemptIdentity = AudioCaptureIdlePolicy.CaptureAttemptIdentity.resolve(
                    selectedInput: selectedInput,
                    forcingInputUID: forcingInputUID,
                    previous: previousAttemptIdentity
                ) else {
                    throw NSError(
                        domain: "ASRService",
                        code: -4,
                        userInfo: [NSLocalizedDescriptionKey: "No remaining microphone is available."]
                    )
                }
                let selection = DirectCoreAudioDeviceSelection.preferredUID(attemptIdentity.uid)
                // Preserve the selected endpoint's identity before the async UID
                // resolution, where Bluetooth topology churn can make it vanish.
                self.audioStartAttemptInputUID = attemptIdentity.uid
                self.audioStartAttemptInputName = attemptIdentity.name
                self.audioStartAttemptIsBluetooth = attemptIdentity.isBluetooth
                self.audioStartAttemptIsInternalMicrophone = attemptIdentity.isInternalMicrophone
                let device = try await self.directAudioLifecycleController.resolveDevice(
                    selection: selection,
                    reason: "recording_start"
                )
                self.audioStartAttemptInputUID = device.uid
                self.audioStartAttemptInputName = device.name
                self.audioStartAttemptIsBluetooth = device.isBluetooth
                self.audioStartAttemptIsInternalMicrophone = device.isUnavailableWhenClamshellClosed
                AppServices.shared.microphonePreferenceCoordinator.reportResolvedSelection(
                    uid: device.uid,
                    name: device.name
                )
                let snapshot = try await self.directAudioLifecycleController.start(
                    deviceID: device.id,
                    deviceName: device.name,
                    reason: "recording_start"
                )
                try Task.checkCancellation()
                self.activeAudioCaptureBackend = .directCoreAudio
                let callbackDurationMilliseconds =
                    Double(snapshot.bufferFrameSize ?? 0) /
                    max(snapshot.sampleRate ?? 0, 1) * 1000
                let callbackMs = Int(callbackDurationMilliseconds.rounded())
                self.benchmarkLog(
                    "audio_backend kind=direct_core_audio device=\(snapshot.deviceID ?? 0) " +
                        "generation=\(snapshot.generation) frames=\(snapshot.bufferFrameSize ?? 0) " +
                        "sampleRate=\(Int((snapshot.sampleRate ?? 0).rounded())) callbackMs=\(callbackMs)"
                )
                return
            } catch {
                await self.directAudioLifecycleController.invalidate(reason: "recording_start_failed")
                DebugLogger.shared.error(
                    "Direct Core Audio capture failed: \(error.localizedDescription)",
                    source: "ASRService"
                )
                throw error
            }
        }

        await self.directAudioLifecycleController.invalidate(reason: "av_audio_engine_selected")

        try await self.startAVAudioEngineCapture()
    }

    func startAVAudioEngineCapture() async throws {
        await self.audioEngineRetirementDrain.waitForScheduledReleases()
        self.benchmarkLog("audio_backend kind=av_audio_engine reason=faster_recording_start_disabled")
        try self.configureSession()
        try await self.startEngine()
        try self.setupEngineTap()
        self.activeAudioCaptureBackend = .audioEngine
    }

    func stopActiveAudioCapture(
        retainDirectPreparedCapture: Bool = true,
        reason: String
    ) async {
        switch self.activeAudioCaptureBackend {
        case .directCoreAudio:
            let report = await self.directAudioLifecycleController.stop(
                retainPrepared: retainDirectPreparedCapture,
                reason: reason
            )
            if report.status != noErr {
                DebugLogger.shared.warning(
                    "Direct Core Audio stop returned OSStatus \(report.status)",
                    source: "ASRService"
                )
            }
            if report.droppedPackets > 0 {
                DebugLogger.shared.warning(
                    "Direct Core Audio dropped \(report.droppedPackets) packet(s)",
                    source: "ASRService"
                )
            }
        case .audioEngine:
            self.removeEngineTap()
            if let engine = self.engineStorage as? AVAudioEngine, engine.isRunning {
                engine.stop()
            }
        case .systemAudio:
            await self.systemAudioCapture.stop()
        case .none:
            break
        }
        self.activeAudioCaptureBackend = .none
    }

    var inputFormat: AVAudioFormat?
    var micPermissionGranted = false
    var isRequestingMicrophoneAccess = false

    // Thread-safe buffer to prevent "Array mutation while enumerating" and memory corruption crashes
    // during long sessions where reallocation occurs frequently.
    let audioBuffer = ThreadSafeAudioBuffer()
    var lastCompletedAudioFile: DictationAudioMetadata?
    var streamingWavWriter: DictationAudioHistoryStore.StreamingWavWriter?
    var committedStreamingText = ""
    var idleMemoryReleaseTask: Task<Void, Never>?
    static let idleMemoryReleaseNanoseconds: UInt64 = 5 * 60 * 1_000_000_000

    // Streaming transcription state (no VAD)
    let streamingTaskLifecycle = StreamingTaskLifecycle()
    var streamingWorkState = StreamingTranscriptionWorkState()
    var streamingSchedulingSessionID: Int?
    let recordingBufferHandoffGate = RecordingBufferHandoffGate()
    var timedOutStreamingHandoff: (sessionID: Int, token: RecordingBufferHandoffGate.Token)?
    var resetProviderAfterStreamingRecovery = false
    var streamingHealthCheckCount: Int = 0
    var streamingHealthLastBufferCount: Int = 0
    var lastProcessedSampleCount: Int = 0
    var isProcessingChunk: Bool = false
    var skipNextChunk: Bool = false
    var pendingLatestChunk: Bool = false
    var didConsumeSilenceEdgeTick: Bool = false
    var lastVoicedUptime: TimeInterval?
    var didRunStreamingTickThisListen = false
    var previousFullTranscription: String = ""
    var benchmarkSessionID: Int = 0
    var benchmarkRecordingStartedAt: TimeInterval?
    var benchmarkStreamingChunkIndex: Int = 0
    var benchmarkCompletedStreamingChunks: Int = 0
    var benchmarkLastChunkSampleCount: Int = 0
    let transcriptionExecutor = TranscriptionExecutor() // Serializes all CoreML access
    var providerResetDrain: (id: UUID, task: Task<Void, Never>)?
    var engineConfigurationChangeObserver: NSObjectProtocol?
    let audioEngineRetirementDrain = AudioEngineRetirementDrain()
    var audioRouteRecoveryTask: Task<Void, Never>?
    let audioRouteRecoveryDelayNanoseconds: UInt64 = 300_000_000
    var audioRouteRecoveryGeneration: UInt64 = 0
    var pendingAudioRouteRecovery: AudioRouteRecoveryRequest?
    var audioEngineStandbyTask: Task<Void, Never>?
    let audioEngineStandbyNanoseconds: UInt64 = 8_000_000_000
    var isEngineTapInstalled = false
    var isRecoveringAudioRoute = false

    /// Tracks whether we paused system media for this recording session.
    /// Used to resume playback only if we were the ones who paused it.
    var didPauseMediaForThisSession: Bool = false

    var audioLevelSubject = PassthroughSubject<CGFloat, Never>()
    var audioLevelPublisher: AnyPublisher<CGFloat, Never> {
        self.audioLevelSubject.eraseToAnyPublisher()
    }

    var lastAudioLevelSentAt: TimeInterval = 0

    func consumeLastCompletedAudioFile() -> DictationAudioMetadata? {
        let metadata = self.lastCompletedAudioFile
        self.lastCompletedAudioFile = nil
        return metadata
    }

    @available(*, deprecated, renamed: "consumeLastCompletedAudioFile")
    func consumeLastCompletedAudioSnapshot() -> DictationAudioSnapshot? {
        if let metadata = self.consumeLastCompletedAudioFile() {
            DictationAudioHistoryStore.shared.deleteAudio(fileName: metadata.fileName)
        }
        return nil
    }

    func consumeLastFinalTranscriptionDurationMs() -> Int? {
        let duration = self.lastFinalTranscriptionDurationMs
        self.lastFinalTranscriptionDurationMs = nil
        return duration
    }

    func beginStreamingWavWriterIfNeeded() {
        self.abortStreamingWavWriter()
        guard SettingsStore.shared.saveTranscriptionHistory,
              SettingsStore.shared.saveAudioWithTranscriptionHistory
        else { return }
        do {
            self.streamingWavWriter = try DictationAudioHistoryStore.shared.beginStreamingWrite(
                entryID: UUID(),
                timestamp: Date()
            )
        } catch {
            DebugLogger.shared.warning(
                "Could not start streaming WAV writer: \(error.localizedDescription)",
                source: "ASRService"
            )
        }
    }

    func finishStreamingWavWriter(model: String) {
        guard let writer = self.streamingWavWriter else { return }
        self.streamingWavWriter = nil
        do {
            self.lastCompletedAudioFile = try writer.finish(model: model)
        } catch {
            writer.abort()
            DebugLogger.shared.warning(
                "Could not finish streaming WAV: \(error.localizedDescription)",
                source: "ASRService"
            )
        }
    }

    func abortStreamingWavWriter() {
        self.streamingWavWriter?.abort()
        self.streamingWavWriter = nil
        if let metadata = self.lastCompletedAudioFile {
            DictationAudioHistoryStore.shared.deleteAudio(fileName: metadata.fileName)
            self.lastCompletedAudioFile = nil
        }
    }

    /// Copy only the incremental delta when possible so a preview tick does
    /// not allocate the full 30-second ring.
    func previewChunk(
        logicalSampleCount: Int,
        logicalStart: Int,
        incrementalDeltaStart: Int?
    ) -> (samples: [Float], kind: StreamingTranscriptStitcher.Kind) {
        if let incrementalDeltaStart {
            let start = max(incrementalDeltaStart, logicalStart)
            let available = logicalSampleCount - start
            if available > 0 {
                let delta = self.audioBuffer.getRange(startingAt: start, count: available)
                if delta.count == available {
                    return (delta, .incrementalDelta)
                }
            }
        }
        return (self.audioBuffer.getRetained(), .retainedWindow)
    }

    func dropRetainedAudioAfterPreview(currentSampleCount: Int, usedIncrementalDelta: Bool) {
        if usedIncrementalDelta {
            #if arch(arm64)
            let accepted = (self.transcriptionProvider as? FluidAudioProvider)?.acceptedIncrementalSampleCount
                ?? currentSampleCount
            #else
            let accepted = currentSampleCount
            #endif
            let dropBefore = max(0, accepted - LiveAudioRetention.incrementalOverlapSamples)
            self.audioBuffer.dropSamples(before: dropBefore)
            return
        }
        let dropBefore = max(0, currentSampleCount - LiveAudioRetention.maximumRetainedSamples)
        self.audioBuffer.dropSamples(before: dropBefore)
    }

    func cancelIdleMemoryRelease() {
        self.idleMemoryReleaseTask?.cancel()
        self.idleMemoryReleaseTask = nil
    }

    func scheduleIdleMemoryRelease() {
        self.cancelIdleMemoryRelease()
        self.idleMemoryReleaseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.idleMemoryReleaseNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.releaseIdleModelMemoryIfNeeded()
        }
    }

    func releaseIdleModelMemoryIfNeeded() async {
        guard self.isRunning == false,
              self.isStarting == false,
              self.isLoadingModel == false,
              self.modelDownloadTask == nil,
              LiveTranslationController.shared.isSessionActive == false
        else { return }
        if self.transcriptionProvider is AppleSpeechProvider { return }
        await self.transcriptionProvider.releaseMemory()
        self.isAsrReady = false
        DebugLogger.shared.info("Released idle speech model from memory", source: "ASRService")
    }

    func dictionaryTrainingAudioChunk(at offset: Int, count: Int) -> [Float] {
        self.audioBuffer.getRange(startingAt: offset, count: count)
    }

    var streamingChunkDurationSeconds: Double {
        self.effectiveSpeechModel.streamingPreviewIntervalSeconds
    }

    var minimumStreamingPreviewSamples: Int {
        Int(self.effectiveSpeechModel.minimumStreamingPreviewSeconds * 16_000)
    }

    /// Handles AVAudioEngine tap processing off the @MainActor to avoid touching main-actor state
    /// from CoreAudio's realtime callback thread.
    lazy var audioCapturePipeline: AudioCapturePipeline = {
        let readinessGate = self.audioCaptureReadinessGate
        return AudioCapturePipeline(
            audioBuffer: self.audioBuffer,
            onAcceptedSamples: { [weak self] samples in
                self?.streamingWavWriter?.append(samples)
            },
            onFirstAudio: { sessionID, attemptID, sampleCount, frameLength, sampleRate, acquisitionMs, elapsedMs in
                Task {
                    readinessGate.signalFirstPCM(
                        sessionID: sessionID,
                        attemptID: attemptID
                    )
                }
                DispatchQueue.main.async {
                    LiveTranslationController.shared.markFirstBuffer()
                    let bufferMs = Int((Double(frameLength) / sampleRate * 1000).rounded())
                    DebugLogger.shared.benchmark(
                        "ASR_BENCH",
                        message: "session=\(sessionID) attempt=\(attemptID) " +
                            "first_audio sampleCount=\(sampleCount) frameLength=\(frameLength) " +
                            "sampleRate=\(Int(sampleRate.rounded())) bufferMs=\(bufferMs) " +
                            "acquisitionMs=\(acquisitionMs) elapsedMs=\(elapsedMs)",
                        source: "ASRBenchmark"
                    )
                }
            },
            onLevel: { [weak self] level in
                // Keep Combine sends on the main queue.
                DispatchQueue.main.async { [weak self] in
                    self?.audioLevelSubject.send(level)
                }
            },
            onSpeechEnergy: { [weak self] (hostTime: UInt64, voiced: Bool) in
                DispatchQueue.main.async { [weak self] in
                    guard voiced else { return }
                    self?.lastVoicedUptime = ProcessInfo.processInfo.systemUptime
                    self?.didConsumeSilenceEdgeTick = false
                    LiveTranslationController.shared.markSpeechStart(hostTime: hostTime)
                }
            },
            onCaptureHealth: { [weak self] sessionID, attemptID, audioMs, sampleCount, rms, peak in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard sessionID == self.benchmarkSessionID,
                          self.isRunning,
                          self.isStoppingFinalTranscription == false
                    else { return }
                    let silent = rms < 0.002 && peak < 0.01
                    self.benchmarkLog(
                        "capture_health attempt=\(attemptID) audioMs=\(audioMs) " +
                            "samples=\(sampleCount) rms=\(String(format: "%.6f", rms)) " +
                            "peak=\(String(format: "%.6f", peak)) silent=\(silent) " +
                            "inputUID=\(self.audioStartAttemptInputUID ?? "unknown")"
                    )
                    if self.silentPCMRecoveryWatchdog.shouldRecover(
                        isInternalMicrophone: self.audioStartAttemptIsInternalMicrophone,
                        isDirectCapture: self.activeAudioCaptureBackend == .directCoreAudio,
                        rms: rms,
                        peak: peak
                    ) {
                        self.benchmarkLog(
                            "capture_health_recovery_triggered attempt=\(attemptID) " +
                                "audioMs=\(audioMs) rms=\(String(format: "%.6f", rms)) " +
                                "peak=\(String(format: "%.6f", peak))"
                        )
                        self.scheduleAudioRouteRecovery(reason: "sustained silent PCM")
                    }
                }
            }
        )
    }()

    init() {
        // CRITICAL FIX: Do NOT call any framework-triggering APIs here!
        // This includes:
        // - AVCaptureDevice.authorizationStatus (triggers AVFCapture/CoreAudio)
        // - checkIfModelsExist() (accesses transcriptionProvider, can trigger FluidAudio/CoreML)
        //
        // All such calls are deferred to initialize() which runs 1.5 seconds after
        // SwiftUI's view graph is stable, preventing race conditions with AttributeGraph.
        //
        // Default values are set in the property declarations:
        // - micStatus = .notDetermined
        // - micPermissionGranted = false
        // - modelsExistOnDisk = false
        self.vocabularyChangeObserver = NotificationCenter.default.addObserver(
            forName: .parakeetVocabularyDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleParakeetVocabularyDidChange()
            }
        }
        self.settingsBackupRestoreObserver = NotificationCenter.default.addObserver(
            forName: .settingsBackupDidRestore,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleAudioRouteRecovery(
                    reason: "settings backup restored",
                    requiresIdlePrewarm: true,
                    reconcilesInputSelection: true
                )
            }
        }
        self.clamshellStateChangeObserver = NotificationCenter.default.addObserver(
            forName: .clamshellStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let isClosed = notification.userInfo?["isClosed"] as? Bool ?? ClamshellState.isClosed
            Task { @MainActor [weak self] in
                self?.handleClamshellStateChanged(isClosed: isClosed)
            }
        }
        self.inputDeviceAvailabilityChangeObserver = NotificationCenter.default.addObserver(
            forName: .inputDeviceAvailabilityDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let deviceID = notification.userInfo?["deviceID"] as? AudioObjectID
            Task { @MainActor [weak self] in
                self?.handleInputDeviceAvailabilityChanged(deviceID: deviceID)
            }
        }
    }

    deinit {
        if let observer = self.vocabularyChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = self.engineConfigurationChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = self.settingsBackupRestoreObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = self.clamshellStateChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = self.inputDeviceAvailabilityChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func handleClamshellStateChanged(isClosed: Bool) {
        DebugLogger.shared.info(
            "Clamshell \(isClosed ? "closed" : "opened"); refreshing microphone availability",
            source: "ASRService"
        )
        self.scheduleAudioRouteRecovery(
            reason: isClosed ? "clamshell closed" : "clamshell opened",
            requiresIdlePrewarm: true,
            reconcilesInputSelection: true
        )
    }

    func handleInputDeviceAvailabilityChanged(deviceID: AudioObjectID?) {
        let resolvedInput = AppServices.shared.microphonePreferenceCoordinator.inputDeviceForCapture()
        let preparedDeviceID = self.directAudioLifecycleController.snapshot.deviceID
        let confirmedUID = AppServices.shared.microphonePreferenceCoordinator.confirmedActiveInputUID
        let activeSelectionChanged = self.isRunning && resolvedInput?.uid != confirmedUID
        let preparedSelectionChanged = self.hasPreparedAudioCapture && resolvedInput?.id != preparedDeviceID
        guard activeSelectionChanged || preparedSelectionChanged else { return }

        self.scheduleAudioRouteRecovery(
            reason: "input availability changed:\(deviceID ?? 0)",
            requiresIdlePrewarm: true,
            reconcilesInputSelection: true
        )
    }

    @MainActor
    func handleParakeetVocabularyDidChange() {
        let model = SettingsStore.shared.selectedSpeechModel
        guard model.supportsCustomVocabulary else { return }
        guard self.isRunning == false else {
            self.hasPendingParakeetVocabularyReload = true
            DebugLogger.shared.info(
                "ASRService: Vocabulary changed while recording; queued reload for when recording stops.",
                source: "ASRService"
            )
            return
        }
        self.hasPendingParakeetVocabularyReload = false
        self.resetTranscriptionProvider()
    }

    @MainActor
    func applyPendingParakeetVocabularyReloadIfNeeded() {
        guard self.hasPendingParakeetVocabularyReload else { return }

        self.hasPendingParakeetVocabularyReload = false
        let model = SettingsStore.shared.selectedSpeechModel
        guard model.supportsCustomVocabulary else { return }

        DebugLogger.shared.info(
            "ASRService: Applying queued vocabulary reload after recording stopped.",
            source: "ASRService"
        )
        self.resetTranscriptionProvider()
    }

    func refreshWordBoostStatus() {
        let model = SettingsStore.shared.selectedSpeechModel
        guard model.supportsCustomVocabulary,
              let provider = self.fluidAudioProvider,
              provider.isReady
        else {
            self.wordBoostStatusText = "Word boost: off"
            return
        }

        if provider.isWordBoostingActive {
            let count = provider.boostedVocabularyTermsCount
            if let lastHit = self.lastBoostHitTerm, !lastHit.isEmpty {
                self.wordBoostStatusText = "Word boost: ON (\(count) terms) • last hit: \(lastHit)"
            } else {
                self.wordBoostStatusText = "Word boost: ON (\(count) terms) • no hit yet"
            }
        } else {
            self.wordBoostStatusText = "Word boost: ON (0 terms loaded)"
        }
    }

    func recordWordBoostHitIfAny(transcribedText: String) {
        let model = SettingsStore.shared.selectedSpeechModel
        guard model.supportsCustomVocabulary,
              let provider = self.fluidAudioProvider,
              provider.isWordBoostingActive
        else { return }

        let hits = provider.detectBoostedTerms(in: transcribedText, limit: 1)
        guard let hit = hits.first else { return }
        if hit != self.lastBoostHitTerm {
            self.lastBoostHitTerm = hit
            DebugLogger.shared.info("BOOST_HIT: '\(hit)'", source: "ASRService")
        }
        self.refreshWordBoostStatus()
    }

    /// Call this AFTER the app has finished launching to complete ASR initialization.
    /// This must be called from onAppear or later, never during init.
    func initialize() async {
        await AudioStartupGate.shared.scheduleOpenAfterInitialUISettled()
        await AudioStartupGate.shared.waitUntilOpen()
        guard self.isTerminating == false else { return }

        // Check microphone permission (deferred from init to avoid AVFCapture race condition)
        self.micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        self.micPermissionGranted = (self.micStatus == .authorized)

        let initialInputSnapshot = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let devices = AudioDevice.listInputDevicesRefreshingLiveness()
                let defaultInputUID = AudioDevice.getDefaultInputDevice()?.uid
                continuation.resume(returning: (devices, defaultInputUID))
            }
        }
        guard self.isTerminating == false else { return }

        let microphonePreferenceCoordinator = AppServices.shared.microphonePreferenceCoordinator
        microphonePreferenceCoordinator.reconcileMicrophoneSelection(
            availableInputs: initialInputSnapshot.0,
            defaultInputUID: initialInputSnapshot.1
        )

        self.registerDefaultDeviceChangeListener()
        self.registerEngineConfigurationChangeObserver()
        self.registerDeviceListChangeListener()

        // Initialize device list cache
        self.cacheCurrentDeviceList(initialInputSnapshot.0)
        if microphonePreferenceCoordinator.needsMicrophonePriorityMigration {
            self.scheduleAudioRouteRecovery(
                reason: "app microphone migration pending",
                requiresIdlePrewarm: true,
                reconcilesInputSelection: true
            )
        }

        // Register the input callback and allocate its fixed ring now. This
        // does not start the device or show the microphone privacy indicator.
        await self.prewarmConfiguredAudioCaptureIfPossible(reason: "startup")

        // Check if models exist on disk and auto-load if present
        // This is done in a Task to support async model detection (e.g., AppleSpeechAnalyzerProvider)
        Task { [weak self] in
            guard let self = self else { return }

            // Use async check to accurately detect models (especially for Apple Speech Analyzer)
            await self.checkIfModelsExistAsync()

            // Auto-load models if they exist on disk to avoid "Downloaded but not loaded" state
            if self.modelsExistOnDisk {
                DebugLogger.shared.info("Models found on disk, auto-loading...", source: "ASRService")
                do {
                    try await self.ensureAsrReady()
                    DebugLogger.shared.info("Models auto-loaded successfully on startup", source: "ASRService")
                    await self.prewarmConfiguredAudioCaptureIfPossible(reason: "startup")
                } catch {
                    DebugLogger.shared.error("Failed to auto-load models on startup: \(error)", source: "ASRService")
                }
            }
        }
    }

    /// Check if models exist on disk without loading them (synchronous).
    ///
    /// **Note**: For `AppleSpeechAnalyzerProvider`, this returns a cached value that may be stale.
    /// Use `checkIfModelsExistAsync()` for an up-to-date result.
    func checkIfModelsExist() {
        self.modelExistenceCheckID = UUID()
        self.modelsExistOnDisk = self.transcriptionProvider.modelsExistOnDisk()
        DebugLogger.shared.debug("Models exist on disk: \(self.modelsExistOnDisk)", source: "ASRService")
    }

    /// Check if models exist on disk without loading them (async).
    ///
    /// This method performs an accurate async check for providers that require it
    /// (e.g., `AppleSpeechAnalyzerProvider` uses `SpeechTranscriber.installedLocales`).
    func checkIfModelsExistAsync() async {
        let model = SettingsStore.shared.selectedSpeechModel
        let checkID = UUID()
        self.modelExistenceCheckID = checkID
        let exists: Bool

        // For Apple Speech Analyzer, use the async refresh method
        if model == .appleSpeechAnalyzer {
            if #available(macOS 26.0, *) {
                let provider = self.getAppleSpeechAnalyzerProvider()
                exists = await provider.refreshModelsExistOnDiskAsync()
            } else {
                exists = self.getAppleSpeechProvider().modelsExistOnDisk()
            }
        } else {
            exists = model.isInstalled
        }

        guard
            self.modelExistenceCheckID == checkID,
            SettingsStore.shared.selectedSpeechModel == model
        else {
            return
        }
        self.modelsExistOnDisk = exists
        DebugLogger.shared.debug("Models exist on disk: \(self.modelsExistOnDisk)", source: "ASRService")
    }

    func requestMicAccess() {
        guard self.isRequestingMicrophoneAccess == false else { return }
        self.isRequestingMicrophoneAccess = true
        Task { @MainActor [weak self] in
            await AudioStartupGate.shared.scheduleOpenAfterInitialUISettled()
            await AudioStartupGate.shared.waitUntilOpen()
            guard let self else { return }
            guard self.isTerminating == false else {
                self.isRequestingMicrophoneAccess = false
                return
            }

            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                guard let self else { return }
                Task { @MainActor in
                    self.isRequestingMicrophoneAccess = false
                    self.micPermissionGranted = granted
                    self.micStatus = granted ? .authorized : .denied
                    if granted {
                        await self.prewarmConfiguredAudioCaptureIfPossible(reason: "permission_granted")
                    }
                }
            }
        }
    }

    func startMicrophonePreview() async {
        guard self.micStatus == .authorized,
              self.isRunning == false,
              self.isStarting == false,
              self.isTerminating == false
        else { return }

        self.microphonePreviewOperationGeneration &+= 1
        let operationGeneration = self.microphonePreviewOperationGeneration
        self.isMicrophonePreviewRequested = true

        if self.isMicrophonePreviewActive || self.audioCapturePipeline.isLevelMonitoringEnabled {
            self.audioCapturePipeline.setLevelMonitoringEnabled(false)
            _ = await self.directAudioLifecycleController.stop(
                retainPrepared: false,
                reason: "onboarding_microphone_preview_restart"
            )
            guard operationGeneration == self.microphonePreviewOperationGeneration,
                  self.isMicrophonePreviewRequested,
                  self.isRunning == false,
                  self.isStarting == false,
                  self.isTerminating == false,
                  Task.isCancelled == false
            else {
                self.abandonMicrophonePreviewRequestIfOwned(operationGeneration)
                return
            }
            self.activeAudioCaptureBackend = .none
            self.isMicrophonePreviewActive = false
            self.audioLevelSubject.send(0)
        }

        self.audioEngineStandbyTask?.cancel()
        self.audioEngineStandbyTask = nil
        await self.audioEngineRetirementDrain.waitForScheduledReleases()
        guard operationGeneration == self.microphonePreviewOperationGeneration,
              self.isMicrophonePreviewRequested,
              self.isRunning == false,
              self.isStarting == false,
              self.isTerminating == false,
              Task.isCancelled == false
        else {
            self.abandonMicrophonePreviewRequestIfOwned(operationGeneration)
            return
        }
        self.microphonePreviewError = nil
        self.audioCapturePipeline.setLevelMonitoringEnabled(true)

        do {
            guard let selection = self.directCoreAudioDeviceSelection() else {
                throw NSError(
                    domain: "ASRService",
                    code: -4,
                    userInfo: [NSLocalizedDescriptionKey: "No usable microphone is available."]
                )
            }
            let device = try await self.directAudioLifecycleController.resolveDevice(
                selection: selection,
                reason: "onboarding_microphone_preview"
            )
            try Task.checkCancellation()
            guard operationGeneration == self.microphonePreviewOperationGeneration,
                  self.isRunning == false,
                  self.isStarting == false,
                  self.isTerminating == false
            else { throw CancellationError() }
            _ = try await self.directAudioLifecycleController.start(
                deviceID: device.id,
                deviceName: device.name,
                reason: "onboarding_microphone_preview"
            )
            try Task.checkCancellation()
            guard operationGeneration == self.microphonePreviewOperationGeneration,
                  self.isRunning == false,
                  self.isStarting == false,
                  self.isTerminating == false
            else { throw CancellationError() }
            self.activeAudioCaptureBackend = .directCoreAudio
            self.isMicrophonePreviewActive = true
            DebugLogger.shared.info(
                "Started onboarding microphone preview with '\(device.name)'",
                source: "ASRService"
            )
        } catch {
            // A newer preview, page-exit stop, or dictation start owns cleanup
            // after invalidating this operation. Do not tear down its capture.
            guard operationGeneration == self.microphonePreviewOperationGeneration else {
                return
            }
            self.audioCapturePipeline.setLevelMonitoringEnabled(false)
            await self.directAudioLifecycleController.invalidate(
                reason: "onboarding_microphone_preview_failed"
            )
            self.activeAudioCaptureBackend = .none
            self.isMicrophonePreviewActive = false
            self.isMicrophonePreviewRequested = false
            self.microphonePreviewError = error is CancellationError ? nil : error.localizedDescription
            guard error is CancellationError == false else { return }
            DebugLogger.shared.warning(
                "Onboarding microphone preview failed: \(error.localizedDescription)",
                source: "ASRService"
            )
        }
    }

    func stopMicrophonePreview(retainPreparedCapture: Bool = true) async {
        self.microphonePreviewOperationGeneration &+= 1
        let operationGeneration = self.microphonePreviewOperationGeneration
        self.isMicrophonePreviewRequested = false
        self.microphonePreviewError = nil
        guard self.isMicrophonePreviewActive || self.audioCapturePipeline.isLevelMonitoringEnabled else {
            return
        }

        self.audioCapturePipeline.setLevelMonitoringEnabled(false)
        _ = await self.directAudioLifecycleController.stop(
            retainPrepared: retainPreparedCapture,
            reason: "onboarding_microphone_preview_stop"
        )
        guard operationGeneration == self.microphonePreviewOperationGeneration else { return }
        self.activeAudioCaptureBackend = .none
        self.isMicrophonePreviewActive = false
        self.audioLevelSubject.send(0)
    }

    func abandonMicrophonePreviewRequestIfOwned(_ operationGeneration: UInt64) {
        guard operationGeneration == self.microphonePreviewOperationGeneration else { return }
        self.isMicrophonePreviewRequested = false
        self.audioCapturePipeline.setLevelMonitoringEnabled(false)
        self.activeAudioCaptureBackend = .none
        self.isMicrophonePreviewActive = false
        self.microphonePreviewError = nil
        self.audioLevelSubject.send(0)
    }

    func handOffMicrophonePreviewToCaptureStartIfNeeded() -> Bool {
        guard self.isMicrophonePreviewRequested ||
            self.isMicrophonePreviewActive ||
            self.audioCapturePipeline.isLevelMonitoringEnabled
        else { return false }

        // Invalidate preview ownership without stopping Core Audio. The direct
        // lifecycle serializes any in-flight preview start, and recording can
        // reuse the already-running input without losing opening PCM.
        self.microphonePreviewOperationGeneration &+= 1
        self.isMicrophonePreviewRequested = false
        self.audioCapturePipeline.setLevelMonitoringEnabled(false)
        self.isMicrophonePreviewActive = false
        self.microphonePreviewError = nil
        self.audioLevelSubject.send(0)
        return true
    }

    func stopHandedOffMicrophonePreviewAfterCancelledStart() async {
        self.audioCapturePipeline.setRecordingEnabled(false)
        _ = await self.directAudioLifecycleController.stop(
            retainPrepared: true,
            reason: "cancelled_microphone_preview_handoff"
        )
        self.activeAudioCaptureBackend = .none
        self.audioLevelSubject.send(0)
    }

    func openSystemSettingsForMic() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}

