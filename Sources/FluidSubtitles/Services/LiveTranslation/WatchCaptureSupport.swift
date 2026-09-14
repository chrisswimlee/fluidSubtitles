import AppKit
import Foundation

enum WatchCaptureStop {
    static let fallbackCopy = "That app had no audio. Capturing this Mac instead."
    static let waitingCopy =
        "Waiting for audio from that app. Play the video, or switch Capture to This Mac."
    static let helperHonestyCopy =
        "This Mac hears the system mix and is the default. Safari includes every WebKit process, so Mail, Slack, and other WKWebView audio can ride along. Chrome helpers mix every Chrome tab, not one. A virtual or aggregate output can loop that mix; Watch then tightens the howl gate."

    /// A silent app at Listen start is not a reason to capture This Mac.
    /// The video may not have started yet.
    static func shouldFallbackToThisMacOnSilence() -> Bool { false }

    static func shouldNotifyUser(intentionalStop: Bool, alreadyReported: Bool) -> Bool {
        !intentionalStop && !alreadyReported
    }

    static func userFacingStatus(_ message: String) -> String {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "Capture stopped." }
        let folded = text.lowercased()
        if folded.contains("target app closed")
            || (folded.contains("app") && (folded.contains("closed") || folded.contains("terminated")))
        {
            return "Target app closed."
        }
        return text
    }
}

enum TheaterKeyPolicy {
    /// Chrome may take key. Hold it only while the caption editor is open.
    static func shouldRestoreExternalApp(isEditing: Bool) -> Bool {
        !isEditing
    }
}

struct WatchCaptureApp: Identifiable, Hashable {
    var id: String
    var title: String
}

enum WatchSourceSettings {
    static func selectedBundleID(_ settings: SettingsStore) -> String {
        if settings.theaterWatchTarget == .app {
            return settings.theaterWatchAppBundleID
        }
        return ""
    }

    @discardableResult
    static func apply(_ bundleID: String, to settings: SettingsStore) -> Bool {
        let previous = self.selectedBundleID(settings)
        if bundleID.isEmpty {
            settings.theaterWatchTarget = .thisMac
            settings.theaterWatchAppBundleID = ""
        } else {
            settings.theaterWatchTarget = .app
            settings.theaterWatchAppBundleID = bundleID
        }
        return bundleID != previous
    }

    static func displayTitle(_ settings: SettingsStore) -> String {
        let bundleID = self.selectedBundleID(settings)
        return bundleID.isEmpty ? "This Mac" : WatchAppCatalog.title(for: bundleID)
    }
}

/// Start-time ScreenCaptureKit filter only. Does not start extra ASR or streams.
enum WatchAppInclusion {
    static func matches(candidateBundleID: String, targetBundleID: String) -> Bool {
        let candidate = candidateBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = targetBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, !target.isEmpty else { return false }
        if candidate == target || candidate.hasPrefix(target + ".") {
            return true
        }
        return self.familyPrefixes(for: target).contains { prefix in
            candidate == prefix || candidate.hasPrefix(prefix + ".")
        }
    }

    static func familyPrefixes(for bundleID: String) -> [String] {
        let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        var prefixes = [id]
        if id == "com.apple.Safari"
            || id.hasPrefix("com.apple.Safari.")
            || id == "com.apple.SafariTechnologyPreview"
        {
            prefixes.append("com.apple.WebKit")
        }
        if id.hasPrefix("org.mozilla.firefox") {
            prefixes.append("org.mozilla.firefox")
            prefixes.append("org.mozilla.plugincontainer")
        }
        return prefixes
    }

    static func includedBundleIDs(targetBundleID: String, candidates: [String]) -> [String] {
        candidates.filter { self.matches(candidateBundleID: $0, targetBundleID: targetBundleID) }
    }
}

enum WatchAppCatalog {
    private static let cacheLock = NSLock()
    private static var cachedRunning: [NSRunningApplication] = []
    private static var cachedRunningAt = Date.distantPast
    private static let runningCacheTTL: TimeInterval = 3

    static func apps(
        running: [NSRunningApplication]? = nil,
        excludingBundleID: String? = Bundle.main.bundleIdentifier,
        including: WatchCaptureApp? = nil
    ) -> [WatchCaptureApp] {
        let running = running ?? self.cachedRunningApplications()
        var seen = Set<String>()
        var apps: [WatchCaptureApp] = []
        for application in running {
            guard application.activationPolicy == .regular,
                  let bundleID = application.bundleIdentifier,
                  !bundleID.isEmpty,
                  bundleID != excludingBundleID,
                  let title = application.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty
            else { continue }
            if seen.insert(bundleID).inserted {
                apps.append(WatchCaptureApp(id: bundleID, title: title))
            }
        }
        if let including, !including.id.isEmpty, including.id != excludingBundleID,
           seen.insert(including.id).inserted
        {
            apps.append(including)
        }
        return apps.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    static func title(for bundleID: String) -> String {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "This Mac" }
        if let name = self.cachedRunningApplications()
            .first(where: { $0.bundleIdentifier == trimmed })?
            .localizedName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty
        {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: trimmed),
           let name = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return name
        }
        return trimmed
    }

    private static func cachedRunningApplications() -> [NSRunningApplication] {
        self.cacheLock.lock()
        if Date().timeIntervalSince(self.cachedRunningAt) < self.runningCacheTTL, !self.cachedRunning.isEmpty {
            let running = self.cachedRunning
            self.cacheLock.unlock()
            return running
        }
        self.cacheLock.unlock()
        let running = NSWorkspace.shared.runningApplications
        self.cacheLock.lock()
        self.cachedRunning = running
        self.cachedRunningAt = Date()
        self.cacheLock.unlock()
        return running
    }
}
