import Foundation

/// Protects custom-dictionary terms so Apple Translation does not rewrite names.
enum TranslationGlossary {
    struct ProtectedText: Equatable {
        let text: String
        let tokens: [String: String]
    }

    static func protectedTerms(from settings: SettingsStore = .shared) -> [String] {
        var terms: [String] = []
        for entry in settings.customDictionaryEntries {
            terms.append(contentsOf: entry.triggers)
            if !entry.replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                terms.append(entry.replacement)
            }
        }
        return Array(Set(terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
            .filter { $0.count >= 2 }
            .sorted { $0.count > $1.count }
    }

    static func protect(_ text: String, terms: [String]) -> ProtectedText {
        guard !text.isEmpty, !terms.isEmpty else {
            return ProtectedText(text: text, tokens: [:])
        }

        var result = text
        var tokens: [String: String] = [:]
        var index = 0
        for term in terms {
            guard !term.isEmpty, result.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil else {
                continue
            }
            let token = "[[FT\(index)]]"
            index += 1
            tokens[token] = term
            result = result.replacingOccurrences(of: term, with: token, options: [.caseInsensitive, .diacriticInsensitive])
        }
        return ProtectedText(text: result, tokens: tokens)
    }

    static func restore(_ text: String, tokens: [String: String]) -> String {
        var result = text
        for (token, original) in tokens {
            result = result.replacingOccurrences(of: token, with: original)
        }
        return result
    }

    /// Terms that appear in the source but vanished from a polished caption.
    static func lostProtectedTerms(source: String, polished: String, terms: [String]) -> [String] {
        terms.filter { term in
            let needle = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard needle.count >= 2 else { return false }
            let presentInSource = source.range(
                of: needle,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil
            let presentInPolished = polished.range(
                of: needle,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil
            return presentInSource && !presentInPolished
        }
    }
}

enum SpokenLanguageResolver {
    static func spokenLanguageID(settings: SettingsStore = .shared) -> String {
        let model = settings.selectedSpeechModel
        switch model {
        case .parakeetRealtime, .parakeetTDTv2:
            return "en"
        case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLargeTurbo, .whisperLarge:
            if let code = settings.selectedWhisperLanguageCode, !code.isEmpty {
                return code
            }
        case .cohereTranscribeSixBit:
            return settings.selectedCohereLanguage.rawValue
        case .nemotronOffline, .nemotronStreaming, .nemotronStreaming320:
            let raw = settings.selectedNemotronLanguage.rawValue
            if raw == "auto" {
                break
            }
            return raw
        case .appleSpeech, .appleSpeechAnalyzer:
            return settings.selectedAppleSpeechLocaleIdentifier
        default:
            break
        }
        return settings.onboardingSelectedLanguageID
    }

    static func sourceLanguage(settings: SettingsStore = .shared) -> TranslationLanguage {
        if let fromRecognizer = TranslationLanguageCatalog.language(
            id: self.spokenLanguageID(settings: settings)
        ) {
            return fromRecognizer
        }
        return TranslationLanguageCatalog.language(id: settings.translationSourceLanguageID)
            ?? TranslationLanguageCatalog.english
    }

    static func targetLanguage(settings: SettingsStore = .shared) -> TranslationLanguage {
        TranslationLanguageCatalog.language(id: settings.translationTargetLanguageID)
            ?? TranslationLanguageCatalog.defaultTarget(forSource: self.sourceLanguage(settings: settings))
    }

    static func setSourceLanguage(_ language: TranslationLanguage, settings: SettingsStore = .shared) {
        settings.translationSourceLanguageID = language.id
        settings.onboardingSelectedLanguageID = language.id
        VoiceEngineLanguageCatalog.applyPreferredRoute(forLanguageID: language.id, to: settings)
        if settings.translationTargetLanguageID == language.id {
            settings.translationTargetLanguageID = TranslationLanguageCatalog.defaultTarget(forSource: language).id
        }
    }

    static func pairLabel(settings: SettingsStore = .shared) -> String {
        "\(self.sourceLanguage(settings: settings).displayName) → \(self.targetLanguage(settings: settings).displayName)"
    }
}

enum LiveTranslationTiming {
    /// English default after a finished-looking clause. Language-aware helpers override this.
    static let completeSettleNanoseconds: UInt64 = 700_000_000
    /// English default after no new words on an open thought.
    static let openSettleNanoseconds: UInt64 = 1_100_000_000
    static let commitStabilityNanoseconds: UInt64 = Self.openSettleNanoseconds
    static let minPauseFinalizeCharacters = 22
    static let minPauseFinalizeWords = 4
    /// Thai needs a real clause, not a few syllables.
    static let minPauseFinalizeCharactersThai = 22
    /// Korean/Japanese: only force a pause-cut on a long run-on.
    static let minPauseFinalizeCharactersVerbFinal = 48
    static let maxDraftCharacters = 240
    static let contextSentenceCount = 4
    /// About an hour of lecture clauses at a speaking pace.
    static let maxCommittedLines = 200
    static let polishTimeoutNanoseconds: UInt64 = 2_000_000_000
    static let polishMaxTokens = 64
    static let polishTemperature = 0.1
    static let polishPriorCaptionCount = 2

    static func completeSettleNanoseconds(languageID: String) -> UInt64 {
        switch TranslationClauseSegmenter.languageCode(from: languageID) {
        case "ko", "ja":
            return 1_200_000_000
        case "th":
            return 1_000_000_000
        default:
            return Self.completeSettleNanoseconds
        }
    }

    static func openSettleNanoseconds(languageID: String) -> UInt64 {
        switch TranslationClauseSegmenter.languageCode(from: languageID) {
        case "ko", "ja":
            return 1_800_000_000
        case "th":
            return 1_500_000_000
        default:
            return Self.openSettleNanoseconds
        }
    }

    static func contextCount(languageID: String) -> Int {
        switch TranslationClauseSegmenter.languageCode(from: languageID) {
        case "ko", "ja":
            return 4
        default:
            return Self.contextSentenceCount
        }
    }
}
