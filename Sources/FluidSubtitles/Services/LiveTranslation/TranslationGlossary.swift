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
        if let stored = TranslationLanguageCatalog.language(id: settings.translationSourceLanguageID) {
            return stored
        }
        return TranslationLanguageCatalog.language(id: self.spokenLanguageID(settings: settings))
            ?? TranslationLanguageCatalog.english
    }

    static func voiceEngineSupportsSource(settings: SettingsStore = .shared) -> Bool {
        let source = self.sourceLanguage(settings: settings)
        guard VoiceEngineLanguageCatalog.supports(settings.selectedSpeechModel, languageID: source.id) else {
            return false
        }
        let spoken = TranslationLanguageCatalog.language(id: self.spokenLanguageID(settings: settings))
        return spoken?.id == source.id
    }

    static func voiceEngineMismatchMessage(settings: SettingsStore = .shared) -> String? {
        let source = self.sourceLanguage(settings: settings)
        let spoken = TranslationLanguageCatalog.language(id: self.spokenLanguageID(settings: settings))

        if source.id == TranslationLanguageCatalog.thai.id,
           self.shouldWarnThaiNemotron(settings: settings, spoken: spoken)
        {
            return TranslationLanguageCatalog.thaiNemotronExperimentalWarning
        }

        guard !self.voiceEngineSupportsSource(settings: settings) else { return nil }

        if source.id == TranslationLanguageCatalog.korean.id {
            return self.koreanMismatchMessage(model: settings.selectedSpeechModel, spoken: spoken)
        }

        switch settings.selectedSpeechModel {
        case .parakeetRealtime, .parakeetTDTv2:
            return "Parakeet Flash and TDT v2 only hear English. Switch Voice Engine to Apple Speech or Whisper for \(source.displayName)."
        case .parakeetTDT:
            return "Parakeet TDT v3 does not hear Korean or Thai. Switch Voice Engine to Apple Speech or Whisper for \(source.displayName)."
        default:
            if source.id == TranslationLanguageCatalog.thai.id {
                let heard = spoken?.displayName ?? "another language"
                return "The current Voice Engine is set to hear \(heard), not Thai. Apple Speech or Whisper is the better Theater default."
            }
            let heard = spoken?.displayName ?? "another language"
            return "The current Voice Engine is set to hear \(heard), not \(source.displayName)."
        }
    }

    /// Caption under Theater pickers. Hidden when a mismatch is already showing.
    static func theaterEngineHint(settings: SettingsStore = .shared) -> String? {
        guard self.voiceEngineMismatchMessage(settings: settings) == nil else { return nil }
        return TranslationLanguageCatalog.theaterEngineHint(forSource: self.sourceLanguage(settings: settings))
    }

    static func stageEngineSummary(settings: SettingsStore = .shared) -> String {
        if let mismatch = self.voiceEngineMismatchMessage(settings: settings) {
            return mismatch
        }
        let source = self.sourceLanguage(settings: settings)
        let model = settings.selectedSpeechModel.displayName
        return "Hearing \(source.displayName) with \(model)."
    }

    private static func isNemotronModel(_ model: SettingsStore.SpeechModel) -> Bool {
        switch model {
        case .nemotronOffline, .nemotronStreaming, .nemotronStreaming320:
            return true
        default:
            return false
        }
    }

    private static func shouldWarnThaiNemotron(
        settings: SettingsStore,
        spoken: TranslationLanguage?
    ) -> Bool {
        guard self.isNemotronModel(settings.selectedSpeechModel) else { return false }
        let language = settings.selectedNemotronLanguage
        let isExperimentalThai = language.rawValue.caseInsensitiveCompare("th-TH") == .orderedSame
            || language.displayName.localizedCaseInsensitiveContains("experimental")
        let spokenIsNotThai = spoken?.id != TranslationLanguageCatalog.thai.id
        return isExperimentalThai || spokenIsNotThai
    }

    private static func koreanMismatchMessage(
        model: SettingsStore.SpeechModel,
        spoken: TranslationLanguage?
    ) -> String {
        switch model {
        case .parakeetRealtime, .parakeetTDTv2:
            return "Parakeet Flash and TDT v2 only hear English. Switch to Apple Speech, Cohere, or Whisper for Korean."
        case .parakeetTDT:
            return "Parakeet TDT v3 does not hear Korean. Switch to Apple Speech, Cohere, or Whisper."
        default:
            let heard = spoken?.displayName ?? "English"
            return "The current Voice Engine is set to hear \(heard), not Korean. Switch to Apple Speech, Cohere, or Whisper."
        }
    }

    static func targetLanguage(settings: SettingsStore = .shared) -> TranslationLanguage {
        TranslationLanguageCatalog.language(id: settings.translationTargetLanguageID)
            ?? TranslationLanguageCatalog.defaultTarget(forSource: self.sourceLanguage(settings: settings))
    }

    static func setSourceLanguage(_ language: TranslationLanguage, settings: SettingsStore = .shared) {
        settings.translationSourceLanguageID = language.id
        settings.onboardingSelectedLanguageID = language.id
        Self.pinSpokenEngineToSource(settings: settings)
    }

    static func pinSpokenEngineToSource(settings: SettingsStore = .shared) {
        Self.pinWhisperToSpokenSource(settings: settings)
        Self.pinAppleSpeechToSpokenSource(settings: settings)
    }

    /// Theater Listen refuses Whisper automatic detection. Auto-detect can
    /// flip language mid-talk or silently translate a bilingual clause.
    /// Q&A extras keep auto-detect so English, Korean, and Thai questions can land.
    static func pinWhisperToSpokenSource(settings: SettingsStore = .shared) {
        guard settings.selectedSpeechModel.isWhisperModel else { return }
        if settings.theaterAlsoHearOtherLanguages { return }
        let sourceID = self.sourceLanguage(settings: settings).id
        guard let code = VoiceEngineLanguageCatalog.whisperLanguageCode(for: sourceID) else { return }
        settings.selectedWhisperLanguageCode = code
    }

    /// Speech Analyzer rejects the Mac locale when it is not Korean, English, or Thai.
    static func pinAppleSpeechToSpokenSource(settings: SettingsStore = .shared) {
        switch settings.selectedSpeechModel {
        case .appleSpeech, .appleSpeechAnalyzer:
            break
        default:
            return
        }
        let sourceID = self.sourceLanguage(settings: settings).id
        settings.selectedAppleSpeechLocaleIdentifier =
            VoiceEngineLanguageCatalog.preferredAppleSpeechAnalyzerLocale(forLanguageID: sourceID)
    }

    static func isSameLanguagePair(settings: SettingsStore = .shared) -> Bool {
        self.sourceLanguage(settings: settings).id == self.targetLanguage(settings: settings).id
    }

    static func pairLabel(settings: SettingsStore = .shared) -> String {
        let source = self.sourceLanguage(settings: settings)
        let target = self.targetLanguage(settings: settings)
        if source.id == target.id {
            return "\(source.displayName) captions"
        }
        return "\(source.displayName) → \(target.displayName)"
    }
}

enum LiveTranslationTiming {
    /// English confirm after a finished ending.
    static let completeSettleNanoseconds: UInt64 = 1_000_000_000
    /// English open-thought silence before a forced cut.
    static let openSettleNanoseconds: UInt64 = 3_500_000_000
    /// Brief hold after end-of-utterance so the last ASR tick can land.
    static let eouHoldNanoseconds: UInt64 = 400_000_000
    static let minPauseFinalizeCharacters = 22
    static let minPauseFinalizeWords = 4
    /// Thai needs a real clause, not a few syllables.
    static let minPauseFinalizeCharactersThai = 22
    /// Korean/Japanese: only force a pause-cut on a long run-on.
    static let minPauseFinalizeCharactersVerbFinal = 48
    static let maxDraftCharacters = 240
    /// Start printing a run-on before it becomes a whole paragraph.
    static let followAlongWords = 8
    static let followAlongCharacters = 36
    /// Pause-finalize only this much so a long unpunctuated talk is not one dump.
    static let maxLineWords = 12
    static let maxLineCharacters = 80
    static let contextSentenceCount = 4
    /// Lines shown on Theater at once. The session archive keeps the rest.
    static let visibleTheaterLines = 3
    /// Visible Theater window. Overflow goes to the session archive on disk.
    static let maxCommittedLines = 200
    /// After this much silence, skip ASR ticks and start a new e2e measurement.
    static let silenceHoldNanoseconds: UInt64 = 400_000_000
    static let silenceHoldSeconds: TimeInterval = 0.4
    static let polishPriorCaptionCount = 4
    static let polishTemperature = 0.2
    static let polishMaxTokens = 256
    static let polishTimeoutNanoseconds: UInt64 = 8_000_000_000
    /// Local commit MT must lose to Apple if it is slower than a clause.
    static let commitTranslationTimeoutNanoseconds: UInt64 = 4_000_000_000
    /// After this many local attempts, an 80% echo rate disables local MT for the listen.
    static let localEchoFailMinimumAttempts = 5
    static let localEchoFailRatio = 0.80

    static func completeSettleNanoseconds(languageID: String) -> UInt64 {
        switch TranslationClauseSegmenter.languageCode(from: languageID) {
        case "ko", "ja":
            return 2_000_000_000
        case "th":
            return 1_500_000_000
        default:
            return Self.completeSettleNanoseconds
        }
    }

    static func openSettleNanoseconds(languageID: String) -> UInt64 {
        switch TranslationClauseSegmenter.languageCode(from: languageID) {
        case "ko", "ja":
            return 6_000_000_000
        case "th":
            return 4_000_000_000
        default:
            return Self.openSettleNanoseconds
        }
    }
}
