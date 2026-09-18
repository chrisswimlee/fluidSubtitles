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
        terms.append(contentsOf: TheaterTalkPack.sanitizedTerms(settings.theaterTalkPackTerms))
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
        for term in self.orderedTerms(terms) {
            guard self.containsTerm(term, in: result) else { continue }
            let token = Self.lockToken(index)
            index += 1
            tokens[token] = term
            result = self.replaceTerm(term, with: token, in: result)
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
        self.orderedTerms(terms).filter { term in
            self.containsTerm(term, in: source) && !self.containsTerm(term, in: polished)
        }
    }

    static func containsTerm(_ term: String, in text: String) -> Bool {
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= 2, !text.isEmpty else { return false }
        return text.range(of: self.termPattern(needle), options: self.termOptions(for: needle)) != nil
    }

    /// Short all-caps tokens match as written so IT does not eat "it" and AI does not eat Thai.
    private static func termOptions(for term: String) -> String.CompareOptions {
        if self.requiresExactCase(term) {
            return [.regularExpression]
        }
        return [.regularExpression, .caseInsensitive, .diacriticInsensitive]
    }

    private static func requiresExactCase(_ term: String) -> Bool {
        let letters = term.filter(\.isLetter)
        return letters.count >= 2 && letters.count <= 3 && letters.allSatisfy(\.isUppercase)
    }

    private static func orderedTerms(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var unique: [String] = []
        for term in terms
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .filter({ $0.count >= 2 })
            .sorted(by: { $0.count > $1.count })
        {
            if seen.insert(term.lowercased()).inserted {
                unique.append(term)
            }
        }
        return unique
    }

    private static func replaceTerm(_ term: String, with token: String, in text: String) -> String {
        text.replacingOccurrences(of: self.termPattern(term), with: token, options: self.termOptions(for: term))
    }

    private static func termPattern(_ term: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: term)
        if self.usesWordBoundary(term) {
            return "\\b\(escaped)\\b"
        }
        return escaped
    }

    private static func usesWordBoundary(_ term: String) -> Bool {
        !term.unicodeScalars.contains { scalar in
            (0xAC00...0xD7AF).contains(scalar.value)
                || (0x3040...0x30FF).contains(scalar.value)
                || (0x4E00...0x9FFF).contains(scalar.value)
                || (0x0E00...0x0E7F).contains(scalar.value)
        }
    }

    /// Private-use wrappers so a later term like FT cannot smash a lock token.
    private static func lockToken(_ index: Int) -> String {
        "\u{FFF9}\(index)\u{FFFA}"
    }
}

enum SpokenLanguageResolver {
    /// Either-way pairing is off. Translate stays I speak → Show as.
    static var dynamicPairingAvailable: Bool { false }

    static func spokenLanguageID(settings: SettingsStore = .shared) -> String {
        if let heard = self.heardLanguage(settings: settings) {
            return heard.id
        }
        return self.rawSpokenLanguageID(settings: settings)
    }

    /// What the Voice Engine is actually set to hear, mapped to I speak (en, ko, ja, th).
    /// `en-US` and `en` are the same language.
    static func heardLanguage(settings: SettingsStore = .shared) -> TranslationLanguage? {
        TranslationLanguageCatalog.language(id: self.rawSpokenLanguageID(settings: settings))
    }

    static func rawSpokenLanguageID(settings: SettingsStore = .shared) -> String {
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
        return self.heardLanguage(settings: settings) ?? TranslationLanguageCatalog.english
    }

    static func voiceEngineSupportsSource(settings: SettingsStore = .shared) -> Bool {
        let source = self.sourceLanguage(settings: settings)
        let model = settings.selectedSpeechModel
        guard VoiceEngineLanguageCatalog.supports(model, languageID: source.id) else {
            return false
        }
        if self.heardLanguage(settings: settings)?.id == source.id {
            return true
        }
        if model.isWhisperModel, self.shouldAutoDetectWhisper(settings: settings) {
            return true
        }
        return false
    }

    static func voiceEngineMismatchMessage(settings: SettingsStore = .shared) -> String? {
        let source = self.sourceLanguage(settings: settings)
        let spoken = self.heardLanguage(settings: settings)

        if source.id == TranslationLanguageCatalog.thai.id,
           self.shouldWarnThaiNemotron(settings: settings, spoken: spoken)
        {
            return TranslationLanguageCatalog.thaiNemotronExperimentalWarning
        }

        if spoken?.id == source.id
            || spoken?.displayName == source.displayName
        {
            if VoiceEngineLanguageCatalog.supports(settings.selectedSpeechModel, languageID: source.id) {
                return nil
            }
        }

        guard !self.voiceEngineSupportsSource(settings: settings) else { return nil }

        if source.id == TranslationLanguageCatalog.korean.id
            || source.id == TranslationLanguageCatalog.japanese.id
        {
            return self.verbFinalMismatchMessage(
                language: source,
                model: settings.selectedSpeechModel,
                spoken: spoken
            )
        }

        switch settings.selectedSpeechModel {
        case .parakeetRealtime, .parakeetTDTv2:
            return "Parakeet Flash and TDT v2 only hear English. Switch Voice Engine to Apple Speech or Whisper for \(source.displayName)."
        case .parakeetTDT:
            return "Parakeet TDT v3 does not hear Korean, Japanese, or Thai. Switch Voice Engine to Apple Speech or Whisper for \(source.displayName)."
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
        if self.isDynamicPairingEnabled(settings: settings) {
            return TheaterReadiness.dynamicPairingHint(isWhisper: settings.selectedSpeechModel.isWhisperModel)
        }
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

    private static func verbFinalMismatchMessage(
        language: TranslationLanguage,
        model: SettingsStore.SpeechModel,
        spoken: TranslationLanguage?
    ) -> String {
        switch model {
        case .parakeetRealtime, .parakeetTDTv2:
            return "Parakeet Flash and TDT v2 only hear English. Switch to Apple Speech, Cohere, or Whisper for \(language.displayName)."
        case .parakeetTDT:
            return "Parakeet TDT v3 does not hear \(language.displayName). Switch to Apple Speech, Cohere, or Whisper."
        default:
            let heard = spoken?.displayName ?? "English"
            return "The current Voice Engine is set to hear \(heard), not \(language.displayName). Switch to Apple Speech, Cohere, or Whisper."
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
        Self.pinCohereToSpokenSource(settings: settings)
        Self.pinNemotronToSpokenSource(settings: settings)
    }

    /// Pins every Voice Engine language binding to I speak. Returns true when
    /// the selected engine's listening language changed and ASR must reload.
    @discardableResult
    static func syncSpokenEngineToTheater(settings: SettingsStore = .shared) -> Bool {
        let before = self.selectedEngineLanguageKey(settings: settings)
        self.pinSpokenEngineToSource(settings: settings)
        return before != self.selectedEngineLanguageKey(settings: settings)
    }

    static func selectedEngineLanguageKey(settings: SettingsStore = .shared) -> String {
        switch settings.selectedSpeechModel {
        case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLargeTurbo, .whisperLarge:
            return "whisper:\(settings.selectedWhisperLanguageCode ?? "auto")"
        case .appleSpeech, .appleSpeechAnalyzer:
            return "apple:\(settings.selectedAppleSpeechLocaleIdentifier)"
        case .cohereTranscribeSixBit:
            return "cohere:\(settings.selectedCohereLanguage.rawValue)"
        case .nemotronOffline, .nemotronStreaming, .nemotronStreaming320:
            return "nemotron:\(settings.selectedNemotronLanguage.rawValue)"
        default:
            return settings.selectedSpeechModel.rawValue
        }
    }

    /// Theater Listen refuses Whisper automatic detection unless Q&A extras
    /// are on. Either way is a later product. Auto-detect can flip language
    /// mid-talk or silently translate a bilingual clause.
    static func pinWhisperToSpokenSource(settings: SettingsStore = .shared) {
        if self.shouldAutoDetectWhisper(settings: settings) { return }
        let sourceID = self.sourceLanguage(settings: settings).id
        guard let code = VoiceEngineLanguageCatalog.whisperLanguageCode(for: sourceID) else { return }
        settings.selectedWhisperLanguageCode = code
    }

    /// Speech Analyzer rejects the Mac locale when it is not Korean, English, Japanese, or Thai.
    static func pinAppleSpeechToSpokenSource(settings: SettingsStore = .shared) {
        let sourceID = self.sourceLanguage(settings: settings).id
        settings.selectedAppleSpeechLocaleIdentifier =
            VoiceEngineLanguageCatalog.preferredAppleSpeechAnalyzerLocale(forLanguageID: sourceID)
    }

    static func pinCohereToSpokenSource(settings: SettingsStore = .shared) {
        let sourceID = self.sourceLanguage(settings: settings).id
        guard let language = VoiceEngineLanguageCatalog.cohereLanguage(forLanguageID: sourceID) else { return }
        settings.selectedCohereLanguage = language
    }

    static func pinNemotronToSpokenSource(settings: SettingsStore = .shared) {
        let sourceID = self.sourceLanguage(settings: settings).id
        guard let language = VoiceEngineLanguageCatalog.nemotronLanguage(forLanguageID: sourceID) else { return }
        settings.selectedNemotronLanguage = language
    }

    static func isSameLanguagePair(settings: SettingsStore = .shared) -> Bool {
        if settings.theaterSessionMode == .transcription { return true }
        return self.sourceLanguage(settings: settings).id == self.targetLanguage(settings: settings).id
    }

    static func pairLabel(settings: SettingsStore = .shared) -> String {
        let source = self.sourceLanguage(settings: settings)
        let target = self.targetLanguage(settings: settings)
        if source.id == target.id {
            return "\(source.displayName) captions"
        }
        if self.isDynamicPairingEnabled(settings: settings) {
            return "\(source.displayName) ↔ \(target.displayName)"
        }
        return "\(source.displayName) → \(target.displayName)"
    }

    static func shouldAutoDetectWhisper(settings: SettingsStore = .shared) -> Bool {
        settings.theaterAlsoHearOtherLanguages || self.isDynamicPairingEnabled(settings: settings)
    }

    /// Auto-detecting the spoken language and swapping source/target based on
    /// what was heard is removed: translation always runs in the one fixed
    /// direction the user configured (I speak -> Show as), never "either way".
    static func isDynamicPairingEnabled(settings _: SettingsStore = .shared) -> Bool {
        false
    }

    /// I speak / Show as. Always the fixed configured direction.
    static func pairForSpokenText(
        _: String,
        settings: SettingsStore = .shared
    ) -> (source: TranslationLanguage, target: TranslationLanguage) {
        (self.sourceLanguage(settings: settings), self.targetLanguage(settings: settings))
    }

    static func listenLanguageID(for text: String, settings: SettingsStore = .shared) -> String {
        self.pairForSpokenText(text, settings: settings).source.id
    }
}

enum SpokenScriptDetector {
    static func languageID(in text: String, among allowed: [String]) -> String? {
        let allowedIDs = Set(allowed)
        guard !allowedIDs.isEmpty else { return nil }
        var scores: [String: Int] = [:]
        let countHanForJapanese = allowedIDs.contains(TranslationLanguageCatalog.japanese.id)
            && !allowedIDs.contains(TranslationLanguageCatalog.korean.id)

        for scalar in text.unicodeScalars {
            if Self.isHangul(scalar) {
                Self.add("ko", to: &scores, allowed: allowedIDs)
            } else if Self.isThai(scalar) {
                Self.add("th", to: &scores, allowed: allowedIDs)
            } else if Self.isKana(scalar) {
                Self.add("ja", to: &scores, allowed: allowedIDs)
            } else if countHanForJapanese, Self.isHan(scalar) {
                Self.add("ja", to: &scores, allowed: allowedIDs)
            } else if Self.isLatinLetter(scalar) {
                Self.add("en", to: &scores, allowed: allowedIDs)
            }
        }

        let ranked = scores.filter { $0.value > 0 }.sorted { $0.value > $1.value }
        guard let top = ranked.first, top.value >= 2 else { return nil }
        if let second = ranked.dropFirst().first, second.value * 2 >= top.value {
            return nil
        }
        return top.key
    }

    private static func add(_ id: String, to scores: inout [String: Int], allowed: Set<String>) {
        guard allowed.contains(id) else { return }
        scores[id, default: 0] += 1
    }

    private static func isLatinLetter(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.letters.contains(scalar) && scalar.value < 0x0250
    }

    private static func isHangul(_ scalar: Unicode.Scalar) -> Bool {
        (0x1100 ... 0x11FF).contains(scalar.value)
            || (0x3130 ... 0x318F).contains(scalar.value)
            || (0xAC00 ... 0xD7AF).contains(scalar.value)
    }

    private static func isKana(_ scalar: Unicode.Scalar) -> Bool {
        (0x3040 ... 0x30FF).contains(scalar.value)
            || (0x31F0 ... 0x31FF).contains(scalar.value)
            || (0xFF66 ... 0xFF9D).contains(scalar.value)
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00 ... 0x9FFF).contains(scalar.value)
            || (0x3400 ... 0x4DBF).contains(scalar.value)
    }

    private static func isThai(_ scalar: Unicode.Scalar) -> Bool {
        (0x0E00 ... 0x0E7F).contains(scalar.value)
    }
}

nonisolated enum LiveTranslationTiming {
    /// English confirm after a finished ending.
    static let completeSettleNanoseconds: UInt64 = 500_000_000
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
    /// Floor for a pause-cut so a leftover is a clause, not two words.
    static let followAlongWords = 8
    /// Pause-finalize only this much so a long unpunctuated talk is not one dump.
    static let maxLineWords = 12
    static let maxLineCharacters = 80
    static let contextSentenceCount = 4
    /// Captions kept on the Theater board. Off-screen lines are dropped.
    static let visibleTheaterLines = 3
    static let maxCommittedLines = visibleTheaterLines
    /// After this much silence, skip ASR ticks and start a new e2e measurement.
    static let silenceHoldNanoseconds: UInt64 = 400_000_000
    static let silenceHoldSeconds: TimeInterval = 0.4
    static let polishPriorCaptionCount = 4
    static let polishTemperature = 0.2
    static let polishMaxTokens = 256
    /// A commit MT call must fail, not hang, since the burst-safe log
    /// holds the row until `inFlightSources` is empty again. `warmAppleTranslation`
    /// is fire-and-forget at session start, not awaited — the session's first
    /// commit can race a cold Apple Translation session start (model load,
    /// first `.translationTask` attach), which can take longer than a few
    /// seconds. This only needs to catch a truly hung call, not enforce
    /// snappy latency, so the floor stays generous.
    static let translateClauseTimeoutNanoseconds: UInt64 = 25_000_000_000
    /// Local first-print polish and Apple-failure MT must lose to Apple if slower than a clause.
    static let commitTranslationTimeoutNanoseconds: UInt64 = 4_000_000_000
    /// After this many local attempts, an 80% miss rate disables local MT for the listen.
    static let localEchoFailMinimumAttempts = 5
    static let localEchoFailRatio = 0.80

    static func completeSettleNanoseconds(languageID: String) -> UInt64 {
        switch TranslationClauseSegmenter.languageCode(from: languageID) {
        case "ko", "ja":
            return 1_000_000_000
        case "th":
            return 800_000_000
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
