//
//  ASRService+DevicesAndStreaming.swift
//  fluid
//
//  Device listeners, model cache, streaming ticks, and output formatting.
//

import AVFoundation
import CoreAudio
import Foundation

extension ASRService {
    // MARK: - Device Monitoring (Bluetooth Auto-Switch & Disconnect Handling)

    /// Registers a listener for device list changes (additions/removals)
    /// This enables auto-switching to newly connected devices (especially Bluetooth)
    func registerDeviceListChangeListener() {
        guard self.deviceListListenerInstalled == false else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let token: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Defer to next runloop pass — CoreAudio may hold an internal lock during
            // this callback, and our handler makes synchronous CoreAudio queries that
            // would deadlock waiting for the same lock.
            DispatchQueue.main.async { self?.handleDeviceListChanged() }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            token
        )

        if status == noErr {
            self.deviceListListenerInstalled = true
            self.deviceListListenerToken = token
            DebugLogger.shared.debug("Device list change listener registered", source: "ASRService")
        } else {
            self.deviceListListenerToken = nil
            DebugLogger.shared.error("Failed to register device list listener: \(status)", source: "ASRService")
        }
    }

    /// Monitors a specific device for availability (DeviceIsAlive property)
    /// Used to detect when preferred device disconnects
    func startMonitoringDevice(_ deviceID: AudioObjectID) {
        // Unregister previous device if any
        self.stopMonitoringDevice()

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let token: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.handleDeviceAvailabilityChanged(deviceID: deviceID) }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            deviceID,
            &address,
            DispatchQueue.main,
            token
        )

        if status == noErr {
            self.monitoredDeviceID = deviceID
            self.monitoredDeviceIsAliveListenerToken = token
            DebugLogger.shared.debug("Started monitoring device ID: \(deviceID)", source: "ASRService")
        } else {
            self.monitoredDeviceID = nil
            self.monitoredDeviceIsAliveListenerToken = nil
            DebugLogger.shared.error("Failed to monitor device \(deviceID): \(status)", source: "ASRService")
        }
    }

    /// Stops monitoring the currently monitored device
    func stopMonitoringDevice() {
        guard let deviceID = self.monitoredDeviceID else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        if let token = self.monitoredDeviceIsAliveListenerToken {
            _ = AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, token)
        }
        self.monitoredDeviceID = nil
        self.monitoredDeviceIsAliveListenerToken = nil
        DebugLogger.shared.debug("Stopped monitoring device ID: \(deviceID)", source: "ASRService")
    }

    /// Handles device list changes (new device connected or device removed)
    func handleDeviceListChanged() {
        DebugLogger.shared.info("🔄 Device list changed - checking for new/removed devices", source: "ASRService")

        // Perform CoreAudio queries off the main thread — during a device topology change
        // the HAL may still be settling, and synchronous queries on main can deadlock.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let currentDevices = AudioDevice.listInputDevicesRefreshingLiveness()
            let defaultInputUID = AudioDevice.getDefaultInputDevice()?.uid

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let cachedUIDs = self.cachedDeviceUIDs
                let cachedDeviceIDsByUID = self.cachedInputDeviceIDsByUID
                let cachedLivenessByUID = self.cachedInputLivenessByUID
                let currentUIDs = Set(currentDevices.map(\.uid))
                let currentDeviceIDsByUID = Dictionary(
                    currentDevices.map { ($0.uid, $0.id) },
                    uniquingKeysWith: { current, _ in current }
                )
                let currentLivenessByUID = Dictionary(
                    currentDevices.map { ($0.uid, $0.isAlive) },
                    uniquingKeysWith: { current, _ in current }
                )

                DebugLogger.shared.debug("Current input devices: \(currentDevices.map { $0.name }.joined(separator: ", "))", source: "ASRService")

                if currentUIDs != cachedUIDs ||
                    currentDeviceIDsByUID != cachedDeviceIDsByUID ||
                    currentLivenessByUID != cachedLivenessByUID
                {
                    let microphonePreferenceCoordinator =
                        AppServices.shared.microphonePreferenceCoordinator
                    let migrationPending = microphonePreferenceCoordinator.needsMicrophonePriorityMigration
                    let resolvedInput = microphonePreferenceCoordinator.reconcileMicrophoneSelection(
                        availableInputs: currentDevices,
                        defaultInputUID: defaultInputUID
                    )
                    let priorityUIDs = SettingsStore.shared.microphonePriority.map(\.uid)
                    let livenessRequiresRecovery =
                        (self.isRunning &&
                            resolvedInput?.uid != microphonePreferenceCoordinator.confirmedActiveInputUID) ||
                        (self.hasPreparedAudioCapture &&
                            resolvedInput?.id != self.directAudioLifecycleController.snapshot.deviceID)
                    let shouldReconcileInputSelection = AudioCaptureIdlePolicy.shouldReconcileInputSelection(
                        priorityInputUIDs: priorityUIDs,
                        migrationPending: migrationPending,
                        previousInputUIDs: cachedUIDs,
                        currentInputUIDs: currentUIDs
                    ) || AudioCaptureIdlePolicy.didResolvedPriorityInputIdentityChange(
                        priorityInputUIDs: priorityUIDs,
                        previousInputDeviceIDsByUID: cachedDeviceIDsByUID,
                        currentInputDeviceIDsByUID: currentDeviceIDsByUID
                    ) || livenessRequiresRecovery
                    if shouldReconcileInputSelection {
                        self.scheduleAudioRouteRecovery(
                            reason: "app microphone availability changed",
                            requiresIdlePrewarm: true,
                            reconcilesInputSelection: true
                        )
                    }
                }

                self.cacheCurrentDeviceList(currentDevices)
            }
        }
    }

    /// Handles device availability changes (device disconnected or reconnected)
    func handleDeviceAvailabilityChanged(deviceID: AudioObjectID) {
        DebugLogger.shared.info("⚠️ Device availability changed for ID: \(deviceID)", source: "ASRService")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let isAlive = AudioDevice.refreshInputDeviceLiveness(deviceID: deviceID)
            DispatchQueue.main.async { [weak self] in
                self?.applyDeviceAvailability(isAlive: isAlive, deviceID: deviceID)
            }
        }
    }

    func applyDeviceAvailability(isAlive: Bool, deviceID: AudioObjectID) {
        DebugLogger.shared.debug(
            "Device \(deviceID) cached alive status: \(isAlive)",
            source: "ASRService"
        )
        if isAlive == false {
            // Device disconnected
            DebugLogger.shared.warning("❌ Monitored device (ID: \(deviceID)) DISCONNECTED", source: "ASRService")
            self.stopMonitoringDevice()

            if self.isRunning {
                DebugLogger.shared.info(
                    "Device changed during recording - deferring rebuild until audio route recovery",
                    source: "ASRService"
                )
                self.scheduleAudioRouteRecovery(
                    reason: "monitored input disconnected",
                    reconcilesInputSelection: true
                )
            } else {
                DebugLogger.shared.info("Not recording - device disconnect handled gracefully", source: "ASRService")
            }
        } else {
            DebugLogger.shared.info("✅ Device (ID: \(deviceID)) is still alive", source: "ASRService")
        }
    }

    /// Gets the currently bound input device (if determinable)
    func getCurrentlyBoundInputDevice() -> AudioDevice.Device? {
        let directSnapshot = self.directAudioLifecycleController.snapshot
        if let deviceID = directSnapshot.deviceID {
            return AudioDevice.Device(
                id: deviceID,
                uid: "",
                name: directSnapshot.deviceName ?? "Direct Core Audio input",
                hasInput: true,
                hasOutput: false
            )
        }

        // Check if engine exists before accessing inputNode
        guard self.engineStorage != nil else { return nil }
        guard let audioUnit = self.engine.inputNode.audioUnit else { return nil }

        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            &size
        )

        if status == noErr, deviceID != 0 {
            return AudioDevice.listInputDevices().first { $0.id == deviceID }
        }

        return nil
    }

    func cacheCurrentDeviceList(_ devices: [AudioDevice.Device]) {
        self.cachedDeviceUIDs = Set(devices.map { $0.uid })
        self.cachedInputDeviceIDsByUID = Dictionary(
            devices.map { ($0.uid, $0.id) },
            uniquingKeysWith: { current, _ in current }
        )
        self.cachedInputLivenessByUID = Dictionary(
            devices.map { ($0.uid, $0.isAlive) },
            uniquingKeysWith: { current, _ in current }
        )
    }

    // Audio tap processing is handled by AudioCapturePipeline (thread-safe).

    func ensureAsrReady() async throws {
        try await self.ensureAsrReady(progressHandler: nil)
    }

    func ensureAsrReady(progressHandler: ((Double) -> Void)?) async throws {
        self.cancelIdleMemoryRelease()
        try self.requireStreamingProviderAvailable()
        guard self.modelDownloadTask == nil else {
            throw NSError(
                domain: "ASRService",
                code: -2001,
                userInfo: [NSLocalizedDescriptionKey: "Another model download is already in progress."]
            )
        }
        if let drain = self.providerResetDrain {
            await drain.task.value
            if self.providerResetDrain?.id == drain.id {
                self.providerResetDrain = nil
            }
        }
        let provider = self.transcriptionProvider
        let model = SettingsStore.shared.selectedSpeechModel
        let providerKey = "\(model.id):\(type(of: provider)):\(provider.name)"
        DebugLogger.shared.info(
            "ensureAsrReady() requested for model=\(model.id) [supportsStreaming=\(model.supportsStreaming)] provider=\(providerKey)",
            source: "ASRService"
        )

        // Single-flight for the same model. A reset invalidates the provider key but retains
        // the retiring task so replacements can wait for cache cleanup before starting.
        while let existingTask = self.ensureReadyTask {
            let existingTaskID = self.ensureReadyTaskID
            if self.ensureReadyProviderKey == providerKey,
               self.ensureReadyOperationID == existingTaskID,
               !self.isCancellingModelPreparation
            {
                try await existingTask.value
                return
            }

            self.isCancellingModelPreparation = true
            existingTask.cancel()
            _ = await existingTask.result
            if self.ensureReadyTaskID == existingTaskID {
                self.ensureReadyTask = nil
                self.ensureReadyTaskID = nil
                self.ensureReadyProviderKey = nil
                self.isCancellingModelPreparation = false
            }
        }

        guard SettingsStore.shared.selectedSpeechModel == model else {
            throw CancellationError()
        }

        let operationID = UUID()
        let task = Task { @MainActor in
            try await self.performEnsureAsrReady(
                provider: provider,
                operationID: operationID,
                externalProgressHandler: progressHandler
            )
        }
        self.ensureReadyTask = task
        self.ensureReadyTaskID = operationID
        self.ensureReadyProviderKey = providerKey
        self.ensureReadyOperationID = operationID
        self.isCancellingModelPreparation = false

        defer {
            if ensureReadyTaskID == operationID {
                ensureReadyTask = nil
                ensureReadyTaskID = nil
                ensureReadyProviderKey = nil
                if ensureReadyOperationID == operationID {
                    ensureReadyOperationID = nil
                }
                isCancellingModelPreparation = false
            }
        }

        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func performEnsureAsrReady(
        provider: TranscriptionProvider,
        operationID: UUID,
        externalProgressHandler: ((Double) -> Void)? = nil
    ) async throws {
        guard self.ensureReadyOperationID == operationID else { throw CancellationError() }
        self.isCancellingModelPreparation = false
        DebugLogger.shared.debug(
            "ensureAsrReady(begin): provider=\(provider.name), providerReady=\(provider.isReady), isAsrReady=\(self.isAsrReady), isRunning=\(self.isRunning)",
            source: "ASRService"
        )

        // Check if already ready
        if self.isAsrReady, provider.isReady {
            DebugLogger.shared.debug("ASR already ready with loaded models, skipping initialization", source: "ASRService")
            self.refreshWordBoostStatus()
            return
        }

        // If the flag is set but provider isn't ready (e.g., provider switch without reset), re-init.
        if self.isAsrReady, !provider.isReady {
            DebugLogger.shared.debug("ASR marked ready but provider not ready; re-initializing", source: "ASRService")
        }

        self.isAsrReady = false
        let modelsAlreadyCached = provider.modelsExistOnDisk()

        let totalStartTime = Date()
        do {
            let initializationStart = Date()
            DebugLogger.shared.info("=== ASR INITIALIZATION START ===", source: "ASRService")
            DebugLogger.shared.info("Using provider: \(provider.name) [providerReady=\(provider.isReady)]", source: "ASRService")

            DebugLogger.shared.info("Models already cached on disk: \(modelsAlreadyCached)", source: "ASRService")
            DebugLogger.shared.debug("Model cache lookup complete in \(String(format: "%.3f", Date().timeIntervalSince(totalStartTime)))s", source: "ASRService")

            // Suppress stderr noise during model loading (ALWAYS restore, even on failure).
            let originalStderr = dup(STDERR_FILENO)
            var didRedirectStderr = false
            if originalStderr != -1 {
                let devNull = open("/dev/null", O_WRONLY)
                if devNull != -1 {
                    dup2(devNull, STDERR_FILENO)
                    close(devNull)
                    didRedirectStderr = true
                }
            }

            defer {
                // Only restore if we actually redirected stderr.
                if didRedirectStderr, originalStderr != -1 {
                    dup2(originalStderr, STDERR_FILENO)
                }
                if originalStderr != -1 {
                    close(originalStderr)
                }
            }

            // Set correct loading state based on whether models are cached.
            try Task.checkCancellation()
            guard self.ensureReadyOperationID == operationID else { throw CancellationError() }
            if modelsAlreadyCached {
                self.isLoadingModel = true
                self.isDownloadingModel = false
                self.downloadProgress = nil
                self.modelPreparationPhase = .loading
                DebugLogger.shared.info("📦 LOADING cached model into memory...", source: "ASRService")
            } else {
                self.isDownloadingModel = true
                self.isLoadingModel = false
                self.downloadProgress = nil
                self.modelPreparationPhase = .preparingDownload
                DebugLogger.shared.info("⬇️ DOWNLOADING model...", source: "ASRService")
            }

            // Use the transcription provider to prepare models
            let downloadStartTime = Date()
            DebugLogger.shared.info("Calling transcriptionProvider.prepare()...", source: "ASRService")
            try await self.prepareProviderWithRecovery(
                provider: provider,
                modelsAlreadyCached: modelsAlreadyCached,
                progressHandler: { [weak self] progress in
                    DispatchQueue.main.async {
                        guard
                            let self,
                            self.ensureReadyOperationID == operationID,
                            !self.isCancellingModelPreparation
                        else {
                            return
                        }
                        self.applyModelPreparationProgress(
                            progress,
                            updatesActiveModelState: true,
                            externalProgressHandler: externalProgressHandler
                        )
                    }
                }
            )
            try Task.checkCancellation()
            guard self.ensureReadyOperationID == operationID else { throw CancellationError() }
            let downloadDuration = Date().timeIntervalSince(downloadStartTime)
            DebugLogger.shared.info("✓ Provider preparation completed in \(String(format: "%.1f", downloadDuration)) seconds", source: "ASRService")

            self.isDownloadingModel = false
            // Keep isLoadingModel true until first transcription completes (for large models that need warm-up)
            if !self.hasCompletedFirstTranscription {
                self.isLoadingModel = true
                self.modelPreparationPhase = .loading
                DebugLogger.shared.info("⏳ Model loaded, waiting for first transcription to complete...", source: "ASRService")
            } else {
                self.isLoadingModel = false
                self.modelPreparationPhase = nil
            }
            self.downloadProgress = nil
            self.modelsExistOnDisk = true

            let totalDuration = Date().timeIntervalSince(initializationStart)
            DebugLogger.shared.info("=== ASR INITIALIZATION COMPLETE ===", source: "ASRService")
            DebugLogger.shared.info("Total initialization time: \(String(format: "%.1f", totalDuration)) seconds", source: "ASRService")

            self.isAsrReady = true
            self.isCancellingModelPreparation = false
            self.refreshWordBoostStatus()
        } catch is CancellationError {
            DebugLogger.shared.info("ASR initialization cancelled", source: "ASRService")
            if provider.shouldClearCacheAfterCancellation,
               provider.modelsExistOnDisk() == false
            {
                do {
                    try await provider.clearCache()
                } catch {
                    DebugLogger.shared.warning(
                        "Failed to clear incomplete model cache after cancellation: \(error)",
                        source: "ASRService"
                    )
                }
            }
            if self.ensureReadyOperationID == operationID {
                self.isDownloadingModel = false
                self.isLoadingModel = false
                self.downloadProgress = nil
                self.modelPreparationPhase = nil
                self.modelsExistOnDisk = provider.modelsExistOnDisk()
                self.isCancellingModelPreparation = false
            }
            throw CancellationError()
        } catch {
            if Task.isCancelled || Self.isModelPreparationCancellation(error) {
                if provider.shouldClearCacheAfterCancellation,
                   provider.modelsExistOnDisk() == false
                {
                    try? await provider.clearCache()
                }
                if self.ensureReadyOperationID == operationID {
                    self.isDownloadingModel = false
                    self.isLoadingModel = false
                    self.downloadProgress = nil
                    self.modelPreparationPhase = nil
                    self.modelsExistOnDisk = provider.modelsExistOnDisk()
                    self.isCancellingModelPreparation = false
                }
                throw CancellationError()
            }
            DebugLogger.shared.error("ASR initialization failed with error: \(error)", source: "ASRService")
            DebugLogger.shared.error("Error details: \(error.localizedDescription)", source: "ASRService")
            if self.ensureReadyOperationID == operationID {
                self.isDownloadingModel = false
                self.isLoadingModel = false
                self.downloadProgress = nil
                self.modelPreparationPhase = nil
            }
            throw error
        }
    }

    func applyModelPreparationProgress(
        _ progress: ModelPreparationProgress,
        updatesActiveModelState: Bool,
        externalProgressHandler: ((Double) -> Void)?
    ) {
        switch progress.phase {
        case .preparingDownload:
            self.downloadProgress = nil
            if updatesActiveModelState {
                self.isDownloadingModel = true
                self.isLoadingModel = false
            }
        case .downloading:
            self.downloadProgress = progress.fractionCompleted
            if updatesActiveModelState {
                self.isDownloadingModel = true
                self.isLoadingModel = false
            }
            if let fraction = progress.fractionCompleted {
                externalProgressHandler?(fraction)
            }
        case .optimizing:
            self.downloadProgress = nil
            if updatesActiveModelState {
                self.isDownloadingModel = true
                self.isLoadingModel = false
            }
        case .loading:
            self.downloadProgress = nil
            if updatesActiveModelState {
                self.isDownloadingModel = false
                self.isLoadingModel = true
            }
        }

        self.modelPreparationPhase = progress.phase
    }

    func prepareProviderWithRecovery(
        provider: TranscriptionProvider,
        modelsAlreadyCached: Bool,
        progressHandler: @escaping (ModelPreparationProgress) -> Void
    ) async throws {
        let start = Date()
        var firstError: Error?
        do {
            try await provider.prepare(progressHandler: progressHandler)
            DebugLogger.shared.info(
                "ASRService: Provider '\(provider.name)' prepared successfully in \(String(format: "%.2f", Date().timeIntervalSince(start)))s",
                source: "ASRService"
            )
            return
        } catch {
            if Task.isCancelled || Self.isModelPreparationCancellation(error) {
                throw CancellationError()
            }
            firstError = error
            DebugLogger.shared.error("ASRService: First prepare attempt for \(provider.name) failed after \(String(format: "%.2f", Date().timeIntervalSince(start)))s", source: "ASRService")
            DebugLogger.shared.warning(
                "ASRService: First prepare failed for \(provider.name): \(error). " +
                    "Attempting a single recovery by clearing provider cache.",
                source: "ASRService"
            )
        }

        guard modelsAlreadyCached else {
            DebugLogger.shared.error(
                "ASRService: Provider cache was empty; recovery retry disabled after first failure for \(provider.name).",
                source: "ASRService"
            )
            throw NSError(
                domain: "ASRService",
                code: -2000,
                userInfo: [NSLocalizedDescriptionKey: "Provider preparation failed: \(self.errorSummary(from: firstError))"]
            )
        }

        try Task.checkCancellation()
        do {
            DebugLogger.shared.info("ASRService: Clearing provider cache before retry for \(provider.name)", source: "ASRService")
            try await provider.clearCache()
        } catch {
            DebugLogger.shared.warning(
                "ASRService: Provider cache clear failed for \(provider.name): \(error)",
                source: "ASRService"
            )
        }

        // One strict retry. If this fails, we let the caller handle the error.
        try Task.checkCancellation()
        do {
            try await provider.prepare(progressHandler: progressHandler)
        } catch {
            if Task.isCancelled || Self.isModelPreparationCancellation(error) {
                throw CancellationError()
            }
            throw error
        }
        DebugLogger.shared.info(
            "ASRService: Provider '\(provider.name)' prepared successfully after cache-clear retry",
            source: "ASRService"
        )
    }

    func errorSummary(from error: Error?) -> String {
        if let error { return error.localizedDescription }
        return "Unknown error"
    }

    nonisolated static func isModelPreparationCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    // MARK: - Model lifecycle helpers (parity with original API)

    func predownloadSelectedModel() {
        Task { [weak self] in
            guard let self = self else { return }
            DebugLogger.shared.info("Starting model predownload...", source: "ASRService")
            // ensureAsrReady handles setting the correct loading/downloading state
            do {
                try await self.ensureAsrReady()
                DebugLogger.shared.info("Model predownload completed successfully", source: "ASRService")
            } catch is CancellationError {
                DebugLogger.shared.info("Model predownload cancelled", source: "ASRService")
            } catch {
                DebugLogger.shared.error("Model predownload failed: \(error)", source: "ASRService")
                self.errorTitle = "Download Failed"
                self.errorMessage = error.localizedDescription
                self.showError = true
            }
        }
    }

    func preloadModelAfterSelection() async {
        // ensureAsrReady handles setting the correct loading/downloading state
        do {
            try await self.ensureAsrReady()
        } catch {
            DebugLogger.shared.error("Model preload failed: \(error)", source: "ASRService")
        }
    }

    // MARK: - Cache management

    func clearModelCache() async throws {
        try self.requireStreamingProviderAvailable()
        DebugLogger.shared.debug("Clearing model cache via transcription provider", source: "ASRService")
        self.streamingWorkState.invalidateProvider()
        self.isAsrReady = false
        await self.transcriptionExecutor.cancelAndAwaitPending()
        try await self.transcriptionProvider.clearCache()
        self.modelsExistOnDisk = false
    }

    func clearModelCache(for model: SettingsStore.SpeechModel) async throws {
        try self.requireStreamingProviderAvailable()
        DebugLogger.shared.debug("Clearing model cache for \(model.displayName)", source: "ASRService")
        if SettingsStore.shared.selectedSpeechModel == model {
            self.streamingWorkState.invalidateProvider()
            self.isAsrReady = false
            await self.transcriptionExecutor.cancelAndAwaitPending()
        }
        let provider = self.getProvider(for: model)
        try await provider.clearCache()

        if model.requiresExternalArtifacts {
            SettingsStore.shared.setExternalCoreMLArtifactsDirectory(nil, for: model)
        }

        guard SettingsStore.shared.selectedSpeechModel == model else { return }
        self.resetTranscriptionProvider()
        await self.checkIfModelsExistAsync()
    }

    // MARK: - Timer-based Streaming Transcription (RMS silence gate after first tick)

    func startStreamingTranscription() {
        self.streamingSchedulingSessionID = nil
        _ = self.streamingTaskLifecycle.cancelScheduler()
        guard self.isAsrReady else { return }
        self.didRunStreamingTickThisListen = false
        self.lastVoicedUptime = nil
        self.didConsumeSilenceEdgeTick = false
        self.pendingLatestChunk = false
        self.streamingSchedulingSessionID = self.benchmarkSessionID

        DebugLogger.shared.debug(
            "Starting streaming transcription task (interval: \(self.streamingChunkDurationSeconds)s, minSamples: \(self.minimumStreamingPreviewSamples))",
            source: "ASRService"
        )
        self.scheduleNextStreamingChunk(sessionID: self.benchmarkSessionID, delayNanoseconds: 0)
    }

    func scheduleNextStreamingChunk(sessionID: Int, delayNanoseconds: UInt64) {
        guard self.isRunning,
              self.benchmarkSessionID == sessionID,
              self.streamingSchedulingSessionID == sessionID
        else { return }
        self.streamingTaskLifecycle.schedule(
            sessionID: sessionID,
            delayNanoseconds: delayNanoseconds
        ) { [weak self] operationID in
            await self?.processStreamingChunk(sessionID: sessionID, operationID: operationID)
            self?.benchmarkLog(
                "streaming_active_exit session=\(sessionID) operation=\(operationID.uuidString)"
            )
        } completion: { [weak self] operationID in
            let isLateCompletion = self?.isRunning == false || self?.streamingSchedulingSessionID != sessionID
            if isLateCompletion {
                self?.benchmarkLog(
                    "streaming_active_cleanup_begin session=\(sessionID) operation=\(operationID.uuidString)"
                )
            }
            self?.streamingChunkDidFinish(sessionID: sessionID, operationID: operationID)
            if isLateCompletion {
                self?.benchmarkLog(
                    "streaming_active_cleanup_end session=\(sessionID) operation=\(operationID.uuidString)"
                )
            }
        }
    }

    func streamingChunkDidFinish(sessionID: Int, operationID: UUID) {
        guard self.streamingWorkState.finishOperation(
            sessionID: sessionID,
            operationID: operationID
        ) else { return }
        self.isProcessingChunk = false
        self.finishStreamingDrainRecovery(sessionID: sessionID)
        guard self.isRunning,
              self.benchmarkSessionID == sessionID,
              self.streamingSchedulingSessionID == sessionID
        else { return }

        self.streamingHealthCheckCount += 1
        if self.streamingHealthCheckCount >= 3 {
            let currentBufferCount = self.audioBuffer.count
            if currentBufferCount == self.streamingHealthLastBufferCount,
               currentBufferCount < 16_000
            {
                DebugLogger.shared.warning(
                    "Audio buffer not growing after three streaming intervals (count: \(currentBufferCount)). " +
                        "Audio capture may have failed. Check if engine is running and tap is installed.",
                    source: "ASRService"
                )
            }
            self.streamingHealthLastBufferCount = currentBufferCount
            self.streamingHealthCheckCount = 0
        }

        self.scheduleNextStreamingChunk(
            sessionID: sessionID,
            delayNanoseconds: UInt64(self.streamingChunkDurationSeconds * 1_000_000_000)
        )
    }

    func processStreamingChunk(sessionID: Int, operationID: UUID) async {
        guard self.isRunning,
              self.benchmarkSessionID == sessionID,
              self.streamingSchedulingSessionID == sessionID,
              let providerGeneration = self.streamingWorkState.beginOperation(
                  sessionID: sessionID,
                  operationID: operationID
              )
        else { return }
        self.benchmarkStreamingChunkIndex += 1
        let chunkIndex = self.benchmarkStreamingChunkIndex
        let chunkAgeMs = self.elapsedMilliseconds(since: self.benchmarkRecordingStartedAt)

        // Skip if already processing to prevent queue buildup
        guard !self.isProcessingChunk else {
            DebugLogger.shared.debug("⚠️ Skipping chunk - previous transcription still in progress", source: "ASRService")
            self.benchmarkLog("chunk_skip index=\(chunkIndex) reason=busy ageMs=\(chunkAgeMs)")
            if LiveTranslationController.shared.isSessionActive {
                self.pendingLatestChunk = true
            } else {
                self.skipNextChunk = true
            }
            return
        }

        if self.pendingLatestChunk {
            self.pendingLatestChunk = false
        } else if self.skipNextChunk {
            self.skipNextChunk = false
            if !LiveTranslationController.shared.isSessionActive {
                DebugLogger.shared.debug("⚠️ Skipping chunk for ANE recovery", source: "ASRService")
                self.benchmarkLog("chunk_skip index=\(chunkIndex) reason=recovery ageMs=\(chunkAgeMs)")
                return
            }
        }

        if LiveTranslationSilenceGate.shouldSkipASRTick(
            hadFirstTick: self.didRunStreamingTickThisListen,
            lastVoicedUptime: self.lastVoicedUptime,
            now: ProcessInfo.processInfo.systemUptime,
            consumedSilenceEdgeTick: self.didConsumeSilenceEdgeTick,
            thermal: ProcessInfo.processInfo.thermalState
        ) {
            self.benchmarkLog("chunk_skip index=\(chunkIndex) reason=silence ageMs=\(chunkAgeMs)")
            LiveTranslationController.shared.markSilenceHold()
            return
        }
        if LiveTranslationSilenceGate.isPastHold(
            lastVoicedUptime: self.lastVoicedUptime,
            now: ProcessInfo.processInfo.systemUptime
        ) {
            self.didConsumeSilenceEdgeTick = true
        }

        guard self.isAsrReady, self.transcriptionProvider.isReady else {
            self.benchmarkLog("chunk_skip index=\(chunkIndex) reason=not_ready ageMs=\(chunkAgeMs) isAsrReady=\(self.isAsrReady) providerReady=\(self.transcriptionProvider.isReady)")
            return
        }

        // Thread-safe count check
        let currentSampleCount = self.audioBuffer.count
        // Most ASR models require at least 1 second of 16kHz audio (16,000 samples) to transcribe
        let minSamples = self.minimumStreamingPreviewSamples
        guard currentSampleCount >= minSamples else {
            // Only log once per recording session to avoid spam
            if currentSampleCount > 0, self.lastProcessedSampleCount == 0 {
                DebugLogger.shared.debug(
                    "Waiting for more audio data (\(currentSampleCount)/\(minSamples) samples)",
                    source: "ASRService"
                )
                self.benchmarkLog("chunk_wait index=\(chunkIndex) ageMs=\(chunkAgeMs) samples=\(currentSampleCount) minSamples=\(minSamples)")
            }
            return
        }

        let logicalStart = self.audioBuffer.logicalStart
        #if arch(arm64)
        let incrementalProvider = self.transcriptionProvider as? FluidAudioProvider
        let incrementalDeltaStart = incrementalProvider?.incrementalPreviewDeltaStart(
            totalSampleCount: currentSampleCount
        )
        #else
        let incrementalDeltaStart: Int? = nil
        #endif
        let preview = self.previewChunk(
            logicalSampleCount: currentSampleCount,
            logicalStart: logicalStart,
            incrementalDeltaStart: incrementalDeltaStart
        )
        let chunk = preview.samples
        let usesIncrementalDelta = preview.kind == .incrementalDelta
            || (incrementalDeltaStart == nil
                && self.transcriptionProvider.streamingPreviewMode == .incrementalDelta
                && logicalStart > 0)

        // Validate chunk is not empty (defensive check)
        guard !chunk.isEmpty else {
            DebugLogger.shared.warning("Audio buffer returned empty chunk despite count > 0. Skipping transcription.", source: "ASRService")
            self.benchmarkLog("chunk_skip index=\(chunkIndex) reason=empty ageMs=\(chunkAgeMs)")
            return
        }

        self.isProcessingChunk = true
        self.didRunStreamingTickThisListen = true

        let startTime = Date()
        let startedAt = startTime.timeIntervalSince1970
        let newSamples = max(0, currentSampleCount - self.benchmarkLastChunkSampleCount)
        self.benchmarkLastChunkSampleCount = currentSampleCount
        let audioMilliseconds = Int((Double(currentSampleCount) / 16_000.0 * 1000).rounded())
        self.benchmarkLog(
            "chunk_start index=\(chunkIndex) ageMs=\(chunkAgeMs) samples=\(currentSampleCount) " +
                "inputSamples=\(chunk.count) newSamples=\(newSamples) audioMs=\(audioMilliseconds) " +
                "provider=\(self.transcriptionProvider.name)"
        )

        do {
            DebugLogger.shared.debug("Streaming chunk starting transcription (samples: \(currentSampleCount), input: \(chunk.count)) using \(self.transcriptionProvider.name)", source: "ASRService")
            let result: ASRTranscriptionResult
            let useDelta = usesIncrementalDelta
                || self.transcriptionProvider.streamingPreviewMode == .incrementalDelta
            if useDelta {
                do {
                    result = try await self.transcriptionExecutor.run { [provider = self.transcriptionProvider] in
                        let result = try await provider.transcribeStreamingDelta(
                            chunk,
                            totalSampleCount: currentSampleCount
                        )
                        logStreamingProviderOperationReturn(
                            sessionID: sessionID,
                            operationID: operationID,
                            route: "incremental_delta"
                        )
                        return result
                    }
                } catch {
                    if Task.isCancelled || error is CancellationError {
                        throw CancellationError()
                    }
                    guard self.streamingWorkState.canPublishPreview(
                        sessionID: sessionID,
                        operationID: operationID,
                        providerGeneration: providerGeneration,
                        isRunning: self.isRunning,
                        schedulingSessionID: self.streamingSchedulingSessionID
                    ) else { return }
                    DebugLogger.shared.warning(
                        "Incremental delta preview failed; retrying with the retained window",
                        source: "ASRService"
                    )
                    let retainedWindow = self.audioBuffer.getRetained()
                    result = try await self.transcriptionExecutor.run { [provider = self.transcriptionProvider] in
                        let result = try await provider.transcribeStreaming(retainedWindow)
                        logStreamingProviderOperationReturn(
                            sessionID: sessionID,
                            operationID: operationID,
                            route: "incremental_fallback_window"
                        )
                        return result
                    }
                }
            } else {
                result = try await self.transcriptionExecutor.run { [provider = self.transcriptionProvider] in
                    let result = try await provider.transcribeStreaming(chunk)
                    logStreamingProviderOperationReturn(
                        sessionID: sessionID,
                        operationID: operationID,
                        route: "retained_window"
                    )
                    return result
                }
            }

            let canPublishPreview = self.streamingWorkState.canPublishPreview(
                sessionID: sessionID,
                operationID: operationID,
                providerGeneration: providerGeneration,
                isRunning: self.isRunning,
                schedulingSessionID: self.streamingSchedulingSessionID
            )
            if canPublishPreview == false {
                let scheduledSession = self.streamingSchedulingSessionID.map(String.init) ?? "none"
                self.benchmarkLog(
                    "streaming_executor_return publish=false index=\(chunkIndex) session=\(sessionID) " +
                        "operation=\(operationID.uuidString) running=\(self.isRunning) " +
                        "scheduledSession=\(scheduledSession)"
                )
                return
            }

            let duration = Date().timeIntervalSince(startTime)
            DebugLogger.shared.debug(
                "Streaming chunk transcription finished in \(String(format: "%.2f", duration))s",
                source: "ASRService"
            )
            let rawText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let newText = ASRService.applySpokenPunctuationFormatting(
                ASRService.applyCustomDictionary(ASRService.removeFillerWords(rawText))
            )
            self.recordWordBoostHitIfAny(transcribedText: newText)
            self.benchmarkCompletedStreamingChunks += 1
            self.lastProcessedSampleCount = currentSampleCount

            // Mark first transcription as complete to clear loading state
            if !self.hasCompletedFirstTranscription {
                self.hasCompletedFirstTranscription = true
                self.isLoadingModel = false
                self.modelPreparationPhase = nil
                DebugLogger.shared.info("✅ Model warmed up - first streaming transcription completed", source: "ASRService")
            }

            if !newText.isEmpty {
                if self.transcriptionProvider.streamingPreviewMode == .trailingWindow {
                    self.committedStreamingText = StreamingTranscriptStitcher.stitch(
                        committed: self.committedStreamingText,
                        incoming: newText
                    )
                } else {
                    let updatedText = self.smartDiffUpdate(previous: self.previousFullTranscription, current: newText)
                    self.committedStreamingText = updatedText
                }
                if LiveTranslationController.shared.isSessionActive {
                    self.committedStreamingText = StreamingTranscriptStitcher.boundLiveTranscript(
                        self.committedStreamingText
                    )
                }
                self.partialTranscription = self.committedStreamingText
                self.previousFullTranscription = newText
                DebugLogger.shared.debug("✅ Streaming: '\(self.partialTranscription)' (\(String(format: "%.2f", duration))s)", source: "ASRService")
            }
            if result.endOfUtterance {
                LiveTranslationController.shared.handleEndOfUtterance()
            }
            self.dropRetainedAudioAfterPreview(
                currentSampleCount: currentSampleCount,
                usedIncrementalDelta: useDelta
            )
            let rtf = duration / (Double(currentSampleCount) / 16_000.0)
            let chunkDoneAgeMs = self.elapsedMilliseconds(since: self.benchmarkRecordingStartedAt)
            self.benchmarkLog(
                "chunk_done index=\(chunkIndex) elapsedMs=\(self.elapsedMilliseconds(since: startedAt)) ageMs=\(chunkDoneAgeMs) " +
                    "samples=\(currentSampleCount) inputSamples=\(chunk.count) rawChars=\(rawText.count) cleanedChars=\(newText.count) rtf=\(String(format: "%.3f", rtf))"
            )

            // If transcription takes longer than the interval, skip next to prevent queue buildup
            // This allows slower machines to still work without overwhelming the system
            if duration > self.streamingChunkDurationSeconds {
                DebugLogger.shared.debug(
                    "⚠️ Transcription slow (\(String(format: "%.2f", duration))s > \(self.streamingChunkDurationSeconds)s), skipping next chunk",
                    source: "ASRService"
                )
                self.skipNextChunk = true
            }
        } catch where self.streamingWorkState.canPublishPreview(
            sessionID: sessionID,
            operationID: operationID,
            providerGeneration: providerGeneration,
            isRunning: self.isRunning,
            schedulingSessionID: self.streamingSchedulingSessionID
        ) {
            DebugLogger.shared.error("❌ Streaming failed: \(error)", source: "ASRService")
            self.benchmarkLog("chunk_fail index=\(chunkIndex) elapsedMs=\(self.elapsedMilliseconds(since: startedAt)) samples=\(currentSampleCount) inputSamples=\(chunk.count) error=\(error.localizedDescription)")
            self.skipNextChunk = true
        } catch {
            self.benchmarkLog(
                "chunk_stale_failure index=\(chunkIndex) session=\(sessionID) operation=\(operationID.uuidString)"
            )
        }
    }

    /// Smart diff to prevent text from jumping around
    func smartDiffUpdate(previous: String, current: String) -> String {
        guard !previous.isEmpty else { return current }
        guard !current.isEmpty else { return previous }

        let prevWords = previous.split(separator: " ").map(String.init)
        let currWords = current.split(separator: " ").map(String.init)

        // Find longest common prefix
        var commonPrefixLength = 0
        for i in 0..<min(prevWords.count, currWords.count) {
            if prevWords[i].lowercased().trimmingCharacters(in: .punctuationCharacters) ==
                currWords[i].lowercased().trimmingCharacters(in: .punctuationCharacters)
            {
                commonPrefixLength = i + 1
            } else {
                break
            }
        }

        // If >50% overlap, keep stable prefix and add new words
        if commonPrefixLength > prevWords.count / 2 {
            let stableWords = Array(currWords[0..<min(commonPrefixLength, currWords.count)])
            let newWords = currWords.count > commonPrefixLength ? Array(currWords[commonPrefixLength...]) : []
            return (stableWords + newWords).joined(separator: " ")
        } else {
            return current // Significant change
        }
    }

    func typeTextToActiveField(_ text: String) {
        self.typeTextToActiveField(text, preferredTargetPID: nil, textReadyAt: nil)
    }

    func typeTextToActiveField(_ text: String, preferredTargetPID: pid_t?, textReadyAt: TimeInterval? = nil) {
        self.typeOutputPlanToActiveField(.plain(text), preferredTargetPID: preferredTargetPID, textReadyAt: textReadyAt)
    }

    func typeOutputPlanToActiveField(
        _ plan: DictationLiteralOutputPlan,
        preferredTargetPID: pid_t?,
        textReadyAt: TimeInterval? = nil,
        tracksDictionaryCorrections: Bool = false,
        preferPaste: Bool = false,
        completion: (@MainActor (TypingService.DeliveryOutcome) -> Void)? = nil
    ) {
        let requestedAt = ProcessInfo.processInfo.systemUptime
        let textReadyAge = textReadyAt.map { Int(((requestedAt - $0) * 1000).rounded()) }
        let text = plan.plainText
        DebugLogger.shared.benchmark(
            "TYPING_BENCH",
            message: "asr_type_request chars=\(text.count) preferredPID=\(preferredTargetPID.map { String($0) } ?? "nil") textReadyAgeMs=\(textReadyAge.map { String($0) } ?? "nil")",
            source: "TypingBenchmark"
        )
        self.typingService.typeOutputPlanInstantly(
            plan,
            preferredTargetPID: preferredTargetPID,
            textReadyAt: textReadyAt,
            tracksDictionaryCorrections: tracksDictionaryCorrections,
            preferPaste: preferPaste,
            completion: completion
        )
        let dispatchedAt = ProcessInfo.processInfo.systemUptime
        let textReadyToDispatchMs = textReadyAt.map {
            String(Int(((dispatchedAt - $0) * 1000).rounded()))
        } ?? "nil"
        DebugLogger.shared.benchmark(
            "TYPING_BENCH",
            message: "asr_type_dispatched chars=\(text.count) preferredPID=\(preferredTargetPID.map { String($0) } ?? "nil") textReadyToDispatchMs=\(textReadyToDispatchMs)",
            source: "TypingBenchmark"
        )
    }

    func typeOutputPlanToActiveFieldAndWait(
        _ plan: DictationLiteralOutputPlan,
        preferredTargetPID: pid_t?,
        textReadyAt: TimeInterval? = nil,
        tracksDictionaryCorrections: Bool = false,
        postInsertionKey: SettingsStore.SpokenSendKey? = nil,
        requiredFocusTarget: TypingService.CapturedFocusTarget? = nil
    ) async -> TypingService.DeliveryOutcome {
        let requestedAt = ProcessInfo.processInfo.systemUptime
        let textReadyAge = textReadyAt.map { Int(((requestedAt - $0) * 1000).rounded()) }
        let text = plan.plainText
        DebugLogger.shared.benchmark(
            "TYPING_BENCH",
            message: "asr_type_request chars=\(text.count) preferredPID=\(preferredTargetPID.map { String($0) } ?? "nil") textReadyAgeMs=\(textReadyAge.map { String($0) } ?? "nil")",
            source: "TypingBenchmark"
        )
        let outcome = await withCheckedContinuation { continuation in
            self.typingService.typeOutputPlanInstantly(
                plan,
                preferredTargetPID: preferredTargetPID,
                textReadyAt: textReadyAt,
                tracksDictionaryCorrections: tracksDictionaryCorrections,
                postInsertionKey: postInsertionKey,
                requiredFocusTarget: requiredFocusTarget
            ) { outcome in
                continuation.resume(returning: outcome)
            }
        }
        let dispatchedAt = ProcessInfo.processInfo.systemUptime
        let textReadyToDispatchMs = textReadyAt.map {
            String(Int(((dispatchedAt - $0) * 1000).rounded()))
        } ?? "nil"
        DebugLogger.shared.benchmark(
            "TYPING_BENCH",
            message: "asr_type_dispatched chars=\(text.count) preferredPID=\(preferredTargetPID.map { String($0) } ?? "nil") textReadyToDispatchMs=\(textReadyToDispatchMs)",
            source: "TypingBenchmark"
        )
        return outcome
    }

    /// Removes filler sounds from transcribed text
    static func removeFillerWords(_ text: String) -> String {
        guard SettingsStore.shared.removeFillerWordsEnabled else { return text }

        let fillers = Set(SettingsStore.shared.fillerWords.map { $0.lowercased() })

        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        let filtered = words.filter { word in
            !fillers.contains(word.lowercased().trimmingCharacters(in: .punctuationCharacters))
        }

        return filtered.joined(separator: " ")
    }

    // MARK: - Custom Dictionary (Cached Regex)

    /// Cache for compiled custom dictionary regexes.
    /// Key: trigger word, Value: (compiled regex, escaped replacement template)
    /// Cleared when dictionary entries change.
    static var cachedDictionaryPatterns: [(regex: NSRegularExpression, template: String)] = []
    static var dictionaryCacheNeedsRebuild: Bool = true

    /// Rebuilds the regex cache if dictionary has changed.
    /// Called lazily on first apply after settings change.
    static func rebuildDictionaryCache() {
        let entries = SettingsStore.shared.customDictionaryEntries
        var patterns: [(regex: NSRegularExpression, template: String)] = []

        for entry in entries {
            for trigger in entry.triggers {
                guard !trigger.isEmpty else { continue }

                let consumesHorizontalSeparators = !entry.replacement.isEmpty &&
                    entry.replacement.allSatisfy(\.isWhitespace)
                let escapedTrigger = self.dictionaryPattern(
                    for: trigger,
                    consumesHorizontalSeparators: consumesHorizontalSeparators
                )
                guard let regex = try? NSRegularExpression(
                    pattern: escapedTrigger,
                    options: .caseInsensitive
                ) else { continue }

                patterns.append((regex: regex, template: NSRegularExpression.escapedTemplate(for: entry.replacement)))
            }
        }

        self.cachedDictionaryPatterns = patterns.sorted {
            $0.regex.pattern.utf16.count > $1.regex.pattern.utf16.count
        }
        self.dictionaryCacheNeedsRebuild = false
    }

    static func dictionaryPattern(
        for trigger: String,
        consumesHorizontalSeparators: Bool = false
    ) -> String {
        let escapedTrigger = NSRegularExpression.escapedPattern(for: trigger)
        let prefix = self.startsWithWordCharacter(trigger) ? "\\b" : ""
        let suffix = self.endsWithWordCharacter(trigger) ? "\\b" : ""
        let separator = consumesHorizontalSeparators ? "[ \\t]*" : ""
        return separator + prefix + escapedTrigger + suffix + separator
    }

    static func startsWithWordCharacter(_ text: String) -> Bool {
        guard let scalar = text.unicodeScalars.first else { return false }
        return self.isWordCharacter(scalar)
    }

    static func endsWithWordCharacter(_ text: String) -> Bool {
        guard let scalar = text.unicodeScalars.last else { return false }
        return self.isWordCharacter(scalar)
    }

    static func isWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
    }

    /// Invalidates the dictionary cache. Called when settings change.
    static func invalidateDictionaryCache() {
        self.dictionaryCacheNeedsRebuild = true
    }

    /// Applies custom dictionary replacements to transcribed text.
    /// Replaces trigger words/phrases with their designated replacements.
    /// Uses case-insensitive matching with word boundaries.
    /// Optimized: caches compiled regexes to avoid per-call compilation overhead.
    static func applyCustomDictionary(_ text: String) -> String {
        // Fast path: no entries configured
        let entries = SettingsStore.shared.customDictionaryEntries
        guard !entries.isEmpty else { return text }

        // Rebuild cache if needed (lazy initialization)
        if self.dictionaryCacheNeedsRebuild {
            self.rebuildDictionaryCache()
        }

        guard !self.cachedDictionaryPatterns.isEmpty else {
            return text
        }

        var result = text

        // Apply cached regexes - O(n) where n = number of patterns
        for pattern in self.cachedDictionaryPatterns {
            result = pattern.regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: pattern.template
            )
        }

        return result
    }

    // MARK: - GAAV Mode Formatting

    /// Applies GAAV mode formatting: removes first letter capitalization and trailing period.
    /// This is useful for search queries, form fields, or casual text input.
    ///
    /// Feature requested by maxgaav – thank you for the suggestion!
    static func applyGAAVFormatting(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        var result = text

        if SettingsStore.shared.gaavRemoveTrailingPeriodEnabled, result.hasSuffix(".") {
            result.removeLast()
        }

        if SettingsStore.shared.gaavLowercaseFirstLetterEnabled, let first = result.first, first.isUppercase {
            result = first.lowercased() + result.dropFirst()
        }

        return result
    }

    // MARK: - Continuous Dictation Mode Formatting

    /// Applies split continuous-dictation formatting so transcribed segments chain naturally.
    /// Spacing and context-aware capitalization are independently controlled.
    ///
    /// Implements the chaining behavior requested in GitHub issue #390.
    static func applyContinuousDictationFormatting(_ text: String, precedingText: String) -> String {
        guard !text.isEmpty else { return text }
        let spacingEnabled = SettingsStore.shared.continuousDictationSpacingEnabled
        let smartCapsEnabled = SettingsStore.shared.contextAwareCapitalizationEnabled
        guard spacingEnabled || smartCapsEnabled else { return text }

        var result = text

        if smartCapsEnabled {
            let precedingTrimmed = precedingText.trimmingCharacters(in: .whitespaces)
            let boundaryCharacter = self.lastCapitalizationBoundaryCharacter(in: precedingTrimmed)
            if boundaryCharacter == nil || boundaryCharacter?.isSentenceEndingPunctuation == true {
                result = self.replacingFirstLetter(in: result, transform: { $0.uppercased() })
            } else {
                result = self.replacingFirstLetter(in: result, transform: { $0.lowercased() })
            }
        }

        if spacingEnabled {
            if let lastPreceding = precedingText.last,
               !lastPreceding.isWhitespace,
               result.first?.isWhitespace != true
            {
                result = " " + result
            }

            if result.last?.isWhitespace != true {
                result += " "
            }
        }

        return result
    }

    static func lastCapitalizationBoundaryCharacter(in text: String) -> Character? {
        for character in text.reversed() {
            if character.isNewline {
                return nil
            }
            if character.isHorizontalWhitespace || character.isClosingPunctuationWrapper {
                continue
            }
            return character
        }
        return nil
    }

    static func replacingFirstLetter(in text: String, transform: (Character) -> String) -> String {
        guard let index = text.firstIndex(where: { $0.isLetter }) else { return text }
        let nextIndex = text.index(after: index)
        return String(text[..<index]) + transform(text[index]) + String(text[nextIndex...])
    }
}

extension Character {
    var isSentenceEndingPunctuation: Bool {
        self == "." || self == "!" || self == "?"
    }

    var isHorizontalWhitespace: Bool {
        self.unicodeScalars.allSatisfy { CharacterSet.whitespaces.contains($0) }
    }

    var isClosingPunctuationWrapper: Bool {
        switch self {
        case "\"", "'", "”", "’", "»", "›", ")", "]", "}", "」", "』":
            return true
        default:
            return false
        }
    }
}

// swiftlint:enable type_body_length

extension SettingsStore.SpeechModel {
    var nemotronProviderMode: NemotronProvider.Mode {
        switch self {
        case .nemotronStreaming: return .streaming
        case .nemotronStreaming320: return .streaming320
        default: return .offline
        }
    }
}

extension ASRService {
    /// Cancels only the idle delay. Active provider work is intentionally not
    /// cancelled because incremental providers use cancellation to discard state
    /// needed by the final pass.
    func stopStreamingScheduler(sessionID: Int) {
        let startedAt = Date().timeIntervalSince1970
        if self.streamingSchedulingSessionID == sessionID {
            self.streamingSchedulingSessionID = nil
        }
        let cancelled = self.streamingTaskLifecycle.cancelScheduler()
        self.benchmarkLog(
            "streaming_scheduler_cancel session=\(sessionID) hadIdleTask=\(cancelled) " +
                "elapsedMs=\(self.elapsedMilliseconds(since: startedAt))"
        )
    }

    /// Drains only real in-flight provider work before the shared PCM buffer is
    /// handed off. An idle scheduler never participates in this await.
    func drainActiveStreamingWork(sessionID: Int) async -> Bool {
        let startedAt = Date().timeIntervalSince1970
        guard self.streamingTaskLifecycle.activeTaskToDrain(sessionID: sessionID) != nil else {
            self.benchmarkLog(
                "streaming_timer_stop begin phase=idle session=\(sessionID)"
            )
            self.benchmarkLog(
                "streaming_timer_stop end phase=idle session=\(sessionID) elapsedMs=0 " +
                    "completedChunks=\(self.benchmarkCompletedStreamingChunks)"
            )
            return true
        }
        self.benchmarkLog(
            "streaming_timer_stop begin phase=active session=\(sessionID)"
        )
        // Keep the idle fast path synchronous; only real work gets a deadline.
        let completed = await self.streamingTaskLifecycle.drain(
            sessionID: sessionID,
            timeoutNanoseconds: Self.streamingDrainTimeoutNanoseconds
        )
        self.benchmarkLog(
            "streaming_active_drain_resume session=\(sessionID)"
        )
        self.benchmarkLog(
            "streaming_timer_stop end phase=active session=\(sessionID) completed=\(completed) " +
                "elapsedMs=\(self.elapsedMilliseconds(since: startedAt)) " +
                "completedChunks=\(self.benchmarkCompletedStreamingChunks)"
        )
        return completed
    }

    static var streamingRecoveryMessage: String {
        "Speech recognition took too long to finish. This recording could not be transcribed. " +
            "Wait for the model to recover, or restart \(FluidProduct.displayName) before recording again."
    }

    func presentStreamingRecoveryError() {
        self.errorTitle = "Speech recognition needs recovery"
        self.errorMessage = Self.streamingRecoveryMessage
        self.showError = true
    }

    func requireStreamingProviderAvailable() throws {
        guard self.recordingBufferHandoffGate.isRecovering else { return }
        throw NSError(domain: "ASRService", code: -2002, userInfo: [
            NSLocalizedDescriptionKey: Self.streamingRecoveryMessage,
        ])
    }

    func beginStreamingDrainRecovery(sessionID: Int, token: RecordingBufferHandoffGate.Token) {
        self.timedOutStreamingHandoff = (sessionID, token)
        self.recordingBufferHandoffGate.markTimedOut(token)
        self.presentStreamingRecoveryError()
        // Completion may have won the main-actor turn after the deadline fired.
        if self.streamingTaskLifecycle.activeTaskToDrain(sessionID: sessionID) == nil {
            self.finishStreamingDrainRecovery(sessionID: sessionID)
        }
    }

    func finishStreamingDrainRecovery(sessionID: Int) {
        guard let recovery = self.timedOutStreamingHandoff, recovery.sessionID == sessionID else { return }
        self.timedOutStreamingHandoff = nil
        // The provider has actually returned. Only now may its PCM and state be retired.
        if self.benchmarkSessionID == sessionID {
            self.abortStreamingWavWriter()
            self.audioBuffer.clear()
            self.committedStreamingText.removeAll()
            self.streamingWorkState.endSession(sessionID)
            self.partialTranscription = ""
            self.previousFullTranscription = ""
            self.isProcessingChunk = false
            self.skipNextChunk = false
        }
        self.recordingBufferHandoffGate.complete(recovery.token)
        if self.resetProviderAfterStreamingRecovery {
            self.resetProviderAfterStreamingRecovery = false
            self.resetTranscriptionProvider()
        }
        if self.errorMessage == Self.streamingRecoveryMessage {
            self.errorMessage = "The speech model has recovered. Please record your dictation again."
        }
        self.benchmarkLog("streaming_drain_recovered session=\(sessionID)")
    }
}
