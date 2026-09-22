import ApplicationServices
import Foundation

/// What the old FluidVoice dictation shortcut may do when it fires.
/// A missing callback leaves the microphone idle. It must not call `ASRService.start`.
enum DictationHotkeyCaptureStart: Equatable {
    case invokeCallback
    case leaveMicrophoneIdle

    static func resolve(hasCallback: Bool) -> Self {
        hasCallback ? .invokeCallback : .leaveMicrophoneIdle
    }

    /// The Listen and Type shortcut is saved, but macOS will not deliver it.
    static func blocksListenAndType(enabled: Bool, accessibilityTrusted: Bool) -> Bool {
        enabled && !accessibilityTrusted
    }

    /// Ask once per launch. Repeating the prompt on every tap retry stacks dialogs.
    static func shouldRequestSystemPrompt(alreadyRequested: Bool, trusted: Bool) -> Bool {
        !trusted && !alreadyRequested
    }

    static func requestSystemPrompt() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Releasing the old dictation shortcut must not stop a Theater Listen.
    static func releaseStopsCapture(holdMode: HotkeyHoldModeType, theaterSessionActive: Bool) -> Bool {
        switch holdMode {
        case .transcription, .promptMode, .promptAssignment:
            return !theaterSessionActive
        case .translateInsert, .captionListen:
            return true
        }
    }
}
