import Foundation

/// Apple Translation is the caption engine. A local small LLM is optional
/// first-print sharpening; Apple stays the fallback.
enum TheaterTranslationEngineKind: String, CaseIterable, Identifiable {
    case apple
    case localLLM

    var id: String { self.rawValue }

    var displayName: String {
        switch self {
        case .apple: return "Apple Translation"
        case .localLLM: return "Local small LLM (experimental)"
        }
    }

    var purpose: String {
        switch self {
        case .apple:
            return "Turns that text into Korean, English, Thai, or Japanese. On this Mac. Not a chat model."
        case .localLLM:
            return "Experimental. A running local model can sharpen the first print. Apple Translation stays the fallback."
        }
    }
}

/// User-facing copy that keeps Voice Engine (speech to text) separate from
/// Translation Engine (Apple Translation, optional local LLM).
enum TheaterEngineCopy {
    static let voiceTitle = "Voice Engine"
    static let voicePurpose = "Sharpens speech into text for the language you speak."

    static let translationTitle = "Translation Engine"
    static let translationPurpose =
        "Apple Translation on this Mac, not a chat model. Optional experimental local LLM to sharpen the first print."

    static func translationName(settings: SettingsStore = .shared) -> String {
        settings.theaterTranslationEngine.displayName
    }

    static func voiceRunningLine(settings: SettingsStore = .shared) -> String {
        SpokenLanguageResolver.stageEngineSummary(settings: settings)
    }

    static func translationRunningLine(
        mode: TheaterSessionMode,
        sameLanguage: Bool,
        pack: TranslationPackAvailability,
        engine: TheaterTranslationEngineKind = .apple
    ) -> String {
        switch mode {
        case .transcription:
            return "Voice writes what you say. Translation Engine stays off."
        case .translation:
            if sameLanguage {
                return "Same language — Apple Translation is not needed."
            }
            if engine == .localLLM {
                return "Experimental local LLM can sharpen the first print. Apple Translation stays the fallback."
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
