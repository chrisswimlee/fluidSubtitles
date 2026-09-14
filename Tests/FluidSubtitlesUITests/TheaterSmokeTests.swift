//
//  TheaterSmokeTests.swift
//  Fluid
//
//  Launch smoke: sidebar Theater shows languages, Watch source, and Theater chrome.
//  Do not click Listen or start live audio. Pause exists only after Listen.
//

import XCTest

final class TheaterSmokeTests: XCTestCase {
    func testLaunchShowsTheaterLanguagesAndListen() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-OnboardingCompleted", "YES",
            "-TheaterHideChrome", "NO",
            "-TheaterMinimized", "NO",
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        let sidebarTheater = app.descendants(matching: .any)["sidebar.theater"]
        XCTAssertTrue(sidebarTheater.waitForExistence(timeout: 8), "Theater sidebar item")
        sidebarTheater.click()

        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26 {
            XCTAssertTrue(
                app.descendants(matching: .any)["theater.needsMacOS26"].waitForExistence(timeout: 8),
                "Theater requires macOS 26"
            )
            return
        }

        let languages = app.descendants(matching: .any)["theater.languages"]
        XCTAssertTrue(languages.waitForExistence(timeout: 8), "Home language card")

        let mode = app.descendants(matching: .any)["theater.mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 4), "Lectern / Watch")

        let watchButton = app.segmentedControls["theater.mode"].buttons["Watch"]
        if watchButton.waitForExistence(timeout: 2) {
            watchButton.click()
        } else {
            app.buttons["Watch"].firstMatch.click()
        }
        XCTAssertTrue(
            app.descendants(matching: .any)["theater.watchSource"].waitForExistence(timeout: 4),
            "Watch capture picker"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["theater.checkCapture"].waitForExistence(timeout: 4),
            "Check capture"
        )

        let listen = app.descendants(matching: .any)["theater.listen"]
        XCTAssertTrue(listen.waitForExistence(timeout: 4), "Listen")

        let openTheater = app.descendants(matching: .any)["theater.open"]
        XCTAssertTrue(openTheater.waitForExistence(timeout: 4), "Open Theater")
        openTheater.click()

        XCTAssertTrue(
            app.descendants(matching: .any)["theater.window.languages"].waitForExistence(timeout: 6),
            "Theater window languages"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["theater.window.watchSource"].waitForExistence(timeout: 4),
            "Theater window capture source"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["theater.window.mode"].waitForExistence(timeout: 4),
            "Lectern / Watch is on Theater chrome"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["theater.window.listen"].waitForExistence(timeout: 4),
            "Listen is on Theater chrome"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["theater.minimize"].waitForExistence(timeout: 4),
            "Minimize is on Theater chrome before Listen"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["theater.window.clear"].waitForExistence(timeout: 4),
            "Clear captions is on Theater chrome"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["theater.window.checkCapture"].waitForExistence(timeout: 4),
            "Check capture is on Theater chrome in Watch"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["theater.status"].waitForExistence(timeout: 4),
            "Status line after Open Theater"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["theater.pause"].exists,
            "Pause only appears after Listen; smoke must not start audio"
        )
    }
}
