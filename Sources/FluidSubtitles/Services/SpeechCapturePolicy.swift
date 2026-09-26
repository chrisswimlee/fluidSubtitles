import Foundation

/// Capture policy the speech engine reads for this Listen.
/// Theater installs one; dictation leaves it nil.
@MainActor
protocol SpeechCapturePolicy: AnyObject {
    var isSessionActive: Bool { get }
    var boundLiveTranscript: Bool { get }
    var keepShortUtterances: Bool { get }
    var preferLatestChunk: Bool { get }
    var retainsAudio: Bool { get }
    /// Dictation pauses Spotify so the mic hears you. A lectern's media is the talk.
    var pausesMedia: Bool { get }
    /// Dictation beeps so you know the hotkey stopped. A hall PA must stay silent.
    var playsListenChime: Bool { get }

    func markFirstBuffer()
    func markSpeechStart(hostTime: UInt64)
    func markSilenceHold()
    func handleEndOfUtterance()
}

/// Theater Listen never pauses the presenter's deck or chimes into the room.
/// A missing policy is not FluidVoice dictation, so the old pause-media switch does not apply.
enum TheaterListenCapture {
    static func shouldPauseMedia(policyPausesMedia: Bool?, settingEnabled: Bool) -> Bool {
        _ = settingEnabled
        return policyPausesMedia == true
    }

    static func shouldPlayListenChime(policyPlaysChime: Bool?) -> Bool {
        policyPlaysChime == true
    }
}
