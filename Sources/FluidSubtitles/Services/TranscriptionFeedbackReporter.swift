import Foundation

enum TranscriptionFeedbackReporter {
    struct Payload: Equatable, Sendable {
        let rawText: String
        let processedText: String
        let processingModel: String
        let comments: String
    }

    enum ReporterError: LocalizedError {
        case emptyExample

        var errorDescription: String? {
            switch self {
            case .emptyExample:
                return "Add the raw or processed text before saving a local example."
            }
        }
    }

    static func markdown(for payload: Payload) -> String {
        """
        Speech stays on this Mac. Attach this file to a GitHub issue if you want to share it.

        **Model:** \(payload.processingModel)

        **Raw**
        ```
        \(payload.rawText)
        ```

        **Processed**
        ```
        \(payload.processedText)
        ```

        **Comments**
        \(payload.comments.isEmpty ? "(none)" : payload.comments)
        """
    }

    @MainActor
    static func submit(_ payload: Payload) throws {
        let raw = payload.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let processed = payload.processedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty || !processed.isEmpty else {
            throw ReporterError.emptyExample
        }
        _ = try LocalFeedbackDraft.share(title: "Transcription example", body: self.markdown(for: payload))
    }
}
