@testable import FluidSubtitles_Debug
import XCTest

@MainActor
final class MediaPlaybackServiceTests: XCTestCase {
    func testPauseOtherAppsIsDisabledWithoutLicensedAdapter() async {
        let didPause = await MediaPlaybackService.shared.pauseIfPlaying()
        XCTAssertFalse(didPause)
        await MediaPlaybackService.shared.resumeIfWePaused(true)
    }
}
