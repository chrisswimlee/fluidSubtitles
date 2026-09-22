import AppKit
import Foundation
import PromiseKit
import Security

// swiftlint:disable function_body_length cyclomatic_complexity type_body_length
// Tracked grandfather: existing FluidVoice-era file. New work belongs in a smaller file.

enum SimpleUpdateError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case jsonDecoding
    case noSuitableRelease
    case noAsset
    case updateAlreadyInProgress
    case downloadFailed
    case unzipFailed
    case notAnAppBundle
    case codesignMismatch
    case checksumMissing
    case checksumMismatch
    case unexpectedBundleID
    case rollbackUnavailable
    case rollbackRestoreFailed
    case updatesNotConfigured

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL."
        case .invalidResponse: return "Invalid HTTP response from GitHub."
        case .jsonDecoding: return "The data couldn’t be read because it isn’t in the correct format."
        case .noSuitableRelease: return "No suitable release found."
        case .noAsset: return "No matching asset found in the latest release."
        case .updateAlreadyInProgress: return "An update is already being installed."
        case .downloadFailed: return "Failed to download update."
        case .unzipFailed: return "Failed to extract the update archive."
        case .notAnAppBundle: return "Extracted content does not contain an app bundle."
        case .codesignMismatch: return "Downloaded app’s code signature does not match current app."
        case .checksumMissing: return "The GitHub release does not include a SHA256SUMS file."
        case .checksumMismatch: return "The downloaded update did not match the published SHA256."
        case .unexpectedBundleID: return "The downloaded update is not a fluidSubtitles app."
        case .rollbackUnavailable: return "No rollback backup is available."
        case .rollbackRestoreFailed: return "Failed to restore a previous version."
        case .updatesNotConfigured: return "\(FluidProduct.displayName) does not publish automatic updates yet."
        }
    }
}

struct UpdateOperationGate {
    private(set) var isActive = false

    mutating func begin() -> Bool {
        guard !self.isActive else { return false }
        self.isActive = true
        return true
    }

    mutating func finish() {
        self.isActive = false
    }
}

struct GHRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
        let content_type: String
    }

    let tag_name: String
    let prerelease: Bool
    let assets: [Asset]
    let body: String?
    let name: String?
    let published_at: String?
    let html_url: URL?
}

private struct SemanticVersion: Comparable {
    enum Identifier: Equatable {
        case numeric(Int)
        case string(String)
    }

    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [Identifier]

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        // Stable release has higher precedence than prerelease for same core version.
        if lhs.prerelease.isEmpty && rhs.prerelease.isEmpty { return false }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }

        let count = min(lhs.prerelease.count, rhs.prerelease.count)
        for index in 0..<count {
            let left = lhs.prerelease[index]
            let right = rhs.prerelease[index]
            if left == right { continue }

            switch (left, right) {
            case let (.numeric(a), .numeric(b)):
                return a < b
            case (.numeric, .string):
                return true
            case (.string, .numeric):
                return false
            case let (.string(a), .string(b)):
                return a < b
            }
        }

        // If all compared identifiers are equal, shorter prerelease has lower precedence.
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

@MainActor
final class SimpleUpdater {
    struct ReleaseBuildOption {
        let version: String
        let url: URL
    }

    struct ReleaseNote: Codable, Hashable {
        let version: String
        let title: String
        let notes: String
        let publishedAt: Date?
        let url: URL?
        let isPrerelease: Bool
    }

    static let shared = SimpleUpdater()
    private init() {}

    private let fileManager = FileManager.default
    private let maxRollbackBackups = 3
    private let rollbackBackupDirectoryName = "RollbackBackups"
    private var updateOperationGate = UpdateOperationGate()
    private var updateStatusWindow: NSWindow?

    var isUpdateInProgress: Bool {
        return self.updateOperationGate.isActive
    }

    private var installedAppName: String {
        return Bundle.main.bundleURL.deletingPathExtension().lastPathComponent
    }

    private var currentAppVersion: String {
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    func hasRollbackBackup() -> Bool {
        return self.latestRollbackBackup() != nil
    }

    func latestRollbackVersion() -> String? {
        guard let latest = self.latestRollbackBackup() else { return nil }
        return self.versionString(for: latest)
    }

    func rollbackToLatestBackup() async throws {
        guard self.updateOperationGate.begin() else {
            throw SimpleUpdateError.updateAlreadyInProgress
        }

        var shouldKeepOperationActive = false
        defer {
            if !shouldKeepOperationActive {
                self.resetUpdateOperation()
            }
        }

        guard let rollbackBundleURL = self.latestRollbackBackup() else {
            throw SimpleUpdateError.rollbackUnavailable
        }

        self.createRollbackBackup(beforeRollback: true)

        do {
            try self.performSwapAndRelaunch(
                installedAppURL: Bundle.main.bundleURL,
                downloadedAppURL: rollbackBundleURL
            )
            DebugLogger.shared.info(
                "SimpleUpdater: Rolled back to \(rollbackBundleURL.lastPathComponent)",
                source: "SimpleUpdater"
            )
            shouldKeepOperationActive = true
        } catch {
            throw SimpleUpdateError.rollbackRestoreFailed
        }
    }

    func fetchRecentReleaseBuildOptions(
        owner: String,
        repo: String,
        limit: Int = 3,
        includePrerelease: Bool = false
    ) async throws -> [ReleaseBuildOption] {
        let releases = try await self.fetchReleases(owner: owner, repo: repo)
        let count = max(1, limit)
        let candidates = self.sortedCandidateReleases(
            releases,
            includePrerelease: includePrerelease
        ).prefix(count)

        return candidates.map { entry in
            let release = entry.release
            let zipAsset = release.assets.first {
                $0.content_type == "application/zip" ||
                    $0.content_type == "application/x-zip-compressed" ||
                    $0.name.lowercased().hasSuffix(".zip")
            }
            let fallbackTagURL = URL(string: "https://github.com/\(owner)/\(repo)/releases/tag/\(release.tag_name)")
            let fallbackReleasesURL = URL(string: "https://github.com/\(owner)/\(repo)/releases")
            let url = zipAsset?.browser_download_url ??
                release.html_url ??
                fallbackTagURL ??
                fallbackReleasesURL ??
                URL(fileURLWithPath: "/")
            return ReleaseBuildOption(version: release.tag_name, url: url)
        }
    }

    func fetchRecentReleaseNotes(
        owner: String,
        repo: String,
        limit: Int = 6,
        includePrerelease: Bool = false
    ) async throws -> [ReleaseNote] {
        let releases = try await self.fetchReleases(owner: owner, repo: repo)
        let count = max(1, limit)

        return self.sortedCandidateReleases(
            releases,
            includePrerelease: includePrerelease
        )
        .prefix(count)
        .map { entry in
            let release = entry.release
            return ReleaseNote(
                version: release.tag_name,
                title: Self.nonEmpty(release.name) ?? release.tag_name,
                notes: Self.nonEmpty(release.body) ?? "No release notes available.",
                publishedAt: Self.parseGitHubDate(release.published_at),
                url: release.html_url,
                isPrerelease: release.prerelease
            )
        }
    }

    // Allowed Apple Developer Team IDs for code-sign validation.
    // Always include the running app’s team so this fork can update itself.
    private var allowedTeamIDs: Set<String> {
        var ids = FluidProduct.allowedUpdateTeamIDs
        if let current = Self.currentSigningTeamID() {
            ids.insert(current)
        }
        return ids
    }

    private static func currentSigningTeamID() -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode
        else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &info
        ) == errSecSuccess,
              let info = info as? [String: Any]
        else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static let githubDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let githubFractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func parseGitHubDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return self.githubDateFormatter.date(from: value) ??
            self.githubFractionalDateFormatter.date(from: value)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    // Fetch latest release notes from GitHub
    func fetchLatestReleaseNotes(
        owner: String,
        repo: String,
        includePrerelease: Bool = false
    ) async throws -> (version: String, notes: String) {
        let releases = try await self.fetchReleases(owner: owner, repo: repo)

        guard let latest = self.selectLatestRelease(
            from: releases,
            includePrerelease: includePrerelease
        ) else {
            throw SimpleUpdateError.noSuitableRelease
        }

        let version = latest.tag_name
        let notes = latest.body ?? "No release notes available."

        return (version, notes)
    }

    // Silent check that returns update info without showing alerts or installing
    func checkForUpdate(
        owner: String,
        repo: String,
        includePrerelease: Bool = false
    ) async throws -> (hasUpdate: Bool, latestVersion: String) {
        guard !self.isUpdateInProgress else {
            throw SimpleUpdateError.updateAlreadyInProgress
        }
        guard UpdateSignaturePolicy.canInstallPublicUpdates(
            currentTeam: Self.currentSigningTeamID(),
            allowed: FluidProduct.allowedUpdateTeamIDs
        ) else {
            throw SimpleUpdateError.updatesNotConfigured
        }

        let releases = try await self.fetchReleases(owner: owner, repo: repo)

        guard let latest = self.selectLatestRelease(
            from: releases,
            includePrerelease: includePrerelease
        ) else {
            throw SimpleUpdateError.noSuitableRelease
        }

        let currentVersionString = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let current = self.parseSemanticVersion(currentVersionString) ?? SemanticVersion(
            major: 0,
            minor: 0,
            patch: 0,
            prerelease: []
        )
        let latestTag = latest.tag_name
        guard let latestVersion = self.parseSemanticVersion(latestTag) else {
            throw SimpleUpdateError.noSuitableRelease
        }

        // Return whether update is available
        return (latestVersion > current, latestTag)
    }

    func publishedRepository() throws -> (owner: String, repo: String) {
        guard let repository = FluidProduct.updateRepository else {
            throw SimpleUpdateError.updatesNotConfigured
        }
        return repository
    }

    func checkAndUpdate(
        owner: String,
        repo: String,
        includePrerelease: Bool = false
    ) async throws {
        guard UpdateSignaturePolicy.canInstallPublicUpdates(
            currentTeam: Self.currentSigningTeamID(),
            allowed: FluidProduct.allowedUpdateTeamIDs
        ) else {
            throw SimpleUpdateError.updatesNotConfigured
        }
        guard self.updateOperationGate.begin() else {
            throw SimpleUpdateError.updateAlreadyInProgress
        }

        var shouldKeepOperationActive = false
        defer {
            if !shouldKeepOperationActive {
                self.resetUpdateOperation()
            }
        }

        let releases = try await self.fetchReleases(owner: owner, repo: repo)

        guard let latest = self.selectLatestRelease(
            from: releases,
            includePrerelease: includePrerelease
        ) else {
            throw SimpleUpdateError.noSuitableRelease
        }

        let currentVersionString = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let current = self.parseSemanticVersion(currentVersionString) ?? SemanticVersion(
            major: 0,
            minor: 0,
            patch: 0,
            prerelease: []
        )
        let latestTag = latest.tag_name
        guard let latestVersion = self.parseSemanticVersion(latestTag) else {
            throw SimpleUpdateError.noSuitableRelease
        }

        // up to date
        if !(latestVersion > current) {
            throw PMKError.cancelled // mimic AppUpdater semantics for up-to-date
        }

        // Find asset matching: "{repo-lower}-{version-from-tag}.*" and zip preferred
        let rawVersion = latestTag.hasPrefix("v") ? String(latestTag.dropFirst()) : latestTag
        let prefix = "\(repo.lowercased())-\(rawVersion)"
        let asset = latest.assets.first { asset in
            let base = (asset.name as NSString).deletingPathExtension.lowercased()
            return (base == prefix) &&
                (asset.content_type == "application/zip" || asset.content_type == "application/x-zip-compressed")
        } ?? latest.assets.first { asset in
            let base = (asset.name as NSString).deletingPathExtension.lowercased()
            return base == prefix
        }

        guard let asset = asset else { throw SimpleUpdateError.noAsset }
        guard let checksumAsset = latest.assets.first(where: {
            $0.name.caseInsensitiveCompare("SHA256SUMS") == .orderedSame ||
                $0.name.caseInsensitiveCompare("SHA256SUMS.txt") == .orderedSame
        }) else {
            throw SimpleUpdateError.checksumMissing
        }

        self.showUpdateInstallStatus(version: rawVersion)

        let tempDir = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: Bundle.main.bundleURL,
            create: true
        )
        let downloadURL = tempDir.appendingPathComponent(asset.browser_download_url.lastPathComponent)

        do {
            let (tmpFile, _) = try await URLSession.shared.download(from: asset.browser_download_url)
            try FileManager.default.moveItem(at: tmpFile, to: downloadURL)
        } catch {
            throw SimpleUpdateError.downloadFailed
        }

        let checksumText: String
        do {
            let (data, _) = try await URLSession.shared.data(from: checksumAsset.browser_download_url)
            checksumText = String(data: data, encoding: .utf8) ?? ""
        } catch {
            throw SimpleUpdateError.checksumMissing
        }
        guard let expectedDigest = UpdateSignaturePolicy.expectedSHA256(
            fromChecksumFile: checksumText,
            assetName: downloadURL.lastPathComponent
        ) else {
            throw SimpleUpdateError.checksumMissing
        }
        let actualDigest = try UpdateSignaturePolicy.hexSHA256(ofFile: downloadURL)
        guard actualDigest == expectedDigest else {
            throw SimpleUpdateError.checksumMismatch
        }

        let extractedBundleURL: URL
        do {
            extractedBundleURL = try await self.unzip(at: downloadURL)
        } catch {
            throw SimpleUpdateError.unzipFailed
        }

        guard extractedBundleURL.pathExtension == "app" else {
            throw SimpleUpdateError.notAnAppBundle
        }

        try await self.verifyCodeSignature(for: extractedBundleURL)
        let newInfo = try await self.codeSigningInformation(for: extractedBundleURL)
        let newTeam = UpdateSignaturePolicy.teamID(fromCodesignOutput: newInfo)
        let newBundleID = UpdateSignaturePolicy.bundleIdentifier(fromCodesignOutput: newInfo)
            ?? Bundle(url: extractedBundleURL)?.bundleIdentifier
        guard newBundleID == FluidProduct.bundleIdentifier else {
            throw SimpleUpdateError.unexpectedBundleID
        }
        let designated = UpdateSignaturePolicy.designatedRequirement(fromCodesignOutput: newInfo) ?? ""
        if !designated.contains(FluidProduct.bundleIdentifier) {
            throw SimpleUpdateError.unexpectedBundleID
        }

        let currentTeam = Self.currentSigningTeamID()
        let accepted = UpdateSignaturePolicy.accepts(
            currentTeam: currentTeam,
            newTeam: newTeam,
            allowed: self.allowedTeamIDs,
            bundleIdentifier: newBundleID
        )
        guard accepted else {
            DebugLogger.shared.error(
                "SimpleUpdater: Code-sign mismatch. Current Team=\(currentTeam ?? "none") New Team=\(newTeam ?? "none")",
                source: "SimpleUpdater"
            )
            throw SimpleUpdateError.codesignMismatch
        }

        self.createRollbackBackup(beforeRollback: false)

        // Replace and relaunch
        try self.performSwapAndRelaunch(
            installedAppURL: Bundle.main.bundleURL,
            downloadedAppURL: extractedBundleURL
        )
        shouldKeepOperationActive = true
    }

    // MARK: - Helpers

    private func showUpdateInstallStatus(version: String) {
        guard self.updateStatusWindow == nil else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 132),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.title = "Installing \(FluidProduct.displayName) \(version)"
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = NSVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
        content.material = .popover
        content.blendingMode = .behindWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 16
        content.layer?.masksToBounds = true
        content.autoresizingMask = [.width, .height]

        let icon = NSImageView(frame: NSRect(x: 22, y: 42, width: 52, height: 52))
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        content.addSubview(icon)

        let title = NSTextField(labelWithString: "Installing \(FluidProduct.displayName) \(version)")
        title.frame = NSRect(x: 92, y: 76, width: 304, height: 24)
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        content.addSubview(title)

        let detail = NSTextField(wrappingLabelWithString: "Downloading the update. \(FluidProduct.displayName) will restart automatically.")
        detail.frame = NSRect(x: 92, y: 42, width: 304, height: 34)
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 2
        content.addSubview(detail)

        let progress = NSProgressIndicator(frame: NSRect(x: 92, y: 24, width: 304, height: 6))
        progress.style = .bar
        progress.isIndeterminate = true
        progress.controlSize = .small
        progress.startAnimation(nil)
        content.addSubview(progress)

        panel.contentView = content
        panel.center()
        panel.orderFrontRegardless()
        self.updateStatusWindow = panel
    }

    private func resetUpdateOperation() {
        self.updateOperationGate.finish()
        self.updateStatusWindow?.close()
        self.updateStatusWindow = nil
    }

    private func fetchReleases(owner: String, repo: String) async throws -> [GHRelease] {
        guard let releasesURL = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases") else {
            throw SimpleUpdateError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: releasesURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SimpleUpdateError.invalidResponse
        }

        do {
            return try JSONDecoder().decode([GHRelease].self, from: data)
        } catch {
            throw SimpleUpdateError.jsonDecoding
        }
    }

    private func selectLatestRelease(from releases: [GHRelease], includePrerelease: Bool) -> GHRelease? {
        return self.sortedCandidateReleases(releases, includePrerelease: includePrerelease).first?.release
    }

    private func sortedCandidateReleases(
        _ releases: [GHRelease],
        includePrerelease: Bool
    ) -> [(release: GHRelease, version: SemanticVersion)] {
        return releases
            .compactMap { release in
                guard let version = self.parseSemanticVersion(release.tag_name) else {
                    return nil
                }
                let isPrerelease = self.isPrereleaseRelease(release)
                if !includePrerelease, isPrerelease {
                    return nil
                }
                return (release, version)
            }
            .sorted { lhs, rhs in
                if lhs.version != rhs.version {
                    return lhs.version > rhs.version
                }

                // Tie-break with publish date when tags map to same semantic version.
                let lhsPublished = lhs.release.published_at ?? ""
                let rhsPublished = rhs.release.published_at ?? ""
                return lhsPublished > rhsPublished
            }
    }

    private func isPrereleaseRelease(_ release: GHRelease) -> Bool {
        return release.prerelease || self.hasPrereleaseSuffix(in: release.tag_name)
    }

    private func hasPrereleaseSuffix(in version: String) -> Bool {
        var trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            trimmed.removeFirst()
        }
        if let plusIndex = trimmed.firstIndex(of: "+") {
            trimmed = String(trimmed[..<plusIndex])
        }

        guard let hyphenIndex = trimmed.firstIndex(of: "-") else {
            return false
        }

        let suffix = trimmed[trimmed.index(after: hyphenIndex)...]
        return suffix.isEmpty == false
    }

    private func rollbackRootDirectory() -> URL {
        let base = self.fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let support = base ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support
            .appendingPathComponent("Fluid", isDirectory: true)
            .appendingPathComponent(self.rollbackBackupDirectoryName, isDirectory: true)
            .appendingPathComponent(self.installedAppName, isDirectory: true)
    }

    private func availableRollbackBackups() -> [URL] {
        let backupDir = self.rollbackRootDirectory()
        guard self.fileManager.fileExists(atPath: backupDir.path) else { return [] }

        let urls: [URL]
        do {
            urls = try self.fileManager.contentsOfDirectory(
                at: backupDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return []
        }

        return Self.sortedRollbackBackups(urls.filter { $0.pathExtension == "app" }) { url in
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
    }

    private func latestRollbackBackup() -> URL? {
        let currentVersion = self.currentAppVersion
        return self.availableRollbackBackups().first {
            Self.isRollbackVersion(self.versionString(for: $0), differentFrom: currentVersion)
        }
    }

    private func versionString(for appURL: URL) -> String? {
        guard let bundle = Bundle(url: appURL) else { return nil }
        return bundle.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    private func sanitizeVersion(_ version: String) -> String {
        return version
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    private func createRollbackBackup(beforeRollback: Bool) {
        let currentAppVersion = self.currentAppVersion
        let appURL = Bundle.main.bundleURL
        let backupRoot = self.rollbackRootDirectory()

        do {
            try self.fileManager.createDirectory(
                at: backupRoot,
                withIntermediateDirectories: true
            )
        } catch {
            DebugLogger.shared.warning("SimpleUpdater: Failed to create rollback backup folder: \(error.localizedDescription)", source: "SimpleUpdater")
            return
        }

        let timestamp = Int(Date().timeIntervalSince1970)
        let safeVersion = self.sanitizeVersion(currentAppVersion)
        let backupName = beforeRollback
            ? "\(self.installedAppName)-\(safeVersion)-rollback-\(timestamp).app"
            : "\(self.installedAppName)-\(safeVersion)-\(timestamp).app"
        let backupURL = backupRoot.appendingPathComponent(backupName)

        do {
            try self.fileManager.copyItem(at: appURL, to: backupURL)
            try? self.fileManager.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: backupURL.path
            )
            self.pruneRollbackBackups()
            DebugLogger.shared.info(
                "SimpleUpdater: Created rollback backup at \(backupURL.path)",
                source: "SimpleUpdater"
            )
        } catch {
            DebugLogger.shared.warning(
                "SimpleUpdater: Failed to create rollback backup: \(error.localizedDescription)",
                source: "SimpleUpdater"
            )
        }
    }

    private func pruneRollbackBackups() {
        let backups = self.availableRollbackBackups()
        guard backups.count > self.maxRollbackBackups else { return }

        for oldBackup in backups.dropFirst(self.maxRollbackBackups) {
            do {
                try self.fileManager.removeItem(at: oldBackup)
            } catch {
                DebugLogger.shared.warning(
                    "SimpleUpdater: Failed to remove old rollback backup \(oldBackup.lastPathComponent): \(error.localizedDescription)",
                    source: "SimpleUpdater"
                )
            }
        }
    }

    static func sortedRollbackBackups(
        _ urls: [URL],
        modificationDate: (URL) -> Date?
    ) -> [URL] {
        return urls
            .compactMap { url -> (URL, Date)? in
                guard let createdAt = self.rollbackBackupCreationDate(
                    from: url,
                    fallbackModificationDate: modificationDate(url)
                ) else {
                    return nil
                }
                return (url, createdAt)
            }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
    }

    static func isRollbackVersion(_ version: String?, differentFrom currentVersion: String) -> Bool {
        guard let version else { return false }
        return version != currentVersion
    }

    private static func rollbackBackupCreationDate(
        from url: URL,
        fallbackModificationDate: Date?
    ) -> Date? {
        if let timestamp = self.rollbackBackupTimestamp(from: url) {
            return Date(timeIntervalSince1970: timestamp)
        }

        return fallbackModificationDate
    }

    private static func rollbackBackupTimestamp(from url: URL) -> TimeInterval? {
        let name = url.deletingPathExtension().lastPathComponent
        guard let suffix = name.split(separator: "-").last,
              let timestamp = TimeInterval(suffix)
        else {
            return nil
        }

        return timestamp
    }

    private func parseSemanticVersion(_ version: String) -> SemanticVersion? {
        var trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            trimmed.removeFirst()
        }

        // Ignore build metadata for precedence.
        if let plusIndex = trimmed.firstIndex(of: "+") {
            trimmed = String(trimmed[..<plusIndex])
        }

        let components = trimmed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard !components.isEmpty else { return nil }

        let coreComponents = components[0].split(separator: ".", omittingEmptySubsequences: false)
        guard coreComponents.count >= 2 else { return nil }
        guard let major = Int(coreComponents[0]), let minor = Int(coreComponents[1]) else { return nil }
        let patch: Int
        if coreComponents.count >= 3 {
            guard let parsedPatch = Int(coreComponents[2]) else { return nil }
            patch = parsedPatch
        } else {
            patch = 0
        }

        let prereleaseIdentifiers: [SemanticVersion.Identifier]
        if components.count > 1 {
            prereleaseIdentifiers = components[1]
                .split(separator: ".", omittingEmptySubsequences: false)
                .map { identifier in
                    if let numeric = Int(identifier) {
                        return .numeric(numeric)
                    }
                    return .string(identifier.lowercased())
                }
        } else {
            prereleaseIdentifiers = []
        }

        return SemanticVersion(
            major: major,
            minor: minor,
            patch: patch,
            prerelease: prereleaseIdentifiers
        )
    }

    private func unzip(at url: URL) async throws -> URL {
        let extractDir = url.deletingLastPathComponent()
            .appendingPathComponent("extract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-o", url.path, "-d", extractDir.path]

        return try await withCheckedThrowingContinuation { cont in
            proc.terminationHandler = { process in
                guard process.terminationStatus == 0,
                      let appURL = UpdateSignaturePolicy.selectSoleTopLevelApp(in: extractDir),
                      UpdateSignaturePolicy.isSafeExtractedApp(appURL, workDirectory: extractDir)
                else {
                    cont.resume(throwing: SimpleUpdateError.unzipFailed)
                    return
                }
                cont.resume(returning: appURL)
            }
            do { try proc.run() } catch { cont.resume(throwing: error) }
        }
    }

    private func verifyCodeSignature(for bundleURL: URL) async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        proc.arguments = ["--verify", "--deep", "--strict", bundleURL.path]
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            proc.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    cont.resume()
                } else {
                    cont.resume(throwing: SimpleUpdateError.codesignMismatch)
                }
            }
            do { try proc.run() } catch { cont.resume(throwing: error) }
        }
    }

    private func codeSigningInformation(for bundleURL: URL) async throws -> String {
        let details = Process()
        details.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        details.arguments = ["-dvvv", bundleURL.path]
        let detailsPipe = Pipe()
        details.standardError = detailsPipe

        let requirements = Process()
        requirements.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        requirements.arguments = ["-d", "--requirements", "-", bundleURL.path]
        let requirementsPipe = Pipe()
        requirements.standardOutput = requirementsPipe
        requirements.standardError = Pipe()

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            details.terminationHandler = { _ in cont.resume() }
            do { try details.run() } catch { cont.resume(throwing: error) }
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            requirements.terminationHandler = { _ in cont.resume() }
            do { try requirements.run() } catch { cont.resume(throwing: error) }
        }

        let detailText = String(data: detailsPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let requirementText = String(
            data: requirementsPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return detailText + "\n" + requirementText
    }

    private func performSwapAndRelaunch(installedAppURL: URL, downloadedAppURL: URL) throws {
        // Handle app name changes: if the downloaded app has a different name,
        // we need to replace the old app and use the new name
        let installedAppName = installedAppURL.lastPathComponent
        let downloadedAppName = downloadedAppURL.lastPathComponent

        DebugLogger.shared.info("SimpleUpdater: Installing app - Current: \(installedAppName), New: \(downloadedAppName)", source: "SimpleUpdater")

        let finalAppURL: URL
        if installedAppName != downloadedAppName {
            // App name changed - use the new name
            finalAppURL = installedAppURL.deletingLastPathComponent().appendingPathComponent(downloadedAppName)
            DebugLogger.shared.info("SimpleUpdater: App name changed, installing to: \(finalAppURL.path)", source: "SimpleUpdater")

            // Safety check: ensure we don't overwrite an existing app with the new name
            if FileManager.default.fileExists(atPath: finalAppURL.path) {
                DebugLogger.shared.info("SimpleUpdater: Removing existing app at new location: \(finalAppURL.path)", source: "SimpleUpdater")
                try FileManager.default.removeItem(at: finalAppURL)
            }

            // Remove old app if it exists
            if FileManager.default.fileExists(atPath: installedAppURL.path) {
                DebugLogger.shared.info("SimpleUpdater: Removing old app: \(installedAppURL.path)", source: "SimpleUpdater")
                try FileManager.default.removeItem(at: installedAppURL)
            }

            // Move new app to Applications with new name
            try FileManager.default.moveItem(at: downloadedAppURL, to: finalAppURL)
            DebugLogger.shared.info("SimpleUpdater: Successfully installed new app at: \(finalAppURL.path)", source: "SimpleUpdater")
        } else {
            // Same name - normal replacement
            DebugLogger.shared.info("SimpleUpdater: Same app name, performing normal replacement", source: "SimpleUpdater")
            if FileManager.default.fileExists(atPath: installedAppURL.path) {
                try FileManager.default.removeItem(at: installedAppURL)
            }
            try FileManager.default.moveItem(at: downloadedAppURL, to: installedAppURL)
            finalAppURL = installedAppURL
        }

        // Use modern NSWorkspace API for more reliable app launching
        DispatchQueue.main.async {
            DebugLogger.shared.info("SimpleUpdater: Attempting to relaunch app at: \(finalAppURL.path)", source: "SimpleUpdater")

            // Verify the app exists before trying to launch
            guard FileManager.default.fileExists(atPath: finalAppURL.path) else {
                DebugLogger.shared.error("SimpleUpdater: ERROR - App not found at expected location: \(finalAppURL.path)", source: "SimpleUpdater")
                self.resetUpdateOperation()
                // Don't terminate if we can't find the new app
                return
            }

            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true

            NSWorkspace.shared.openApplication(at: finalAppURL, configuration: configuration) { _, error in
                if let error = error {
                    DebugLogger.shared.error("SimpleUpdater: Failed to relaunch app: \(error)", source: "SimpleUpdater")
                    DebugLogger.shared.error("SimpleUpdater: App location: \(finalAppURL.path)", source: "SimpleUpdater")
                    Task { @MainActor in
                        self.resetUpdateOperation()
                    }
                    // Don't terminate if relaunch failed - let user manually restart
                    return
                }

                DebugLogger.shared.info("SimpleUpdater: Successfully relaunched app, terminating old instance", source: "SimpleUpdater")
                // Give the new instance time to fully start before terminating
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}
