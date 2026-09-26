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
        XCTAssertEqual(
            TheaterMinimize.homeHelp(for: .close, listening: true),
            TheaterReadiness.closeWhileListening
        )
        XCTAssertEqual(
            TheaterMinimize.homeHelp(for: .open, listening: true),
            TheaterReadiness.openTheaterHelp
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
        XCTAssertFalse(TheaterOverlayPolicy.showsWindowShadow(presentation: .transparent))
        XCTAssertTrue(TheaterOverlayPolicy.showsWindowShadow(presentation: .popup))
        XCTAssertFalse(
            TheaterOverlayPolicy.hidesTitlebarButtons(presentation: .popup, toolsPinned: false)
        )
        XCTAssertTrue(
            TheaterOverlayPolicy.hidesTitlebarButtons(
                presentation: .popup,
                toolsPinned: false,
                hideChrome: true
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
            TheaterOverlayPolicy.reservesToolBarSlot(presentation: .popup, hideChrome: false)
        )
        XCTAssertFalse(
            TheaterOverlayPolicy.reservesToolBarSlot(presentation: .popup, hideChrome: true)
        )
        XCTAssertFalse(
            TheaterOverlayPolicy.reservesToolBarSlot(presentation: .transparent, hideChrome: false)
        )
        XCTAssertTrue(
            TheaterOverlayPolicy.reservesToolBarSlot(
                presentation: .transparent,
                hideChrome: false,
                toolsPinned: true
            )
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
        let custom = CGRect(x: 100, y: 80, width: 1600, height: 900)
        XCTAssertEqual(
            TheaterWindowPlacement.resolvedFrame(
                stored: custom,
                visible: self.visible,
                presentation: .popup
            ),
            self.visible
        )
        XCTAssertEqual(
            TheaterWindowPlacement.resolvedFrame(
                stored: custom,
                visible: self.visible,
                presentation: .popup,
                keepUserSize: true
            ),
            custom
        )
    }

    func testOverlayCaptionBarBecomesAFullScreenPopup() {
        let bar = TheaterPositionPreset.captionBar.frame(in: self.visible)
        XCTAssertTrue(TheaterWindowPlacement.isOverlayCaptionBar(bar, visible: self.visible))
        XCTAssertFalse(
            TheaterWindowPlacement.isOverlayCaptionBar(
                CGRect(x: 80, y: 80, width: 1100, height: 440),
                visible: self.visible
            )
        )
        XCTAssertEqual(
            TheaterWindowPlacement.resolvedFrame(
                stored: bar,
                visible: self.visible,
                presentation: .popup
            ),
            self.visible
        )
        let lower = TheaterPositionPreset.lowerThird.frame(in: self.visible)
        XCTAssertTrue(TheaterWindowPlacement.isLowerThirdLeftover(lower, visible: self.visible))
        XCTAssertEqual(
            TheaterWindowPlacement.resolvedFrame(
                stored: lower,
                visible: self.visible,
                presentation: .popup
            ),
            self.visible
        )
        XCTAssertEqual(TheaterPositionPreset.captionBar.resolved(for: .popup), .fillScreen)
        XCTAssertEqual(TheaterPositionPreset.fillScreen.resolved(for: .transparent), .captionBar)
        XCTAssertEqual(TheaterPositionPreset.fillScreen.frame(in: self.visible), self.visible)
        XCTAssertTrue(TheaterPositionPreset.fillScreen.isAvailable(for: .popup))
        XCTAssertFalse(TheaterPositionPreset.fillScreen.isAvailable(for: .transparent))
        XCTAssertFalse(TheaterPositionPreset.captionBar.isAvailable(for: .popup))
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
        XCTAssertTrue(TheaterChromeHelp.board.hasPrefix("Settings —"))
        XCTAssertTrue(TheaterChromeHelp.smaller.hasPrefix("Smaller captions —"))
        XCTAssertTrue(TheaterChromeHelp.larger.hasPrefix("Larger captions —"))
        XCTAssertFalse(TheaterChromeHelp.smaller.contains("spoken line"))
        XCTAssertFalse(TheaterChromeHelp.larger.contains("spoken line"))
        XCTAssertTrue(TheaterChromeHelp.captionPlate.hasPrefix("Caption plate —"))
        XCTAssertEqual(
            TheaterChromeHelp.position(.captionBar),
            TheaterChromeHelp.captionBar
        )
        XCTAssertEqual(
            TheaterChromeHelp.position(.fillScreen),
            TheaterChromeHelp.fillScreen
        )
    }
}

@MainActor
final class TheaterMenuBarTests: XCTestCase {
    func testMenuBarListsOverlayTypography() {
        let menu = NSMenu()
        TheaterMenuBarController.appendOverlayControls(to: menu, target: TheaterMenuBarController.shared)
        let titles = menu.items.map(\.title)
        XCTAssertTrue(titles.contains("Larger Captions"))
        XCTAssertTrue(titles.contains("Smaller Captions"))
        XCTAssertTrue(titles.contains("Caption Font"))
        XCTAssertTrue(titles.contains("Theme"))
        XCTAssertTrue(titles.contains(TheaterReadiness.linePrintTitle))
        XCTAssertTrue(titles.contains(TheaterReadiness.printGapTitle))
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

    func testMenuBarDoesNotOfferAScreenShareToggle() {
        let menu = self.overlayMenu()
        XCTAssertNil(menu.items.first { $0.title == "Hide from Screen Share" })
        XCTAssertEqual(TheaterReadiness.screenShare.contains("Share the slides window"), true)
        XCTAssertEqual(TheaterReadiness.screenShare.contains("include these captions"), true)
    }

    func testMenuBarMinimizeFlipsToShowTheater() {
        let settings = SettingsStore.shared
        let previous = settings.theaterMinimized
        defer { settings.theaterMinimized = previous }
        let menu = self.overlayMenu()
        let minimize = TheaterMenuBarController.item(.minimize, in: menu)

        settings.theaterMinimized = true
        TheaterMenuBarController.applyState(to: menu)
        XCTAssertEqual(minimize?.title, "Expand Theater")
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

    func testMenuShortcutsMatchPresenterChords() {
        let menu = self.overlayMenu()
        let pairs: [(TheaterMenuBarController.ItemTag, TheaterPresenterHotkey.Action)] = [
            (.pause, .togglePause),
            (.overlayTools, .toggleTools),
            (.largerText, .fontLarger),
            (.smallerText, .fontSmaller),
            (.minimize, .toggleVisible),
            (.clear, .clear),
            (.copy, .copy),
            (.undo, .undo),
        ]
        for pair in pairs {
            let item = TheaterMenuBarController.item(pair.0, in: menu)
            XCTAssertEqual(item?.keyEquivalent, TheaterPresenterHotkey.keyEquivalent(for: pair.1), pair.1.rawValue)
            XCTAssertEqual(item?.keyEquivalentModifierMask, TheaterPresenterHotkey.modifiers, pair.1.rawValue)
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
            (TheaterChromeHelp.copyAll, "C", kVK_ANSI_C, .copy),
            (TheaterChromeHelp.undo, "Z", kVK_ANSI_Z, .undo),
            (TheaterChromeHelp.larger, "Equals", kVK_ANSI_Equal, .fontLarger),
            (TheaterChromeHelp.smaller, "Minus", kVK_ANSI_Minus, .fontSmaller),
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
        XCTAssertEqual(
            TheaterChromeHelp.captionFont(current: "System"),
            "Caption font — Typeface for spoken and Show-as. Now System."
        )
    }

    func testHoverHelpSitsBelowTheControl() {
        let origin = TheaterHoverHelp.bubbleOrigin(
            anchor: CGRect(x: 40, y: 20, width: 40, height: 40),
            container: CGSize(width: 800, height: 400),
            bubbleSize: CGSize(width: 200, height: 40)
        )
        XCTAssertEqual(origin.x, 40)
        XCTAssertEqual(origin.y, 68)
    }

    func testHoverHelpStaysOnTheBoardAtTheRightEdge() {
        let origin = TheaterHoverHelp.bubbleOrigin(
            anchor: CGRect(x: 760, y: 20, width: 40, height: 40),
            container: CGSize(width: 800, height: 400),
            bubbleSize: CGSize(width: 200, height: 40)
        )
        XCTAssertEqual(origin.x, 588)
        XCTAssertEqual(origin.y, 68)
    }

    func testHoverHelpFlipsAboveWhenTheBoardIsShort() {
        let origin = TheaterHoverHelp.bubbleOrigin(
            anchor: CGRect(x: 40, y: 80, width: 40, height: 40),
            container: CGSize(width: 800, height: 140),
            bubbleSize: CGSize(width: 200, height: 50)
        )
        XCTAssertEqual(origin.x, 40)
        XCTAssertEqual(origin.y, 22)
    }

    func testHoverHelpWidthFitsANarrowBoard() {
        XCTAssertEqual(TheaterHoverHelp.bubbleWidth(containerWidth: 200), 176)
        XCTAssertEqual(TheaterHoverHelp.bubbleWidth(containerWidth: 800), 280)
        XCTAssertEqual(TheaterHoverHelp.bubbleWidth(containerWidth: 20), 0)
    }

    @MainActor
    func testHoverHelpHideOnlyClearsTheMatchingLabel() {
        let broker = TheaterHoverHelpBroker()
        let copy = TheaterHoverHelpValue(text: TheaterChromeHelp.copyAll, anchor: .zero)
        broker.show(copy)
        broker.hide(text: TheaterChromeHelp.clear)
        XCTAssertEqual(broker.value, copy)
        broker.hide(text: TheaterChromeHelp.copyAll)
        XCTAssertNil(broker.value)
        broker.show(copy)
        broker.clear()
        XCTAssertNil(broker.value)
    }
}

final class TheaterCaptionScaleTests: XCTestCase {
    func testCaptionSizesGrowWithTheBoard() {
        let narrow = TheaterCaptionScale.sizes(setting: 42, stageWidth: 1100)
        let wide = TheaterCaptionScale.sizes(setting: 42, stageWidth: 1920)
        XCTAssertEqual(narrow.spoken, TheaterCaptionScale.spokenSize(setting: 42))
        XCTAssertEqual(narrow.translated, TheaterCaptionScale.translatedSize(setting: 42))
        XCTAssertGreaterThan(wide.translated, narrow.translated)
        XCTAssertGreaterThan(wide.spoken, narrow.spoken)
    }

    func testCaptionSizeShrinksWhenTheBoardIsShorterThanTheLine() {
        let proposed = TheaterCaptionScale.displaySize(setting: 42, stageWidth: 1920)
        let stageHeight: CGFloat = 140
        let fitted = TheaterCaptionScale.fittedDisplaySize(
            proposed: proposed,
            stageHeight: stageHeight
        ) { display in
            let spoken = TheaterCaptionScale.spokenSize(setting: display)
            let translated = TheaterCaptionScale.translatedSize(setting: display)
            return TheaterBilingualWrap.boardHeight(
                rows: [
                    TheaterBilingualWrap.Row(text: " ", isSpoken: false),
                    TheaterBilingualWrap.Row(text: " ", isSpoken: true)
                ],
                spokenFont: NSFont.systemFont(ofSize: spoken, weight: .semibold),
                translatedFont: NSFont.systemFont(ofSize: translated, weight: .semibold)
            )
        }
        XCTAssertLessThan(fitted, proposed)
        let height = TheaterBilingualWrap.boardHeight(
            rows: [
                TheaterBilingualWrap.Row(text: " ", isSpoken: false),
                TheaterBilingualWrap.Row(text: " ", isSpoken: true)
            ],
            spokenFont: NSFont.systemFont(
                ofSize: TheaterCaptionScale.spokenSize(setting: fitted),
                weight: .semibold
            ),
            translatedFont: NSFont.systemFont(
                ofSize: TheaterCaptionScale.translatedSize(setting: fitted),
                weight: .semibold
            )
        )
        XCTAssertLessThanOrEqual(height, stageHeight)
    }

    func testCaptionSizeStaysPutAcrossASmallMeasurementTick() {
        XCTAssertEqual(
            TheaterCaptionScale.resolvedDisplaySize(proposed: 42.4, locked: 42, lockedFits: true),
            42
        )
        XCTAssertEqual(
            TheaterCaptionScale.resolvedDisplaySize(proposed: 44, locked: 42, lockedFits: true),
            42
        )
        XCTAssertEqual(
            TheaterCaptionScale.resolvedDisplaySize(proposed: 36, locked: 42, lockedFits: true),
            36
        )
        XCTAssertEqual(
            TheaterCaptionScale.resolvedDisplaySize(proposed: 30, locked: 42, lockedFits: false),
            30
        )
        XCTAssertEqual(
            TheaterCaptionScale.resolvedDisplaySize(
                proposed: 50,
                locked: 42,
                lockedFits: true
            ),
            50
        )
    }
}
