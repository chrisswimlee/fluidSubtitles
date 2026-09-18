import Foundation

private final class ProbeTally: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedPeak: Float = 0
    private var recordedPackets = 0

    var peak: Float {
        self.lock.withLock { self.recordedPeak }
    }

    var packets: Int {
        self.lock.withLock { self.recordedPackets }
    }

    func record(peak: Float) {
        self.lock.withLock {
            self.recordedPackets += 1
            self.recordedPeak = max(self.recordedPeak, peak)
        }
    }
}

enum WatchCaptureProbe {
    enum Outcome: Equatable, Sendable {
        case heardAudio
        case silent
        case denied
        case needsReopen
        case noDisplay
        case failed(String)
        case busy
    }

    static let energyThreshold: Float = 0.008

    static func statusKind(for outcome: Outcome) -> TheaterStatusKind {
        switch outcome {
        case .heardAudio:
            return .success
        case .silent, .busy:
            return .info
        case .denied, .needsReopen, .noDisplay, .failed:
            return .warning
        }
    }

    static func message(for outcome: Outcome) -> String {
        switch outcome {
        case .heardAudio:
            if WatchOutputRoute.looksLikeLoopbackOrAggregate() {
                return "Heard system audio. \(WatchOutputRoute.warningCopy)"
            }
            return "Heard system audio. Listen will caption Korean, English, Thai, or Japanese."
        case .silent:
            return "Capture is running but heard no audio. Play a Korean, English, Thai, or Japanese video that is not DRM."
        case .denied:
            return ScreenRecordingAccess.deniedCopy
        case .needsReopen:
            return ScreenRecordingAccess.reopenCopy
        case .noDisplay:
            return "No display is available to capture audio."
        case .failed(let text):
            return text
        case .busy:
            return "Stop Listen before checking capture."
        }
    }

    static func outcome(
        resolution: ScreenRecordingAccess.Resolution,
        listening: Bool
    ) -> Outcome? {
        if listening { return .busy }
        switch resolution {
        case .granted:
            return nil
        case .denied:
            return .denied
        case .needsReopen:
            return .needsReopen
        case .noDisplay:
            return .noDisplay
        }
    }

    static func classify(peak: Float, packets: Int) -> Outcome {
        if packets > 0, peak >= self.energyThreshold {
            return .heardAudio
        }
        return .silent
    }

    @MainActor
    static func run(
        source: TheaterCaptureSource? = nil,
        appBundleID: String? = nil,
        timeoutNanoseconds: UInt64 = 1_500_000_000
    ) async -> Outcome {
        if LiveTranslationController.shared.isSessionActive {
            return .busy
        }
        let settings = SettingsStore.shared
        let resolvedSource = source ?? settings.theaterCaptureSource
        let resolvedBundleID = appBundleID ?? settings.theaterWatchAppBundleID

        let capture = SystemAudioCapture()
        let tally = ProbeTally()
        let gate = WatchFeedbackSession()
        let aggressive = WatchOutputRoute.looksLikeLoopbackOrAggregate()
        do {
            try await capture.start(
                source: resolvedSource == .lecternMicrophone ? .watchThisMac : resolvedSource,
                appBundleID: resolvedBundleID,
                packetHandler: { samples, frameCount, sampleRate, _, _ in
                    guard gate.admit(
                        samples,
                        count: frameCount,
                        sampleRate: sampleRate,
                        aggressive: aggressive
                    ) else { return }
                    var localPeak: Float = 0
                    for index in 0..<frameCount {
                        localPeak = max(localPeak, abs(samples[index]))
                    }
                    tally.record(peak: localPeak)
                },
                onStopped: { _ in }
            )
        } catch {
            return self.failedOutcome(error)
        }

        try? await Task.sleep(nanoseconds: timeoutNanoseconds)
        await capture.stop()
        return self.classify(peak: tally.peak, packets: tally.packets)
    }

    private static func failedOutcome(_ error: Error) -> Outcome {
        if let capture = error as? SystemAudioCaptureError {
            switch capture {
            case .screenRecordingDenied:
                return .denied
            case .needsReopen:
                return .needsReopen
            case .noDisplay:
                return .noDisplay
            case .startFailed(let message):
                return .failed(message)
            }
        }
        return .failed(ScreenRecordingAccess.message(forStartError: error))
    }
}
