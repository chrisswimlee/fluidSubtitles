import AppKit
import AVFoundation
import Foundation
import SwiftUI

extension ContentView {
    func startCaptionListening() {
        guard !self.asr.isRunningOrStarting else {
            LiveTranslationController.shared.listenStartFailed()
            LiveTranslationController.shared.reportListenFailure("Still stopping the last Listen. Try again.")
            return
        }
        guard TheaterAvailability.isSupported else {
            LiveTranslationController.shared.listenStartFailed()
            LiveTranslationController.shared.reportListenFailure(TheaterAvailability.unsupportedCopy)
            return
        }
        MicrophoneAccess.refresh(self.asr)
        if MicrophoneAccess.isDenied(self.asr.micStatus) {
            LiveTranslationController.shared.listenStartFailed()
            LiveTranslationController.shared.reportListenFailure(MicrophoneAccess.deniedCopy)
            return
        }
        let model = SettingsStore.shared.selectedSpeechModel
        if !model.isInstalled {
            LiveTranslationController.shared.listenStartFailed()
            LiveTranslationController.shared.reportListenFailure(
                "Download \(model.displayName) before Listen. Apple Speech works without a download."
            )
            return
        }
        Task {
            let granted = await MicrophoneAccess.authorize(updating: self.asr)
            if !granted {
                LiveTranslationController.shared.listenStartFailed()
                LiveTranslationController.shared.reportListenFailure(MicrophoneAccess.deniedCopy)
                return
            }
            let prepared = await TheaterSpeechSession.shared.prepareListen(kind: .captions, asr: self.asr)
            guard prepared,
                  LiveTranslationController.shared.isSessionActive,
                  LiveTranslationController.shared.listenKind == .captions
            else {
                return
            }
            let startOutcome = await self.asr.start()
            if startOutcome == .failed {
                TheaterSpeechSession.shared.clear(asr: self.asr)
                LiveTranslationController.shared.cancelSession()
                LiveTranslationController.shared.reportListenFailure(
                    MicrophoneAccess.isAuthorized(self.asr.micStatus)
                        ? "Could not start listening. Check the microphone and Voice Engine."
                        : MicrophoneAccess.deniedCopy
                )
            }
        }
        Task {
            try? await self.asr.ensureAsrReady()
        }
    }

    func startInsertTranslationListening() {
        guard !self.asr.isRunningOrStarting else {
            LiveTranslationController.shared.listenStartFailed()
            LiveTranslationController.shared.reportListenFailure("Still stopping the last Listen. Try again.")
            return
        }
        // Capture before Listen can move focus. First PCM is too late.
        self.captureRecordingTargetContext()
        Task {
            let prepared = await TheaterSpeechSession.shared.prepareListen(kind: .insert, asr: self.asr)
            guard prepared else {
                return
            }
            let startOutcome = await self.asr.start()
            if startOutcome == .failed {
                TheaterSpeechSession.shared.clear(asr: self.asr)
                LiveTranslationController.shared.cancelSession()
                self.menuBarManager.hideRecordingOverlayImmediately(reason: "asr_start_failed")
            }
        }
        Task {
            try? await self.asr.ensureAsrReady()
        }
    }

    /// Theater Stop. Does not enter spoken-send, prompt-test, AI post-process,
    /// or play a listen chime.
    func stopTheaterListening() async {
        let pipelineID = UUID().uuidString
        await DebugLogger.$pipelineID.withValue(pipelineID) {
            await self.processStoppedTheaterListen(pipelineID: pipelineID)
        }
    }

    func processStoppedTheaterListen(pipelineID: String) async {
        let pipelineStartedAt = ProcessInfo.processInfo.systemUptime
        let expectedOverlayLifecycleID = self.overlayLifecycleID
        self.appBench("theater_stop_begin id=\(pipelineID)")
        defer {
            self.appBench(
                "theater_stop_return id=\(pipelineID) elapsedMs=\((ProcessInfo.processInfo.systemUptime - pipelineStartedAt) * 1000)"
            )
        }

        LiveTranslationController.shared.markListeningStop()
        let kind = LiveTranslationController.shared.listenKind ?? .captions
        let transcribedText = await self.asr.stop(onFinalTranscriptionStarted: nil)
        let audioFile = self.asr.consumeLastCompletedAudioFile()
        let transcriptionDurationMilliseconds = self.asr.consumeLastFinalTranscriptionDurationMs()
        await self.processStoppedTranslation(
            transcribedText: transcribedText,
            route: .normal,
            pipelineID: pipelineID,
            pipelineStartedAt: pipelineStartedAt,
            transcriptionDurationMilliseconds: transcriptionDurationMilliseconds,
            audioFile: kind == .insert ? audioFile : nil,
            expectedOverlayLifecycleID: expectedOverlayLifecycleID,
            stopOverlayDidRequestHide: false
        )
        TheaterSpeechSession.shared.clear(asr: self.asr)
    }

    /// Escape / cancel. Stops the mic without dictation Stop, spoken-send, or AI.
    @discardableResult
    func cancelTheaterListenIfNeeded() -> Bool {
        let theaterActive = LiveTranslationController.shared.isSessionActive
            || TheaterSpeechSession.shared.isSessionActive
        guard theaterActive else { return false }
        self.cancelPrewarmDictationIfNeeded()
        Task {
            await self.asr.stopWithoutTranscription()
        }
        LiveTranslationController.shared.cancelSession()
        self.menuBarManager.hideRecordingOverlayImmediately(reason: "theater_escape")
        return true
    }
}
