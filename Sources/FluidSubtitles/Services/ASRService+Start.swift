//
//  ASRService+Start.swift
//  fluid
//
//  Microphone start and capture handoff.
//

import AVFoundation
import Combine
import Foundation

extension ASRService {
    /// Starts the speech recognition session.
    @discardableResult
    func start(
        forDictionaryTraining: Bool = false,
        onCaptureStarted: (@MainActor () -> Void)? = nil
    ) async -> AudioCaptureStartOutcome {
        DebugLogger.shared.info("🎤 START() called - beginning recording session", source: "ASRService")

        let watchCaptions = !forDictionaryTraining && self.isWatchCaptionCapture
        if watchCaptions {
            guard ScreenRecordingAccess.isGranted else {
                DebugLogger.shared.error("❌ START() blocked - Screen Recording not authorized", source: "ASRService")
                return .failed
            }
        } else {
            guard self.micStatus == .authorized else {
                DebugLogger.shared.error("❌ START() blocked - mic not authorized", source: "ASRService")
                return .failed
            }
        }
        guard !self.recordingBufferHandoffGate.isRecovering else {
            self.presentStreamingRecoveryError()
            return .failed
        }
        guard self.isRunning == false, self.isStarting == false else {
            DebugLogger.shared.warning("⚠️ START() blocked - already running (started: \(self.isRunning), starting: \(self.isStarting))", source: "ASRService")
            return .alreadyActive
        }
        guard self.isTerminating == false else {
            DebugLogger.shared.warning("START() blocked - app is terminating", source: "ASRService")
            return .failed
        }
        self.audioCaptureStartGeneration &+= 1
        let startGeneration = self.audioCaptureStartGeneration
        self.isStarting = true
        defer { self.finishAudioCaptureStart() }

        // A prior stop may already have disabled capture while its final live-preview
        // operation still owns the shared PCM buffer. Reserve this start immediately,
        // but do not clear or enable the buffer until that bounded handoff completes.
        while self.recordingBufferHandoffGate.isActive {
            await self.recordingBufferHandoffGate.waitUntilAvailable()
            guard !self.recordingBufferHandoffGate.isRecovering else {
                self.presentStreamingRecoveryError()
                return .failed
            }
            guard startGeneration == self.audioCaptureStartGeneration,
                  self.isTerminating == false
            else {
                DebugLogger.shared.debug(
                    "Audio capture start cancelled while waiting for the previous buffer handoff",
                    source: "ASRService"
                )
                return .failed
            }
        }

        // Reserve the start before relinquishing preview ownership so a
        // press-and-hold release can cancel the handoff. Keep the running input
        // alive; startConfiguredAudioCapture reuses it for zero-stop first PCM.
        let handedOffMicrophonePreview = self.handOffMicrophonePreviewToCaptureStartIfNeeded()

        // Reset media pause state for this session
        self.didPauseMediaForThisSession = false
        self.audioEngineStandbyTask?.cancel()
        self.audioEngineStandbyTask = nil
        await self.waitForPendingAudioRouteRecoveryBeforeStart()
        guard startGeneration == self.audioCaptureStartGeneration,
              self.isTerminating == false
        else {
            if handedOffMicrophonePreview {
                await self.stopHandedOffMicrophonePreviewAfterCancelledStart()
            }
            DebugLogger.shared.debug(
                "Audio capture start cancelled during route handoff generation=\(startGeneration)",
                source: "ASRService"
            )
            return .failed
        }

        DebugLogger.shared.debug("🧹 Clearing buffers and state", source: "ASRService")
        self.finalText.removeAll()
        self.abortStreamingWavWriter()
        self.audioBuffer.clear(keepingCapacity: true) // specific optimization for restart
        self.partialTranscription.removeAll()
        self.previousFullTranscription.removeAll()
        self.committedStreamingText.removeAll()
        self.cancelIdleMemoryRelease()
        self.lastBoostHitTerm = nil
        self.lastProcessedSampleCount = 0
        self.isProcessingChunk = false
        self.skipNextChunk = false
        self.benchmarkSessionID += 1
        self.streamingWorkState.beginSession(self.benchmarkSessionID)
        self.streamingHealthCheckCount = 0
        self.streamingHealthLastBufferCount = 0
        self.silentPCMRecoveryWatchdog = AudioCaptureIdlePolicy.SilentPCMRecoveryWatchdog()
        let captureSessionID = self.benchmarkSessionID
        self.audioCaptureAttemptID &+= 1
        var readinessAttemptID = self.audioCaptureAttemptID
        self.audioCaptureReadinessGate.arm(
            sessionID: captureSessionID,
            attemptID: readinessAttemptID
        )
        self.benchmarkRecordingStartedAt = Date().timeIntervalSince1970
        self.benchmarkStreamingChunkIndex = 0
        self.benchmarkCompletedStreamingChunks = 0
        self.benchmarkLastChunkSampleCount = 0
        (self.transcriptionProvider as? FluidAudioProvider)?.resetStreamingPreviewCache()
        if !forDictionaryTraining {
            self.beginStreamingWavWriterIfNeeded()
        }
        self.audioCapturePipeline.setRecordingEnabled(
            true,
            sessionID: captureSessionID,
            attemptID: readinessAttemptID,
            startHostTime: mach_absolute_time()
        )
        self.refreshWordBoostStatus()
        let dims = self.currentSpeechModelDimensions()
        self.benchmarkLog("recording_start model=\(dims.model) provider=\(dims.provider) supportsStreaming=\(SettingsStore.shared.selectedSpeechModel.supportsStreaming)")
        DebugLogger.shared.debug("✅ Buffers cleared", source: "ASRService")

        self.isDictionaryTrainingCaptureActive = false
        if watchCaptions {
            return await self.startWatchAudioCapture(
                captureSessionID: captureSessionID,
                readinessAttemptID: readinessAttemptID,
                startGeneration: startGeneration,
                onCaptureStarted: onCaptureStarted
            )
        }

        do {
            let maximumStartAttempts =
                SettingsStore.shared.experimentalDirectAudioCaptureEnabled
                    ? max(AudioDevice.listInputDevices().count, 1) + 1
                    : 1
            var startAttempt = 1
            var fallbackAttempt = 1
            var failedInputUIDs = Set<String>()
            var immediatelyRetriedInputUID: String?
            var bluetoothStabilization = AudioCaptureIdlePolicy.BluetoothInputStabilization()
            var forcedInputUID: String?
            self.audioStartAttemptInputUID = nil
            while true {
                let routeGenerationAtStart = self.audioRouteRecoveryGeneration
                do {
                    try await self.startConfiguredAudioCapture(
                        excluding: failedInputUIDs,
                        forcingInputUID: forcedInputUID
                    )
                } catch {
                    guard let failedUID = self.audioStartAttemptInputUID else { throw error }
                    let now = ProcessInfo.processInfo.systemUptime
                    let retryBluetoothInput = bluetoothStabilization.shouldRetry(
                        inputUID: failedUID,
                        isBluetoothInput: self.audioStartAttemptIsBluetooth,
                        now: now
                    )
                    let retrySameInput = retryBluetoothInput || immediatelyRetriedInputUID == nil
                    if retryBluetoothInput {
                        forcedInputUID = failedUID
                        immediatelyRetriedInputUID = failedUID
                        self.logBluetoothStartupRetry(
                            uid: failedUID,
                            attempt: startAttempt + 1,
                            elapsed: bluetoothStabilization.elapsed(at: now),
                            reason: error.localizedDescription
                        )
                    } else {
                        forcedInputUID = nil
                        if bluetoothStabilization.inputUID == failedUID {
                            self.logBluetoothStartupStabilizationEnded(
                                uid: failedUID,
                                elapsed: bluetoothStabilization.elapsed(at: now),
                                outcome: "budget_exhausted"
                            )
                        }
                        if immediatelyRetriedInputUID == nil {
                            immediatelyRetriedInputUID = failedUID
                        } else {
                            failedInputUIDs.insert(failedUID)
                        }
                        fallbackAttempt += 1
                    }
                    guard retryBluetoothInput || fallbackAttempt <= maximumStartAttempts,
                          startGeneration == self.audioCaptureStartGeneration,
                          self.isTerminating == false
                    else {
                        throw error
                    }
                    readinessAttemptID = try await self.prepareAudioCaptureStartRetry(
                        sessionID: captureSessionID,
                        startGeneration: startGeneration,
                        completedAttempt: startAttempt,
                        reason: "backend_start_error:\(error.localizedDescription)",
                        waitForTopologyQuiet: retryBluetoothInput || retrySameInput == false
                    )
                    startAttempt += 1
                    continue
                }
                self.benchmarkLog(
                    "first_pcm_wait_begin attempt=\(startAttempt) " +
                        "attemptID=\(readinessAttemptID) " +
                        "timeoutMs=\(self.firstPCMTimeoutNanoseconds / 1_000_000) " +
                        "routeGeneration=\(routeGenerationAtStart) " +
                        "captureGeneration=\(self.directAudioLifecycleController.snapshot.generation)"
                )
                let readiness = await self.audioCaptureReadinessGate.wait(
                    sessionID: captureSessionID,
                    attemptID: readinessAttemptID,
                    timeoutNanoseconds: self.firstPCMTimeoutNanoseconds
                )
                guard startGeneration == self.audioCaptureStartGeneration,
                      self.isTerminating == false
                else {
                    throw CancellationError()
                }
                let routeStayedStable =
                    routeGenerationAtStart == self.audioRouteRecoveryGeneration &&
                    self.pendingAudioRouteRecovery == nil &&
                    self.isRecoveringAudioRoute == false
                if readiness == .ready, routeStayedStable {
                    if let stabilizedUID = bluetoothStabilization.inputUID {
                        self.logBluetoothStartupStabilizationEnded(
                            uid: stabilizedUID,
                            elapsed: bluetoothStabilization.elapsed(
                                at: ProcessInfo.processInfo.systemUptime
                            ),
                            outcome: "first_pcm"
                        )
                    }
                    AppServices.shared.microphonePreferenceCoordinator.confirmActiveSelection(
                        uid: self.audioStartAttemptInputUID,
                        name: self.audioStartAttemptInputName
                    )
                    self.benchmarkLog(
                        "first_pcm_wait_end result=ready attempt=\(startAttempt) " +
                            "attemptID=\(readinessAttemptID) " +
                            "bufferedSamples=\(self.audioBuffer.count)"
                    )
                    break
                }

                self.benchmarkLog(
                    "first_pcm_wait_end result=\(readiness) attempt=\(startAttempt) " +
                        "attemptID=\(readinessAttemptID) " +
                        "routeStable=\(routeStayedStable)"
                )
                if readiness == .cancelled {
                    throw CancellationError()
                }
                var retrySameInput = false
                var retryBluetoothInput = false
                if let failedUID = self.audioStartAttemptInputUID {
                    let now = ProcessInfo.processInfo.systemUptime
                    retryBluetoothInput = bluetoothStabilization.shouldRetry(
                        inputUID: failedUID,
                        isBluetoothInput: self.audioStartAttemptIsBluetooth,
                        now: now
                    )
                    retrySameInput = retryBluetoothInput || (
                        readiness == .formatInvalidated && immediatelyRetriedInputUID == nil
                    )
                    if retryBluetoothInput {
                        forcedInputUID = failedUID
                        immediatelyRetriedInputUID = failedUID
                        self.logBluetoothStartupRetry(
                            uid: failedUID,
                            attempt: startAttempt + 1,
                            elapsed: bluetoothStabilization.elapsed(at: now),
                            reason: "readiness_\(readiness)"
                        )
                    } else {
                        forcedInputUID = nil
                        if bluetoothStabilization.inputUID == failedUID {
                            self.logBluetoothStartupStabilizationEnded(
                                uid: failedUID,
                                elapsed: bluetoothStabilization.elapsed(at: now),
                                outcome: "budget_exhausted"
                            )
                        }
                        if retrySameInput {
                            immediatelyRetriedInputUID = failedUID
                        } else {
                            failedInputUIDs.insert(failedUID)
                            fallbackAttempt += 1
                        }
                    }
                }
                guard retryBluetoothInput || fallbackAttempt <= maximumStartAttempts else {
                    let message: String
                    switch readiness {
                    case .timedOut:
                        message = "The selected microphone started but did not deliver audio."
                    case .formatInvalidated:
                        message = "The microphone format did not stabilize after reconnecting."
                    case .staleSession:
                        message = "Audio capture was replaced before the microphone became ready."
                    case .cancelled:
                        message = "Audio capture was cancelled."
                    case .ready:
                        message = "The microphone route changed before capture became stable."
                    }
                    throw NSError(
                        domain: "ASRService",
                        code: -2,
                        userInfo: [NSLocalizedDescriptionKey: message]
                    )
                }

                readinessAttemptID = try await self.prepareAudioCaptureStartRetry(
                    sessionID: captureSessionID,
                    startGeneration: startGeneration,
                    completedAttempt: startAttempt,
                    reason: "readiness_\(readiness)_routeStable_\(routeStayedStable)",
                    waitForTopologyQuiet: retryBluetoothInput || retrySameInput == false
                )
                startAttempt += 1
            }
            self.isDictionaryTrainingCaptureActive = forDictionaryTraining
            self.isRunning = true
            DebugLogger.shared.info(
                "✅ Audio capture running after first PCM (session=\(captureSessionID))",
                source: "ASRService"
            )
            onCaptureStarted?()

            // Pause only after capture is live so media control cannot delay the
            // first PCM packet. A quick stop while this await is in flight is
            // handled explicitly below.
            if SettingsStore.shared.pauseMediaDuringTranscription {
                let didPause = await MediaPlaybackService.shared.pauseIfPlaying()
                guard self.isRunning, self.isStoppingFinalTranscription == false else {
                    if didPause {
                        await MediaPlaybackService.shared.resumeIfWePaused(true)
                    }
                    return .started
                }
                self.didPauseMediaForThisSession = didPause
                if didPause {
                    DebugLogger.shared.info("🎵 Paused system media for transcription", source: "ASRService")
                }
            }

            // Direct capture already owns a required device-liveness listener
            // on its off-main lifecycle queue.
            if self.activeAudioCaptureBackend == .audioEngine,
               let currentDevice = getCurrentlyBoundInputDevice()
            {
                DebugLogger.shared.debug("👀 Starting device monitoring for: \(currentDevice.name)", source: "ASRService")
                self.startMonitoringDevice(currentDevice.id)
            } else if self.activeAudioCaptureBackend == .audioEngine {
                DebugLogger.shared.debug("ℹ️ No device to monitor", source: "ASRService")
            }

            // Only start streaming for models that support it (large Whisper models are too slow)
            let model = self.effectiveSpeechModel
            if model.supportsStreaming, !forDictionaryTraining {
                DebugLogger.shared.debug("📡 Starting streaming transcription...", source: "ASRService")
                self.benchmarkLog("streaming_timer_start intervalMs=\(Int((self.streamingChunkDurationSeconds * 1000).rounded())) minSamples=\(self.minimumStreamingPreviewSamples)")
                self.startStreamingTranscription()
            } else if forDictionaryTraining {
                DebugLogger.shared.debug("⏸️ Skipping streaming for dictionary training sample", source: "ASRService")
            } else {
                DebugLogger.shared.debug("⏸️ Skipping streaming - model '\(model.displayName)' does not support real-time chunk processing", source: "ASRService")
            }
            DebugLogger.shared.info("✅ START() completed successfully", source: "ASRService")
            return .started
        } catch {
            await self.audioCaptureReadinessGate.cancel(
                sessionID: captureSessionID,
                attemptID: readinessAttemptID
            )
            self.isDictionaryTrainingCaptureActive = false
            self.audioCapturePipeline.setRecordingEnabled(false)
            self.isRunning = false
            await self.stopActiveAudioCapture(
                retainDirectPreparedCapture: false,
                reason: "start_failed"
            )
            await self.retireAudioEngineAndWait(reason: "start_failed")
            let wasCancelled =
                error is CancellationError ||
                startGeneration != self.audioCaptureStartGeneration ||
                self.isTerminating
            if wasCancelled {
                DebugLogger.shared.info(
                    "Audio capture start cancelled generation=\(startGeneration)",
                    source: "ASRService"
                )
            } else {
                DebugLogger.shared.error("Failed to start ASR session: \(error)", source: "ASRService")
            }

            // Resume media if we paused it before the failure
            if self.didPauseMediaForThisSession {
                await MediaPlaybackService.shared.resumeIfWePaused(true)
                self.didPauseMediaForThisSession = false
                DebugLogger.shared.info("🎵 Resumed system media after start failure", source: "ASRService")
            }

            guard wasCancelled == false else { return .failed }
            AppServices.shared.microphonePreferenceCoordinator.markActiveSelectionUnavailable()

            // Provide user-friendly error feedback
            let nsError = error as NSError
            let noUsableMicrophone = nsError.domain == "ASRService" && nsError.code == -4
            let errorMessage: String
            if nsError.domain == "ASRService" {
                if noUsableMicrophone {
                    errorMessage = "No usable microphone is available. Open your MacBook or connect a microphone, then try again."
                } else if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                    // Extract useful info from AVFoundation error
                    if underlyingError.domain == AVFoundationErrorDomain || underlyingError.domain == NSOSStatusErrorDomain {
                        errorMessage = "Failed to start audio recording. The audio device may be in use by another application or unavailable. Please check your audio settings and try again."
                    } else {
                        errorMessage = "Failed to start audio recording: \(underlyingError.localizedDescription)"
                    }
                } else {
                    errorMessage = "Failed to start audio recording after multiple attempts. Please check your audio device and try again."
                }
            } else {
                errorMessage = "Failed to start audio recording: \(error.localizedDescription)"
            }

            self.errorTitle = noUsableMicrophone ? "Microphone Unavailable" : "Recording Error"
            self.errorMessage = errorMessage
            self.showError = true

            // Post notification for UI to display
            NotificationCenter.default.post(
                name: NSNotification.Name("ASRServiceStartFailed"),
                object: nil,
                userInfo: ["errorMessage": errorMessage]
            )
            return .failed
        }
    }

    func waitForPendingStart() async {
        guard self.isStarting else { return }
        await withCheckedContinuation { continuation in
            if self.isStarting {
                self.audioCaptureStartWaiters.append(continuation)
            } else {
                continuation.resume()
            }
        }
    }

    func prepareAudioCaptureStartRetry(
        sessionID: Int,
        startGeneration: UInt64,
        completedAttempt: Int,
        reason: String,
        waitForTopologyQuiet: Bool = true
    ) async throws -> UInt64 {
        self.audioCapturePipeline.setRecordingEnabled(false)
        await self.directAudioLifecycleController.invalidate(
            reason: "start_retry_attempt_\(completedAttempt):\(reason)"
        )
        // Invalidation retires the packet gate and drains accepted packets, so
        // this clear cannot be followed by late PCM from the failed attempt.
        self.audioBuffer.clear(keepingCapacity: true)
        let routeRecoveryWasPending = self.audioRouteRecoveryTask != nil
        await self.waitForPendingAudioRouteRecoveryBeforeStart()
        guard startGeneration == self.audioCaptureStartGeneration,
              self.isTerminating == false
        else {
            throw CancellationError()
        }
        if routeRecoveryWasPending == false, waitForTopologyQuiet {
            try await Task.sleep(nanoseconds: self.audioRouteRecoveryDelayNanoseconds)
        }
        guard startGeneration == self.audioCaptureStartGeneration,
              self.isTerminating == false
        else {
            throw CancellationError()
        }

        self.audioCaptureAttemptID &+= 1
        let attemptID = self.audioCaptureAttemptID
        self.audioCaptureReadinessGate.arm(
            sessionID: sessionID,
            attemptID: attemptID
        )
        self.audioCapturePipeline.setRecordingEnabled(
            true,
            sessionID: sessionID,
            attemptID: attemptID,
            startHostTime: mach_absolute_time()
        )
        DebugLogger.shared.info(
            "Retrying direct audio startup in the same session after \(reason) " +
                "(nextAttempt=\(completedAttempt + 1))",
            source: "ASRService"
        )
        return attemptID
    }

    func logBluetoothStartupRetry(
        uid: String,
        attempt: Int,
        elapsed: TimeInterval,
        reason: String
    ) {
        let elapsedMilliseconds = Int((elapsed * 1000).rounded())
        let admissionWindowMilliseconds = Int(
            (AudioCaptureIdlePolicy.BluetoothInputStabilization.retryAdmissionWindow * 1000).rounded()
        )
        self.benchmarkLog(
            "bluetooth_start_retry uid=\(uid) attempt=\(attempt) " +
                "elapsedMs=\(elapsedMilliseconds) " +
                "admissionWindowMs=\(admissionWindowMilliseconds) reason=\(reason)"
        )
    }

    func logBluetoothStartupStabilizationEnded(
        uid: String,
        elapsed: TimeInterval,
        outcome: String
    ) {
        self.benchmarkLog(
            "bluetooth_start_stabilization_end uid=\(uid) outcome=\(outcome) " +
                "elapsedMs=\(Int((elapsed * 1000).rounded()))"
        )
    }

    func cancelPendingAudioCaptureStart(reason: String) async {
        guard self.isStarting, self.isRunning == false else { return }
        self.audioCaptureStartGeneration &+= 1
        // A start waiting for the previous session's PCM handoff must wake to
        // observe the generation change; the old stop keeps ownership of the gate.
        self.recordingBufferHandoffGate.releasePendingWaiters()
        let cancelledSessionID = self.benchmarkSessionID
        self.benchmarkLog(
            "capture_start_cancel reason=\(reason) session=\(cancelledSessionID) " +
                "generation=\(self.audioCaptureStartGeneration)"
        )
        await self.audioCaptureReadinessGate.cancel(
            sessionID: cancelledSessionID,
            attemptID: self.audioCaptureAttemptID
        )
        await self.waitForPendingStart()
    }

    func finishAudioCaptureStart() {
        self.isStarting = false
        let deferredRecovery = self.deferredBluetoothStartupRouteRecovery.take()
        self.audioCaptureStateDidSettle.send()
        let waiters = self.audioCaptureStartWaiters
        self.audioCaptureStartWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }

        if let deferredRecovery {
            Task { @MainActor [weak self] in
                await self?.processDeferredBluetoothStartupRouteRecovery(deferredRecovery)
            }
        }
    }

    func processDeferredBluetoothStartupRouteRecovery(
        _ request: AudioCaptureIdlePolicy.DeferredBluetoothRouteRecovery.Request
    ) async {
        do {
            try await Task.sleep(nanoseconds: self.audioRouteRecoveryDelayNanoseconds)
        } catch {
            return
        }
        guard self.isTerminating == false else { return }

        let snapshot = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let devices = AudioDevice.listInputDevicesRefreshingLiveness()
                let defaultInputUID = AudioDevice.getDefaultInputDevice()?.uid
                continuation.resume(returning: (devices, defaultInputUID))
            }
        }
        guard self.isTerminating == false else { return }
        if self.isStarting {
            self.deferredBluetoothStartupRouteRecovery.preserve(
                reason: request.reason,
                requiresIdlePrewarm: request.requiresIdlePrewarm,
                reconcilesInputSelection: request.reconcilesInputSelection
            )
            return
        }

        let microphonePreferenceCoordinator = AppServices.shared.microphonePreferenceCoordinator
        let resolvedInput: AudioDevice.Device?
        if request.reconcilesInputSelection {
            resolvedInput = microphonePreferenceCoordinator.reconcileMicrophoneSelection(
                availableInputs: snapshot.0,
                defaultInputUID: snapshot.1
            )
        } else {
            resolvedInput = microphonePreferenceCoordinator.inputDeviceForCapture(
                availableInputs: snapshot.0,
                defaultInputUID: snapshot.1
            )
        }
        self.cacheCurrentDeviceList(snapshot.0)

        let activeSnapshot = self.directAudioLifecycleController.snapshot
        let shouldRecover = AudioCaptureIdlePolicy.shouldRecoverAfterDeferredBluetoothReconciliation(
            isRunning: self.isRunning,
            confirmedInputUID: microphonePreferenceCoordinator.confirmedActiveInputUID,
            activeDeviceID: activeSnapshot.deviceID,
            resolvedInputUID: resolvedInput?.uid,
            resolvedDeviceID: resolvedInput?.id,
            hasPreparedCapture: self.hasPreparedAudioCapture,
            requiresIdlePrewarm: request.requiresIdlePrewarm
        )
        guard shouldRecover else {
            self.benchmarkLog(
                "bluetooth_deferred_reconciliation_noop event=\(request.reason) " +
                    "resolvedUID=\(resolvedInput?.uid ?? "none")"
            )
            return
        }

        self.scheduleAudioRouteRecovery(
            reason: "deferred after Bluetooth startup: \(request.reason)",
            requiresIdlePrewarm: request.requiresIdlePrewarm,
            reconcilesInputSelection: false
        )
    }

    /// Stops the recording session and returns the transcribed text.
    ///
    /// This method performs the complete transcription process:
    /// 1. Stops audio capture and processing
    /// 2. Ensures ASR models are ready
    /// 3. Transcribes all recorded audio
    /// 4. Returns the final transcribed text
    ///
    /// ## Process
    /// - Stops the audio engine and removes processing tap
    /// - Validates that ASR models are available and ready
    /// - Processes all recorded audio through the ASR pipeline
    /// - Returns the transcribed text for use by the caller
    ///
    /// ## Returns
    /// The transcribed text from the entire recording session, or an empty string if transcription fails.
    ///
    /// ## Note
    /// This method does not update `finalText` property to avoid UI conflicts.
    /// Callers should handle the returned text as needed.
    ///
    /// ## Errors
    /// Returns empty string if:
    /// - No recording was in progress
    /// - ASR models are not available
    /// - Transcription process fails
    /// Check debug logs for detailed error information.
    /// Re-decode the retained window for Theater. Streaming deltas are a preview;
    /// presentation captions should wait for this fuller pass.
    func confirmStreamingTranscript() async -> String {
        let fallback = self.partialTranscription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard self.isRunning else { return fallback }
        let retained = self.audioBuffer.getRetained()
        guard retained.count >= 16_000 else { return fallback }

        do {
            let provider = self.transcriptionProvider
            let result = try await self.transcriptionExecutor.run { [provider] in
                try await provider.transcribeStreaming(retained)
            }
            let newText = ASRService.applySpokenPunctuationFormatting(
                ASRService.applyCustomDictionary(ASRService.removeFillerWords(result.text))
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newText.isEmpty else { return fallback }

            if provider.streamingPreviewMode == .trailingWindow {
                return StreamingTranscriptStitcher.stitch(
                    committed: self.committedStreamingText.isEmpty ? fallback : self.committedStreamingText,
                    incoming: newText
                ).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return newText
        } catch {
            DebugLogger.shared.debug(
                "Theater confirmation transcription skipped: \(error.localizedDescription)",
                source: "ASRService"
            )
            return fallback
        }
    }

    /// - Parameter onCaptureStopped: Optional callback fired on the main actor
    ///   after the audio engine has stopped but before the (potentially slow)
    ///   final transcription pass. Use this for immediate stop cues that
    ///   shouldn't wait on finalization. Only invoked when capture was actually
    ///   running (i.e. not when `stop()` early-returns because `isRunning` is false).
    /// - Parameter onFinalTranscriptionStarted: Optional main-actor callback
    ///   shown only when final transcription outlives the short status delay.
}
