//
//  SettingsStore+DictationFormatting.swift
//  Fluid
//
//  Filler words, GAAV, continuous dictation, and the custom dictionary.
//

import Combine
import Foundation

extension SettingsStore {
    // MARK: - Filler Words

    static let defaultFillerWords = [
        "um",
        "uh",
        "er",
        "ah",
        "eh",
        "umm",
        "uhh",
        "err",
        "ahh",
        "ehh",
        "hmm",
        "hm",
        "mm",
        "mmm",
        "erm",
        "urm",
        "ugh",
    ]

    var fillerWords: [String] {
        get {
            if let stored = defaults.array(forKey: Keys.fillerWords) as? [String] {
                return stored
            }
            return Self.defaultFillerWords
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.fillerWords)
        }
    }

    var removeFillerWordsEnabled: Bool {
        get { self.defaults.object(forKey: Keys.removeFillerWordsEnabled) as? Bool ?? true }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.removeFillerWordsEnabled)
        }
    }

    var autoConvertPunctuationEnabled: Bool {
        get { self.defaults.object(forKey: Keys.autoConvertPunctuationEnabled) as? Bool ?? true }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.autoConvertPunctuationEnabled)
        }
    }

    var literalDictationFormattingEnabled: Bool {
        get { self.defaults.object(forKey: Keys.literalDictationFormattingEnabled) as? Bool ?? false }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.literalDictationFormattingEnabled)
        }
    }

    static let defaultPunctuationDictionaryPrefix = "literal"

    enum SpokenFormattingAction: String, Codable, CaseIterable, Identifiable {
        case newLine
        case newParagraph
        case tab
        case space

        var id: Self { self }

        var title: String {
            switch self {
            case .newLine: return "New Line"
            case .newParagraph: return "New Paragraph"
            case .tab: return "Tab"
            case .space: return "Space"
            }
        }

        var displaySymbol: String {
            switch self {
            case .newLine: return "⏎"
            case .newParagraph: return "¶"
            case .tab: return "⇥"
            case .space: return "␣"
            }
        }

        var output: String {
            switch self {
            case .newLine: return "\n"
            case .newParagraph: return "\n\n"
            case .tab: return "\t"
            case .space: return " "
            }
        }
    }

    struct SpokenFormattingActionRule: Codable, Identifiable, Hashable {
        var action: SpokenFormattingAction
        var aliases: [String]
        var isEnabled: Bool

        var id: SpokenFormattingAction { self.action }

        init(action: SpokenFormattingAction, aliases: [String], isEnabled: Bool = true) {
            self.action = action
            self.aliases = PunctuationDictionaryRule.normalizedAliases(aliases)
            self.isEnabled = isEnabled && !self.aliases.isEmpty
        }
    }

    static let defaultSpokenFormattingActionRules: [SpokenFormattingActionRule] = [
        SpokenFormattingActionRule(action: .newLine, aliases: ["new line", "next line"]),
        SpokenFormattingActionRule(action: .newParagraph, aliases: ["new paragraph", "next paragraph"]),
        SpokenFormattingActionRule(action: .tab, aliases: ["tab"]),
        SpokenFormattingActionRule(action: .space, aliases: ["space"]),
    ]

    static let defaultPunctuationDictionaryRules: [PunctuationDictionaryRule] = [
        PunctuationDictionaryRule(aliases: ["comma"], symbol: ","),
        PunctuationDictionaryRule(aliases: ["period", "full stop"], symbol: "."),
        PunctuationDictionaryRule(aliases: ["dot"], symbol: "."),
        PunctuationDictionaryRule(aliases: ["question mark", "questionmark"], symbol: "?"),
        PunctuationDictionaryRule(aliases: ["exclamation mark", "exclamation point", "bang"], symbol: "!"),
        PunctuationDictionaryRule(aliases: ["colon"], symbol: ":"),
        PunctuationDictionaryRule(aliases: ["semicolon", "semi colon"], symbol: ";"),
        PunctuationDictionaryRule(aliases: ["ellipsis", "dot dot dot", "three dots"], symbol: "..."),
        PunctuationDictionaryRule(aliases: ["slash", "forward slash", "forwardslash"], symbol: "/"),
        PunctuationDictionaryRule(aliases: ["backslash", "back slash"], symbol: "\\"),
        PunctuationDictionaryRule(aliases: ["hyphen"], symbol: "-"),
        PunctuationDictionaryRule(aliases: ["dash", "minus sign"], symbol: "-"),
        PunctuationDictionaryRule(aliases: ["em dash", "long dash"], symbol: "—"),
        PunctuationDictionaryRule(aliases: ["en dash"], symbol: "–"),
        PunctuationDictionaryRule(
            aliases: ["open parenthesis", "open parentheses", "left parenthesis", "left parentheses", "open paren", "left paren"],
            symbol: "("
        ),
        PunctuationDictionaryRule(
            aliases: ["close parenthesis", "close parentheses", "right parenthesis", "right parentheses", "close paren", "right paren"],
            symbol: ")"
        ),
        PunctuationDictionaryRule(aliases: ["open bracket", "left bracket", "open square bracket", "left square bracket"], symbol: "["),
        PunctuationDictionaryRule(aliases: ["close bracket", "right bracket", "close square bracket", "right square bracket"], symbol: "]"),
        PunctuationDictionaryRule(
            aliases: ["open brace", "left brace", "open curly brace", "left curly brace", "open curly bracket", "left curly bracket"],
            symbol: "{"
        ),
        PunctuationDictionaryRule(
            aliases: ["close brace", "right brace", "close curly brace", "right curly brace", "close curly bracket", "right curly bracket"],
            symbol: "}"
        ),
        PunctuationDictionaryRule(aliases: ["open angle bracket", "left angle bracket", "less than sign"], symbol: "<"),
        PunctuationDictionaryRule(aliases: ["close angle bracket", "right angle bracket", "greater than sign"], symbol: ">"),
        PunctuationDictionaryRule(aliases: ["quote", "quotes", "quotation mark", "double quote"], symbol: "\""),
        PunctuationDictionaryRule(aliases: ["open quote", "opening quote", "open double quote", "opening double quote"], symbol: "\""),
        PunctuationDictionaryRule(aliases: ["close quote", "closing quote", "close double quote", "closing double quote"], symbol: "\""),
        PunctuationDictionaryRule(aliases: ["single quote"], symbol: "'"),
        PunctuationDictionaryRule(aliases: ["apostrophe"], symbol: "'"),
        PunctuationDictionaryRule(aliases: ["at the rate", "at sign", "commercial at"], symbol: "@"),
        PunctuationDictionaryRule(aliases: ["ampersand", "and sign"], symbol: "&"),
        PunctuationDictionaryRule(aliases: ["plus sign", "plus"], symbol: "+"),
        PunctuationDictionaryRule(aliases: ["equals sign", "equal sign", "equal", "equals"], symbol: "="),
        PunctuationDictionaryRule(aliases: ["percent sign", "percentage sign", "percent"], symbol: "%"),
        PunctuationDictionaryRule(aliases: ["dollar sign", "dollar"], symbol: "$"),
        PunctuationDictionaryRule(aliases: ["hash", "hash sign", "hashtag", "pound sign", "number sign"], symbol: "#"),
        PunctuationDictionaryRule(aliases: ["asterisk", "star symbol"], symbol: "*"),
        PunctuationDictionaryRule(aliases: ["underscore"], symbol: "_"),
        PunctuationDictionaryRule(aliases: ["pipe", "vertical bar"], symbol: "|"),
        PunctuationDictionaryRule(aliases: ["tilde"], symbol: "~"),
        PunctuationDictionaryRule(aliases: ["caret"], symbol: "^"),
        PunctuationDictionaryRule(aliases: ["backtick", "back tick"], symbol: "`"),
    ]

    struct PunctuationDictionaryRule: Codable, Identifiable, Hashable {
        let id: UUID
        var aliases: [String]
        var symbol: String

        init(aliases: [String], symbol: String) {
            self.id = UUID()
            self.aliases = Self.normalizedAliases(aliases)
            self.symbol = Self.normalizedSymbol(symbol) ?? symbol
        }

        init(id: UUID, aliases: [String], symbol: String) {
            self.id = id
            self.aliases = Self.normalizedAliases(aliases)
            self.symbol = Self.normalizedSymbol(symbol) ?? symbol
        }

        static func normalizedAlias(_ value: String) -> String? {
            let alias = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return alias.isEmpty ? nil : alias
        }

        static func normalizedAliases(_ values: [String]) -> [String] {
            var seen: Set<String> = []
            var aliases: [String] = []
            aliases.reserveCapacity(values.count)

            for value in values {
                guard let alias = self.normalizedAlias(value), !seen.contains(alias) else { continue }
                seen.insert(alias)
                aliases.append(alias)
            }

            return aliases
        }

        static func normalizedSymbol(_ value: String) -> String? {
            let symbol = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return symbol.isEmpty ? nil : symbol
        }
    }

    static func normalizedPunctuationDictionaryPrefix(_ value: String) -> String? {
        let prefix = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return prefix.isEmpty ? nil : prefix
    }

    var punctuationDictionaryPrefix: String {
        get {
            guard let stored = self.defaults.string(forKey: Keys.punctuationDictionaryPrefix),
                  let normalized = Self.normalizedPunctuationDictionaryPrefix(stored)
            else {
                return Self.defaultPunctuationDictionaryPrefix
            }
            return normalized
        }
        set {
            objectWillChange.send()
            self.defaults.set(
                Self.normalizedPunctuationDictionaryPrefix(newValue) ?? Self.defaultPunctuationDictionaryPrefix,
                forKey: Keys.punctuationDictionaryPrefix
            )
        }
    }

    var punctuationDictionaryRules: [PunctuationDictionaryRule] {
        get {
            guard let data = defaults.data(forKey: Keys.punctuationDictionaryRules),
                  let decoded = try? JSONDecoder().decode([PunctuationDictionaryRule].self, from: data)
            else {
                return Self.defaultPunctuationDictionaryRules
            }
            return decoded.compactMap { rule in
                let aliases = PunctuationDictionaryRule.normalizedAliases(rule.aliases)
                guard !aliases.isEmpty,
                      let symbol = PunctuationDictionaryRule.normalizedSymbol(rule.symbol)
                else {
                    return nil
                }
                return PunctuationDictionaryRule(id: rule.id, aliases: aliases, symbol: symbol)
            }
        }
        set {
            objectWillChange.send()
            let normalizedRules = newValue.compactMap { rule -> PunctuationDictionaryRule? in
                let aliases = PunctuationDictionaryRule.normalizedAliases(rule.aliases)
                guard !aliases.isEmpty,
                      let symbol = PunctuationDictionaryRule.normalizedSymbol(rule.symbol)
                else {
                    return nil
                }
                return PunctuationDictionaryRule(id: rule.id, aliases: aliases, symbol: symbol)
            }
            if let encoded = try? JSONEncoder().encode(normalizedRules) {
                self.defaults.set(encoded, forKey: Keys.punctuationDictionaryRules)
            }
        }
    }

    var spokenFormattingActionRules: [SpokenFormattingActionRule] {
        get {
            guard let data = defaults.data(forKey: Keys.spokenFormattingActionRules),
                  let decoded = try? JSONDecoder().decode([SpokenFormattingActionRule].self, from: data)
            else {
                return Self.defaultSpokenFormattingActionRules
            }

            var rulesByAction: [SpokenFormattingAction: SpokenFormattingActionRule] = [:]
            for rule in decoded where rulesByAction[rule.action] == nil {
                rulesByAction[rule.action] = rule
            }
            let orderedRules = SpokenFormattingAction.allCases.map { action in
                guard let rule = rulesByAction[action] else {
                    return Self.defaultSpokenFormattingActionRules.first { $0.action == action }
                        ?? SpokenFormattingActionRule(action: action, aliases: [], isEnabled: false)
                }
                return SpokenFormattingActionRule(
                    action: action,
                    aliases: rule.aliases,
                    isEnabled: rule.isEnabled
                )
            }
            return self.removingDuplicateSpokenFormattingAliases(from: orderedRules)
        }
        set {
            objectWillChange.send()
            var rulesByAction: [SpokenFormattingAction: SpokenFormattingActionRule] = [:]
            for rule in newValue where rulesByAction[rule.action] == nil {
                rulesByAction[rule.action] = rule
            }
            let orderedRules = SpokenFormattingAction.allCases.map { action in
                guard let rule = rulesByAction[action] else {
                    return SpokenFormattingActionRule(action: action, aliases: [], isEnabled: false)
                }
                return SpokenFormattingActionRule(
                    action: action,
                    aliases: rule.aliases,
                    isEnabled: rule.isEnabled
                )
            }
            let normalizedRules = self.removingDuplicateSpokenFormattingAliases(from: orderedRules)
            if let encoded = try? JSONEncoder().encode(normalizedRules) {
                self.defaults.set(encoded, forKey: Keys.spokenFormattingActionRules)
            }
        }
    }

    func removingDuplicateSpokenFormattingAliases(
        from rules: [SpokenFormattingActionRule]
    ) -> [SpokenFormattingActionRule] {
        var claimedAliases = Set(self.punctuationDictionaryRules.flatMap(\.aliases))
        return rules.map { rule in
            let uniqueAliases = rule.aliases.filter { claimedAliases.insert($0).inserted }
            return SpokenFormattingActionRule(
                action: rule.action,
                aliases: uniqueAliases,
                isEnabled: rule.isEnabled
            )
        }
    }

    // MARK: - GAAV Mode

    /// Legacy combined GAAV setting. New behavior uses the split formatting toggles below.
    var gaavModeEnabled: Bool {
        get { self.defaults.object(forKey: Keys.gaavModeEnabled) as? Bool ?? false }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.gaavModeEnabled)
        }
    }

    var gaavLowercaseFirstLetterEnabled: Bool {
        get {
            self.defaults.object(forKey: Keys.gaavLowercaseFirstLetterEnabled) as? Bool ?? self.gaavModeEnabled
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.gaavLowercaseFirstLetterEnabled)
        }
    }

    var gaavRemoveTrailingPeriodEnabled: Bool {
        get {
            self.defaults.object(forKey: Keys.gaavRemoveTrailingPeriodEnabled) as? Bool ?? self.gaavModeEnabled
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.gaavRemoveTrailingPeriodEnabled)
        }
    }

    // MARK: - Continuous Dictation Mode

    /// Legacy combined continuous-dictation setting. New behavior uses the split toggles below.
    var continuousDictationModeEnabled: Bool {
        get { self.defaults.object(forKey: Keys.continuousDictationModeEnabled) as? Bool ?? false }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.continuousDictationModeEnabled)
        }
    }

    var continuousDictationSpacingEnabled: Bool {
        get {
            self.defaults.object(forKey: Keys.continuousDictationSpacingEnabled) as? Bool ?? self.continuousDictationModeEnabled
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.continuousDictationSpacingEnabled)
        }
    }

    var contextAwareCapitalizationEnabled: Bool {
        get {
            self.defaults.object(forKey: Keys.contextAwareCapitalizationEnabled) as? Bool ?? self.continuousDictationModeEnabled
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.contextAwareCapitalizationEnabled)
        }
    }

    var needsDictationFormattingContext: Bool {
        self.continuousDictationSpacingEnabled || self.contextAwareCapitalizationEnabled
    }

    // MARK: - Media Playback Control

    /// When enabled, automatically pauses system media playback when transcription starts.
    /// Only resumes if this app was the one that paused it.
    var pauseMediaDuringTranscription: Bool {
        get { self.defaults.object(forKey: Keys.pauseMediaDuringTranscription) as? Bool ?? false }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.pauseMediaDuringTranscription)
        }
    }

    // MARK: - Custom Dictionary

    /// A custom dictionary entry that maps multiple misheard/alternate spellings to a correct replacement.
    /// For example: ["fluid subtitles", "fluid subtitle"] -> "fluidSubtitles"
    struct CustomDictionaryEntry: Codable, Identifiable, Hashable {
        let id: UUID
        /// Words/phrases to look for (case-insensitive matching)
        var triggers: [String]
        /// The correct replacement text
        var replacement: String

        init(triggers: [String], replacement: String) {
            self.id = UUID()
            self.triggers = triggers.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            self.replacement = replacement
        }

        init(id: UUID, triggers: [String], replacement: String) {
            self.id = id
            self.triggers = triggers.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            self.replacement = replacement
        }

        /// Trims padding around visible replacement text while preserving an intentional
        /// all-whitespace payload such as a newline, space, or tab.
        static func sanitizedReplacement(_ text: String) -> String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? text : trimmed
        }
    }

    var vocabularyBoostingEnabled: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.vocabularyBoostingEnabled)
            return value as? Bool ?? false
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.vocabularyBoostingEnabled)
            NotificationCenter.default.post(name: .parakeetVocabularyDidChange, object: nil)
        }
    }

    enum AutomaticDictionarySuggestionFrequency: Int, Codable, CaseIterable, Identifiable {
        case first = 1
        case second = 2
        case third = 3

        var id: Int { self.rawValue }

        var displayName: String {
            switch self {
            case .first: "1 correction"
            case .second: "2 corrections"
            case .third: "3 corrections"
            }
        }
    }

    var automaticDictionaryLearningEnabled: Bool {
        get { self.defaults.object(forKey: Keys.automaticDictionaryLearningEnabled) as? Bool ?? true }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.automaticDictionaryLearningEnabled)
        }
    }

    var automaticDictionarySuggestionFrequency: AutomaticDictionarySuggestionFrequency {
        get {
            let stored = self.defaults.integer(forKey: Keys.automaticDictionarySuggestionFrequency)
            return AutomaticDictionarySuggestionFrequency(rawValue: stored) ?? .first
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.automaticDictionarySuggestionFrequency)
        }
    }

    var pronunciationMatchingEnabled: Bool {
        get { self.defaults.object(forKey: Keys.pronunciationMatchingEnabled) as? Bool ?? false }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.pronunciationMatchingEnabled)
        }
    }

    /// Custom dictionary entries for word replacement
    var customDictionaryEntries: [CustomDictionaryEntry] {
        get {
            guard let data = defaults.data(forKey: Keys.customDictionaryEntries),
                  let decoded = try? JSONDecoder().decode([CustomDictionaryEntry].self, from: data)
            else {
                return []
            }
            return decoded
        }
        set {
            objectWillChange.send()
            if let encoded = try? JSONEncoder().encode(newValue) {
                self.defaults.set(encoded, forKey: Keys.customDictionaryEntries)
            }
        }
    }
}
