@testable import FluidSubtitles_Debug
import XCTest

final class WhisperLanguageSelectionTests: XCTestCase {
    func testProductWhisperLanguagesAreKoreanEnglishThai() {
        XCTAssertEqual(VoiceEngineLanguageCatalog.whisperLanguageCode(for: "ko"), "ko")
        XCTAssertEqual(VoiceEngineLanguageCatalog.whisperLanguage(forCode: "ko")?.displayName, "Korean")
        XCTAssertEqual(VoiceEngineLanguageCatalog.whisperLanguageCode(for: "th"), "th")
        XCTAssertEqual(VoiceEngineLanguageCatalog.whisperLanguage(forCode: "th")?.displayName, "Thai")
        XCTAssertEqual(VoiceEngineLanguageCatalog.whisperLanguageCode(for: "en"), "en")
        XCTAssertEqual(
            Set(VoiceEngineLanguageCatalog.whisperLanguages.map(\.id)),
            ["en", "ko", "th"]
        )
        XCTAssertNil(VoiceEngineLanguageCatalog.whisperLanguage(forCode: "hu"))
    }

    func testWhisperRunOptionsUseSelectedLanguage() {
        XCTAssertEqual(WhisperProvider.runOptions(languageCode: "ko").language, "ko")
    }

    func testWhisperRunOptionsAllowAutomaticDetection() {
        XCTAssertNil(WhisperProvider.runOptions(languageCode: nil).language)
    }

    func testDictationPinUsesSpokenSourceUnlessQAExtras() {
        let settings = SettingsStore.shared
        let originalModel = settings.selectedSpeechModel
        let originalSource = settings.translationSourceLanguageID
        let originalWhisper = settings.selectedWhisperLanguageCode
        let originalAlsoHear = settings.theaterAlsoHearOtherLanguages
        defer {
            settings.selectedSpeechModel = originalModel
            settings.translationSourceLanguageID = originalSource
            settings.selectedWhisperLanguageCode = originalWhisper
            settings.theaterAlsoHearOtherLanguages = originalAlsoHear
        }

        settings.selectedSpeechModel = .whisperSmall
        settings.translationSourceLanguageID = "en"
        settings.selectedWhisperLanguageCode = nil
        settings.theaterAlsoHearOtherLanguages = false
        SpokenLanguageResolver.pinWhisperToSpokenSource(settings: settings)
        XCTAssertEqual(settings.selectedWhisperLanguageCode, "en")
    }

    func testTheaterListenPinsAutomaticWhisperToSpokenSource() {
        let settings = SettingsStore.shared
        let originalModel = settings.selectedSpeechModel
        let originalSource = settings.translationSourceLanguageID
        let originalWhisper = settings.selectedWhisperLanguageCode
        let originalAlsoHear = settings.theaterAlsoHearOtherLanguages
        defer {
            settings.selectedSpeechModel = originalModel
            settings.translationSourceLanguageID = originalSource
            settings.selectedWhisperLanguageCode = originalWhisper
            settings.theaterAlsoHearOtherLanguages = originalAlsoHear
        }

        settings.selectedSpeechModel = .whisperSmall
        settings.translationSourceLanguageID = "th"
        settings.selectedWhisperLanguageCode = nil
        settings.theaterAlsoHearOtherLanguages = false

        SpokenLanguageResolver.pinWhisperToSpokenSource(settings: settings)

        XCTAssertEqual(settings.selectedWhisperLanguageCode, "th")
        XCTAssertEqual(SpokenLanguageResolver.spokenLanguageID(settings: settings), "th")
        XCTAssertTrue(SpokenLanguageResolver.voiceEngineSupportsSource(settings: settings))
    }

    func testTheaterListenOverwritesMismatchedWhisperLanguage() {
        let settings = SettingsStore.shared
        let originalModel = settings.selectedSpeechModel
        let originalSource = settings.translationSourceLanguageID
        let originalWhisper = settings.selectedWhisperLanguageCode
        let originalAlsoHear = settings.theaterAlsoHearOtherLanguages
        defer {
            settings.selectedSpeechModel = originalModel
            settings.translationSourceLanguageID = originalSource
            settings.selectedWhisperLanguageCode = originalWhisper
            settings.theaterAlsoHearOtherLanguages = originalAlsoHear
        }

        settings.selectedSpeechModel = .whisperSmall
        settings.translationSourceLanguageID = "ko"
        settings.selectedWhisperLanguageCode = "en"
        settings.theaterAlsoHearOtherLanguages = false

        XCTAssertFalse(SpokenLanguageResolver.voiceEngineSupportsSource(settings: settings))
        SpokenLanguageResolver.pinWhisperToSpokenSource(settings: settings)

        XCTAssertEqual(settings.selectedWhisperLanguageCode, "ko")
        XCTAssertTrue(SpokenLanguageResolver.voiceEngineSupportsSource(settings: settings))
    }

    func testTheaterListenLeavesNonWhisperLanguageAlone() {
        let settings = SettingsStore.shared
        let originalModel = settings.selectedSpeechModel
        let originalSource = settings.translationSourceLanguageID
        let originalWhisper = settings.selectedWhisperLanguageCode
        defer {
            settings.selectedSpeechModel = originalModel
            settings.translationSourceLanguageID = originalSource
            settings.selectedWhisperLanguageCode = originalWhisper
        }

        settings.selectedSpeechModel = .appleSpeech
        settings.translationSourceLanguageID = "ko"
        settings.selectedWhisperLanguageCode = nil

        SpokenLanguageResolver.pinWhisperToSpokenSource(settings: settings)

        XCTAssertNil(settings.selectedWhisperLanguageCode)
    }

    func testTheaterQAExtrasLeaveWhisperOnAutomatic() {
        let settings = SettingsStore.shared
        let originalModel = settings.selectedSpeechModel
        let originalSource = settings.translationSourceLanguageID
        let originalWhisper = settings.selectedWhisperLanguageCode
        let originalAlsoHear = settings.theaterAlsoHearOtherLanguages
        defer {
            settings.selectedSpeechModel = originalModel
            settings.translationSourceLanguageID = originalSource
            settings.selectedWhisperLanguageCode = originalWhisper
            settings.theaterAlsoHearOtherLanguages = originalAlsoHear
        }

        settings.selectedSpeechModel = .whisperSmall
        settings.translationSourceLanguageID = "ko"
        settings.selectedWhisperLanguageCode = nil
        settings.theaterAlsoHearOtherLanguages = true

        SpokenLanguageResolver.pinWhisperToSpokenSource(settings: settings)

        XCTAssertNil(settings.selectedWhisperLanguageCode)
        XCTAssertNil(SpokenLanguageHints.whisperLanguageCode(stored: "ko", alsoHearOthers: true))
        XCTAssertEqual(SpokenLanguageHints.whisperLanguageCode(stored: "ko", alsoHearOthers: false), "ko")
    }

    @MainActor
    func testBeginSessionPinsAutomaticWhisperToSpokenSource() {
        let settings = SettingsStore.shared
        let originalModel = settings.selectedSpeechModel
        let originalSource = settings.translationSourceLanguageID
        let originalWhisper = settings.selectedWhisperLanguageCode
        let originalAlsoHear = settings.theaterAlsoHearOtherLanguages
        let controller = LiveTranslationController.shared
        controller.cancelSession()
        defer {
            controller.cancelSession()
            settings.selectedSpeechModel = originalModel
            settings.translationSourceLanguageID = originalSource
            settings.selectedWhisperLanguageCode = originalWhisper
            settings.theaterAlsoHearOtherLanguages = originalAlsoHear
        }

        settings.selectedSpeechModel = .whisperSmall
        settings.translationSourceLanguageID = "ko"
        settings.selectedWhisperLanguageCode = nil
        settings.theaterAlsoHearOtherLanguages = false

        controller.beginSession(kind: .captions)

        XCTAssertEqual(settings.selectedWhisperLanguageCode, "ko")
        XCTAssertTrue(SpokenLanguageResolver.voiceEngineSupportsSource(settings: settings))
    }

    func testStoredWhisperLanguageSelectionResolution() {
        XCTAssertNil(SettingsStore.whisperLanguageCode(fromStoredValue: nil))
        XCTAssertNil(SettingsStore.whisperLanguageCode(fromStoredValue: "auto"))
        XCTAssertEqual(SettingsStore.whisperLanguageCode(fromStoredValue: "ko"), "ko")
        XCTAssertNil(SettingsStore.whisperLanguageCode(fromStoredValue: "hu"))
        XCTAssertNil(SettingsStore.whisperLanguageCode(fromStoredValue: "unsupported"))
    }

    func testAutomaticWhisperLanguageRoundTripsThroughBackupValue() {
        let backupValue = SettingsStore.whisperLanguageBackupValue(for: nil)

        XCTAssertEqual(backupValue, "auto")
        XCTAssertNil(SettingsStore.whisperLanguageCode(fromBackupValue: backupValue))
    }

    func testForcedWhisperLanguageRoundTripsThroughBackupValue() {
        let backupValue = SettingsStore.whisperLanguageBackupValue(for: "ko")

        XCTAssertEqual(backupValue, "ko")
        XCTAssertEqual(SettingsStore.whisperLanguageCode(fromBackupValue: backupValue), "ko")
    }

    func testWhisperLanguageCodesAreUnique() {
        let languageCodes = VoiceEngineLanguageCatalog.whisperLanguages.compactMap {
            VoiceEngineLanguageCatalog.whisperLanguageCode(for: $0.id)
        }
        XCTAssertEqual(languageCodes.count, Set(languageCodes).count)
    }
}
