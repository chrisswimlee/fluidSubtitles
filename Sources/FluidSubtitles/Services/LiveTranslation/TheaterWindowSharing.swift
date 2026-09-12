import AppKit

/// Maps the Theater capture toggle to `NSWindow.sharingType`.
enum TheaterWindowSharing {
    static func sharingType(hideFromScreenShare: Bool) -> NSWindow.SharingType {
        hideFromScreenShare ? .none : .readOnly
    }

    static func apply(_ window: NSWindow, hideFromScreenShare: Bool) {
        let next = self.sharingType(hideFromScreenShare: hideFromScreenShare)
        if window.sharingType != next {
            window.sharingType = next
        }
    }
}
