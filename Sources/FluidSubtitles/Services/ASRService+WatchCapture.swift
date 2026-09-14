import Foundation

extension ASRService {
    var isWatchCaptionCapture: Bool {
        !self.isDictionaryTrainingCaptureActive
            && LiveTranslationController.shared.listenKind == .captions
            && SettingsStore.shared.theaterSessionMode == .watch
    }

    func setCapturePaused(_ paused: Bool) {
        self.audioCapturePipeline.setCapturePaused(paused)
        if paused == false {
            self.systemAudioCapture.resetClock()
        }
    }

    func startWatchAudioCapture(
        captureSessionID: Int,
        readinessAttemptID: UInt64,
        startGeneration: UInt64,
        onCaptureStarted: (@MainActor () -> Void)?
    ) async -> AudioCaptureStartOutcome {
        let pipeline = self.audioCapturePipeline
        let gate = WatchFeedbackSession()
        let aggressive = WatchOutputRoute.looksLikeLoopbackOrAggregate()
        let handler: SystemAudioCapture.PacketHandler = { samples, frameCount, sampleRate, hostTime, sampleTime in
            guard gate.admit(
                samples,
                count: frameCount,
                sampleRate: sampleRate,
                aggressive: aggressive
            ) else { return }
            pipeline.handle(
                samples: samples,
                frameCount: frameCount,
                sampleRate: sampleRate,
                inputHostTime: hostTime,
                inputSampleTime: sampleTime
            )
        }

        var source = SettingsStore.shared.theaterCaptureSource
        if source == .lecternMicrophone {
            source = .watchThisMac
        }
        do {
            try await self.systemAudioCapture.start(
                source: source,
                appBundleID: SettingsStore.shared.theaterWatchAppBundleID,
                packetHandler: handler,
                onStopped: { message in
                    Task { @MainActor in
                        LiveTranslationController.shared.handleWatchCaptureStopped(message)
                    }
                }
            )
        } catch {
            DebugLogger.shared.error(
                "Watch capture failed to start: \(error.localizedDescription)",
                source: "ASRService"
            )
            await MainActor.run {
                LiveTranslationController.shared.reportListenFailure(
                    ScreenRecordingAccess.message(forStartError: error)
                )
            }
            self.audioCapturePipeline.setRecordingEnabled(false)
            return .failed
        }

        self.activeAudioCaptureBackend = .systemAudio
        if aggressive {
            await MainActor.run {
                LiveTranslationController.shared.reportListenStatus(
                    WatchOutputRoute.warningCopy,
                    kind: .info
                )
            }
        }
        if source == .watchApp {
            let readiness = await self.audioCaptureReadinessGate.wait(
                sessionID: captureSessionID,
                attemptID: readinessAttemptID,
                timeoutNanoseconds: 3_000_000_000
            )
            if readiness != .ready,
               startGeneration == self.audioCaptureStartGeneration,
               !WatchCaptureStop.shouldFallbackToThisMacOnSilence()
            {
                await MainActor.run {
                    LiveTranslationController.shared.reportListenStatus(
                        WatchCaptureStop.waitingCopy,
                        kind: .info
                    )
                }
            }
        }

        guard startGeneration == self.audioCaptureStartGeneration, self.isTerminating == false else {
            await self.systemAudioCapture.stop()
            self.activeAudioCaptureBackend = .none
            self.audioCapturePipeline.setRecordingEnabled(false)
            return .failed
        }
        self.isRunning = true
        DebugLogger.shared.info(
            "Watch audio capture running (session=\(captureSessionID))",
            source: "ASRService"
        )
        onCaptureStarted?()
        return .started
    }
}
