import Foundation

protocol TranslationEngine: AnyObject {
    var name: String { get }
    func translate(_ text: String, source: TranslationLanguage, target: TranslationLanguage) async throws -> String
}

struct TranslationEngineError: LocalizedError {
    let message: String
    var errorDescription: String? { self.message }
}
