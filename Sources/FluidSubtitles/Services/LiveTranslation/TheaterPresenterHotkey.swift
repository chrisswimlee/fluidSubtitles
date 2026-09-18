import AppKit
import Carbon

/// Fixed Control+Option chords for presenting: the slide app keeps focus.
enum TheaterPresenterHotkey {
    enum Action: String, Equatable {
        case toggleVisible
        case togglePause
        case clear
        case fontLarger
        case fontSmaller

        var repeats: Bool {
            self == .fontLarger || self == .fontSmaller
        }
    }

    static let modifiers: NSEvent.ModifierFlags = [.control, .option]
    static let fontStep = 2

    static func action(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Action? {
        let relevant = modifiers.intersection([.control, .option, .command, .shift])
        guard relevant == Self.modifiers else { return nil }
        switch Int(keyCode) {
        case kVK_ANSI_H: return .toggleVisible
        case kVK_ANSI_P: return .togglePause
        case kVK_ANSI_K: return .clear
        case kVK_ANSI_Equal: return .fontLarger
        case kVK_ANSI_Minus: return .fontSmaller
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
        case .fontLarger:
            settings.presenterFontSize += Self.fontStep
        case .fontSmaller:
            settings.presenterFontSize -= Self.fontStep
        }
    }
}
