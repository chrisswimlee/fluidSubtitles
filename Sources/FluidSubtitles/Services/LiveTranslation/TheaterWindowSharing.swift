import AppKit

/// Theater stays in screenshots and screen share.
///
/// `NSWindow.SharingType.none` is a legacy flag. On current macOS it does not
/// hide a window from ScreenCaptureKit, and a board that fills the display
/// makes the screenshot come back empty. That empty capture is what was
/// blocking screenshots of the captions.
enum TheaterWindowSharing {
    static func sharingType() -> NSWindow.SharingType {
        .readOnly
    }

    static func apply(_ window: NSWindow) {
        let next = self.sharingType()
        if window.sharingType != next {
            window.sharingType = next
        }
    }
}
