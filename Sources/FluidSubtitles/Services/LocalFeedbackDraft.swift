import AppKit
import Foundation

/// Writes a local note and opens GitHub. Speech and logs never leave this Mac
/// through a POST.
enum LocalFeedbackDraft {
    struct Result: Equatable, Sendable {
        let fileURL: URL
        let body: String
    }

    static func write(
        title: String,
        body: String,
        fileManager: FileManager = .default,
        now: Date = Date(),
        directory: URL? = nil
    ) throws -> Result {
        let folder = (directory ?? AppSupportDirectory.url(fileManager: fileManager))
            .appendingPathComponent("Feedback", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        let fileURL = folder.appendingPathComponent("\(stamp).md", isDirectory: false)
        let document = "# \(title)\n\n\(body)\n"
        try document.write(to: fileURL, atomically: true, encoding: .utf8)
        return Result(fileURL: fileURL, body: document)
    }

    @MainActor
    static func share(
        title: String,
        body: String,
        fileManager: FileManager = .default,
        openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) throws -> Result {
        let draft = try self.write(title: title, body: body, fileManager: fileManager)
        ClipboardService.copyToClipboard(draft.body)
        if let url = FluidProduct.feedbackURL {
            openURL(url)
        }
        return draft
    }
}
