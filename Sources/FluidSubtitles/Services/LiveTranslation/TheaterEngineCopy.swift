import Foundation

/// User-facing copy that keeps Voice Engine (speech to text) separate from
/// Translation Engine (Apple Translation on this Mac).
enum TheaterEngineCopy {
    static let voiceTitle = "Voice Engine"
    static let voicePurpose = "Sharpens speech into text for the language you speak."

    static let translationTitle = "Translation Engine"
    static let translationName = "Apple Translation"
    static let translationPurpose =
        "Turns that text into Korean, English, Thai, or Japanese. On this Mac. Not a chat model."

    static func voiceRunningLine(settings: SettingsStore = .shared) -> String {
        SpokenLanguageResolver.stageEngineSummary(settings: settings)
    }

    static func translationRunningLine(
        mode: TheaterSessionMode,
        sameLanguage: Bool,
        pack: TranslationPackAvailability
    ) -> String {
        switch mode {
        case .transcription:
            return "Voice writes what you say. Translation Engine stays off."
        case .translation:
            if sameLanguage {
                return "Same language — Apple Translation is not needed."
            }
            switch pack {
            case .installed:
                return "Running Apple Translation on this Mac."
            case .supported:
                return "Apple Translation needs this language pack once."
            case .unsupported:
                return "This pair is not supported by Apple Translation."
            case .unknown:
                return "Apple Translation is not ready yet."
            }
        }
    }
}
