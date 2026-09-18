import AppKit
import Carbon
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

final class TheaterOverlayPolicyTests: XCTestCase {
    private let visible = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    func testIdleOverlayHidesChromeAndClicksThrough() {
        XCTAssertTrue(
            TheaterOverlayPolicy.hidesAllChrome(presentation: .transparent, toolsPinned: false)
        )
        XCTAssertTrue(
            TheaterOverlayPolicy.ignoresMouseEvents(
                presentation: .transparent,
                toolsPinned: false,
                minimized: false
            )
        )
        XCTAssertTrue(
            TheaterOverlayPolicy.hidesTitlebarButtons(presentation: .transparent, toolsPinned: false)
        )
        XCTAssertFalse(
            TheaterOverlayPolicy.movableByBackground(
                presentation: .transparent,
                toolsPinned: false,
                minimized: false
            )
        )
    }

    func testPinnedOverlayShowsToolsAndStopsClickThrough() {
        XCTAssertFalse(
            TheaterOverlayPolicy.hidesAllChrome(presentation: .transparent, toolsPinned: true)
        )
        XCTAssertFalse(
            TheaterOverlayPolicy.ignoresMouseEvents(
                presentation: .transparent,
                toolsPinned: true,
                minimized: false
            )
        )
        XCTAssertTrue(
            TheaterOverlayPolicy.movableByBackground(
                presentation: .transparent,
                toolsPinned: true,
                minimized: false
            )
        )
    }

    func testPopupDropsToNormalWhileThisAppIsFront() {
        XCTAssertEqual(
            TheaterOverlayPolicy.windowLevel(presentation: .popup, appIsActive: true),
            .normal
        )
        XCTAssertFalse(
            TheaterOverlayPolicy.isFloatingPanel(presentation: .popup, appIsActive: true)
        )
        XCTAssertEqual(
            TheaterOverlayPolicy.windowLevel(presentation: .popup, appIsActive: false),
            .floating
        )
        XCTAssertEqual(
            TheaterOverlayPolicy.windowLevel(presentation: .transparent, appIsActive: true),
            .floating
        )
    }

    func testPopupNeverClicksThroughAndCaptionsOnlyStaysPopup() {
        XCTAssertFalse(
            TheaterOverlayPolicy.ignoresMouseEvents(
                presentation: .popup,
                toolsPinned: false,
                minimized: false
            )
        )
        XCTAssertTrue(
            TheaterOverlayPolicy.usesCaptionsOnlyChrome(presentation: .popup, hideChrome: true)
        )
        XCTAssertFalse(
            TheaterOverlayPolicy.usesCaptionsOnlyChrome(presentation: .transparent, hideChrome: true)
        )
        XCTAssertTrue(
            TheaterOverlayPolicy.movableByBackground(
                presentation: .popup,
                toolsPinned: false,
                minimized: false
            )
        )
    }

    func testPinClearsOnPopupMinimizeAndClose() {
        XCTAssertTrue(
            TheaterOverlayPolicy.shouldClearPin(
                presentation: .popup,
                minimized: false,
                windowEnabled: true
            )
        )
        XCTAssertTrue(
            TheaterOverlayPolicy.shouldClearPin(
                presentation: .transparent,
                minimized: true,
                windowEnabled: true
            )
        )
        XCTAssertTrue(
            TheaterOverlayPolicy.shouldClearPin(
                presentation: .transparent,
                minimized: false,
                windowEnabled: false
            )
        )
        XCTAssertFalse(
            TheaterOverlayPolicy.shouldClearPin(
                presentation: .transparent,
                minimized: false,
                windowEnabled: true
            )
        )
    }

    func testOverlayFallsBackToCaptionBarAndKeepsAThinFrame() {
        let bar = TheaterPositionPreset.captionBar.frame(in: self.visible)
        XCTAssertEqual(
            TheaterWindowPlacement.resolvedFrame(stored: nil, visible: self.visible, presentation: .transparent),
            bar
        )
        XCTAssertEqual(
            TheaterWindowPlacement.resolvedFrame(
                stored: CGRect(x: 80, y: 80, width: 1100, height: 440),
                visible: self.visible,
                presentation: .transparent
            ),
            bar
        )
        let thin = CGRect(x: 100, y: 80, width: 1600, height: 180)
        XCTAssertFalse(
            TheaterWindowPlacement.shouldFillScreen(
                stored: thin,
                visible: self.visible,
                presentation: .transparent
            )
        )
        XCTAssertEqual(
            TheaterWindowPlacement.resolvedFrame(
                stored: thin,
                visible: self.visible,
                presentation: .transparent
            ),
            thin
        )
        let filled = TheaterWindowPlacement.resolvedFrame(
            stored: self.visible,
            visible: self.visible,
            presentation: .transparent
        )
        XCTAssertEqual(filled, bar)
    }

    func testPopupStillFillsTheVisibleScreen() {
        XCTAssertEqual(
            TheaterWindowPlacement.resolvedFrame(stored: nil, visible: self.visible, presentation: .popup),
            self.visible
        )
        XCTAssertTrue(
            TheaterWindowPlacement.shouldFillScreen(
                stored: CGRect(x: 80, y: 80, width: 1100, height: 440),
                visible: self.visible,
                presentation: .popup
            )
        )
    }

    func testCaptionBarStaysInsideTheSafeMargin() {
        let safe = self.visible.insetBy(dx: 96, dy: 54)
        let frame = TheaterPositionPreset.captionBar.frame(in: self.visible)
        XCTAssertTrue(safe.contains(frame))
        XCTAssertEqual(frame.height, TheaterPositionPreset.captionBarHeight, accuracy: 0.5)
        XCTAssertEqual(frame.minY, safe.minY, accuracy: 0.5)
    }

    func testCaptionPlateIsOverlayOnly() {
        XCTAssertTrue(
            TheaterOverlayPolicy.showsCaptionPlate(presentation: .transparent, backingBar: true)
        )
        XCTAssertFalse(
            TheaterOverlayPolicy.showsCaptionPlate(presentation: .popup, backingBar: true)
        )
        XCTAssertEqual(TheaterOverlayPolicy.minSize(for: .transparent), TheaterOverlayPolicy.overlayMinSize)
        XCTAssertEqual(TheaterOverlayPolicy.minSize(for: .popup), TheaterOverlayPolicy.popupMinSize)
    }

    func testHoverTagsNameTheControl() {
        XCTAssertTrue(TheaterChromeHelp.listen.hasPrefix("Listen —"))
        XCTAssertTrue(TheaterChromeHelp.listen.contains("Control-Option-L"))
        XCTAssertTrue(TheaterChromeHelp.overlay.hasPrefix("Overlay —"))
        XCTAssertTrue(TheaterChromeHelp.overlay.contains("Control-Option-T"))
        XCTAssertTrue(TheaterChromeHelp.board.hasPrefix("Board —"))
        XCTAssertTrue(TheaterChromeHelp.captionPlate.hasPrefix("Caption plate —"))
        XCTAssertEqual(
            TheaterChromeHelp.position(.captionBar),
            TheaterChromeHelp.captionBar
        )
    }
}

@MainActor
final class TheaterMenuBarTests: XCTestCase {
    func testMenuBarListsOverlayTypography() {
        let menu = NSMenu()
        TheaterMenuBarController.appendOverlayControls(to: menu, target: TheaterMenuBarController.shared)
        let titles = menu.items.map(\.title)
        XCTAssertTrue(titles.contains("Larger Text"))
        XCTAssertTrue(titles.contains("Smaller Text"))
        XCTAssertTrue(titles.contains("Caption Font"))
        XCTAssertTrue(titles.contains("Theme"))
        XCTAssertTrue(titles.contains(TheaterPresentationStyle.transparent.displayName))
        XCTAssertTrue(titles.contains("Caption Plate"))
        XCTAssertNotNil(menu.items.first { $0.title == "Caption Font" }?.submenu)
        XCTAssertEqual(
            menu.items.first { $0.title == "Caption Font" }?.submenu?.items.count,
            TheaterTypeface.allCases.count
        )
    }

    func testMenuBarCaptionPlateIsEnabledOnlyForOverlay() {
        let settings = SettingsStore.shared
        let previous = settings.theaterPresentationStyle
        defer { settings.theaterPresentationStyle = previous }
        let menu = NSMenu()
        TheaterMenuBarController.appendOverlayControls(to: menu, target: TheaterMenuBarController.shared)

        settings.theaterPresentationStyle = TheaterPresentationStyle.transparent.rawValue
        TheaterMenuBarController.applyState(to: menu)
        XCTAssertTrue(TheaterMenuBarController.item(.captionPlate, in: menu)?.isEnabled == true)
        XCTAssertEqual(
            TheaterMenuBarController.item(.overlayStyle, in: menu)?.state,
            .on
        )

        settings.theaterPresentationStyle = TheaterPresentationStyle.popup.rawValue
        TheaterMenuBarController.applyState(to: menu)
        XCTAssertTrue(TheaterMenuBarController.item(.captionPlate, in: menu)?.isEnabled == false)
        XCTAssertEqual(TheaterMenuBarController.item(.popupStyle, in: menu)?.state, .on)
    }

    func testMenuBarSizeLabelUsesTheCaptionSetting() {
        let menu = NSMenu()
        TheaterMenuBarController.appendOverlayControls(to: menu, target: TheaterMenuBarController.shared)
        TheaterMenuBarController.applyState(to: menu)
        let label = TheaterMenuBarController.item(.sizeLabel, in: menu)?.title ?? ""
        XCTAssertTrue(label.contains("\(SettingsStore.shared.presenterFontSize)"))
        XCTAssertTrue(label.contains("pt"))
    }

    func testMenuBarTextSizeStopsAtTheRangeEnds() {
        let settings = SettingsStore.shared
        let previous = settings.presenterFontSize
        defer { settings.presenterFontSize = previous }
        let menu = self.overlayMenu()
        let range = SettingsStore.presenterFontSizeRange

        settings.presenterFontSize = range.upperBound
        TheaterMenuBarController.applyState(to: menu)
        XCTAssertEqual(TheaterMenuBarController.item(.largerText, in: menu)?.isEnabled, false)
        XCTAssertEqual(TheaterMenuBarController.item(.smallerText, in: menu)?.isEnabled, true)

        settings.presenterFontSize = range.lowerBound
        TheaterMenuBarController.applyState(to: menu)
        XCTAssertEqual(TheaterMenuBarController.item(.largerText, in: menu)?.isEnabled, true)
        XCTAssertEqual(TheaterMenuBarController.item(.smallerText, in: menu)?.isEnabled, false)
        XCTAssertEqual(
            TheaterMenuBarController.item(.sizeLabel, in: menu)?.title,
            "Size \(range.lowerBound) pt"
        )
    }

    func testMenuBarSaysWhenTheBoardIsHiddenFromZoom() {
        let settings = SettingsStore.shared
        let previous = settings.theaterHideFromScreenShare
        defer { settings.theaterHideFromScreenShare = previous }
        let menu = self.overlayMenu()
        let share = TheaterMenuBarController.item(.hideShare, in: menu)

        settings.theaterHideFromScreenShare = true
        TheaterMenuBarController.applyState(to: menu)
        XCTAssertEqual(share?.state, .on)
        XCTAssertTrue(share?.title.contains(TheaterReadiness.hiddenFromZoomBadge) == true)

        settings.theaterHideFromScreenShare = false
        TheaterMenuBarController.applyState(to: menu)
        XCTAssertEqual(share?.state, .off)
        XCTAssertEqual(share?.title, "Hide from Screen Share")
    }

    func testMenuBarMinimizeFlipsToShowTheater() {
        let settings = SettingsStore.shared
        let previous = settings.theaterMinimized
        defer { settings.theaterMinimized = previous }
        let menu = self.overlayMenu()
        let minimize = TheaterMenuBarController.item(.minimize, in: menu)

        settings.theaterMinimized = true
        TheaterMenuBarController.applyState(to: menu)
        XCTAssertEqual(minimize?.title, "Show Theater")
        XCTAssertEqual(minimize?.toolTip, TheaterChromeHelp.expand)
        XCTAssertEqual(minimize?.isEnabled, settings.theaterWindowEnabled)

        settings.theaterMinimized = false
        TheaterMenuBarController.applyState(to: menu)
        XCTAssertEqual(minimize?.title, "Minimize Theater")
        XCTAssertEqual(minimize?.toolTip, TheaterChromeHelp.minimize)
    }

    func testMenuBarChecksOnlyTheChosenFontAndTheme() {
        let settings = SettingsStore.shared
        let previousFont = settings.presenterFontFamily
        let previousTheme = settings.theaterAppearance
        defer {
            settings.presenterFontFamily = previousFont
            settings.theaterAppearance = previousTheme
        }
        let menu = self.overlayMenu()
        let face = TheaterTypeface.allCases.last!
        let appearance = TheaterAppearance.allCases.last!
        settings.presenterFontFamily = face.rawValue
        settings.theaterAppearance = appearance.rawValue
        TheaterMenuBarController.applyState(to: menu)

        let fonts = menu.items.first { $0.title == "Caption Font" }?.submenu?.items ?? []
        XCTAssertEqual(fonts.filter { $0.state == .on }.map { $0.representedObject as? String }, [face.rawValue])
        let themes = menu.items.first { $0.title == "Theme" }?.submenu?.items ?? []
        XCTAssertEqual(themes.filter { $0.state == .on }.map { $0.representedObject as? String }, [appearance.rawValue])
    }

    func testEveryMenuBarActionHasAHoverTag() {
        let menu = self.overlayMenu()
        // Submenu parents get AppKit's submenuAction:, so only leaves count.
        let actions = menu.items
            .flatMap { $0.submenu?.items ?? [$0] }
            .filter { $0.action != nil }
        XCTAssertFalse(actions.isEmpty)
        for item in actions {
            XCTAssertFalse(item.toolTip?.isEmpty ?? true, "\(item.title) has no hover tag")
            XCTAssertTrue(item.target === TheaterMenuBarController.shared, "\(item.title) has no target")
        }
    }

    private func overlayMenu() -> NSMenu {
        let menu = NSMenu()
        TheaterMenuBarController.appendOverlayControls(to: menu, target: TheaterMenuBarController.shared)
        return menu
    }
}

final class TheaterChromeHelpTests: XCTestCase {
    func testHoverTagShortcutsMatchPresenterHotkeys() {
        let pairs: [(help: String, key: String, keyCode: Int, action: TheaterPresenterHotkey.Action)] = [
            (TheaterChromeHelp.listen, "L", kVK_ANSI_L, .listen),
            (TheaterChromeHelp.pause, "P", kVK_ANSI_P, .togglePause),
            (TheaterChromeHelp.minimize, "H", kVK_ANSI_H, .toggleVisible),
            (TheaterChromeHelp.clear, "K", kVK_ANSI_K, .clear),
            (TheaterChromeHelp.larger, "=", kVK_ANSI_Equal, .fontLarger),
            (TheaterChromeHelp.smaller, "-", kVK_ANSI_Minus, .fontSmaller),
            (TheaterChromeHelp.overlayTools, "T", kVK_ANSI_T, .toggleTools),
        ]
        for pair in pairs {
            XCTAssertTrue(pair.help.contains("Control-Option-\(pair.key)"), pair.help)
            XCTAssertEqual(
                TheaterPresenterHotkey.action(keyCode: UInt16(pair.keyCode), modifiers: [.control, .option]),
                pair.action,
                pair.help
            )
        }
    }

    func testTagPutsTheShortcutAfterWhatItDoes() {
        XCTAssertEqual(TheaterChromeHelp.tag("Retry", does: "Try again."), "Retry — Try again.")
        XCTAssertEqual(
            TheaterChromeHelp.tag("Pause", does: "Freeze.", shortcut: "Control-Option-P"),
            "Pause — Freeze. Control-Option-P."
        )
    }
}
