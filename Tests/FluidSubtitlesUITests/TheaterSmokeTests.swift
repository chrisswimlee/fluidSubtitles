//
//  TheaterSmokeTests.swift
//  Fluid
//
//  Launch smoke: sidebar Theater shows languages, Voice / Translate, and Theater chrome.
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

        let languages = app.descendants(matching: .any)["theater.languages"]
        XCTAssertTrue(languages.waitForExistence(timeout: 8), "Home language card")

        let mode = app.descendants(matching: .any)["theater.mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 4), "Voice / Translate")

        let voiceButton = app.segmentedControls["theater.mode"].buttons["Voice"]
        if voiceButton.waitForExistence(timeout: 2) {
            voiceButton.click()
        } else {
            app.buttons["Voice"].firstMatch.click()
        }
        XCTAssertTrue(
            app.descendants(matching: .any)["theater.voiceEngine"].waitForExistence(timeout: 4),
            "Voice Engine is speech to text"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["theater.customizeVoiceEngine"].waitForExistence(timeout: 4),
            "Voice Engine in Voice mode"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["theater.translationEngine"].waitForExistence(timeout: 4),
            "Translation Engine names Apple Translation"
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
            app.descendants(matching: .any)["theater.window.mode"].waitForExistence(timeout: 4),
            "Voice / Translate is on Theater chrome"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["theater.window.listen"].waitForExistence(timeout: 4),
            "Listen is on Theater chrome"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["theater.presentationStyle"].waitForExistence(timeout: 4),
            "Settings stays on Theater chrome"
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
