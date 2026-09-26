@testable import FluidSubtitles_Debug
import XCTest

@MainActor
final class SettingsStoreDictationFormattingTests: XCTestCase {
    private func withRestoredFormattingState(_ run: () -> Void) {
        let settings = SettingsStore.shared
        let originalPrefix = settings.punctuationDictionaryPrefix
        let originalRules = settings.punctuationDictionaryRules
        let originalActionRules = settings.spokenFormattingActionRules
        let originalFrequency = settings.automaticDictionarySuggestionFrequency
        defer {
            settings.punctuationDictionaryPrefix = originalPrefix
            settings.punctuationDictionaryRules = originalRules
            settings.spokenFormattingActionRules = originalActionRules
            settings.automaticDictionarySuggestionFrequency = originalFrequency
        }
        run()
    }

    // MARK: - PunctuationDictionaryRule normalization

    func testPunctuationDictionaryRuleNormalizesAliasesOnInit() {
        let rule = SettingsStore.PunctuationDictionaryRule(
            aliases: ["  Comma  ", "COMMA", "comma", "  ", "Full Stop"],
            symbol: "  ,  "
        )
        XCTAssertEqual(rule.aliases, ["comma", "full stop"])
        XCTAssertEqual(rule.symbol, ",")
    }

    func testPunctuationDictionaryRuleNormalizedAliasesDedupesCaseInsensitively() {
        let aliases = SettingsStore.PunctuationDictionaryRule.normalizedAliases(["Dash", "dash", " DASH ", "en dash"])
        XCTAssertEqual(aliases, ["dash", "en dash"])
    }

    func testPunctuationDictionaryRuleNormalizedSymbolTrimsAndRejectsEmpty() {
        XCTAssertEqual(SettingsStore.PunctuationDictionaryRule.normalizedSymbol("  @  "), "@")
        XCTAssertNil(SettingsStore.PunctuationDictionaryRule.normalizedSymbol("   "))
        XCTAssertNil(SettingsStore.PunctuationDictionaryRule.normalizedSymbol(""))
    }

    // MARK: - punctuationDictionaryPrefix

    func testNormalizedPunctuationDictionaryPrefixTrimsLowercasesAndRejectsEmpty() {
        XCTAssertEqual(SettingsStore.normalizedPunctuationDictionaryPrefix("  Computer  "), "computer")
        XCTAssertNil(SettingsStore.normalizedPunctuationDictionaryPrefix("   "))
    }

    func testPunctuationDictionaryPrefixFallsBackToDefaultWhenSetToWhitespace() {
        self.withRestoredFormattingState {
            let settings = SettingsStore.shared
            settings.punctuationDictionaryPrefix = "   "
            XCTAssertEqual(settings.punctuationDictionaryPrefix, SettingsStore.defaultPunctuationDictionaryPrefix)
        }
    }

    func testPunctuationDictionaryPrefixNormalizesCasingWhenSet() {
        self.withRestoredFormattingState {
            let settings = SettingsStore.shared
            settings.punctuationDictionaryPrefix = "  Computer  "
            XCTAssertEqual(settings.punctuationDictionaryPrefix, "computer")
        }
    }

    // MARK: - punctuationDictionaryRules

    func testPunctuationDictionaryRulesSetterDropsRulesThatNormalizeToEmpty() {
        self.withRestoredFormattingState {
            let settings = SettingsStore.shared
            settings.punctuationDictionaryRules = [
                SettingsStore.PunctuationDictionaryRule(aliases: ["arrow"], symbol: "->"),
                SettingsStore.PunctuationDictionaryRule(aliases: ["   ", ""], symbol: "!"),
                SettingsStore.PunctuationDictionaryRule(aliases: ["nothing"], symbol: "   "),
            ]

            let stored = settings.punctuationDictionaryRules
            XCTAssertEqual(stored.count, 1)
            XCTAssertEqual(stored[0].aliases, ["arrow"])
            XCTAssertEqual(stored[0].symbol, "->")
        }
    }

    // MARK: - spokenFormattingActionRules

    func testSpokenFormattingActionRulesAlwaysCoversEveryActionInOrder() {
        self.withRestoredFormattingState {
            let settings = SettingsStore.shared
            settings.punctuationDictionaryRules = []
            settings.spokenFormattingActionRules = [
                SettingsStore.SpokenFormattingActionRule(action: .tab, aliases: ["tab"]),
            ]

            let rules = settings.spokenFormattingActionRules
            XCTAssertEqual(rules.map(\.action), SettingsStore.SpokenFormattingAction.allCases)

            let newLineRule = rules.first { $0.action == .newLine }
            XCTAssertEqual(
                newLineRule?.isEnabled,
                false,
                "An action missing from the stored set must come back disabled with no aliases"
            )
            XCTAssertEqual(newLineRule?.aliases, [])
        }
    }

    func testSpokenFormattingActionRulesDropsAliasesAlreadyClaimedByPunctuationRules() {
        self.withRestoredFormattingState {
            let settings = SettingsStore.shared
            settings.punctuationDictionaryRules = [
                SettingsStore.PunctuationDictionaryRule(aliases: ["tab"], symbol: "T"),
            ]
            settings.spokenFormattingActionRules = [
                SettingsStore.SpokenFormattingActionRule(action: .tab, aliases: ["tab", "indent"]),
            ]

            let tabRule = settings.spokenFormattingActionRules.first { $0.action == .tab }
            XCTAssertEqual(
                tabRule?.aliases,
                ["indent"],
                "An alias already claimed by a punctuation rule must not also trigger the action rule"
            )
        }
    }

    // MARK: - automaticDictionarySuggestionFrequency

    func testAutomaticDictionarySuggestionFrequencyFallsBackToFirstWhenUnset() {
        self.withRestoredFormattingState {
            let settings = SettingsStore.shared
            settings.defaults.removeObject(forKey: SettingsStore.Keys.automaticDictionarySuggestionFrequency)
            XCTAssertEqual(settings.automaticDictionarySuggestionFrequency, .first)
        }
    }

    func testAutomaticDictionarySuggestionFrequencyRoundTrips() {
        self.withRestoredFormattingState {
            let settings = SettingsStore.shared
            settings.automaticDictionarySuggestionFrequency = .third
            XCTAssertEqual(settings.automaticDictionarySuggestionFrequency, .third)
        }
    }
}
