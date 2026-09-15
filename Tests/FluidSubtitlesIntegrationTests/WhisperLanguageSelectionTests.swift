@testable import FluidSubtitles_Debug
import XCTest

final class WhisperLanguageSelectionTests: XCTestCase {
    func testProductWhisperLanguagesAreKoreanEnglishThaiJapanese() {
        XCTAssertEqual(VoiceEngineLanguageCatalog.whisperLanguageCode(for: "ko"), "ko")
        XCTAssertEqual(VoiceEngineLanguageCatalog.whisperLanguage(forCode: "ko")?.displayName, "Korean")
        XCTAssertEqual(VoiceEngineLanguageCatalog.whisperLanguageCode(for: "th"), "th")
        XCTAssertEqual(VoiceEngineLanguageCatalog.whisperLanguage(forCode: "th")?.displayName, "Thai")
        XCTAssertEqual(VoiceEngineLanguageCatalog.whisperLanguageCode(for: "ja"), "ja")
        XCTAssertEqual(VoiceEngineLanguageCatalog.whisperLanguage(forCode: "ja")?.displayName, "Japanese")
        XCTAssertEqual(VoiceEngineLanguageCatalog.whisperLanguageCode(for: "en"), "en")
        XCTAssertEqual(
            Set(VoiceEngineLanguageCatalog.whisperLanguages.map(\.id)),
            ["en", "ko", "ja", "th"]
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

    func testTheaterListenKeepsWhisperInSyncWhenAppleSpeechIsSelected() {
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

        XCTAssertEqual(settings.selectedWhisperLanguageCode, "ko")
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

    func testPinLocksCohereAndNemotronToISpeak() {
        let settings = SettingsStore.shared
        let originalModel = settings.selectedSpeechModel
        let originalSource = settings.translationSourceLanguageID
        let originalCohere = settings.selectedCohereLanguage
        let originalNemotron = settings.selectedNemotronLanguage
        let originalWhisper = settings.selectedWhisperLanguageCode
        let originalApple = settings.selectedAppleSpeechLocaleIdentifier
        defer {
            settings.selectedSpeechModel = originalModel
            settings.translationSourceLanguageID = originalSource
            settings.selectedCohereLanguage = originalCohere
            settings.selectedNemotronLanguage = originalNemotron
            settings.selectedWhisperLanguageCode = originalWhisper
            settings.selectedAppleSpeechLocaleIdentifier = originalApple
        }

        settings.translationSourceLanguageID = "ko"
        settings.selectedSpeechModel = .cohereTranscribeSixBit
        settings.selectedCohereLanguage = .english
        SpokenLanguageResolver.pinSpokenEngineToSource(settings: settings)
        XCTAssertEqual(settings.selectedCohereLanguage, .korean)
        XCTAssertTrue(SpokenLanguageResolver.voiceEngineSupportsSource(settings: settings))
        XCTAssertNil(SpokenLanguageResolver.voiceEngineMismatchMessage(settings: settings))

        settings.selectedSpeechModel = .nemotronStreaming
        settings.selectedNemotronLanguage = .english
        SpokenLanguageResolver.pinSpokenEngineToSource(settings: settings)
        XCTAssertEqual(settings.selectedNemotronLanguage.rawValue, "ko")
        XCTAssertEqual(SpokenLanguageResolver.spokenLanguageID(settings: settings), "ko")
        XCTAssertTrue(SpokenLanguageResolver.voiceEngineSupportsSource(settings: settings))
    }

    func testPinSpokenEngineLocksEveryBindingToISpeak() {
        let settings = SettingsStore.shared
        let originalModel = settings.selectedSpeechModel
        let originalSource = settings.translationSourceLanguageID
        let originalWhisper = settings.selectedWhisperLanguageCode
        let originalApple = settings.selectedAppleSpeechLocaleIdentifier
        let originalCohere = settings.selectedCohereLanguage
        let originalNemotron = settings.selectedNemotronLanguage
        let originalAlsoHear = settings.theaterAlsoHearOtherLanguages
        defer {
            settings.selectedSpeechModel = originalModel
            settings.translationSourceLanguageID = originalSource
            settings.selectedWhisperLanguageCode = originalWhisper
            settings.selectedAppleSpeechLocaleIdentifier = originalApple
            settings.selectedCohereLanguage = originalCohere
            settings.selectedNemotronLanguage = originalNemotron
            settings.theaterAlsoHearOtherLanguages = originalAlsoHear
        }

        settings.theaterAlsoHearOtherLanguages = false
        settings.selectedSpeechModel = .appleSpeech
        settings.translationSourceLanguageID = "ja"
        settings.selectedWhisperLanguageCode = "en"
        settings.selectedAppleSpeechLocaleIdentifier = "en-US"
        settings.selectedCohereLanguage = .english
        settings.selectedNemotronLanguage = .english

        XCTAssertTrue(SpokenLanguageResolver.syncSpokenEngineToTheater(settings: settings))
        XCTAssertEqual(settings.selectedWhisperLanguageCode, "ja")
        XCTAssertEqual(settings.selectedAppleSpeechLocaleIdentifier, "ja-JP")
        XCTAssertEqual(settings.selectedCohereLanguage, .japanese)
        XCTAssertEqual(settings.selectedNemotronLanguage.rawValue, "ja-JP")
        XCTAssertFalse(SpokenLanguageResolver.syncSpokenEngineToTheater(settings: settings))
        XCTAssertEqual(SpokenLanguageResolver.spokenLanguageID(settings: settings), "ja")
        XCTAssertTrue(SpokenLanguageResolver.voiceEngineSupportsSource(settings: settings))
        XCTAssertNil(SpokenLanguageResolver.voiceEngineMismatchMessage(settings: settings))
    }

    func testWhisperLargeHearsISpeakEnglish() {
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

        settings.selectedSpeechModel = .whisperLarge
        settings.translationSourceLanguageID = "en"
        settings.selectedWhisperLanguageCode = "en"
        settings.theaterAlsoHearOtherLanguages = false
        SpokenLanguageResolver.pinSpokenEngineToSource(settings: settings)

        XCTAssertTrue(VoiceEngineLanguageCatalog.supports(.whisperLarge, languageID: "en"))
        XCTAssertTrue(SpokenLanguageResolver.voiceEngineSupportsSource(settings: settings))
        XCTAssertNil(SpokenLanguageResolver.voiceEngineMismatchMessage(settings: settings))
        XCTAssertEqual(
            SpokenLanguageResolver.stageEngineSummary(settings: settings),
            "Hearing English with Whisper Large."
        )
    }

    func testSyncSpokenEngineDetectsISpeakChange() {
        let settings = SettingsStore.shared
        let originalModel = settings.selectedSpeechModel
        let originalSource = settings.translationSourceLanguageID
        let originalApple = settings.selectedAppleSpeechLocaleIdentifier
        defer {
            settings.selectedSpeechModel = originalModel
            settings.translationSourceLanguageID = originalSource
            settings.selectedAppleSpeechLocaleIdentifier = originalApple
        }

        settings.selectedSpeechModel = .appleSpeechAnalyzer
        settings.translationSourceLanguageID = "en"
        SpokenLanguageResolver.pinSpokenEngineToSource(settings: settings)
        XCTAssertFalse(SpokenLanguageResolver.syncSpokenEngineToTheater(settings: settings))

        settings.translationSourceLanguageID = "ko"
        XCTAssertTrue(SpokenLanguageResolver.syncSpokenEngineToTheater(settings: settings))
        XCTAssertEqual(settings.selectedAppleSpeechLocaleIdentifier, "ko-KR")
    }

    func testWhisperLanguageCodesAreUnique() {
        let languageCodes = VoiceEngineLanguageCatalog.whisperLanguages.compactMap {
            VoiceEngineLanguageCatalog.whisperLanguageCode(for: $0.id)
        }
        XCTAssertEqual(languageCodes.count, Set(languageCodes).count)
    }
}
