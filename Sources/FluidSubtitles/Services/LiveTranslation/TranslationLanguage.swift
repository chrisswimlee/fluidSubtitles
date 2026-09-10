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
    static let thai = TranslationLanguage(id: "th", displayName: "Thai", appleLanguageCode: "th")

    /// fluidSubtitles only translates among these three languages.
    static let all: [TranslationLanguage] = [
        Self.english,
        Self.korean,
        Self.thai,
    ]

    static let supportedIDs: Set<String> = Set(Self.all.map(\.id))

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

    static func defaultTarget(forSource source: TranslationLanguage) -> TranslationLanguage {
        source.id == Self.english.id ? Self.thai : Self.english
    }

    static func targets(excluding source: TranslationLanguage) -> [TranslationLanguage] {
        self.all.filter { $0.id != source.id }
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
