import AppKit

class MenuBarIconGenerator {
    static func createMenuBarIcon() -> NSImage? {
        let size = TheaterMenuBarMark.pointSize
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.clear.set()
            rect.fill()
            TheaterMenuBarMark.draw(in: rect, color: .black)
            return true
        }
        image.isTemplate = true
        return image
    }
}
