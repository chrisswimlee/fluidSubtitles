@testable import FluidSubtitles_Debug
import XCTest

final class AppleSpeechLocaleTests: XCTestCase {
    func testAnalyzerLocalesAreKoreanEnglishThai() {
        XCTAssertEqual(VoiceEngineLanguageCatalog.preferredAppleSpeechAnalyzerLocale(forLanguageID: "en"), "en-US")
        XCTAssertEqual(VoiceEngineLanguageCatalog.preferredAppleSpeechAnalyzerLocale(forLanguageID: "ko"), "ko-KR")
        XCTAssertEqual(VoiceEngineLanguageCatalog.preferredAppleSpeechAnalyzerLocale(forLanguageID: "th"), "th-TH")
        XCTAssertEqual(VoiceEngineLanguageCatalog.appleSpeechAnalyzerLocaleIdentifier(for: "ja"), nil)
    }

    func testAnalyzerMatchesLanguagePrefixNotExactMacLocale() {
        let supported = ["en-US", "ko-KR", "th-TH"]
        XCTAssertEqual(
            VoiceEngineLanguageCatalog.resolveAppleSpeechAnalyzerLocale(
                preferredIdentifier: "en",
                languageID: "en",
                supportedIdentifiers: supported
            ),
            "en-US"
        )
        XCTAssertEqual(
            VoiceEngineLanguageCatalog.resolveAppleSpeechAnalyzerLocale(
                preferredIdentifier: "en-GB",
                languageID: "en",
                supportedIdentifiers: supported
            ),
            "en-US"
        )
        XCTAssertEqual(
            VoiceEngineLanguageCatalog.resolveAppleSpeechAnalyzerLocale(
                preferredIdentifier: "ko",
                languageID: "ko",
                supportedIdentifiers: supported
            ),
            "ko-KR"
        )
    }

    func testAnalyzerIgnoresMacLocaleWhenISpeakIsDifferent() {
        let supported = ["en-US", "ko-KR", "ja-JP", "sv-SE"]
        XCTAssertEqual(
            VoiceEngineLanguageCatalog.resolveAppleSpeechAnalyzerLocale(
                preferredIdentifier: "sv-SE",
                languageID: "en",
                supportedIdentifiers: supported
            ),
            "en-US"
        )
        XCTAssertEqual(
            VoiceEngineLanguageCatalog.resolveAppleSpeechAnalyzerLocale(
                preferredIdentifier: "ja-JP",
                languageID: "ko",
                supportedIdentifiers: supported
            ),
            "ko-KR"
        )
    }

    func testAnalyzerReturnsNilWhenLanguageIsMissing() {
        XCTAssertNil(
            VoiceEngineLanguageCatalog.resolveAppleSpeechAnalyzerLocale(
                preferredIdentifier: "th-TH",
                languageID: "th",
                supportedIdentifiers: ["en-US", "ko-KR"]
            )
        )
    }

    func testPinAppleSpeechFollowsISpeak() {
        let settings = SettingsStore.shared
        let originalModel = settings.selectedSpeechModel
        let originalSource = settings.translationSourceLanguageID
        let originalLocale = settings.selectedAppleSpeechLocaleIdentifier
        defer {
            settings.selectedSpeechModel = originalModel
            settings.translationSourceLanguageID = originalSource
            settings.selectedAppleSpeechLocaleIdentifier = originalLocale
        }

        settings.selectedSpeechModel = .appleSpeechAnalyzer
        settings.translationSourceLanguageID = "ko"
        settings.selectedAppleSpeechLocaleIdentifier = "sv-SE"
        SpokenLanguageResolver.pinAppleSpeechToSpokenSource(settings: settings)
        XCTAssertEqual(settings.selectedAppleSpeechLocaleIdentifier, "ko-KR")
    }
}
