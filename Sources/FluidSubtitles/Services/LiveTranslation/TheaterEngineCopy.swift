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
            return "Turns that text into a supported language. On this Mac. Not a chat model."
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

    /// Name on the Voice Engine screen. The stored display names still say
    /// "Blazing Fast" and "Apple ASR Legacy" for older cards.
    static func voiceEngineName(_ model: SettingsStore.SpeechModel) -> String {
        switch model {
        case .parakeetTDT: return "Parakeet TDT v3"
        case .parakeetTDTv2: return "Parakeet TDT v2"
        case .parakeetRealtime: return "Parakeet Flash"
        case .qwen3Asr: return "Qwen3"
        case .cohereTranscribeSixBit: return "Cohere Transcribe"
        case .nemotronOffline: return "Nemotron 3.5"
        case .nemotronStreaming, .nemotronStreaming320: return "Nemotron Speech 3.5"
        case .appleSpeech: return "Apple Speech"
        case .appleSpeechAnalyzer: return "Apple Speech Analyzer"
        case .whisperTiny: return "Whisper Tiny"
        case .whisperBase: return "Whisper Base"
        case .whisperSmall: return "Whisper Small"
        case .whisperMedium: return "Whisper Medium"
        case .whisperLargeTurbo: return "Whisper Large Turbo"
        case .whisperLarge: return "Whisper Large"
        }
    }

    static func voiceEngineDetail(_ model: SettingsStore.SpeechModel) -> String {
        "\(model.languageSupport) · \(model.downloadSize)"
    }

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
