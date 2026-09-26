@testable import FluidSubtitles_Debug
import XCTest

@MainActor
final class SettingsStorePromptBindingAndMigrationTests: XCTestCase {
    private func withRestoredPromptState(_ run: () -> Void) {
        let settings = SettingsStore.shared
        let originalProfiles = settings.dictationPromptProfiles
        let originalBindings = settings.appPromptBindings
        let originalConfigurations = settings.dictationPromptConfigurations
        defer {
            settings.dictationPromptProfiles = originalProfiles
            settings.appPromptBindings = originalBindings
            settings.dictationPromptConfigurations = originalConfigurations
        }
        run()
    }

    private func withRestoredDefaults(keys: [String], run: () -> Void) {
        let defaults = SettingsStore.shared.defaults
        let originalValues = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in originalValues {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        run()
    }

    // MARK: - upsertAppPromptBinding / removeAppPromptBinding

    func testUpsertAppPromptBindingInsertsThenUpdatesInPlace() {
        self.withRestoredPromptState {
            let settings = SettingsStore.shared
            settings.appPromptBindings = []

            settings.upsertAppPromptBinding(
                for: .dictate,
                appBundleID: "  Com.Apple.Notes  ",
                appName: "Notes",
                promptID: "p1"
            )
            XCTAssertEqual(settings.appPromptBindings.count, 1)
            let inserted = settings.appPromptBindings[0]
            XCTAssertEqual(inserted.appBundleID, "com.apple.notes")
            XCTAssertEqual(inserted.promptID, "p1")

            settings.upsertAppPromptBinding(
                for: .dictate,
                appBundleID: "com.apple.notes",
                appName: "Notes Updated",
                promptID: "  "
            )
            XCTAssertEqual(settings.appPromptBindings.count, 1, "Same mode + bundle ID must update, not duplicate")
            let updated = settings.appPromptBindings[0]
            XCTAssertEqual(updated.id, inserted.id)
            XCTAssertEqual(updated.appName, "Notes Updated")
            XCTAssertNil(updated.promptID, "Blank promptID must resolve to nil (Default)")
        }
    }

    func testUpsertAppPromptBindingIgnoresBlankBundleID() {
        self.withRestoredPromptState {
            let settings = SettingsStore.shared
            settings.appPromptBindings = []

            settings.upsertAppPromptBinding(for: .dictate, appBundleID: "   ", appName: "Ignored", promptID: nil)

            XCTAssertTrue(settings.appPromptBindings.isEmpty)
        }
    }

    func testRemoveAppPromptBindingByID() {
        self.withRestoredPromptState {
            let settings = SettingsStore.shared
            settings.appPromptBindings = []
            settings.upsertAppPromptBinding(for: .dictate, appBundleID: "com.apple.notes", appName: "Notes", promptID: nil)
            let id = settings.appPromptBindings[0].id

            settings.removeAppPromptBinding(id: id)

            XCTAssertTrue(settings.appPromptBindings.isEmpty)
        }
    }

    func testRemoveAppPromptBindingByModeAndBundleID() {
        self.withRestoredPromptState {
            let settings = SettingsStore.shared
            settings.appPromptBindings = []
            settings.upsertAppPromptBinding(for: .dictate, appBundleID: "com.apple.notes", appName: "Notes", promptID: nil)

            settings.removeAppPromptBinding(for: .dictate, appBundleID: "COM.APPLE.NOTES")

            XCTAssertTrue(settings.appPromptBindings.isEmpty)
        }
    }

    // MARK: - removeDictationPromptConfiguration

    func testRemoveDictationPromptConfigurationDeletesOnlyMatchingKey() {
        self.withRestoredPromptState {
            let settings = SettingsStore.shared
            settings.dictationPromptConfigurations = [
                "__default__": SettingsStore.DictationPromptConfiguration(providerID: "openai"),
                "profile:abc": SettingsStore.DictationPromptConfiguration(providerID: "openai"),
            ]

            settings.removeDictationPromptConfiguration(for: .default)

            let remaining = settings.dictationPromptConfigurations
            XCTAssertNil(remaining["__default__"])
            XCTAssertNotNil(remaining["profile:abc"])
        }
    }

    func testRemoveDictationPromptConfigurationIsNoOpForOffSelection() {
        self.withRestoredPromptState {
            let settings = SettingsStore.shared
            settings.dictationPromptConfigurations = [
                "__default__": SettingsStore.DictationPromptConfiguration(providerID: "openai"),
            ]

            settings.removeDictationPromptConfiguration(for: .off)

            XCTAssertEqual(settings.dictationPromptConfigurations.count, 1)
        }
    }

    // MARK: - migrateToSpeechModel

    func testMigrateToSpeechModelMapsLegacyWhisperSelections() {
        self.withRestoredDefaults(keys: [
            SettingsStore.Keys.selectedTranscriptionProvider,
            SettingsStore.Keys.whisperModelSize,
        ]) {
            let settings = SettingsStore.shared
            settings.defaults.set("whisper", forKey: SettingsStore.Keys.selectedTranscriptionProvider)
            settings.defaults.set("ggml-small.bin", forKey: SettingsStore.Keys.whisperModelSize)

            XCTAssertEqual(settings.migrateToSpeechModel(), .whisperSmall)
        }
    }

    func testMigrateToSpeechModelFallsBackToDefaultForAutoProvider() {
        self.withRestoredDefaults(keys: [
            SettingsStore.Keys.selectedTranscriptionProvider,
            SettingsStore.Keys.whisperModelSize,
        ]) {
            let settings = SettingsStore.shared
            settings.defaults.removeObject(forKey: SettingsStore.Keys.selectedTranscriptionProvider)
            settings.defaults.removeObject(forKey: SettingsStore.Keys.whisperModelSize)

            XCTAssertEqual(settings.migrateToSpeechModel(), SettingsStore.SpeechModel.defaultModel)
        }
    }

    func testMigrateToSpeechModelUnknownWhisperSizeFallsBackToBase() {
        self.withRestoredDefaults(keys: [
            SettingsStore.Keys.selectedTranscriptionProvider,
            SettingsStore.Keys.whisperModelSize,
        ]) {
            let settings = SettingsStore.shared
            settings.defaults.set("whisper", forKey: SettingsStore.Keys.selectedTranscriptionProvider)
            settings.defaults.set("some-unrecognized-size", forKey: SettingsStore.Keys.whisperModelSize)

            XCTAssertEqual(settings.migrateToSpeechModel(), .whisperBase)
        }
    }

    // MARK: - migrateCaptionAccentIfNeeded

    func testMigrateCaptionAccentIfNeededMigratesUnsetAndTealToCaption() {
        self.withRestoredDefaults(keys: [
            SettingsStore.Keys.captionAccentMigration,
            SettingsStore.Keys.accentColorOption,
        ]) {
            let settings = SettingsStore.shared

            settings.defaults.removeObject(forKey: SettingsStore.Keys.captionAccentMigration)
            settings.defaults.removeObject(forKey: SettingsStore.Keys.accentColorOption)
            settings.migrateCaptionAccentIfNeeded()
            XCTAssertEqual(settings.accentColorOption, .caption)

            settings.defaults.removeObject(forKey: SettingsStore.Keys.captionAccentMigration)
            settings.accentColorOption = .teal
            settings.migrateCaptionAccentIfNeeded()
            XCTAssertEqual(settings.accentColorOption, .caption)
        }
    }

    func testMigrateCaptionAccentIfNeededLeavesOtherAccentsAloneAndRunsOnce() {
        self.withRestoredDefaults(keys: [
            SettingsStore.Keys.captionAccentMigration,
            SettingsStore.Keys.accentColorOption,
        ]) {
            let settings = SettingsStore.shared
            settings.defaults.removeObject(forKey: SettingsStore.Keys.captionAccentMigration)
            settings.accentColorOption = .green

            settings.migrateCaptionAccentIfNeeded()
            XCTAssertEqual(settings.accentColorOption, .green)

            // Once migrated, a later switch to teal must not be silently rewritten.
            settings.accentColorOption = .teal
            settings.migrateCaptionAccentIfNeeded()
            XCTAssertEqual(settings.accentColorOption, .teal)
        }
    }

    // MARK: - normalizedTranscriptionPreviewCharLimit

    func testNormalizedTranscriptionPreviewCharLimitClampsToRange() {
        XCTAssertEqual(SettingsStore.normalizedTranscriptionPreviewCharLimit(0), 50)
        XCTAssertEqual(SettingsStore.normalizedTranscriptionPreviewCharLimit(1000), 800)
    }

    func testNormalizedTranscriptionPreviewCharLimitSnapsToStep() {
        XCTAssertEqual(SettingsStore.normalizedTranscriptionPreviewCharLimit(120), 100)
        XCTAssertEqual(SettingsStore.normalizedTranscriptionPreviewCharLimit(275), 300)
    }
}
