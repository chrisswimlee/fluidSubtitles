//
//  UpdateSignaturePolicy.swift
//  Fluid
//
//  Shared update signature and checksum checks.
//

import CryptoKit
import Foundation

nonisolated enum UpdateSignaturePolicy {
    static let expectedBundleIdentifier = FluidProduct.bundleIdentifier

    static func isUsableTeamID(_ raw: String?) -> Bool {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return false
        }
        let lowered = trimmed.lowercased()
        if lowered == "not set" || lowered == "-" || lowered == "adhoc" || lowered == "ad-hoc" {
            return false
        }
        return trimmed.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil
    }

    static func teamID(fromCodesignOutput output: String) -> String? {
        if let line = output.split(separator: "\n").first(where: { $0.hasPrefix("TeamIdentifier=") }) {
            return String(line.dropFirst("TeamIdentifier=".count))
        }
        if let identity = output.split(separator: "\n").first(where: { $0.hasPrefix("Authority=") }) {
            let text = String(identity)
            guard let left = text.lastIndex(of: "("), let right = text.lastIndex(of: ")"), left < right else {
                return nil
            }
            return String(text[text.index(after: left)..<right])
        }
        return nil
    }

    static func bundleIdentifier(fromCodesignOutput output: String) -> String? {
        guard let line = output.split(separator: "\n").first(where: { $0.hasPrefix("Identifier=") }) else {
            return nil
        }
        return String(line.dropFirst("Identifier=".count))
    }

    static func designatedRequirement(fromCodesignOutput output: String) -> String? {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let index = lines.firstIndex(where: { $0.hasPrefix("designated =>") || $0.hasPrefix("designated=>") })
        else {
            return nil
        }
        return lines[index]
    }

    static func accepts(
        currentTeam: String?,
        newTeam: String?,
        allowed: Set<String>,
        bundleIdentifier: String?
    ) -> Bool {
        guard bundleIdentifier == self.expectedBundleIdentifier else {
            return false
        }
        guard self.isUsableTeamID(newTeam) else {
            return false
        }
        if let currentTeam, self.isUsableTeamID(currentTeam), currentTeam == newTeam {
            return true
        }
        if let newTeam, allowed.contains(newTeam) {
            if let currentTeam, self.isUsableTeamID(currentTeam) {
                return allowed.contains(currentTeam)
            }
            return true
        }
        return false
    }

    static func expectedSHA256(fromChecksumFile contents: String, assetName: String) -> String? {
        let needle = assetName.lowercased()
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 2 else { continue }
            let digest = parts[0].lowercased()
            let name = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            if name.lowercased() == needle || name.lowercased().hasSuffix("/\(needle)") {
                return digest
            }
        }
        return nil
    }

    static func hexSHA256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isSafeExtractedApp(_ appURL: URL, workDirectory: URL) -> Bool {
        let app = appURL.standardizedFileURL.path
        let root = workDirectory.standardizedFileURL.path
        guard app.hasPrefix(root.hasSuffix("/") ? root : root + "/") || app == root else {
            return false
        }
        return appURL.pathExtension == "app"
    }

    static func selectSoleTopLevelApp(in directory: URL) -> URL? {
        let apps = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ))?
            .filter { $0.pathExtension == "app" } ?? []
        guard apps.count == 1, let app = apps.first else {
            return nil
        }
        return app
    }
}
