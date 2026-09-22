import Foundation

/// Shortcut insert types this Listen into the app captured at start.
/// Fluid becoming frontmost on Stop must not drop that text.
enum TheaterInsertDelivery {
    static let needsAnotherAppCopy =
        "Click into another app, then use Listen and type."

    static func shouldTypeCurrentListen(
        text: String,
        targetBundleID: String?,
        selfBundleID: String?
    ) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        guard let targetBundleID else { return false }
        if let selfBundleID, targetBundleID == selfBundleID {
            return false
        }
        return true
    }
}
