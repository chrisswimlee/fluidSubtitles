import Foundation

enum TranslationRequestKind: Equatable {
    case live
    case commit
    /// First clause of a Listen. Same mailbox slot and timeout as a later commit.
    case firstCommit

    var occupiesCommitSlot: Bool { self != .live }
}

protocol TranslationEngine: AnyObject {
    var name: String { get }
    func translate(_ text: String, source: TranslationLanguage, target: TranslationLanguage) async throws -> String
    func translate(
        _ text: String,
        source: TranslationLanguage,
        target: TranslationLanguage,
        kind: TranslationRequestKind
    ) async throws -> String
}

extension TranslationEngine {
    func translate(
        _ text: String,
        source: TranslationLanguage,
        target: TranslationLanguage,
        kind: TranslationRequestKind
    ) async throws -> String {
        try await self.translate(text, source: source, target: target)
    }
}

struct TranslationEngineError: LocalizedError {
    let message: String
    var errorDescription: String? { self.message }
    var isSuperseded: Bool { self.message == Self.supersededMessage }
    var isLocalEcho: Bool { self.message == Self.localEchoedMessage }
    var isTimeout: Bool { self.message == Self.timeoutMessage }
    var isSharpenWithdrawn: Bool { self.message == Self.sharpenWithdrawnMessage }
    static let supersededMessage = "Superseded by a newer caption."
    static let localEchoedMessage = "Local caption translation echoed the source."
    static let timeoutMessage = "Apple Translation timed out."
    static let sharpenWithdrawnMessage = "Local sharpening paused while this Mac is hot or short on memory."
    static var superseded: TranslationEngineError { TranslationEngineError(message: Self.supersededMessage) }
    static var timeout: TranslationEngineError { TranslationEngineError(message: Self.timeoutMessage) }
    static var localEchoed: TranslationEngineError { TranslationEngineError(message: Self.localEchoedMessage) }
    static var sharpenWithdrawn: TranslationEngineError {
        TranslationEngineError(message: Self.sharpenWithdrawnMessage)
    }
    static var localRejected: TranslationEngineError {
        TranslationEngineError(message: "Local caption translation was rejected.")
    }
}
