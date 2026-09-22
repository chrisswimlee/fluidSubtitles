import Foundation

struct TranslationLanguage: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let appleLanguageCode: String
    let localeLanguage: Locale.Language

    init(id: String, displayName: String, appleLanguageCode: String, localeLanguage: Locale.Language? = nil) {
        self.id = id
        self.displayName = displayName
        self.appleLanguageCode = appleLanguageCode
        self.localeLanguage = localeLanguage ?? Locale.Language(identifier: appleLanguageCode)
    }

    init(apple language: Locale.Language) {
        let identifier = language.minimalIdentifier
        self.id = identifier
        self.displayName = TranslationLanguageCatalog.displayName(for: language)
        self.appleLanguageCode = identifier
        self.localeLanguage = language
    }
}

enum TranslationLanguageCatalog {
    static let english = TranslationLanguage(id: "en", displayName: "English", appleLanguageCode: "en")
    static let korean = TranslationLanguage(id: "ko", displayName: "Korean", appleLanguageCode: "ko")
    static let japanese = TranslationLanguage(id: "ja", displayName: "Japanese", appleLanguageCode: "ja")
    static let thai = TranslationLanguage(id: "th", displayName: "Thai", appleLanguageCode: "th")
    static let arabic = TranslationLanguage(id: "ar", displayName: "Arabic", appleLanguageCode: "ar")
    static let chinese = TranslationLanguage(id: "zh", displayName: "Chinese", appleLanguageCode: "zh")
    static let danish = TranslationLanguage(id: "da", displayName: "Danish", appleLanguageCode: "da")
    static let dutch = TranslationLanguage(id: "nl", displayName: "Dutch", appleLanguageCode: "nl")
    static let finnish = TranslationLanguage(id: "fi", displayName: "Finnish", appleLanguageCode: "fi")
    static let french = TranslationLanguage(id: "fr", displayName: "French", appleLanguageCode: "fr")
    static let german = TranslationLanguage(id: "de", displayName: "German", appleLanguageCode: "de")
    static let hebrew = TranslationLanguage(id: "he", displayName: "Hebrew", appleLanguageCode: "he")
    static let hindi = TranslationLanguage(id: "hi", displayName: "Hindi", appleLanguageCode: "hi")
    static let indonesian = TranslationLanguage(id: "id", displayName: "Indonesian", appleLanguageCode: "id")
    static let italian = TranslationLanguage(id: "it", displayName: "Italian", appleLanguageCode: "it")
    static let malay = TranslationLanguage(id: "ms", displayName: "Malay", appleLanguageCode: "ms")
    /// Voice engines use `no`. Apple Translation lists Norwegian as `nb`.
    static let norwegian = TranslationLanguage(
        id: "no",
        displayName: "Norwegian",
        appleLanguageCode: "nb",
        localeLanguage: Locale.Language(identifier: "nb")
    )
    static let polish = TranslationLanguage(id: "pl", displayName: "Polish", appleLanguageCode: "pl")
    static let portuguese = TranslationLanguage(id: "pt", displayName: "Portuguese", appleLanguageCode: "pt")
    static let russian = TranslationLanguage(id: "ru", displayName: "Russian", appleLanguageCode: "ru")
    static let spanish = TranslationLanguage(id: "es", displayName: "Spanish", appleLanguageCode: "es")
    static let swedish = TranslationLanguage(id: "sv", displayName: "Swedish", appleLanguageCode: "sv")
    static let turkish = TranslationLanguage(id: "tr", displayName: "Turkish", appleLanguageCode: "tr")
    static let ukrainian = TranslationLanguage(id: "uk", displayName: "Ukrainian", appleLanguageCode: "uk")
    static let vietnamese = TranslationLanguage(id: "vi", displayName: "Vietnamese", appleLanguageCode: "vi")

    /// Languages both Apple Translation and a Voice Engine can use.
    /// Korean and Japanese work with Apple Speech, Cohere, or Whisper.
    /// Thai works best with Apple Speech or Whisper; Nemotron Thai is experimental.
    /// Chinese is Apple's Simplified `zh`. Traditional locales share that language.
    static let all: [TranslationLanguage] = [
        Self.english,
        Self.korean,
        Self.japanese,
        Self.thai,
        Self.arabic,
        Self.chinese,
        Self.danish,
        Self.dutch,
        Self.finnish,
        Self.french,
        Self.german,
        Self.hebrew,
        Self.hindi,
        Self.indonesian,
        Self.italian,
        Self.malay,
        Self.norwegian,
        Self.polish,
        Self.portuguese,
        Self.russian,
        Self.spanish,
        Self.swedish,
        Self.turkish,
        Self.ukrainian,
        Self.vietnamese,
    ]

    static var languageCodeList: String {
        self.all.map { $0.id.uppercased() }.sorted().joined(separator: ", ")
    }

    static let supportedIDs: Set<String> = Set(Self.all.map(\.id))

    /// Alphabetical names for the language menus.
    static var menuOrder: [TranslationLanguage] {
        self.all.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    /// Shown under Theater language pickers when I speak is Thai and no mismatch is visible.
    static let thaiTheaterEngineHint = "Thai speech works best with Apple Speech or Whisper."

    /// Nemotron can list Thai, but Theater should not treat that as a production default.
    static let thaiNemotronExperimentalWarning =
        "Thai is experimental on Nemotron. Apple Speech or Whisper is the better Theater default."

    static func theaterEngineHint(forSource source: TranslationLanguage) -> String? {
        source.id == Self.thai.id ? Self.thaiTheaterEngineHint : nil
    }

    static func displayName(for language: Locale.Language) -> String {
        let identifier = language.minimalIdentifier
        if let name = Locale.current.localizedString(forIdentifier: identifier), !name.isEmpty {
            return name.localizedCapitalized
        }
        if let code = language.languageCode?.identifier,
           let name = Locale.current.localizedString(forLanguageCode: code),
           !name.isEmpty
        {
            return name.localizedCapitalized
        }
        return identifier
    }

    static func languages(from supported: [Locale.Language]) -> [TranslationLanguage] {
        self.all.map { language in
            TranslationLanguage(
                id: language.id,
                displayName: language.displayName,
                appleLanguageCode: language.appleLanguageCode,
                localeLanguage: self.appleLanguage(for: language, from: supported)
            )
        }
    }

    static func language(id: String, in available: [TranslationLanguage] = []) -> TranslationLanguage? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.lowercased().replacingOccurrences(of: "_", with: "-")
        let prefix = String(normalized.split(separator: "-").first ?? Substring(normalized))
        let pool = available.isEmpty ? self.all : available
        return pool.first {
            let candidateID = $0.id.lowercased()
            let candidateCode = $0.appleLanguageCode.lowercased()
            return candidateID == normalized
                || candidateCode == normalized
                || candidateID == prefix
                || candidateCode == prefix
        }
    }

    static func language(matchingSpokenID spokenID: String, in available: [TranslationLanguage] = []) -> TranslationLanguage {
        self.language(id: spokenID, in: available) ?? Self.english
    }

    /// First run captions in the spoken language. A second language is a choice, not a default.
    static func defaultTarget(forSource source: TranslationLanguage) -> TranslationLanguage {
        source
    }

    static func targets(excluding _: TranslationLanguage) -> [TranslationLanguage] {
        self.all
    }

    /// Prefer Apple's already-listed language (especially regionless `en`) over a constructed locale.
    static func appleLanguage(
        for language: TranslationLanguage,
        from supported: [Locale.Language]
    ) -> Locale.Language {
        if supported.contains(where: { $0.minimalIdentifier == language.localeLanguage.minimalIdentifier }) {
            return language.localeLanguage
        }
        let code = (language.localeLanguage.languageCode?.identifier ?? language.id).lowercased()
        let matches = supported.filter { $0.languageCode?.identifier.lowercased() == code }
        if code == "en" {
            return matches.first(where: { $0.minimalIdentifier == "en" })
                ?? matches.first
                ?? language.localeLanguage
        }
        return matches.first(where: { $0.minimalIdentifier == language.appleLanguageCode })
            ?? matches.first
            ?? language.localeLanguage
    }
}

enum TranslationListenKind: String, Sendable {
    /// Fill the Theater window. Do not type into another app.
    case captions
    /// Type the translation into the app that was focused when listening started.
    case insert
}

/// Ordered ASR hints for Theater Q&A. Whisper can auto-detect when extras are on.
enum SpokenLanguageHints {
    static func orderedIDs(primaryID: String, alsoHearOthers: Bool) -> [String] {
        let primary = TranslationLanguageCatalog.language(id: primaryID)?.id
            ?? TranslationLanguageCatalog.english.id
        var ids = [primary]
        if alsoHearOthers {
            for language in TranslationLanguageCatalog.all where language.id != primary {
                ids.append(language.id)
            }
        }
        return ids
    }

    /// `nil` means Whisper auto-detect. Apple Speech stays on I speak.
    static func whisperLanguageCode(stored: String?, alsoHearOthers: Bool) -> String? {
        alsoHearOthers ? nil : stored
    }
}
