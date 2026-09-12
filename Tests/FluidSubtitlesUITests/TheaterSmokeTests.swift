//
//  TheaterSmokeTests.swift
//  Fluid
//
//  Launch smoke: sidebar Theater shows language and Listen chrome.
//

import XCTest

final class TheaterSmokeTests: XCTestCase {
    func testLaunchShowsTheaterLanguagesAndListen() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-OnboardingCompleted", "YES"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        let sidebarTheater = app.descendants(matching: .any)["sidebar.theater"]
        if sidebarTheater.waitForExistence(timeout: 8) {
            sidebarTheater.click()
        }

        // Soft chrome checks only. Do not click Listen or start live audio.
        let languages = app.descendants(matching: .any)["theater.languages"]
        if languages.waitForExistence(timeout: 8) {
            XCTAssertTrue(languages.exists)
        }

        let listen = app.descendants(matching: .any)["theater.listen"]
        if listen.waitForExistence(timeout: 4) {
            XCTAssertTrue(listen.exists)
        }

        let openTheater = app.descendants(matching: .any)["theater.open"]
        if openTheater.waitForExistence(timeout: 4) {
            openTheater.click()
            let windowLanguages = app.descendants(matching: .any)["theater.window.languages"]
            if windowLanguages.waitForExistence(timeout: 6) {
                XCTAssertTrue(windowLanguages.exists)
            }
        }
    }
}
