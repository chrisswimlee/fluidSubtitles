import AppKit

/// Theater controls on the menu-bar icon. Overlay is click-through, so font,
/// size, plate, and board style must live here — not only on the window.
@MainActor
final class TheaterMenuBarController: NSObject {
    static let shared = TheaterMenuBarController()

    weak var menu: NSMenu?

    enum ItemTag: Int {
        case pause = 2100
        case overlayStyle
        case popupStyle
        case overlayTools
        case captionPlate
        case hideShare
        case largerText
        case smallerText
        case sizeLabel
        case spokenLine
        case highContrast
        case minimize
        case copy
        case insert
        case undo
        case clear
    }

    static func appendOverlayControls(to menu: NSMenu, target: TheaterMenuBarController) {
        menu.addItem(.separator())

        func add(_ item: NSMenuItem) {
            item.target = target
            menu.addItem(item)
        }

        let pause = NSMenuItem(
            title: "Pause",
            action: #selector(togglePause),
            keyEquivalent: ""
        )
        pause.tag = ItemTag.pause.rawValue
        pause.toolTip = TheaterChromeHelp.pause
        add(pause)

        let tools = NSMenuItem(
            title: "Show Overlay Tools",
            action: #selector(toggleOverlayTools),
            keyEquivalent: ""
        )
        tools.tag = ItemTag.overlayTools.rawValue
        tools.toolTip = TheaterChromeHelp.overlayTools
        add(tools)

        menu.addItem(.separator())

        let overlay = NSMenuItem(
            title: TheaterPresentationStyle.transparent.displayName,
            action: #selector(choosePresentation(_:)),
            keyEquivalent: ""
        )
        overlay.tag = ItemTag.overlayStyle.rawValue
        overlay.representedObject = TheaterPresentationStyle.transparent.rawValue
        overlay.toolTip = TheaterChromeHelp.overlay
        add(overlay)

        let popup = NSMenuItem(
            title: TheaterPresentationStyle.popup.displayName,
            action: #selector(choosePresentation(_:)),
            keyEquivalent: ""
        )
        popup.tag = ItemTag.popupStyle.rawValue
        popup.representedObject = TheaterPresentationStyle.popup.rawValue
        popup.toolTip = TheaterChromeHelp.popup
        add(popup)

        let plate = NSMenuItem(
            title: "Caption Plate",
            action: #selector(toggleCaptionPlate),
            keyEquivalent: ""
        )
        plate.tag = ItemTag.captionPlate.rawValue
        plate.toolTip = TheaterChromeHelp.captionPlate
        add(plate)

        let share = NSMenuItem(
            title: "Hide from Screen Share",
            action: #selector(toggleHideFromScreenShare),
            keyEquivalent: ""
        )
        share.tag = ItemTag.hideShare.rawValue
        share.toolTip = TheaterChromeHelp.hideFromScreenShare
        add(share)

        menu.addItem(.separator())

        let larger = NSMenuItem(
            title: "Larger Text",
            action: #selector(makeTextLarger),
            keyEquivalent: ""
        )
        larger.tag = ItemTag.largerText.rawValue
        larger.toolTip = TheaterChromeHelp.larger
        add(larger)

        let smaller = NSMenuItem(
            title: "Smaller Text",
            action: #selector(makeTextSmaller),
            keyEquivalent: ""
        )
        smaller.tag = ItemTag.smallerText.rawValue
        smaller.toolTip = TheaterChromeHelp.smaller
        add(smaller)

        let size = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        size.tag = ItemTag.sizeLabel.rawValue
        size.isEnabled = false
        menu.addItem(size)

        let fontMenu = NSMenu(title: "Caption Font")
        for face in TheaterTypeface.allCases {
            let item = NSMenuItem(
                title: face.displayName,
                action: #selector(chooseFont(_:)),
                keyEquivalent: ""
            )
            item.representedObject = face.rawValue
            item.toolTip = TheaterChromeHelp.captionFont
            item.target = target
            fontMenu.addItem(item)
        }
        let fontItem = NSMenuItem(title: "Caption Font", action: nil, keyEquivalent: "")
        fontItem.submenu = fontMenu
        fontItem.toolTip = TheaterChromeHelp.captionFont
        menu.addItem(fontItem)

        let themeMenu = NSMenu(title: "Theme")
        for appearance in TheaterAppearance.allCases {
            let item = NSMenuItem(
                title: appearance.displayName,
                action: #selector(chooseTheme(_:)),
                keyEquivalent: ""
            )
            item.representedObject = appearance.rawValue
            item.toolTip = TheaterChromeHelp.theme
            item.target = target
            themeMenu.addItem(item)
        }
        let themeItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        themeItem.submenu = themeMenu
        themeItem.toolTip = TheaterChromeHelp.theme
        menu.addItem(themeItem)

        menu.addItem(.separator())

        let spoken = NSMenuItem(
            title: "Show the Spoken Line",
            action: #selector(toggleSpokenLine),
            keyEquivalent: ""
        )
        spoken.tag = ItemTag.spokenLine.rawValue
        spoken.toolTip = TheaterChromeHelp.spokenLine
        add(spoken)

        let printMenu = NSMenu(title: "Caption Print-in")
        for style in TheaterCaptionPrintStyle.allCases {
            let item = NSMenuItem(
                title: style.displayName,
                action: #selector(choosePrintStyle(_:)),
                keyEquivalent: ""
            )
            item.representedObject = style.rawValue
            item.toolTip = style.help
            item.target = target
            printMenu.addItem(item)
        }
        let printItem = NSMenuItem(title: "Caption Print-in", action: nil, keyEquivalent: "")
        printItem.submenu = printMenu
        printItem.toolTip = TheaterChromeHelp.printIn
        menu.addItem(printItem)

        let contrast = NSMenuItem(
            title: "High Contrast",
            action: #selector(toggleHighContrast),
            keyEquivalent: ""
        )
        contrast.tag = ItemTag.highContrast.rawValue
        contrast.toolTip = TheaterChromeHelp.highContrast
        add(contrast)

        let positionMenu = NSMenu(title: "Position")
        for preset in TheaterPositionPreset.allCases {
            let item = NSMenuItem(
                title: preset.displayName,
                action: #selector(choosePosition(_:)),
                keyEquivalent: ""
            )
            item.representedObject = preset.rawValue
            item.toolTip = TheaterChromeHelp.position(preset)
            item.target = target
            positionMenu.addItem(item)
        }
        let positionItem = NSMenuItem(title: "Position", action: nil, keyEquivalent: "")
        positionItem.submenu = positionMenu
        menu.addItem(positionItem)

        menu.addItem(.separator())

        let minimize = NSMenuItem(
            title: "Minimize Theater",
            action: #selector(toggleMinimized),
            keyEquivalent: ""
        )
        minimize.tag = ItemTag.minimize.rawValue
        minimize.toolTip = TheaterChromeHelp.minimize
        add(minimize)

        let copy = NSMenuItem(
            title: "Copy All",
            action: #selector(copyAll),
            keyEquivalent: ""
        )
        copy.tag = ItemTag.copy.rawValue
        copy.toolTip = TheaterChromeHelp.copyAll
        add(copy)

        // Overlay users can type captions without pinning the tools.
        let insert = NSMenuItem(
            title: "Type into App",
            action: #selector(typeIntoApp),
            keyEquivalent: ""
        )
        insert.tag = ItemTag.insert.rawValue
        insert.toolTip = TheaterChromeHelp.insert
        add(insert)

        let undo = NSMenuItem(
            title: "Undo Last Caption",
            action: #selector(undoLast),
            keyEquivalent: ""
        )
        undo.tag = ItemTag.undo.rawValue
        undo.toolTip = TheaterChromeHelp.undo
        add(undo)

        let clear = NSMenuItem(
            title: "Clear Captions",
            action: #selector(clearCaptions),
            keyEquivalent: ""
        )
        clear.tag = ItemTag.clear.rawValue
        clear.toolTip = TheaterChromeHelp.clear
        add(clear)
    }

    func install(into menu: NSMenu) {
        Self.appendOverlayControls(to: menu, target: self)
        self.menu = menu
        Self.applyState(to: menu)
    }

    func refresh() {
        guard let menu else { return }
        Self.applyState(to: menu)
    }

    static func applyState(to menu: NSMenu) {
        let settings = SettingsStore.shared
        let controller = LiveTranslationController.shared
        let isOverlay = settings.theaterPresentation == .transparent
        let isListening = controller.isSessionActive && controller.listenKind == .captions
        let windowOpen = settings.theaterWindowEnabled
        let size = settings.presenterFontSize
        let range = SettingsStore.presenterFontSizeRange

        item(ItemTag.pause, in: menu)?.title = controller.isPaused ? "Resume" : "Pause"
        item(ItemTag.pause, in: menu)?.isEnabled = isListening
        item(ItemTag.pause, in: menu)?.toolTip = controller.isPaused
            ? TheaterChromeHelp.resume
            : TheaterChromeHelp.pause

        item(ItemTag.overlayStyle, in: menu)?.state = isOverlay ? .on : .off
        item(ItemTag.popupStyle, in: menu)?.state = isOverlay ? .off : .on

        let pinned = PresenterCaptionController.shared.overlayToolsPinned
        let tools = item(ItemTag.overlayTools, in: menu)
        tools?.title = pinned ? "Hide Overlay Tools" : "Show Overlay Tools"
        tools?.state = pinned ? .on : .off
        tools?.isEnabled = windowOpen && isOverlay && !settings.theaterMinimized

        let plate = item(ItemTag.captionPlate, in: menu)
        plate?.state = settings.theaterBackingBar ? .on : .off
        plate?.isEnabled = isOverlay

        let share = item(ItemTag.hideShare, in: menu)
        share?.state = settings.theaterHideFromScreenShare ? .on : .off
        share?.title = settings.theaterHideFromScreenShare
            ? "Hide from Screen Share — \(TheaterReadiness.hiddenFromZoomBadge)"
            : "Hide from Screen Share"

        item(ItemTag.largerText, in: menu)?.isEnabled = size < range.upperBound
        item(ItemTag.smallerText, in: menu)?.isEnabled = size > range.lowerBound
        item(ItemTag.sizeLabel, in: menu)?.title = "Size \(size) pt"

        let sameLanguage = SpokenLanguageResolver.isSameLanguagePair()
        let spoken = item(ItemTag.spokenLine, in: menu)
        spoken?.state = settings.translationShowSource ? .on : .off
        spoken?.isEnabled = !sameLanguage

        item(ItemTag.highContrast, in: menu)?.state = settings.theaterHighContrast ? .on : .off

        let minimize = item(ItemTag.minimize, in: menu)
        minimize?.title = settings.theaterMinimized ? "Show Theater" : "Minimize Theater"
        minimize?.isEnabled = windowOpen
        minimize?.toolTip = settings.theaterMinimized ? TheaterChromeHelp.expand : TheaterChromeHelp.minimize

        item(ItemTag.copy, in: menu)?.isEnabled = PresenterCaptionController.shared.hasDeliverableText
        let insertItem = item(ItemTag.insert, in: menu)
        let hasUntyped = PresenterCaptionController.shared.isEditing
            ? PresenterCaptionController.shared.hasDeliverableText
            : controller.subscriber.hasPendingInsertText
        insertItem?.isEnabled = hasUntyped
        insertItem?.toolTip = !hasUntyped && PresenterCaptionController.shared.hasDeliverableText
            ? TheaterReadiness.insertAlreadyTyped
            : TheaterChromeHelp.insert
        item(ItemTag.undo, in: menu)?.isEnabled = controller.hasUndoableCaption
        item(ItemTag.clear, in: menu)?.isEnabled = controller.hasClearableBoard

        applySubmenuState(
            in: menu,
            title: "Caption Font",
            selected: TheaterTypeface.resolved(settings.presenterFontFamily).rawValue
        )
        applySubmenuState(
            in: menu,
            title: "Theme",
            selected: TheaterAppearance.resolved(settings.theaterAppearance).rawValue
        )
        applySubmenuState(
            in: menu,
            title: "Caption Print-in",
            selected: settings.theaterCaptionPrintStyle.rawValue
        )
        applySubmenuState(
            in: menu,
            title: "Position",
            selected: settings.theaterPositionPreset?.rawValue
        )
    }

    static func item(_ tag: ItemTag, in menu: NSMenu) -> NSMenuItem? {
        menu.item(withTag: tag.rawValue)
    }

    static func applySubmenuState(in menu: NSMenu, title: String, selected: String?) {
        guard let parent = menu.items.first(where: { $0.title == title }),
              let submenu = parent.submenu
        else { return }
        for item in submenu.items {
            let value = item.representedObject as? String
            item.state = value == selected ? .on : .off
        }
    }

    @objc private func togglePause() {
        TheaterPresenterHotkey.perform(.togglePause)
        self.refresh()
    }

    @objc private func toggleOverlayTools() {
        PresenterCaptionController.shared.toggleOverlayToolsPinned()
        self.refresh()
    }

    @objc private func choosePresentation(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        SettingsStore.shared.theaterPresentationStyle = raw
        self.refresh()
    }

    @objc private func toggleCaptionPlate() {
        SettingsStore.shared.theaterBackingBar.toggle()
        self.refresh()
    }

    @objc private func toggleHideFromScreenShare() {
        SettingsStore.shared.theaterHideFromScreenShare.toggle()
        self.refresh()
    }

    @objc private func makeTextLarger() {
        TheaterPresenterHotkey.perform(.fontLarger)
        self.refresh()
    }

    @objc private func makeTextSmaller() {
        TheaterPresenterHotkey.perform(.fontSmaller)
        self.refresh()
    }

    @objc private func chooseFont(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        SettingsStore.shared.presenterFontFamily = raw
        self.refresh()
    }

    @objc private func chooseTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        SettingsStore.shared.theaterAppearance = raw
        self.refresh()
    }

    @objc private func toggleSpokenLine() {
        SettingsStore.shared.translationShowSource.toggle()
        self.refresh()
    }

    @objc private func choosePrintStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        SettingsStore.shared.theaterCaptionPrintStyle = TheaterCaptionPrintStyle.resolved(raw)
        self.refresh()
    }

    @objc private func toggleHighContrast() {
        SettingsStore.shared.theaterHighContrast.toggle()
        self.refresh()
    }

    @objc private func choosePosition(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let preset = TheaterPositionPreset(rawValue: raw)
        else { return }
        PresenterCaptionController.shared.applyPositionPreset(preset)
        self.refresh()
    }

    @objc private func toggleMinimized() {
        TheaterPresenterHotkey.perform(.toggleVisible)
        self.refresh()
    }

    @objc private func copyAll() {
        LiveTranslationController.shared.copyCaptionText()
    }

    @objc private func typeIntoApp() {
        LiveTranslationController.shared.insertCaptionText()
        self.refresh()
    }

    @objc private func undoLast() {
        LiveTranslationController.shared.undoLastCaption()
        self.refresh()
    }

    @objc private func clearCaptions() {
        LiveTranslationController.shared.clearBoard()
        self.refresh()
    }
}
