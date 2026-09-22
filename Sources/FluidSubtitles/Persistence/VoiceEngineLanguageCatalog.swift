import Foundation
#if canImport(Speech)
import Speech
#endif

// swiftlint:disable function_body_length cyclomatic_complexity type_body_length
// Tracked grandfather: existing FluidVoice-era file. New work belongs in a smaller file.

struct VoiceEngineLanguage: Identifiable, Equatable {
    let id: String
    let displayName: String
    let aliases: [String]
    let isPopular: Bool

    var popularDisplayName: String {
        self.id == "zh" ? "Mandarin" : self.displayName
    }
}

struct VoiceEngineLanguageRoute: Identifiable, Equatable {
    enum LanguageBinding: Equatable {
        case automatic
        case appleSpeech(localeIdentifier: String)
        case cohere(SettingsStore.CohereLanguage)
        case nemotron(SettingsStore.NemotronLanguage)
        case whisper(languageCode: String)

        var id: String {
            switch self {
            case .automatic:
                return "auto"
            case let .appleSpeech(localeIdentifier):
                return "apple-\(localeIdentifier)"
            case let .cohere(language):
                return "cohere-\(language.rawValue)"
            case let .nemotron(language):
                return "nemotron-\(language.rawValue)"
            case let .whisper(languageCode):
                return "whisper-\(languageCode)"
            }
        }
    }

    let language: VoiceEngineLanguage
    let model: SettingsStore.SpeechModel
    let binding: LanguageBinding

    var id: String {
        "\(self.language.id)-\(self.model.rawValue)-\(self.binding.id)"
    }

    /// Language-aware badge. UI can keep reading `route.badgeText`.
    var badgeText: String? {
        VoiceEngineLanguageCatalog.badgeText(for: self)
    }
}

enum VoiceEngineLanguageCatalog {
    static let productLanguageIDs: Set<String> = TranslationLanguageCatalog.supportedIDs

    static func isProductLanguageID(_ id: String) -> Bool {
        let normalized = id.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        let prefix = normalized.split(separator: "-").first.map(String.init) ?? normalized
        return self.productLanguageIDs.contains(prefix)
    }

    static func allLanguages(
        availableModels: [SettingsStore.SpeechModel] = SettingsStore.SpeechModel.availableModels
    ) -> [VoiceEngineLanguage] {
        self.languageDefinitions.filter { language in
            Self.productLanguageIDs.contains(language.id)
                && !Self.routes(for: language, availableModels: availableModels).isEmpty
        }
    }

    static func popularLanguages(
        availableModels: [SettingsStore.SpeechModel] = SettingsStore.SpeechModel.availableModels
    ) -> [VoiceEngineLanguage] {
        self.allLanguages(availableModels: availableModels).filter(\.isPopular)
    }

    static func searchableLanguages(
        query: String,
        availableModels: [SettingsStore.SpeechModel] = SettingsStore.SpeechModel.availableModels
    ) -> [VoiceEngineLanguage] {
        let languages = Self.allLanguages(availableModels: availableModels)
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else { return languages }

        return languages.filter { language in
            language.displayName.lowercased().contains(normalizedQuery) ||
                language.id.lowercased().contains(normalizedQuery) ||
                language.aliases.contains { $0.lowercased().contains(normalizedQuery) }
        }
    }

    static func language(
        id: String,
        availableModels: [SettingsStore.SpeechModel] = SettingsStore.SpeechModel.availableModels
    ) -> VoiceEngineLanguage? {
        self.allLanguages(availableModels: availableModels).first { $0.id == id }
    }

    static var whisperLanguages: [VoiceEngineLanguage] {
        self.languageDefinitions.filter {
            Self.productLanguageIDs.contains($0.id) && self.whisperLanguageCode(for: $0.id) != nil
        }
    }

    static var productCohereLanguages: [SettingsStore.CohereLanguage] {
        SettingsStore.CohereLanguage.allCases.filter { self.productLanguageIDs.contains($0.rawValue) }
    }

    static var productNemotronLanguages: [SettingsStore.NemotronLanguage] {
        SettingsStore.NemotronLanguage.allCases.filter { language in
            language == .auto || self.isProductLanguageID(language.rawValue)
        }
    }

    static func whisperLanguage(forCode languageCode: String) -> VoiceEngineLanguage? {
        self.whisperLanguages.first { self.whisperLanguageCode(for: $0.id) == languageCode }
    }

    static func routes(
        for language: VoiceEngineLanguage,
        availableModels: [SettingsStore.SpeechModel] = SettingsStore.SpeechModel.availableModels
    ) -> [VoiceEngineLanguageRoute] {
        self.routeCandidates(for: language).filter { route in
            availableModels.contains(route.model)
        }
    }

    /// The onboarding card: this Mac's default Voice Engine, then Apple Speech.
    static func preferredOnboardingRoute(among routes: [VoiceEngineLanguageRoute]) -> VoiceEngineLanguageRoute? {
        let preferredModel = SettingsStore.SpeechModel.defaultModel
        if let route = routes.first(where: { $0.model == preferredModel }) {
            return route
        }
        if let speech = routes.first(where: { $0.model == .appleSpeech }) {
            return speech
        }
        return routes.first
    }

    static func preferredOnboardingRoute(forLanguageID languageID: String) -> VoiceEngineLanguageRoute? {
        self.preferredOnboardingRoute(among: self.routes(forLanguageID: languageID))
    }

    static func routes(
        forLanguageID languageID: String,
        availableModels: [SettingsStore.SpeechModel] = SettingsStore.SpeechModel.availableModels
    ) -> [VoiceEngineLanguageRoute] {
        guard let language = Self.language(id: languageID, availableModels: availableModels) else {
            return []
        }
        return Self.routes(for: language, availableModels: availableModels)
    }

    static func apply(_ route: VoiceEngineLanguageRoute, to settings: SettingsStore = .shared) {
        settings.onboardingSelectedLanguageID = route.language.id
        if let translationLanguage = TranslationLanguageCatalog.language(id: route.language.id) {
            settings.translationSourceLanguageID = translationLanguage.id
        }
        settings.selectedSpeechModel = route.model

        switch route.binding {
        case .automatic:
            break
        case let .whisper(languageCode):
            settings.selectedWhisperLanguageCode = languageCode
        case let .appleSpeech(localeIdentifier):
            settings.selectedAppleSpeechLocaleIdentifier = localeIdentifier
        case let .cohere(language):
            settings.selectedCohereLanguage = language
        case let .nemotron(language):
            settings.selectedNemotronLanguage = language
        }
    }

    static func applyPreferredRoute(forLanguageID languageID: String, to settings: SettingsStore = .shared) {
        guard let language = Self.language(id: languageID) else { return }
        let routes = Self.routes(for: language)
        let preferred = Self.preferredLocalRoute(from: routes) ?? routes.first
        if let preferred {
            Self.apply(preferred, to: settings)
        }
    }

    /// Recommended on the first preferred model for this language.
    /// Thai Nemotron keeps the quieter Experimental label already used in Settings.
    static func badgeText(for route: VoiceEngineLanguageRoute) -> String? {
        if Self.isFirstPreferredRoute(route) {
            return "Recommended"
        }
        if route.language.id == "en", route.model == .parakeetRealtime {
            return "Faster English"
        }
        if route.language.id == "th", Self.isNemotron(route.model) {
            return "Experimental"
        }
        return nil
    }

    /// True when this Voice Engine can hear the product language, not merely
    /// when its leftover locale string happens to match.
    static func supports(_ model: SettingsStore.SpeechModel, languageID: String) -> Bool {
        Self.routes(forLanguageID: languageID).contains { $0.model == model }
    }

    /// Returns the selected engine's route when it can hear this language.
    /// Does not change the Voice Engine the user picked.
    @discardableResult
    static func ensureCompatibleEngine(
        forLanguageID languageID: String,
        settings: SettingsStore = .shared
    ) -> VoiceEngineLanguageRoute? {
        guard let language = Self.language(id: languageID) else { return nil }
        return Self.routes(for: language).first { $0.model == settings.selectedSpeechModel }
    }

    private static func preferredLocalRoute(from routes: [VoiceEngineLanguageRoute]) -> VoiceEngineLanguageRoute? {
        guard let languageID = routes.first?.language.id else { return nil }
        let order = Self.preferredModelOrder(forLanguageID: languageID)
        for model in order {
            if let route = routes.first(where: { $0.model == model && model.isInstalled }) {
                return route
            }
        }
        for model in order {
            if let route = routes.first(where: { $0.model == model }) {
                return route
            }
        }
        return nil
    }

    /// en: Apple Speech Analyzer, then Apple Speech, then Flash (faster English), then the rest.
    /// ko / ja: Apple Speech Analyzer, Apple Speech, Cohere, Whisper, Nemotron. Never Parakeet.
    /// th: Apple Speech Analyzer, Apple Speech, Whisper, Nemotron last. Never Parakeet or Cohere.
    private static func preferredModelOrder(forLanguageID languageID: String) -> [SettingsStore.SpeechModel] {
        switch languageID {
        case "en":
            return [
                .appleSpeechAnalyzer,
                .appleSpeech,
                .parakeetRealtime,
                .parakeetTDTv2,
                .whisperSmall,
                .whisperLargeTurbo,
                .parakeetTDT,
                .nemotronStreaming,
                .nemotronOffline,
                .cohereTranscribeSixBit,
            ]
        case "ko", "ja":
            return [
                .appleSpeechAnalyzer,
                .appleSpeech,
                .cohereTranscribeSixBit,
                .whisperLargeTurbo,
                .whisperLarge,
                .whisperSmall,
                .nemotronStreaming,
                .nemotronOffline,
            ]
        case "th":
            return [
                .appleSpeechAnalyzer,
                .appleSpeech,
                .whisperLargeTurbo,
                .whisperLarge,
                .whisperSmall,
                .nemotronStreaming,
                .nemotronOffline,
            ]
        default:
            return [
                .appleSpeechAnalyzer,
                .appleSpeech,
                .whisperSmall,
                .whisperLargeTurbo,
                .parakeetTDTv2,
                .parakeetTDT,
                .parakeetRealtime,
                .nemotronStreaming,
                .nemotronOffline,
                .cohereTranscribeSixBit,
            ]
        }
    }

    /// Thai + any Nemotron is weak when Apple Speech or Whisper can take over.
    /// English Whisper / Cohere / Nemotron stay put even if Parakeet Flash or
    /// TDT v2 is in the route list — do not yank a user's chosen engine.
    private static func isWeakMatch(
        _ route: VoiceEngineLanguageRoute,
        preferred: VoiceEngineLanguageRoute?
    ) -> Bool {
        guard route.language.id == "th", Self.isNemotron(route.model) else {
            return false
        }
        guard let preferred, !Self.isNemotron(preferred.model) else {
            return false
        }
        return true
    }

    private static func isFirstPreferredRoute(_ route: VoiceEngineLanguageRoute) -> Bool {
        let candidateModels = Set(Self.routeCandidates(for: route.language).map(\.model))
            .intersection(SettingsStore.SpeechModel.availableModels)
        guard let first = Self.preferredModelOrder(forLanguageID: route.language.id)
            .first(where: { candidateModels.contains($0) })
        else {
            return false
        }
        return first == route.model
    }

    private static func isNemotron(_ model: SettingsStore.SpeechModel) -> Bool {
        switch model {
        case .nemotronOffline, .nemotronStreaming, .nemotronStreaming320:
            return true
        default:
            return false
        }
    }

    private static func routeCandidates(for language: VoiceEngineLanguage) -> [VoiceEngineLanguageRoute] {
        var routes: [VoiceEngineLanguageRoute] = []

        // Product Parakeet routes are English-only (Flash, TDT v2, and TDT v3).
        if language.id == "en" {
            routes.append(Self.route(language, .parakeetRealtime, .automatic))
            routes.append(Self.route(language, .parakeetTDTv2, .automatic))
            if Self.parakeetV3LanguageIDs.contains(language.id) {
                routes.append(Self.route(language, .parakeetTDT, .automatic))
            }
        }

        // Cohere has no Thai model.
        if language.id != "th", let cohereLanguage = Self.cohereLanguage(for: language.id) {
            routes.append(Self.route(language, .cohereTranscribeSixBit, .cohere(cohereLanguage)))
        }

        if let nemotronLanguage = Self.nemotronLanguage(for: language.id) {
            routes.append(Self.route(language, .nemotronStreaming, .nemotron(nemotronLanguage)))
            routes.append(Self.route(language, .nemotronOffline, .nemotron(nemotronLanguage)))
        }

        if let whisperLanguageCode = Self.whisperLanguageCode(for: language.id) {
            for model in Self.whisperModelOrder {
                routes.append(Self.route(language, model, .whisper(languageCode: whisperLanguageCode)))
            }
        }

        if let appleSpeechAnalyzerLocale = Self.appleSpeechAnalyzerLocaleIdentifier(for: language.id) {
            routes.append(Self.route(language, .appleSpeechAnalyzer, .appleSpeech(localeIdentifier: appleSpeechAnalyzerLocale)))
        }

        if let appleSpeechLegacyLocale = Self.appleSpeechLegacyLocaleIdentifier(for: language.id) {
            routes.append(Self.route(language, .appleSpeech, .appleSpeech(localeIdentifier: appleSpeechLegacyLocale)))
        }

        let order = Self.preferredModelOrder(forLanguageID: language.id)
        return routes.sorted { lhs, rhs in
            let left = order.firstIndex(of: lhs.model) ?? order.count
            let right = order.firstIndex(of: rhs.model) ?? order.count
            return left < right
        }
    }

    private static func route(
        _ language: VoiceEngineLanguage,
        _ model: SettingsStore.SpeechModel,
        _ binding: VoiceEngineLanguageRoute.LanguageBinding
    ) -> VoiceEngineLanguageRoute {
        VoiceEngineLanguageRoute(language: language, model: model, binding: binding)
    }

    static func cohereLanguage(forLanguageID languageID: String) -> SettingsStore.CohereLanguage? {
        self.cohereLanguageMap[self.languagePrefix(languageID)]
    }

    static func nemotronLanguage(forLanguageID languageID: String) -> SettingsStore.NemotronLanguage? {
        self.nemotronLanguageMap[self.languagePrefix(languageID)]
            ?? self.nemotronLanguageMap[languageID]
    }

    private static func cohereLanguage(for languageID: String) -> SettingsStore.CohereLanguage? {
        self.cohereLanguage(forLanguageID: languageID)
    }

    private static func nemotronLanguage(for languageID: String) -> SettingsStore.NemotronLanguage? {
        self.nemotronLanguage(forLanguageID: languageID)
    }

    static func whisperLanguageCode(for languageID: String) -> String? {
        self.whisperLanguageCodeMap[languageID]
    }

    static func appleSpeechAnalyzerLocaleIdentifier(for languageID: String) -> String? {
        self.appleSpeechAnalyzerLocaleMap[self.languagePrefix(languageID)]
    }

    /// Speech Analyzer locale when this Mac has one. Otherwise the Apple Speech
    /// locale for that language, so a new I speak is not pinned to English.
    static func preferredAppleSpeechAnalyzerLocale(forLanguageID languageID: String) -> String {
        if let mapped = self.appleSpeechAnalyzerLocaleIdentifier(for: languageID) {
            return mapped
        }
        if let legacy = self.appleSpeechLegacyLocaleIdentifier(for: self.languagePrefix(languageID)) {
            return legacy
        }
        return self.appleSpeechAnalyzerLocaleMap["en"] ?? "en-US"
    }

    /// SpeechAnalyzer compares BCP-47 IDs exactly. `en` is not `en-US`.
    /// Pick a supported locale for I speak (Korean, English, Japanese, or Thai).
    static func resolveAppleSpeechAnalyzerLocale(
        preferredIdentifier: String,
        languageID: String,
        supportedIdentifiers: [String]
    ) -> String? {
        let supported = supportedIdentifiers
            .map { self.normalizeLocaleID($0) }
            .filter { !$0.isEmpty }
        guard !supported.isEmpty else { return nil }

        let language = TranslationLanguageCatalog.language(id: languageID)?.id
            ?? TranslationLanguageCatalog.language(id: preferredIdentifier)?.id
            ?? "en"
        let mapped = self.preferredAppleSpeechAnalyzerLocale(forLanguageID: language)
        let preferred = self.normalizeLocaleID(preferredIdentifier)
        var candidates = [mapped, language]
        if self.languagePrefix(preferred) == language {
            candidates.insert(preferred, at: 0)
        }

        for candidate in candidates {
            if let match = self.bestAppleSpeechAnalyzerMatch(candidate, in: supported) {
                return match
            }
        }
        return nil
    }

    static func normalizeLocaleID(_ identifier: String) -> String {
        identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
    }

    static func languagePrefix(_ identifier: String) -> String {
        let normalized = self.normalizeLocaleID(identifier).lowercased()
        return normalized.split(separator: "-").first.map(String.init) ?? normalized
    }

    private static func bestAppleSpeechAnalyzerMatch(_ candidate: String, in supported: [String]) -> String? {
        let needle = self.normalizeLocaleID(candidate)
        if let exact = supported.first(where: { $0.caseInsensitiveCompare(needle) == .orderedSame }) {
            return exact
        }
        let prefix = self.languagePrefix(needle)
        let mapped = self.normalizeLocaleID(self.preferredAppleSpeechAnalyzerLocale(forLanguageID: prefix))
        if let preferred = supported.first(where: { $0.caseInsensitiveCompare(mapped) == .orderedSame }) {
            return preferred
        }
        return supported.first { self.languagePrefix($0) == prefix }
    }

    private static func appleSpeechLegacyLocaleIdentifier(for languageID: String) -> String? {
        guard let preferredLocales = self.appleSpeechLegacyLocalePreferences[languageID] else {
            return nil
        }

        let supportedLocales = self.legacyAppleLocaleIDs
        return preferredLocales.first { supportedLocales.contains($0) }
    }

    private static let popularLanguageIDs: Set<String> = Self.productLanguageIDs

    private static let parakeetV3LanguageIDs: Set<String> = [
        "bg",
        "hr",
        "cs",
        "da",
        "nl",
        "en",
        "et",
        "fi",
        "fr",
        "de",
        "el",
        "hu",
        "it",
        "lv",
        "lt",
        "mt",
        "pl",
        "pt",
        "ro",
        "sk",
        "sl",
        "es",
        "sv",
        "ru",
        "uk",
    ]

    private static let cohereLanguageMap: [String: SettingsStore.CohereLanguage] = [
        "ar": .arabic,
        "de": .german,
        "el": .greek,
        "en": .english,
        "es": .spanish,
        "fr": .french,
        "it": .italian,
        "ja": .japanese,
        "ko": .korean,
        "nl": .dutch,
        "pl": .polish,
        "pt": .portuguese,
        "vi": .vietnamese,
        "zh": .mandarinChinese,
    ]

    private static let nemotronLanguageMap: [String: SettingsStore.NemotronLanguage] = {
        let supportedLanguageIDs = Set(Self.languageDefinitions.map(\.id))
        var languageMap: [String: SettingsStore.NemotronLanguage] = [:]

        for nemotronLanguage in SettingsStore.NemotronLanguage.allCases where nemotronLanguage.rawValue != SettingsStore.NemotronLanguage.auto.rawValue {
            let languageID = Self.languageID(forNemotronLanguage: nemotronLanguage)
            guard supportedLanguageIDs.contains(languageID) else { continue }
            languageMap[languageID] = nemotronLanguage
        }

        return languageMap
    }()

    private static func languageID(forNemotronLanguage language: SettingsStore.NemotronLanguage) -> String {
        switch language.rawValue {
        case "nb-NO":
            return "no"
        default:
            return language.rawValue
                .split(separator: "-", maxSplits: 1)
                .first
                .map(String.init) ?? language.rawValue
        }
    }

    private static let whisperModelOrder: [SettingsStore.SpeechModel] = [
        .whisperSmall,
        .whisperLargeTurbo,
        .whisperLarge,
        .whisperMedium,
        .whisperBase,
        .whisperTiny,
    ]

    /// Locales SpeechTranscriber lists on macOS 27, plus Thai.
    private static let appleSpeechAnalyzerLocaleMap: [String: String] = [
        "de": "de-DE",
        "en": "en-US",
        "es": "es-ES",
        "fr": "fr-FR",
        "hi": "hi-IN",
        "it": "it-IT",
        "ja": "ja-JP",
        "ko": "ko-KR",
        "pt": "pt-BR",
        "th": "th-TH",
        "zh": "zh-CN",
    ]

    private static let appleSpeechLegacyLocalePreferences: [String: [String]] = [
        "ar": ["ar-SA"],
        "ca": ["ca-ES"],
        "cs": ["cs-CZ"],
        "da": ["da-DK"],
        "de": ["de-DE", "de-AT", "de-CH"],
        "el": ["el-GR"],
        "en": ["en-US", "en-GB", "en-CA", "en-AU", "en-IN"],
        "es": ["es-US", "es-ES", "es-MX", "es-419"],
        "fi": ["fi-FI"],
        "fr": ["fr-FR", "fr-CA", "fr-BE", "fr-CH"],
        "he": ["he-IL"],
        "hi": ["hi-IN"],
        "hr": ["hr-HR"],
        "hu": ["hu-HU"],
        "id": ["id-ID"],
        "it": ["it-IT", "it-CH"],
        "ja": ["ja-JP"],
        "ko": ["ko-KR"],
        "ms": ["ms-MY"],
        "nl": ["nl-NL", "nl-BE"],
        "no": ["nb-NO"],
        "pl": ["pl-PL"],
        "pt": ["pt-BR", "pt-PT"],
        "ro": ["ro-RO"],
        "ru": ["ru-RU"],
        "sk": ["sk-SK"],
        "sv": ["sv-SE"],
        "th": ["th-TH"],
        "tr": ["tr-TR"],
        "uk": ["uk-UA"],
        "vi": ["vi-VN"],
        "zh": ["zh-CN", "zh-TW", "zh-HK"],
    ]

    private static let legacyAppleLocaleIDs: Set<String> = {
        #if canImport(Speech)
        if #available(macOS 10.15, *) {
            return Set(SFSpeechRecognizer.supportedLocales().map { Self.normalizedLocaleIdentifier($0.identifier) })
        }
        #endif
        return []
    }()

    private static func normalizedLocaleIdentifier(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-")
    }

    private static let whisperLanguageCodeMap: [String: String] = {
        var languageMap: [String: String] = [:]
        for language in Self.languageDefinitions {
            let whisperCode = language.id
            guard Self.whisperSupportedLanguageCodes.contains(whisperCode) else { continue }
            languageMap[language.id] = whisperCode
        }
        return languageMap
    }()

    private static let whisperSupportedLanguageCodes: Set<String> = [
        "af", "am", "ar", "as", "az", "ba", "be", "bg", "bn", "bo",
        "br", "bs", "ca", "cs", "cy", "da", "de", "el", "en", "es",
        "et", "eu", "fa", "fi", "fo", "fr", "gl", "gu", "ha", "haw",
        "he", "hi", "hr", "ht", "hu", "hy", "id", "is", "it", "ja",
        "jw", "ka", "kk", "km", "kn", "ko", "la", "lb", "ln", "lo",
        "lt", "lv", "mg", "mi", "mk", "ml", "mn", "mr", "ms", "mt",
        "my", "ne", "nl", "nn", "no", "oc", "pa", "pl", "ps", "pt",
        "ro", "ru", "sa", "sd", "si", "sk", "sl", "sn", "so", "sq",
        "sr", "su", "sv", "sw", "ta", "te", "tg", "th", "tk", "tl",
        "tr", "tt", "uk", "ur", "uz", "vi", "yi", "yo", "zh",
    ]

    private static let languageDefinitions: [VoiceEngineLanguage] = [
        Self.language("af", "Afrikaans"),
        Self.language("am", "Amharic"),
        Self.language("ar", "Arabic", aliases: ["Arab"]),
        Self.language("as", "Assamese"),
        Self.language("az", "Azerbaijani"),
        Self.language("ba", "Bashkir"),
        Self.language("be", "Belarusian"),
        Self.language("bg", "Bulgarian"),
        Self.language("bn", "Bengali", aliases: ["Bangla"]),
        Self.language("bo", "Tibetan"),
        Self.language("br", "Breton"),
        Self.language("bs", "Bosnian"),
        Self.language("ca", "Catalan"),
        Self.language("cs", "Czech"),
        Self.language("cy", "Welsh"),
        Self.language("da", "Danish"),
        Self.language("de", "German", aliases: ["Deutsch"]),
        Self.language("el", "Greek"),
        Self.language("en", "English"),
        Self.language("es", "Spanish", aliases: ["Castilian"]),
        Self.language("et", "Estonian"),
        Self.language("eu", "Basque"),
        Self.language("fa", "Persian", aliases: ["Farsi"]),
        Self.language("fi", "Finnish"),
        Self.language("fo", "Faroese"),
        Self.language("fr", "French"),
        Self.language("gl", "Galician"),
        Self.language("gu", "Gujarati"),
        Self.language("ha", "Hausa"),
        Self.language("haw", "Hawaiian"),
        Self.language("he", "Hebrew"),
        Self.language("hi", "Hindi"),
        Self.language("hr", "Croatian"),
        Self.language("ht", "Haitian Creole"),
        Self.language("hu", "Hungarian"),
        Self.language("hy", "Armenian"),
        Self.language("id", "Indonesian"),
        Self.language("is", "Icelandic"),
        Self.language("it", "Italian"),
        Self.language("ja", "Japanese"),
        Self.language("jw", "Javanese"),
        Self.language("ka", "Georgian"),
        Self.language("kk", "Kazakh"),
        Self.language("km", "Khmer"),
        Self.language("kn", "Kannada"),
        Self.language("ko", "Korean"),
        Self.language("la", "Latin"),
        Self.language("lb", "Luxembourgish"),
        Self.language("ln", "Lingala"),
        Self.language("lo", "Lao"),
        Self.language("lt", "Lithuanian"),
        Self.language("lv", "Latvian"),
        Self.language("mg", "Malagasy"),
        Self.language("mi", "Maori"),
        Self.language("mk", "Macedonian"),
        Self.language("ml", "Malayalam"),
        Self.language("mn", "Mongolian"),
        Self.language("mr", "Marathi"),
        Self.language("ms", "Malay"),
        Self.language("mt", "Maltese"),
        Self.language("my", "Myanmar", aliases: ["Burmese"]),
        Self.language("ne", "Nepali"),
        Self.language("nl", "Dutch"),
        Self.language("nn", "Norwegian Nynorsk"),
        Self.language("no", "Norwegian", aliases: ["Norwegian Bokmal"]),
        Self.language("oc", "Occitan"),
        Self.language("pa", "Punjabi"),
        Self.language("pl", "Polish"),
        Self.language("ps", "Pashto"),
        Self.language("pt", "Portuguese"),
        Self.language("ro", "Romanian", aliases: ["Moldavian", "Moldovan"]),
        Self.language("ru", "Russian"),
        Self.language("sa", "Sanskrit"),
        Self.language("sd", "Sindhi"),
        Self.language("si", "Sinhala", aliases: ["Sinhalese"]),
        Self.language("sk", "Slovak"),
        Self.language("sl", "Slovenian"),
        Self.language("sn", "Shona"),
        Self.language("so", "Somali"),
        Self.language("sq", "Albanian"),
        Self.language("sr", "Serbian"),
        Self.language("su", "Sundanese"),
        Self.language("sv", "Swedish"),
        Self.language("sw", "Swahili"),
        Self.language("ta", "Tamil"),
        Self.language("te", "Telugu"),
        Self.language("tg", "Tajik"),
        Self.language("th", "Thai"),
        Self.language("tk", "Turkmen"),
        Self.language("tl", "Tagalog", aliases: ["Filipino"]),
        Self.language("tr", "Turkish"),
        Self.language("tt", "Tatar"),
        Self.language("uk", "Ukrainian"),
        Self.language("ur", "Urdu"),
        Self.language("uz", "Uzbek"),
        Self.language("vi", "Vietnamese"),
        Self.language("yi", "Yiddish"),
        Self.language("yo", "Yoruba"),
        Self.language("zh", "Mandarin Chinese", aliases: ["Chinese", "Mandarin"]),
    ]

    private static func language(
        _ id: String,
        _ displayName: String,
        aliases: [String] = []
    ) -> VoiceEngineLanguage {
        VoiceEngineLanguage(
            id: id,
            displayName: displayName,
            aliases: aliases,
            isPopular: self.popularLanguageIDs.contains(id)
        )
    }
}
