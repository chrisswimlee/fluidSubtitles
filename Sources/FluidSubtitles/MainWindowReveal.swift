import AppKit

/// Finds the SwiftUI shell window and orders it in front of other apps.
enum MainWindowReveal {
    static let identifier = "fluidSubtitles.main"

    static func matchesTitle(_ title: String) -> Bool {
        if title.localizedCaseInsensitiveContains("theater") { return false }
        return title == FluidProduct.displayName
    }

    static func isMainWindow(_ window: NSWindow) -> Bool {
        if window.identifier?.rawValue == Self.identifier { return true }
        guard window.level == .normal else { return false }
        guard window.styleMask.contains(.titled) else { return false }
        guard !(window is NSPanel) else { return false }
        return Self.matchesTitle(window.title)
    }

    static func preferred(in windows: [NSWindow]) -> NSWindow? {
        let matches = windows.filter(self.isMainWindow)
        if let marked = matches.first(where: { $0.identifier?.rawValue == Self.identifier }) {
            return marked
        }
        return matches.first { $0.title == FluidProduct.displayName } ?? matches.first
    }

    static func mark(_ window: NSWindow?) {
        guard let window, window.identifier?.rawValue != Self.identifier else { return }
        window.identifier = NSUserInterfaceItemIdentifier(Self.identifier)
    }

    /// Puts the shell window in front without moving it to another Space.
    /// `moveToActiveSpace` was hiding the window for the whole run; it came
    /// back only when the app was deactivated.
    @discardableResult
    static func bringToFront(_ window: NSWindow) -> Bool {
        if window.alphaValue <= 0.01 {
            window.alphaValue = 1
        }
        self.pullOntoAConnectedScreen(window)
        NSApp.unhide(nil)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        return window.isVisible && window.alphaValue > 0.01
    }

    private static func pullOntoAConnectedScreen(_ window: NSWindow) {
        let frame = window.frame
        let center = NSPoint(x: frame.midX, y: frame.midY)
        if NSScreen.screens.contains(where: { $0.frame.contains(center) }) { return }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let size = NSSize(
            width: min(1000, screen.visibleFrame.width),
            height: min(700, screen.visibleFrame.height)
        )
        let origin = NSPoint(
            x: screen.visibleFrame.midX - size.width / 2,
            y: screen.visibleFrame.midY - size.height / 2
        )
        window.setFrame(NSRect(origin: origin, size: size), display: false)
    }
}
