import AppKit
import Foundation

nonisolated enum AppSupportDirectory {
    static let fluidVoiceBundleIdentifier = "com.FluidApp.app"

    static func url(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Application Support",
                isDirectory: true
            )
        let current = base.appendingPathComponent(FluidProduct.supportFolderName, isDirectory: true)

        if fileManager.fileExists(atPath: current.path) {
            return current
        }

        for legacyName in FluidProduct.priorSupportFolderNames {
            let legacy = base.appendingPathComponent(legacyName, isDirectory: true)
            guard fileManager.fileExists(atPath: legacy.path) else { continue }
            if !self.shouldRenameLegacyFolder(
                named: legacyName,
                fluidVoiceInstalled: self.fluidVoiceAppIsInstalled()
            ) {
                return current
            }
            do {
                try fileManager.moveItem(at: legacy, to: current)
                return current
            } catch {
                DebugLogger.shared.warning(
                    "Could not migrate \(legacyName) support folder: \(error.localizedDescription)",
                    source: "AppSupportDirectory"
                )
                return legacy
            }
        }

        return current
    }

    static func fluidVoiceAppIsInstalled(
        workspace: NSWorkspace = .shared
    ) -> Bool {
        workspace.urlForApplication(withBundleIdentifier: self.fluidVoiceBundleIdentifier) != nil
    }

    static func shouldRenameLegacyFolder(
        named legacyName: String,
        fluidVoiceInstalled: Bool
    ) -> Bool {
        if legacyName == FluidProduct.legacySupportFolderName {
            _ = fluidVoiceInstalled
            return false
        }
        return true
    }
}
