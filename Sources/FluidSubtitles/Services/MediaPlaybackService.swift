import Foundation

// Tracked grandfather: existing FluidVoice-era file. New work belongs in a smaller file.

/// Pause-other-apps is omitted from the public tree. The previously linked
/// MediaRemoteAdapter fork published no LICENSE at the pinned revision.
@MainActor
final class MediaPlaybackService {
    static let shared = MediaPlaybackService()

    private init() {}

    func pauseIfPlaying() async -> Bool {
        DebugLogger.shared.debug(
            "MediaPlaybackService: Pause-other-apps is not shipped without a licensed adapter",
            source: "MediaPlaybackService"
        )
        return false
    }

    func resumeIfWePaused(_ wePaused: Bool) async {
        _ = wePaused
    }
}
