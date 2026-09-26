@testable import FluidSubtitles_Debug
import XCTest

@MainActor
final class SpokenPunctuationFormattingTests: XCTestCase {
    private func withDefaultPunctuationSettings(_ body: () -> Void) {
        let settings = SettingsStore.shared
        let originalEnabled = settings.autoConvertPunctuationEnabled
        let originalPrefix = settings.punctuationDictionaryPrefix
        let originalRules = settings.punctuationDictionaryRules
        let originalActionRules = settings.spokenFormattingActionRules
        defer {
            settings.autoConvertPunctuationEnabled = originalEnabled
            settings.punctuationDictionaryPrefix = originalPrefix
            settings.punctuationDictionaryRules = originalRules
            settings.spokenFormattingActionRules = originalActionRules
        }

        settings.autoConvertPunctuationEnabled = true
        settings.punctuationDictionaryPrefix = "literal"
        settings.punctuationDictionaryRules = SettingsStore.defaultPunctuationDictionaryRules
        settings.spokenFormattingActionRules = SettingsStore.defaultSpokenFormattingActionRules
        body()
    }

    private func format(
        _ text: String,
        appName: String? = nil,
        bundleID: String? = nil,
        windowTitle: String? = nil
    ) -> String {
        ASRService.applySpokenPunctuationFormatting(
            text,
            appName: appName,
            bundleID: bundleID,
            windowTitle: windowTitle
        )
    }

    func testDisabledFeatureLeavesTextUntouched() {
        self.withDefaultPunctuationSettings {
            SettingsStore.shared.autoConvertPunctuationEnabled = false
            XCTAssertEqual(self.format("Hello literal comma world"), "Hello literal comma world")
        }
    }

    func testCommaPhraseInsertsRightAttachedComma() {
        self.withDefaultPunctuationSettings {
            XCTAssertEqual(self.format("Hello literal comma world"), "Hello, world")
        }
    }

    func testPeriodPhraseInsertsRightAttachedPeriod() {
        self.withDefaultPunctuationSettings {
            XCTAssertEqual(self.format("Hello literal period World"), "Hello. World")
        }
    }

    func testQuestionMarkPhraseInsertsRightAttachedSymbol() {
        self.withDefaultPunctuationSettings {
            XCTAssertEqual(self.format("Ready literal question mark"), "Ready?")
        }
    }

    func testAdjacentGeneratedPunctuationDoesNotAddExtraSpace() {
        self.withDefaultPunctuationSettings {
            XCTAssertEqual(self.format("one literal comma literal period"), "one,.")
        }
    }

    func testGeneratedCommaBeforePercentIsDropped() {
        self.withDefaultPunctuationSettings {
            XCTAssertEqual(self.format("50 literal comma literal percent"), "50%")
        }
    }

    func testQuoteAliasTogglesOpenThenClose() {
        self.withDefaultPunctuationSettings {
            XCTAssertEqual(self.format("literal quote hello literal quote"), "\"hello\"")
        }
    }

    func testDashAliasIsSpaceAround() {
        self.withDefaultPunctuationSettings {
            XCTAssertEqual(self.format("Hello literal dash World"), "Hello - World")
        }
    }

    func testHyphenAliasHasNoSurroundingSpace() {
        self.withDefaultPunctuationSettings {
            XCTAssertEqual(self.format("Hello literal hyphen World"), "Hello-World")
        }
    }

    func testParenthesesWrapEnclosedWord() {
        self.withDefaultPunctuationSettings {
            XCTAssertEqual(self.format("literal open paren x literal close paren"), "(x)")
        }
    }

    func testNewLineActionInsertsLineBreakWithoutStraySpacing() {
        self.withDefaultPunctuationSettings {
            XCTAssertEqual(self.format("Hello literal new line World"), "Hello\nWorld")
        }
    }

    func testAtSignRequiresPunctuationFriendlyAppContext() {
        self.withDefaultPunctuationSettings {
            XCTAssertEqual(self.format("literal at sign test"), "literal at sign test")
            XCTAssertEqual(self.format("literal at sign test", appName: "Xcode"), "@test")
        }
    }

    func testAtTheRatePhraseWorksRegardlessOfAppContext() {
        self.withDefaultPunctuationSettings {
            XCTAssertEqual(self.format("literal at the rate test"), "@test")
        }
    }

    func testCustomPrefixReplacesDefaultLiteralPrefix() {
        self.withDefaultPunctuationSettings {
            SettingsStore.shared.punctuationDictionaryPrefix = "computer"
            XCTAssertEqual(self.format("Hello literal comma world"), "Hello literal comma world")
            XCTAssertEqual(self.format("Hello computer comma world"), "Hello, world")
        }
    }

    func testEmptyTextIsReturnedUnchanged() {
        self.withDefaultPunctuationSettings {
            XCTAssertEqual(self.format(""), "")
        }
    }

    func testTextWithoutPrefixIsReturnedUnchanged() {
        self.withDefaultPunctuationSettings {
            XCTAssertEqual(self.format("Nothing to convert here"), "Nothing to convert here")
        }
    }
}
