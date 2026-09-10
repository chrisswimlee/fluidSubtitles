import Foundation

enum AppSupportDirectory {
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
}
