import AppKit

/// Overlay is text on slides. Pop-up is a boxed board.
/// Idle Overlay hides chrome and click-through; pinned Overlay shows tools.
enum TheaterOverlayPolicy {
    static let overlayMinSize = NSSize(width: 480, height: 140)
    static let popupMinSize = NSSize(width: 640, height: 260)
    static let plateHorizontalInset: CGFloat = 10
    static let plateVerticalInset: CGFloat = 3
    static let plateCornerRadius: CGFloat = 8
    static let plateFillAlpha: CGFloat = 0.58

    static func isOverlay(_ presentation: TheaterPresentationStyle) -> Bool {
        presentation == .transparent
    }

    static func hidesAllChrome(
        presentation: TheaterPresentationStyle,
        toolsPinned: Bool
    ) -> Bool {
        Self.isOverlay(presentation) && !toolsPinned
    }

    static func usesCaptionsOnlyChrome(
        presentation: TheaterPresentationStyle,
        hideChrome: Bool
    ) -> Bool {
        presentation == .popup && hideChrome
    }

    /// Resting layout. Pop-up keeps the shelf. Captions only and idle Overlay
    /// give that room to the text until tools are actually showing. A visible
    /// shelf, including hover tools, still insets the board so a line cannot
    /// draw under the buttons.
    static func reservesToolBarSlot(
        presentation: TheaterPresentationStyle,
        hideChrome: Bool,
        toolsPinned: Bool = false
    ) -> Bool {
        if presentation == .transparent {
            return toolsPinned
        }
        return !hideChrome
    }

    static func ignoresMouseEvents(
        presentation: TheaterPresentationStyle,
        toolsPinned: Bool,
        minimized: Bool
    ) -> Bool {
        !minimized && Self.hidesAllChrome(presentation: presentation, toolsPinned: toolsPinned)
    }

    /// Pop-up keeps a window shadow. Overlay is text on the slide, so it does not.
    static func showsWindowShadow(presentation: TheaterPresentationStyle) -> Bool {
        !Self.isOverlay(presentation)
    }

    static func hidesTitlebarButtons(
        presentation: TheaterPresentationStyle,
        toolsPinned: Bool,
        hideChrome: Bool = false
    ) -> Bool {
        if Self.hidesAllChrome(presentation: presentation, toolsPinned: toolsPinned) {
            return true
        }
        return Self.usesCaptionsOnlyChrome(presentation: presentation, hideChrome: hideChrome)
    }

    static func movableByBackground(
        presentation: TheaterPresentationStyle,
        toolsPinned: Bool,
        minimized: Bool
    ) -> Bool {
        if minimized { return false }
        if presentation == .popup { return true }
        return toolsPinned
    }

    static func minSize(for presentation: TheaterPresentationStyle) -> NSSize {
        Self.isOverlay(presentation) ? Self.overlayMinSize : Self.popupMinSize
    }

    static func shouldClearPin(
        presentation: TheaterPresentationStyle,
        minimized: Bool,
        windowEnabled: Bool
    ) -> Bool {
        presentation == .popup || minimized || !windowEnabled
    }

    static func showsCaptionPlate(
        presentation: TheaterPresentationStyle,
        backingBar: Bool
    ) -> Bool {
        Self.isOverlay(presentation) && backingBar
    }

    static func plateColor() -> NSColor {
        NSColor.black.withAlphaComponent(Self.plateFillAlpha)
    }

    /// Overlay stays over slides. Pop-up only floats when another app is
    /// front, so Home and Settings can sit on top of the boxed board.
    static func windowLevel(
        presentation: TheaterPresentationStyle,
        appIsActive: Bool
    ) -> NSWindow.Level {
        if presentation == .transparent { return .floating }
        return appIsActive ? .normal : .floating
    }

    static func isFloatingPanel(
        presentation: TheaterPresentationStyle,
        appIsActive: Bool
    ) -> Bool {
        Self.windowLevel(presentation: presentation, appIsActive: appIsActive) == .floating
    }
}
