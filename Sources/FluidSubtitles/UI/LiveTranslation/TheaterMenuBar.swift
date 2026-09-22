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

        func add(_ item: NSMenuItem, symbol: String? = nil) {
            item.target = target
            if let symbol {
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            }
            menu.addItem(item)
        }

        let pause = TheaterPresenterHotkey.menuItem(
            title: "Pause",
            action: #selector(togglePause),
            shortcut: .togglePause
        )
        pause.tag = ItemTag.pause.rawValue
        pause.toolTip = TheaterChromeHelp.pause
        add(pause, symbol: "pause.fill")

        let tools = TheaterPresenterHotkey.menuItem(
            title: "Show Overlay Tools",
            action: #selector(toggleOverlayTools),
            shortcut: .toggleTools
        )
        tools.tag = ItemTag.overlayTools.rawValue
        tools.toolTip = TheaterChromeHelp.overlayTools
        add(tools, symbol: "slider.horizontal.3")

        menu.addItem(.separator())

        let overlay = NSMenuItem(
            title: TheaterPresentationStyle.transparent.displayName,
            action: #selector(choosePresentation(_:)),
            keyEquivalent: ""
        )
        overlay.tag = ItemTag.overlayStyle.rawValue
        overlay.representedObject = TheaterPresentationStyle.transparent.rawValue
        overlay.toolTip = TheaterChromeHelp.overlay
        add(overlay, symbol: "rectangle.dashed")

        let popup = NSMenuItem(
            title: TheaterPresentationStyle.popup.displayName,
            action: #selector(choosePresentation(_:)),
            keyEquivalent: ""
        )
        popup.tag = ItemTag.popupStyle.rawValue
        popup.representedObject = TheaterPresentationStyle.popup.rawValue
        popup.toolTip = TheaterChromeHelp.popup
        add(popup, symbol: "rectangle.on.rectangle")

        let plate = NSMenuItem(
            title: "Caption Plate",
            action: #selector(toggleCaptionPlate),
            keyEquivalent: ""
        )
        plate.tag = ItemTag.captionPlate.rawValue
        plate.toolTip = TheaterChromeHelp.captionPlate
        add(plate, symbol: "rectangle.fill")

        let share = NSMenuItem(
            title: "Hide from Screen Share",
            action: #selector(toggleHideFromScreenShare),
            keyEquivalent: ""
        )
        share.tag = ItemTag.hideShare.rawValue
        share.toolTip = TheaterChromeHelp.hideFromScreenShare
        add(share, symbol: "eye.slash")

        menu.addItem(.separator())

        let larger = TheaterPresenterHotkey.menuItem(
            title: "Larger Captions",
            action: #selector(makeTextLarger),
            shortcut: .fontLarger
        )
        larger.tag = ItemTag.largerText.rawValue
        larger.toolTip = TheaterChromeHelp.larger
        add(larger, symbol: "plus")

        let smaller = TheaterPresenterHotkey.menuItem(
            title: "Smaller Captions",
            action: #selector(makeTextSmaller),
            shortcut: .fontSmaller
        )
        smaller.tag = ItemTag.smallerText.rawValue
        smaller.toolTip = TheaterChromeHelp.smaller
        add(smaller, symbol: "minus")

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
        fontItem.image = NSImage(systemSymbolName: "textformat", accessibilityDescription: nil)
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

        let spokenMenu = NSMenu(title: "Spoken Line")
        for mode in TheaterSpokenLineMode.allCases {
            let item = NSMenuItem(
                title: mode.displayName,
                action: #selector(chooseSpokenLineMode(_:)),
                keyEquivalent: ""
            )
            item.representedObject = mode.rawValue
            item.toolTip = mode.help
            item.target = target
            spokenMenu.addItem(item)
        }
        let spoken = NSMenuItem(title: "Spoken Line", action: nil, keyEquivalent: "")
        spoken.tag = ItemTag.spokenLine.rawValue
        spoken.submenu = spokenMenu
        spoken.toolTip = TheaterChromeHelp.spokenLine
        add(spoken, symbol: "captions.bubble")

        let contrast = NSMenuItem(
            title: "High Contrast",
            action: #selector(toggleHighContrast),
            keyEquivalent: ""
        )
        contrast.tag = ItemTag.highContrast.rawValue
        contrast.toolTip = TheaterChromeHelp.highContrast
        add(contrast, symbol: "circle.lefthalf.filled")

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

        let minimize = TheaterPresenterHotkey.menuItem(
            title: "Minimize Theater",
            action: #selector(toggleMinimized),
            shortcut: .toggleVisible
        )
        minimize.tag = ItemTag.minimize.rawValue
        minimize.toolTip = TheaterChromeHelp.minimize
        add(minimize, symbol: "arrow.down.right.and.arrow.up.left")

        let copy = TheaterPresenterHotkey.menuItem(
            title: "Copy All",
            action: #selector(copyAll),
            shortcut: .copy
        )
        copy.tag = ItemTag.copy.rawValue
        copy.toolTip = TheaterChromeHelp.copyAll
        add(copy, symbol: "doc.on.doc")

        // Overlay users can type captions without pinning the tools.
        let insert = NSMenuItem(
            title: "Type into App",
            action: #selector(typeIntoApp),
            keyEquivalent: ""
        )
        insert.tag = ItemTag.insert.rawValue
        insert.toolTip = TheaterChromeHelp.insert
        add(insert, symbol: "text.cursor")

        let undo = TheaterPresenterHotkey.menuItem(
            title: "Undo Last Caption",
            action: #selector(undoLast),
            shortcut: .undo
        )
        undo.tag = ItemTag.undo.rawValue
        undo.toolTip = TheaterChromeHelp.undo
        add(undo, symbol: "arrow.uturn.backward")

        let clear = TheaterPresenterHotkey.menuItem(
            title: "Clear Captions",
            action: #selector(clearCaptions),
            shortcut: .clear
        )
        clear.tag = ItemTag.clear.rawValue
        clear.toolTip = TheaterChromeHelp.clear
        add(clear, symbol: "trash")
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
        spoken?.isEnabled = !sameLanguage
        spoken?.submenu?.items.forEach { $0.isEnabled = !sameLanguage }

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
            title: "Spoken Line",
            selected: settings.theaterSpokenLineMode.rawValue
        )
        applySubmenuState(
            in: menu,
            title: "Position",
            selected: settings.theaterPositionPreset?.rawValue
        )
        if let parent = menu.items.first(where: { $0.title == "Position" }),
           let submenu = parent.submenu
        {
            let presentation = settings.theaterPresentation
            for item in submenu.items {
                guard let raw = item.representedObject as? String,
                      let preset = TheaterPositionPreset(rawValue: raw)
                else { continue }
                item.isHidden = !preset.isAvailable(for: presentation)
            }
        }
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

    @objc private func chooseSpokenLineMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        SettingsStore.shared.theaterSpokenLineMode = TheaterSpokenLineMode.resolved(raw)
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
