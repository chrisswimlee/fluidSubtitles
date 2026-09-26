@testable import FluidSubtitles_Debug
import XCTest

final class AppleSpeechLocaleTests: XCTestCase {
    func testAnalyzerLocalesAreKoreanEnglishThaiJapanese() {
        XCTAssertEqual(VoiceEngineLanguageCatalog.preferredAppleSpeechAnalyzerLocale(forLanguageID: "en"), "en-US")
        XCTAssertEqual(VoiceEngineLanguageCatalog.preferredAppleSpeechAnalyzerLocale(forLanguageID: "ko"), "ko-KR")
        XCTAssertEqual(VoiceEngineLanguageCatalog.preferredAppleSpeechAnalyzerLocale(forLanguageID: "th"), "th-TH")
        XCTAssertEqual(VoiceEngineLanguageCatalog.preferredAppleSpeechAnalyzerLocale(forLanguageID: "ja"), "ja-JP")
        XCTAssertEqual(VoiceEngineLanguageCatalog.appleSpeechAnalyzerLocaleIdentifier(for: "fr"), "fr-FR")
        XCTAssertEqual(VoiceEngineLanguageCatalog.appleSpeechAnalyzerLocaleIdentifier(for: "zh"), "zh-CN")
        XCTAssertNil(VoiceEngineLanguageCatalog.appleSpeechAnalyzerLocaleIdentifier(for: "da"))
        XCTAssertEqual(VoiceEngineLanguageCatalog.preferredAppleSpeechAnalyzerLocale(forLanguageID: "fr"), "fr-FR")
        XCTAssertEqual(VoiceEngineLanguageCatalog.preferredAppleSpeechAnalyzerLocale(forLanguageID: "da"), "da-DK")
        XCTAssertEqual(VoiceEngineLanguageCatalog.preferredAppleSpeechAnalyzerLocale(forLanguageID: "no"), "nb-NO")
    }

    func testAnalyzerDropsAPreparedLocaleThatIsNotISpeak() {
        guard #available(macOS 26.0, *) else { return }
        let settings = SettingsStore.shared
        let original = settings.translationSourceLanguageID
        defer { settings.translationSourceLanguageID = original }
        settings.translationSourceLanguageID = "ko"

        let provider = AppleSpeechAnalyzerProvider()
        provider.markPreparedLocaleForTesting("en-US")
        XCTAssertTrue(provider.isReady)
        provider.invalidateIfListeningLanguageChanged()
        XCTAssertFalse(provider.isReady)

        provider.markPreparedLocaleForTesting("ko-KR")
        provider.invalidateIfListeningLanguageChanged()
        XCTAssertTrue(provider.isReady)
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

        settings.translationSourceLanguageID = "ja"
        settings.selectedAppleSpeechLocaleIdentifier = "en-US"
        SpokenLanguageResolver.pinAppleSpeechToSpokenSource(settings: settings)
        XCTAssertEqual(settings.selectedAppleSpeechLocaleIdentifier, "ja-JP")

        settings.selectedSpeechModel = .whisperSmall
        settings.translationSourceLanguageID = "th"
        settings.selectedAppleSpeechLocaleIdentifier = "en-US"
        SpokenLanguageResolver.pinAppleSpeechToSpokenSource(settings: settings)
        XCTAssertEqual(settings.selectedAppleSpeechLocaleIdentifier, "th-TH")
    }

    func testAppleSpeechEnUSIsTheSameLanguageAsISpeakEnglish() {
        let settings = SettingsStore.shared
        let originalModel = settings.selectedSpeechModel
        let originalSource = settings.translationSourceLanguageID
        let originalLocale = settings.selectedAppleSpeechLocaleIdentifier
        defer {
            settings.selectedSpeechModel = originalModel
            settings.translationSourceLanguageID = originalSource
            settings.selectedAppleSpeechLocaleIdentifier = originalLocale
        }

        settings.selectedSpeechModel = .appleSpeech
        settings.translationSourceLanguageID = "en"
        settings.selectedAppleSpeechLocaleIdentifier = "en-US"

        XCTAssertEqual(SpokenLanguageResolver.spokenLanguageID(settings: settings), "en")
        XCTAssertEqual(SpokenLanguageResolver.heardLanguage(settings: settings)?.id, "en")
        XCTAssertTrue(SpokenLanguageResolver.voiceEngineSupportsSource(settings: settings))
        XCTAssertNil(SpokenLanguageResolver.voiceEngineMismatchMessage(settings: settings))
    }
}
