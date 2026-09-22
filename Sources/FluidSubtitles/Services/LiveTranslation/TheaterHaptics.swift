import AppKit

/// Trackpad alignment click. Buttons stay still; the click is the press.
enum TheaterHaptics {
    static func alignment() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}
