import AppKit

class MenuBarIconGenerator {
    static func createMenuBarIcon() -> NSImage? {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.clear.set()
            rect.fill()

            NSColor.black.setFill()
            let top = NSRect(x: 1.5, y: 9.4, width: 11.2, height: 6.2)
            let bottom = NSRect(x: 5.3, y: 2.2, width: 11.2, height: 6.2)
            NSBezierPath(roundedRect: top, xRadius: 2.4, yRadius: 2.4).fill()
            NSBezierPath(roundedRect: bottom, xRadius: 2.4, yRadius: 2.4).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
