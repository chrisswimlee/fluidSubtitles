import XCTest
@testable import FluidSubtitles_Debug

@MainActor
final class TheaterMinimizeTests: XCTestCase {
    func testHomeShowsTheaterWhenTheBoardIsMinimized() {
        XCTAssertEqual(
            TheaterMinimize.homeAction(windowEnabled: true, minimized: true),
            .show
        )
        XCTAssertEqual(
            TheaterMinimize.homeAction(windowEnabled: true, minimized: false),
            .close
        )
        XCTAssertEqual(
            TheaterMinimize.homeAction(windowEnabled: false, minimized: false),
            .open
        )
        XCTAssertEqual(
            TheaterMinimize.homeAction(windowEnabled: false, minimized: true),
            .open
        )
    }

    func testMinimizedBoardDoesNotOrderFront() {
        XCTAssertFalse(TheaterMinimize.shouldOrderFront(minimized: true))
        XCTAssertTrue(TheaterMinimize.shouldOrderFront(minimized: false))
    }

    func testExpandingAMinimizedBoardOrdersFront() {
        // toggleMinimized() must orderFront after this is true. Home / hotkey
        // use show(); chrome expand uses toggle. Without orderFront the board
        // stays orderOut.
        XCTAssertTrue(TheaterMinimize.shouldOrderFront(minimized: false))
    }

    func testHomeCopyMatchesReadiness() {
        XCTAssertEqual(
            TheaterMinimize.homeTitle(for: .open),
            TheaterReadiness.gettingStartedOpen
        )
        XCTAssertEqual(
            TheaterMinimize.homeTitle(for: .show),
            TheaterReadiness.showTheater
        )
        XCTAssertEqual(
            TheaterMinimize.homeTitle(for: .close),
            TheaterReadiness.closeTheater
        )
        XCTAssertEqual(
            TheaterMinimize.homeHelp(for: .show),
            TheaterReadiness.showTheaterHelp
        )
        XCTAssertEqual(
            TheaterMinimize.homeHelp(for: .close),
            TheaterReadiness.closeTheaterHelp
        )
    }
}
