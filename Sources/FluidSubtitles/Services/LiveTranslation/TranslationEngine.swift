import Foundation

enum TranslationRequestKind: Equatable {
    case live
    case commit
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
    static let supersededMessage = "Superseded by a newer caption."
    static let localEchoedMessage = "Local caption translation echoed the source."
    static var superseded: TranslationEngineError { TranslationEngineError(message: Self.supersededMessage) }
    static var localEchoed: TranslationEngineError { TranslationEngineError(message: Self.localEchoedMessage) }
    static var localRejected: TranslationEngineError {
        TranslationEngineError(message: "Local caption translation was rejected.")
    }
}
