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
