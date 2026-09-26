@testable import FluidSubtitles_Debug
import XCTest

@MainActor
final class SettingsStoreMigrationsTests: XCTestCase {
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

    private func withRestoredPromptState(_ run: () -> Void) {
        let settings = SettingsStore.shared
        let originalProfiles = settings.dictationPromptProfiles
        let originalBindings = settings.appPromptBindings
        let originalConfigurations = settings.dictationPromptConfigurations
        let originalSelectedID = settings.selectedDictationPromptID
        let originalCustomPrompt = settings.customDictationPrompt
        defer {
            settings.dictationPromptProfiles = originalProfiles
            settings.appPromptBindings = originalBindings
            settings.dictationPromptConfigurations = originalConfigurations
            settings.selectedDictationPromptID = originalSelectedID
            settings.customDictationPrompt = originalCustomPrompt
        }
        run()
    }

    // MARK: - migrateSecondaryPromptShortcutIfNeeded

    func testMigrateSecondaryPromptShortcutIfNeededDisablesLegacyShortcutOnce() {
        self.withRestoredDefaults(keys: [
            SettingsStore.Keys.secondaryPromptShortcutRemoved,
            SettingsStore.Keys.promptModeShortcutEnabled,
            SettingsStore.Keys.secondaryDictationPromptOff,
            SettingsStore.Keys.promptModeSelectedPromptID,
        ]) {
            let settings = SettingsStore.shared
            settings.defaults.removeObject(forKey: SettingsStore.Keys.secondaryPromptShortcutRemoved)
            settings.defaults.set(true, forKey: SettingsStore.Keys.promptModeShortcutEnabled)
            settings.defaults.set("some-prompt-id", forKey: SettingsStore.Keys.promptModeSelectedPromptID)

            settings.migrateSecondaryPromptShortcutIfNeeded()

            XCTAssertTrue(settings.defaults.bool(forKey: SettingsStore.Keys.secondaryPromptShortcutRemoved))
            XCTAssertFalse(settings.defaults.bool(forKey: SettingsStore.Keys.promptModeShortcutEnabled))
            XCTAssertTrue(settings.defaults.bool(forKey: SettingsStore.Keys.secondaryDictationPromptOff))
            XCTAssertNil(settings.defaults.object(forKey: SettingsStore.Keys.promptModeSelectedPromptID))
        }
    }

    func testMigrateSecondaryPromptShortcutIfNeededIsNoOpAfterFirstRun() {
        self.withRestoredDefaults(keys: [
            SettingsStore.Keys.secondaryPromptShortcutRemoved,
            SettingsStore.Keys.promptModeShortcutEnabled,
        ]) {
            let settings = SettingsStore.shared
            settings.defaults.set(true, forKey: SettingsStore.Keys.secondaryPromptShortcutRemoved)
            settings.defaults.set(true, forKey: SettingsStore.Keys.promptModeShortcutEnabled)

            settings.migrateSecondaryPromptShortcutIfNeeded()

            XCTAssertTrue(
                settings.defaults.bool(forKey: SettingsStore.Keys.promptModeShortcutEnabled),
                "Once the migration guard flag is set, the migration must not touch state again"
            )
        }
    }

    // MARK: - retireLegacySecondaryPromptShortcutIfNeeded

    func testRetireLegacySecondaryPromptShortcutIfNeededClearsLegacyShortcutState() {
        self.withRestoredDefaults(keys: [
            SettingsStore.Keys.legacySecondaryPromptShortcutRetired,
            SettingsStore.Keys.promptModeShortcutEnabled,
            SettingsStore.Keys.secondaryDictationPromptOff,
            SettingsStore.Keys.promptModeHotkeyShortcut,
            SettingsStore.Keys.promptModeSelectedPromptID,
        ]) {
            let settings = SettingsStore.shared
            settings.defaults.removeObject(forKey: SettingsStore.Keys.legacySecondaryPromptShortcutRetired)
            settings.defaults.set(true, forKey: SettingsStore.Keys.promptModeShortcutEnabled)
            settings.defaults.set("legacy-hotkey-data".data(using: .utf8), forKey: SettingsStore.Keys.promptModeHotkeyShortcut)
            settings.defaults.set("some-prompt-id", forKey: SettingsStore.Keys.promptModeSelectedPromptID)

            settings.retireLegacySecondaryPromptShortcutIfNeeded()

            XCTAssertTrue(settings.defaults.bool(forKey: SettingsStore.Keys.legacySecondaryPromptShortcutRetired))
            XCTAssertFalse(settings.defaults.bool(forKey: SettingsStore.Keys.promptModeShortcutEnabled))
            XCTAssertTrue(settings.defaults.bool(forKey: SettingsStore.Keys.secondaryDictationPromptOff))
            XCTAssertNil(settings.defaults.object(forKey: SettingsStore.Keys.promptModeHotkeyShortcut))
            XCTAssertNil(settings.defaults.object(forKey: SettingsStore.Keys.promptModeSelectedPromptID))
        }
    }

    // MARK: - migrateOverlayBottomOffsetTo50IfNeeded

    func testMigrateOverlayBottomOffsetTo50IfNeededSetsOffsetOnce() {
        self.withRestoredDefaults(keys: [
            SettingsStore.Keys.overlayBottomOffsetMigratedTo50,
            SettingsStore.Keys.overlayBottomOffset,
        ]) {
            let settings = SettingsStore.shared
            settings.defaults.removeObject(forKey: SettingsStore.Keys.overlayBottomOffsetMigratedTo50)
            settings.defaults.set(12.0, forKey: SettingsStore.Keys.overlayBottomOffset)

            settings.migrateOverlayBottomOffsetTo50IfNeeded()

            XCTAssertEqual(settings.defaults.double(forKey: SettingsStore.Keys.overlayBottomOffset), 50.0)
            XCTAssertTrue(settings.defaults.bool(forKey: SettingsStore.Keys.overlayBottomOffsetMigratedTo50))

            // A user-chosen offset after the one-time migration must be left alone.
            settings.defaults.set(80.0, forKey: SettingsStore.Keys.overlayBottomOffset)
            settings.migrateOverlayBottomOffsetTo50IfNeeded()
            XCTAssertEqual(settings.defaults.double(forKey: SettingsStore.Keys.overlayBottomOffset), 80.0)
        }
    }

    // MARK: - migrateLegacyDictationAIPreferenceIfNeeded

    func testMigrateLegacyDictationAIPreferenceDefaultsToOffWithNoSignal() {
        self.withRestoredDefaults(keys: [
            SettingsStore.Keys.dictationPromptOff,
            SettingsStore.Keys.enableAIProcessing,
            SettingsStore.Keys.selectedDictationPromptID,
        ]) {
            let settings = SettingsStore.shared
            settings.defaults.removeObject(forKey: SettingsStore.Keys.dictationPromptOff)
            settings.defaults.removeObject(forKey: SettingsStore.Keys.enableAIProcessing)
            settings.selectedDictationPromptID = nil

            settings.migrateLegacyDictationAIPreferenceIfNeeded()

            XCTAssertTrue(settings.defaults.bool(forKey: SettingsStore.Keys.dictationPromptOff))
        }
    }

    func testMigrateLegacyDictationAIPreferenceFollowsLegacyAIProcessingFlag() {
        self.withRestoredDefaults(keys: [
            SettingsStore.Keys.dictationPromptOff,
            SettingsStore.Keys.enableAIProcessing,
            SettingsStore.Keys.selectedDictationPromptID,
        ]) {
            let settings = SettingsStore.shared
            settings.selectedDictationPromptID = nil

            settings.defaults.removeObject(forKey: SettingsStore.Keys.dictationPromptOff)
            settings.defaults.set(true, forKey: SettingsStore.Keys.enableAIProcessing)
            settings.migrateLegacyDictationAIPreferenceIfNeeded()
            XCTAssertFalse(settings.defaults.bool(forKey: SettingsStore.Keys.dictationPromptOff))

            settings.defaults.removeObject(forKey: SettingsStore.Keys.dictationPromptOff)
            settings.defaults.set(false, forKey: SettingsStore.Keys.enableAIProcessing)
            settings.migrateLegacyDictationAIPreferenceIfNeeded()
            XCTAssertTrue(settings.defaults.bool(forKey: SettingsStore.Keys.dictationPromptOff))
        }
    }

    func testMigrateLegacyDictationAIPreferenceStaysOnWithSelectedCustomPrompt() {
        self.withRestoredPromptState {
            self.withRestoredDefaults(keys: [
                SettingsStore.Keys.dictationPromptOff,
                SettingsStore.Keys.enableAIProcessing,
            ]) {
                let settings = SettingsStore.shared
                let profile = SettingsStore.DictationPromptProfile(name: "Custom", prompt: "Be terse.", mode: .dictate)
                settings.dictationPromptProfiles = [profile]
                settings.selectedDictationPromptID = profile.id

                settings.defaults.removeObject(forKey: SettingsStore.Keys.dictationPromptOff)
                settings.defaults.set(false, forKey: SettingsStore.Keys.enableAIProcessing)

                settings.migrateLegacyDictationAIPreferenceIfNeeded()

                XCTAssertFalse(
                    settings.defaults.bool(forKey: SettingsStore.Keys.dictationPromptOff),
                    "A selected custom dictation prompt should keep AI dictation on regardless of the legacy flag"
                )
            }
        }
    }

    func testMigrateLegacyDictationAIPreferenceIsNoOpOnceMigrated() {
        self.withRestoredDefaults(keys: [
            SettingsStore.Keys.dictationPromptOff,
            SettingsStore.Keys.enableAIProcessing,
        ]) {
            let settings = SettingsStore.shared
            settings.defaults.set(false, forKey: SettingsStore.Keys.dictationPromptOff)
            settings.defaults.set(false, forKey: SettingsStore.Keys.enableAIProcessing)

            settings.migrateLegacyDictationAIPreferenceIfNeeded()

            XCTAssertFalse(
                settings.defaults.bool(forKey: SettingsStore.Keys.dictationPromptOff),
                "Once migrated, the stored preference must not be recomputed from the legacy flag"
            )
        }
    }

    // MARK: - migrateDictationPromptProfilesIfNeeded

    func testMigrateDictationPromptProfilesIsNoOpWithoutLegacyPrompt() {
        self.withRestoredPromptState {
            let settings = SettingsStore.shared
            settings.customDictationPrompt = ""
            settings.dictationPromptProfiles = []

            settings.migrateDictationPromptProfilesIfNeeded()

            XCTAssertTrue(settings.dictationPromptProfiles.isEmpty)
            XCTAssertEqual(settings.customDictationPrompt, "")
        }
    }

    func testMigrateDictationPromptProfilesConvertsLegacyPromptWhenNoProfilesExist() {
        self.withRestoredPromptState {
            let settings = SettingsStore.shared
            settings.dictationPromptProfiles = []
            settings.customDictationPrompt = "Always answer in Spanish."

            settings.migrateDictationPromptProfilesIfNeeded()

            XCTAssertEqual(settings.customDictationPrompt, "")
            XCTAssertEqual(settings.dictationPromptProfiles.count, 1)
            let migrated = settings.dictationPromptProfiles[0]
            XCTAssertEqual(migrated.prompt, "Always answer in Spanish.")
            XCTAssertEqual(migrated.mode, .dictate)
            XCTAssertEqual(settings.selectedDictationPromptID, migrated.id)
        }
    }

    func testMigrateDictationPromptProfilesClearsLegacyPromptWhenProfilesAlreadyExist() {
        self.withRestoredPromptState {
            let settings = SettingsStore.shared
            let existingProfile = SettingsStore.DictationPromptProfile(name: "Existing", prompt: "Existing prompt", mode: .dictate)
            settings.dictationPromptProfiles = [existingProfile]
            settings.customDictationPrompt = "Orphaned legacy prompt"
            settings.selectedDictationPromptID = "not-a-real-profile-id"

            settings.migrateDictationPromptProfilesIfNeeded()

            XCTAssertEqual(settings.customDictationPrompt, "")
            XCTAssertEqual(settings.dictationPromptProfiles, [existingProfile])
            XCTAssertNil(
                settings.selectedDictationPromptID,
                "A selection pointing at a nonexistent profile must be reset to Default"
            )
        }
    }

    // MARK: - normalizeDictationPromptConfigurationsIfNeeded

    func testNormalizeDictationPromptConfigurationsRemovesInvalidAndEmptyEntries() {
        self.withRestoredPromptState {
            let settings = SettingsStore.shared
            let profile = SettingsStore.DictationPromptProfile(id: "p1", name: "P1", prompt: "Prompt", mode: .dictate)
            settings.dictationPromptProfiles = [profile]
            settings.dictationPromptConfigurations = [
                "__default__": SettingsStore.DictationPromptConfiguration(),
                "profile:p1": SettingsStore.DictationPromptConfiguration(providerID: "openai"),
                "profile:missing": SettingsStore.DictationPromptConfiguration(providerID: "openai"),
                "__privateAI__": SettingsStore.DictationPromptConfiguration(modelName: "gpt"),
            ]

            settings.normalizeDictationPromptConfigurationsIfNeeded()

            let remainingKeys = Set(settings.dictationPromptConfigurations.keys)
            XCTAssertEqual(remainingKeys, ["profile:p1", "__privateAI__"])
        }
    }

    // MARK: - normalizePromptSelectionsIfNeeded

    func testNormalizePromptSelectionsDedupesAppBindingsKeepingMostRecentlyUpdated() {
        self.withRestoredPromptState {
            let settings = SettingsStore.shared
            let profile = SettingsStore.DictationPromptProfile(id: "p1", name: "P1", prompt: "Prompt", mode: .dictate)
            settings.dictationPromptProfiles = [profile]

            let older = SettingsStore.AppPromptBinding(
                id: "older",
                mode: .dictate,
                appBundleID: "  Com.Apple.Notes  ",
                appName: "Notes",
                promptID: "p1",
                createdAt: Date(timeIntervalSince1970: 1000),
                updatedAt: Date(timeIntervalSince1970: 1000)
            )
            let newer = SettingsStore.AppPromptBinding(
                id: "newer",
                mode: .dictate,
                appBundleID: "com.apple.notes",
                appName: "Notes Latest",
                promptID: "not-a-real-profile-id",
                createdAt: Date(timeIntervalSince1970: 2000),
                updatedAt: Date(timeIntervalSince1970: 2000)
            )
            settings.appPromptBindings = [older, newer]

            settings.normalizePromptSelectionsIfNeeded()

            let bindings = settings.appPromptBindings
            XCTAssertEqual(bindings.count, 1, "Duplicate bindings for the same app + mode must collapse to one")
            let winner = bindings[0]
            XCTAssertEqual(winner.appBundleID, "com.apple.notes")
            XCTAssertEqual(winner.appName, "Notes Latest")
            XCTAssertNil(
                winner.promptID,
                "A binding pointing at a nonexistent profile must have its promptID cleared"
            )
        }
    }

    // MARK: - canonicalProviderKey

    func testCanonicalProviderKeyOnlyPrefixesNonBuiltInProviders() {
        let settings = SettingsStore.shared
        XCTAssertEqual(settings.canonicalProviderKey(for: "  "), "")
        XCTAssertEqual(settings.canonicalProviderKey(for: "custom:already-prefixed"), "custom:already-prefixed")
        XCTAssertEqual(settings.canonicalProviderKey(for: "my-custom-provider-id"), "custom:my-custom-provider-id")
    }
}
