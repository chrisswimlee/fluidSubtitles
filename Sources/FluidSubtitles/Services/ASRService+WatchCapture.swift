import Foundation

extension ASRService {
    /// Watch / SCStream capture is leftover engine code, not a Theater product path.
    var isWatchCaptionCapture: Bool { false }

    func setCapturePaused(_ paused: Bool) {
        self.audioCapturePipeline.setCapturePaused(paused)
    }

    func startWatchAudioCapture(
        captureSessionID _: Int,
        readinessAttemptID _: UInt64,
        startGeneration _: UInt64,
        onCaptureStarted _: (@MainActor () -> Void)?
    ) async -> AudioCaptureStartOutcome {
        DebugLogger.shared.error(
            "Watch capture is not a product path. Theater Listen uses the microphone.",
            source: "ASRService"
        )
        self.audioCapturePipeline.setRecordingEnabled(false)
        return .failed
    }
}
