import AppKit
import Carbon

/// Fixed Control+Option chords for presenting: the slide app keeps focus.
enum TheaterPresenterHotkey {
    enum Action: String, Equatable {
        case toggleVisible
        case togglePause
        case clear
        case copy
        case undo
        case fontLarger
        case fontSmaller
        case toggleTools
        case listen
        case retry

        var repeats: Bool {
            self == .fontLarger || self == .fontSmaller
        }
    }

    static let modifiers: NSEvent.ModifierFlags = [.control, .option]
    static let fontStep = 2

    /// Menu key equivalent for the same Control+Option chord `action` matches.
    static func keyEquivalent(for action: Action) -> String {
        switch action {
        case .toggleVisible: return "h"
        case .togglePause: return "p"
        case .clear: return "k"
        case .copy: return "c"
        case .undo: return "z"
        case .fontLarger: return "="
        case .fontSmaller: return "-"
        case .toggleTools: return "t"
        case .listen: return "l"
        case .retry: return "r"
        }
    }

    static func menuItem(title: String, action: Selector, shortcut: Action) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: self.keyEquivalent(for: shortcut))
        item.keyEquivalentModifierMask = self.modifiers
        return item
    }

    static func action(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Action? {
        let relevant = modifiers.intersection([.control, .option, .command, .shift])
        guard relevant == Self.modifiers else { return nil }
        switch Int(keyCode) {
        case kVK_ANSI_H: return .toggleVisible
        case kVK_ANSI_P: return .togglePause
        case kVK_ANSI_K: return .clear
        case kVK_ANSI_C: return .copy
        case kVK_ANSI_Z: return .undo
        case kVK_ANSI_Equal: return .fontLarger
        case kVK_ANSI_Minus: return .fontSmaller
        case kVK_ANSI_T: return .toggleTools
        case kVK_ANSI_L: return .listen
        case kVK_ANSI_R: return .retry
        default: return nil
        }
    }

    @MainActor
    static func perform(_ action: Action) {
        let controller = LiveTranslationController.shared
        let settings = SettingsStore.shared
        switch action {
        case .toggleVisible:
            if settings.theaterMinimized {
                PresenterCaptionController.shared.show()
            } else {
                PresenterCaptionController.shared.toggleMinimized()
            }
        case .togglePause:
            if controller.isPaused {
                controller.resumeListening()
            } else {
                controller.pauseListening()
            }
        case .clear:
            controller.clearBoard()
        case .copy:
            controller.copyCaptionText()
        case .undo:
            controller.undoLastCaption()
        case .fontLarger:
            settings.presenterFontSize += Self.fontStep
        case .fontSmaller:
            settings.presenterFontSize -= Self.fontStep
        case .toggleTools:
            PresenterCaptionController.shared.toggleOverlayToolsPinned()
        case .retry:
            controller.retryFailedTranslation()
        case .listen:
            // Routed through GlobalHotkeyManager.triggerCaptionListen so the
            // Listen ready gate and dictation-busy check still apply.
            assertionFailure("Route .listen through GlobalHotkeyManager.triggerCaptionListen")
        }
    }
}
