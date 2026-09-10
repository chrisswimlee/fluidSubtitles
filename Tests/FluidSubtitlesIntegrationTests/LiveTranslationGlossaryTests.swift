import XCTest
@testable import FluidSubtitles_Debug

final class LiveTranslationGlossaryTests: XCTestCase {
    func testProtectAndRestoreKeepsNames() {
        let terms = ["fluidSubtitles", "Keynote"]
        let protected = TranslationGlossary.protect(
            "We are demoing fluidSubtitles in Keynote today",
            terms: terms
        )
        XCTAssertFalse(protected.text.contains("fluidSubtitles"))
        XCTAssertFalse(protected.text.contains("Keynote"))
        XCTAssertEqual(
            TranslationGlossary.restore(protected.text, tokens: protected.tokens),
            "We are demoing fluidSubtitles in Keynote today"
        )
    }

    func testEmptyTermsLeaveTextAlone() {
        let protected = TranslationGlossary.protect("hello", terms: [])
        XCTAssertEqual(protected.text, "hello")
        XCTAssertTrue(protected.tokens.isEmpty)
    }

    func testLanguageMatching() {
        XCTAssertEqual(TranslationLanguageCatalog.language(matchingSpokenID: "th-TH").id, "th")
        XCTAssertEqual(TranslationLanguageCatalog.language(matchingSpokenID: "ko-KR").id, "ko")
        XCTAssertEqual(TranslationLanguageCatalog.language(matchingSpokenID: "en").id, "en")
    }

    func testUnsupportedSpokenLanguagesFallBackToEnglish() {
        XCTAssertNil(TranslationLanguageCatalog.language(id: "ja"))
        XCTAssertNil(TranslationLanguageCatalog.language(id: "zh-TW"))
        XCTAssertEqual(TranslationLanguageCatalog.language(matchingSpokenID: "ja-JP").id, "en")
        XCTAssertEqual(TranslationLanguageCatalog.language(matchingSpokenID: "zh-CN").id, "en")
    }

    func testLanguagesFromAppleListStayKoreanEnglishThai() {
        let languages = TranslationLanguageCatalog.languages(from: [
            Locale.Language(identifier: "en-IN"),
            Locale.Language(identifier: "en"),
            Locale.Language(identifier: "th"),
            Locale.Language(identifier: "ko"),
            Locale.Language(identifier: "ja"),
            Locale.Language(identifier: "vi"),
        ])
        XCTAssertEqual(languages.map(\.id), ["en", "ko", "th"])
    }

    func testVoiceEngineLanguagesAreKoreanEnglishThai() {
        XCTAssertEqual(
            Set(VoiceEngineLanguageCatalog.allLanguages().map(\.id)),
            ["en", "ko", "th"]
        )
    }

    func testDefaultTargetAvoidsTheSpokenLanguage() {
        XCTAssertEqual(
            TranslationLanguageCatalog.defaultTarget(forSource: TranslationLanguageCatalog.english).id,
            "th"
        )
        XCTAssertEqual(
            TranslationLanguageCatalog.defaultTarget(forSource: TranslationLanguageCatalog.korean).id,
            "en"
        )
        XCTAssertEqual(
            TranslationLanguageCatalog.defaultTarget(forSource: TranslationLanguageCatalog.thai).id,
            "en"
        )
    }

    func testSourceLanguageFollowsTheVoiceEngine() {
        let settings = SettingsStore.shared
        let originalModel = settings.selectedSpeechModel
        let originalLocale = settings.selectedAppleSpeechLocaleIdentifier
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        defer {
            settings.selectedSpeechModel = originalModel
            settings.selectedAppleSpeechLocaleIdentifier = originalLocale
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
        }

        settings.translationSourceLanguageID = "en"
        settings.translationTargetLanguageID = "th"
        settings.selectedSpeechModel = .appleSpeechAnalyzer
        settings.selectedAppleSpeechLocaleIdentifier = "ko-KR"

        XCTAssertEqual(SpokenLanguageResolver.spokenLanguageID(), "ko-KR")
        XCTAssertEqual(SpokenLanguageResolver.sourceLanguage().id, "ko")
    }

    @MainActor
    func testSettingsBackupRoundTripsTheaterKeys() async throws {
        let settings = SettingsStore.shared
        let originalTheater = settings.theaterWindowEnabled
        let originalInsertEnabled = settings.translationInsertHotkeyEnabled
        let originalInsertShortcut = settings.translationInsertHotkeyShortcut
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        defer {
            settings.theaterWindowEnabled = originalTheater
            settings.translationInsertHotkeyEnabled = originalInsertEnabled
            settings.translationInsertHotkeyShortcut = originalInsertShortcut
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
        }

        let shortcut = HotkeyShortcut(keyCode: 17, modifierFlags: [.option, .command])
        settings.theaterWindowEnabled = true
        settings.translationInsertHotkeyEnabled = true
        settings.translationInsertHotkeyShortcut = shortcut
        settings.translationSourceLanguageID = "ko"
        settings.translationTargetLanguageID = "en"

        let document = try await BackupService.shared.makeBackupDocument()
        XCTAssertEqual(document.settings.theaterWindowEnabled, true)
        XCTAssertEqual(document.settings.translationInsertHotkeyEnabled, true)
        XCTAssertEqual(document.settings.translationInsertHotkeyShortcut, shortcut)
        XCTAssertEqual(document.settings.translationSourceLanguageID, "ko")
        XCTAssertEqual(document.settings.translationTargetLanguageID, "en")

        settings.theaterWindowEnabled = false
        settings.translationInsertHotkeyEnabled = false
        settings.translationInsertHotkeyShortcut = nil
        settings.translationSourceLanguageID = "en"
        settings.translationTargetLanguageID = "th"
        settings.restore(from: document.settings)

        XCTAssertTrue(settings.theaterWindowEnabled)
        XCTAssertTrue(settings.translationInsertHotkeyEnabled)
        XCTAssertEqual(settings.translationInsertHotkeyShortcut, shortcut)
        XCTAssertEqual(settings.translationSourceLanguageID, "ko")
        XCTAssertEqual(settings.translationTargetLanguageID, "en")
    }

    func testAppleLanguagePrefersInstalledEnglish() {
        let installedEnglish = Locale.Language(identifier: "en")
        let regionalEnglish = Locale.Language(identifier: "en-IN")
        let resolved = TranslationLanguageCatalog.appleLanguage(
            for: TranslationLanguageCatalog.english,
            from: [regionalEnglish, installedEnglish]
        )
        XCTAssertEqual(resolved.minimalIdentifier, "en")
    }
}
