//
//  SettingsStore+Migrations.swift
//  Fluid
//
//  UserDefaults migrations and provider-key hygiene.
//

import AppKit
import CryptoKit
import Foundation

extension SettingsStore {
    // MARK: - Private Methods

    func logProviderAPIKeyPersistenceFailure(_ error: Error) {
        DebugLogger.shared.error(
            "Failed to persist provider API keys: \(error.localizedDescription)",
            source: "SettingsStore"
        )
    }

    func migrateTranscriptionStartSoundIfNeeded() {
        guard let legacyEnabled = self.defaults.object(forKey: Keys.enableTranscriptionSounds) as? Bool else { return }
        if legacyEnabled == false {
            self.defaults.set(TranscriptionStartSound.none.rawValue, forKey: Keys.transcriptionStartSound)
        }
        self.defaults.removeObject(forKey: Keys.enableTranscriptionSounds)
    }

    func migrateProviderAPIKeysIfNeeded() {
        self.defaults.removeObject(forKey: Keys.providerAPIKeyIdentifiers)

        var merged = (try? self.keychain.fetchAllKeys()) ?? [:]
        var didMutate = false

        if let legacyDefaults = defaults.dictionary(forKey: Keys.providerAPIKeys) as? [String: String],
           legacyDefaults.isEmpty == false
        {
            merged.merge(self.sanitizeAPIKeys(legacyDefaults)) { _, new in new }
            didMutate = true
        }
        self.defaults.removeObject(forKey: Keys.providerAPIKeys)

        if let legacyKeychain = try? keychain.legacyProviderEntries(),
           legacyKeychain.isEmpty == false
        {
            merged.merge(self.sanitizeAPIKeys(legacyKeychain)) { _, new in new }
            didMutate = true
            try? self.keychain.removeLegacyEntries(providerIDs: Array(legacyKeychain.keys))
        }

        if didMutate {
            do {
                _ = try self.saveProviderAPIKeys(merged)
            } catch {
                self.logProviderAPIKeyPersistenceFailure(error)
            }
        }
    }

    func migrateDictationPromptProfilesIfNeeded() {
        // Migration path from legacy single prompt to multi-prompt profiles.
        // If user had a legacy custom dictation prompt, convert it to a profile and select it.
        let legacyPrompt = self.customDictationPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !legacyPrompt.isEmpty else { return }

        // If profiles already exist, just clear the legacy prompt so we don't keep two sources of truth.
        if self.dictationPromptProfiles.isEmpty == false {
            self.customDictationPrompt = ""
            // If selection points to nowhere, reset to default to avoid confusion.
            if let id = self.selectedDictationPromptID,
               self.dictationPromptProfiles.contains(where: { $0.id == id && $0.mode == .dictate }) == false
            {
                self.selectedDictationPromptID = nil
            }
            return
        }

        let profile = DictationPromptProfile(
            name: "My Custom Prompt",
            prompt: legacyPrompt,
            createdAt: Date(),
            updatedAt: Date()
        )
        self.dictationPromptProfiles = [profile]
        self.selectedDictationPromptID = profile.id
        self.customDictationPrompt = ""
        DebugLogger.shared.info("Migrated legacy custom dictation prompt to a prompt profile", source: "SettingsStore")
    }

    func migrateLegacyDictationAIPreferenceIfNeeded() {
        guard self.defaults.object(forKey: Keys.dictationPromptOff) == nil else { return }

        let hasSelectedCustomDictationPrompt = self.selectedDictationPromptID.flatMap { id in
            self.dictationPromptProfiles.first(where: { $0.id == id && $0.mode == .dictate })
        } != nil

        let shouldStartOff: Bool
        if hasSelectedCustomDictationPrompt {
            shouldStartOff = false
        } else if self.defaults.object(forKey: Keys.enableAIProcessing) != nil {
            shouldStartOff = !self.defaults.bool(forKey: Keys.enableAIProcessing)
        } else {
            shouldStartOff = true
        }

        self.defaults.set(shouldStartOff, forKey: Keys.dictationPromptOff)
    }

    func migrateSecondaryPromptShortcutIfNeeded() {
        guard self.defaults.bool(forKey: Keys.secondaryPromptShortcutRemoved) == false else { return }
        self.defaults.set(false, forKey: Keys.promptModeShortcutEnabled)
        self.defaults.set(true, forKey: Keys.secondaryDictationPromptOff)
        self.defaults.removeObject(forKey: Keys.promptModeSelectedPromptID)
        self.defaults.set(true, forKey: Keys.secondaryPromptShortcutRemoved)
    }

    func retireLegacySecondaryPromptShortcutIfNeeded() {
        guard self.defaults.bool(forKey: Keys.legacySecondaryPromptShortcutRetired) == false else { return }

        self.defaults.set(false, forKey: Keys.promptModeShortcutEnabled)
        self.defaults.set(true, forKey: Keys.secondaryDictationPromptOff)
        self.defaults.removeObject(forKey: Keys.promptModeHotkeyShortcut)
        self.defaults.removeObject(forKey: Keys.promptModeSelectedPromptID)
        self.defaults.set(true, forKey: Keys.legacySecondaryPromptShortcutRetired)
    }

    func normalizePromptSelectionsIfNeeded() {
        if self.defaults.object(forKey: Keys.secondaryDictationPromptOff) == nil {
            self.defaults.set(false, forKey: Keys.secondaryDictationPromptOff)
        }

        // One-time migration to unified edit keys.
        if self.defaults.object(forKey: Keys.selectedEditPromptID) == nil,
           let migratedSelectedEditID = self.selectedEditPromptID
        {
            self.defaults.set(migratedSelectedEditID, forKey: Keys.selectedEditPromptID)
            self.defaults.removeObject(forKey: Keys.selectedWritePromptID)
            self.defaults.removeObject(forKey: Keys.selectedRewritePromptID)
        }

        if self.defaults.object(forKey: Keys.defaultEditPromptOverride) == nil,
           let migratedEditOverride = self.defaultEditPromptOverride
        {
            self.defaults.set(migratedEditOverride, forKey: Keys.defaultEditPromptOverride)
            self.defaults.removeObject(forKey: Keys.defaultWritePromptOverride)
            self.defaults.removeObject(forKey: Keys.defaultRewritePromptOverride)
        }

        // Persist profile mode normalization to the new user-facing modes.
        var normalizedProfiles = self.dictationPromptProfiles
        var didChangeProfiles = false
        for idx in normalizedProfiles.indices {
            let normalizedMode = normalizedProfiles[idx].mode.normalized
            if normalizedProfiles[idx].mode != normalizedMode {
                normalizedProfiles[idx].mode = normalizedMode
                didChangeProfiles = true
            }
        }
        normalizedProfiles.removeAll { profile in
            let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let prompt = Self.stripBasePrompt(for: profile.mode, from: profile.prompt)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let isLegacyPlaceholder = profile.mode.normalized == .dictate &&
                name.caseInsensitiveCompare("Blocked") == .orderedSame &&
                prompt.caseInsensitiveCompare("Blocked prompt") == .orderedSame
            let isAccidentalPrivateAIProfile = profile.mode.normalized == .dictate &&
                name.caseInsensitiveCompare(PrivateAIProviderFeature.displayName) == .orderedSame &&
                prompt.isEmpty
            if isLegacyPlaceholder || isAccidentalPrivateAIProfile {
                didChangeProfiles = true
            }
            return isLegacyPlaceholder || isAccidentalPrivateAIProfile
        }
        if didChangeProfiles {
            self.dictationPromptProfiles = normalizedProfiles
        }

        let privateAIPromptID = PrivateAIProviderPromptFormat.promptSelectionID

        if let id = self.selectedDictationPromptID,
           !(PrivateFeatures.privateAIProvider && id == privateAIPromptID),
           self.dictationPromptProfiles.contains(where: { $0.id == id && $0.mode == .dictate }) == false
        {
            self.selectedDictationPromptID = nil
        }

        if let id = self.selectedEditPromptID,
           self.dictationPromptProfiles.contains(where: { $0.id == id && $0.mode.normalized == .edit }) == false
        {
            self.selectedEditPromptID = nil
        }

        if let id = self.promptModeSelectedPromptID,
           !(PrivateFeatures.privateAIProvider && id == privateAIPromptID),
           self.dictationPromptProfiles.contains(where: { $0.id == id && $0.mode.normalized == .dictate }) == false
        {
            self.promptModeSelectedPromptID = nil
        }

        let validPromptIDsByMode: [PromptMode: Set<String>] = [
            .dictate: Set(self.dictationPromptProfiles.filter { $0.mode.normalized == .dictate }.map(\.id)),
            .edit: Set(self.dictationPromptProfiles.filter { $0.mode.normalized == .edit }.map(\.id)),
        ]

        var normalizedBindings: [AppPromptBinding] = []
        var dedupe: [String: AppPromptBinding] = [:]
        var didMutateBindings = false

        for binding in self.appPromptBindings {
            let normalizedMode = binding.mode.normalized
            guard let normalizedBundleID = Self.normalizeAppBundleID(binding.appBundleID) else {
                didMutateBindings = true
                continue
            }

            var cleaned = binding
            if cleaned.mode != normalizedMode {
                cleaned.mode = normalizedMode
                didMutateBindings = true
            }
            if cleaned.appBundleID != normalizedBundleID {
                cleaned.appBundleID = normalizedBundleID
                didMutateBindings = true
            }

            let trimmedName = cleaned.appName.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedName = trimmedName.isEmpty ? normalizedBundleID : trimmedName
            if cleaned.appName != resolvedName {
                cleaned.appName = resolvedName
                didMutateBindings = true
            }

            if let promptID = cleaned.promptID,
               validPromptIDsByMode[normalizedMode]?.contains(promptID) != true
            {
                cleaned.promptID = nil
                didMutateBindings = true
            }

            let dedupeKey = "\(normalizedMode.rawValue)|\(normalizedBundleID)"
            if let existing = dedupe[dedupeKey] {
                // Keep the most recently updated binding when duplicates exist.
                if cleaned.updatedAt >= existing.updatedAt {
                    dedupe[dedupeKey] = cleaned
                }
                didMutateBindings = true
            } else {
                dedupe[dedupeKey] = cleaned
            }
        }

        normalizedBindings = Array(dedupe.values).sorted { lhs, rhs in
            if lhs.mode.normalized != rhs.mode.normalized {
                return lhs.mode.normalized.rawValue < rhs.mode.normalized.rawValue
            }
            if lhs.appName.localizedCaseInsensitiveCompare(rhs.appName) != .orderedSame {
                return lhs.appName.localizedCaseInsensitiveCompare(rhs.appName) == .orderedAscending
            }
            return lhs.appBundleID < rhs.appBundleID
        }

        if didMutateBindings || normalizedBindings.count != self.appPromptBindings.count {
            self.appPromptBindings = normalizedBindings
        }
    }

    func normalizeDictationPromptConfigurationsIfNeeded() {
        let validKeys = Set(
            ["__default__", "__privateAI__"] + self.dictationPromptProfiles
                .filter { $0.mode.normalized == .dictate }
                .map { "profile:\($0.id)" }
        )
        var configurations = self.dictationPromptConfigurations
        let originalCount = configurations.count
        configurations = configurations.filter { key, configuration in
            validKeys.contains(key) &&
                (
                    configuration.shortcut != nil ||
                        !configuration.providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        !configuration.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
        }
        if configurations.count != originalCount {
            self.dictationPromptConfigurations = configurations
        }
    }

    func migrateOverlayBottomOffsetTo50IfNeeded() {
        if self.defaults.bool(forKey: Keys.overlayBottomOffsetMigratedTo50) {
            return
        }

        self.defaults.set(50.0, forKey: Keys.overlayBottomOffset)
        self.defaults.set(true, forKey: Keys.overlayBottomOffsetMigratedTo50)
        NotificationCenter.default.post(name: NSNotification.Name("OverlayOffsetChanged"), object: nil)
    }

    func scrubSavedProviderAPIKeys() {
        guard let data = defaults.data(forKey: Keys.savedProviders),
              var decoded = try? JSONDecoder().decode([SavedProvider].self, from: data) else { return }

        var didModify = false
        for index in decoded.indices {
            let provider = decoded[index]
            let trimmed = provider.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { continue }

            let keyID = self.canonicalProviderKey(for: provider.id)
            do {
                try self.keychain.storeKey(trimmed, for: keyID)
                didModify = true
            } catch {
                DebugLogger.shared
                    .error(
                        "Failed to migrate API key for \(provider.name): \(error.localizedDescription)",
                        source: "SettingsStore"
                    )
            }

            decoded[index] = SavedProvider(
                id: provider.id,
                name: provider.name,
                baseURL: provider.baseURL,
                apiKey: "",
                models: provider.models
            )
        }

        if didModify,
           let encoded = try? JSONEncoder().encode(decoded)
        {
            self.defaults.set(encoded, forKey: Keys.savedProviders)
        }

        // No need to track migrated IDs; consolidated storage keeps them together.
    }

    func canonicalProviderKey(for providerID: String) -> String {
        let trimmed = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Built-in providers use their ID directly
        if ModelRepository.shared.isBuiltIn(trimmed) {
            return trimmed
        }
        if trimmed.hasPrefix("custom:") {
            return trimmed
        }
        return "custom:\(trimmed)"
    }

    func verifiedProviderIDsForCurrentConfiguration() -> [String] {
        var providerIDs = ModelRepository.builtInProviderIDs + self.savedProviders.map(\.id)
        if PrivateFeatures.privateAIProvider {
            providerIDs.append(PrivateAIProviderFeature.shared.providerID)
        }

        var seenProviderKeys = Set<String>()
        return providerIDs.filter { providerID in
            let key = self.canonicalProviderKey(for: providerID)
            guard !key.isEmpty, seenProviderKeys.insert(key).inserted else { return false }
            return self.isVerifiedProviderForCurrentConfiguration(providerID)
        }
    }

    func isVerifiedProviderForCurrentConfiguration(_ providerID: String) -> Bool {
        let trimmed = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if PrivateFeatures.privateAIProvider,
           trimmed == PrivateAIProviderFeature.shared.providerID
        {
            return PrivateAIProviderPromptFormat.verifiedModelID(settings: self) != nil
        }

        let key = self.canonicalProviderKey(for: trimmed)
        guard let stored = self.verifiedProviderFingerprints[key] else { return false }

        let baseURL = self.providerBaseURLForVerification(for: trimmed)
        let apiKey = (self.getAPIKey(for: trimmed) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard ModelRepository.shared.isLocalEndpoint(baseURL) || !apiKey.isEmpty else { return false }

        return self.providerFingerprint(baseURL: baseURL, apiKey: apiKey) == stored
    }

    func providerBaseURLForVerification(for providerID: String) -> String {
        let savedProviderID = providerID.hasPrefix("custom:") ?
            String(providerID.dropFirst("custom:".count)) : providerID
        if let saved = self.savedProviders.first(where: { $0.id == savedProviderID }) {
            return saved.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if ModelRepository.shared.isBuiltIn(providerID) {
            return ModelRepository.shared.defaultBaseURL(for: providerID).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    func providerFingerprint(baseURL: String, apiKey: String) -> String? {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBaseURL.isEmpty else { return nil }

        let input = "\(trimmedBaseURL)|\(trimmedAPIKey)"
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func syncLinkedProviderSelections(to _: String) {}

    func isPrivateAIProviderID(_ providerID: String) -> Bool {
        PrivateFeatures.privateAIProvider &&
            providerID.trimmingCharacters(in: .whitespacesAndNewlines) == PrivateAIProviderFeature.shared.providerID
    }

    func modelSelection(for providerID: String) -> String? {
        guard !providerID.isEmpty else { return nil }

        if PrivateFeatures.privateAIProvider,
           providerID == PrivateAIProviderFeature.shared.providerID,
           let modelID = PrivateAIProviderPromptFormat.verifiedModelID(settings: self)
        {
            return modelID
        }

        let key = self.canonicalProviderKey(for: providerID)
        if let selected = self.selectedModelByProvider[key],
           !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return selected
        }

        let savedProviderID = providerID.hasPrefix("custom:") ?
            String(providerID.dropFirst("custom:".count)) : providerID
        if let savedModel = self.savedProviders.first(where: { $0.id == savedProviderID })?.models.first,
           !savedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return savedModel
        }

        return ModelRepository.shared.defaultModels(for: providerID).first
    }

    func availableModels(for providerID: String, task: PrivateAIModelTask) -> [String] {
        if self.isPrivateAIProviderID(providerID) {
            return ModelRepository.shared.defaultModels(for: providerID, task: task)
        }

        if let configured = ModelRepository.shared.providerKeys(for: providerID).lazy
            .compactMap({ self.availableModelsByProvider[$0] })
            .first(where: { !$0.isEmpty })
        {
            return configured
        }

        let savedProviderID = providerID.hasPrefix("custom:") ?
            String(providerID.dropFirst("custom:".count)) : providerID
        if let configured = self.savedProviders.first(where: { $0.id == savedProviderID })?.models,
           !configured.isEmpty
        {
            return configured
        }

        return ModelRepository.shared.defaultModels(for: providerID)
    }

    func availableSelectedProviderID(for rawValue: String?) -> String {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "" }
        let providerID = trimmed
        if ModelRepository.shared.isBuiltIn(providerID) { return providerID }
        if PrivateFeatures.privateAIProvider,
           providerID == PrivateAIProviderFeature.shared.providerID
        {
            return providerID
        }

        let savedProviderID = providerID.hasPrefix("custom:") ?
            String(providerID.dropFirst("custom:".count)) : providerID
        if self.savedProviders.contains(where: { $0.id == savedProviderID }) {
            return savedProviderID
        }

        return ""
    }

    func sanitizeAPIKeys(_ values: [String: String]) -> [String: String] {
        values.reduce(into: [String: String]()) { partialResult, pair in
            let sanitizedValue = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard sanitizedValue.isEmpty == false else { return }
            partialResult[pair.key] = sanitizedValue
        }
    }

    func updateDockVisibility(_ visible: Bool) {
        #if os(macOS)
        // IMPORTANT: This is a simplified implementation for development
        // In production, consider these approaches:
        // 1. Use LSUIElement in Info.plist to control default dock visibility
        // 2. Implement a proper helper app or service for dock management
        // 3. Use NSApplication.shared.setActivationPolicy() for better control

        // For now, we'll try multiple approaches with fallbacks

        DebugLogger.shared.debug(
            "Attempting to update dock visibility to: \(visible ? "visible" : "hidden")",
            source: "SettingsStore"
        )

        // Method 1: Try the deprecated TransformProcessType (may not work on all systems)
        let transformState = visible ? ProcessApplicationTransformState(kProcessTransformToForegroundApplication)
            : ProcessApplicationTransformState(kProcessTransformToUIElementApplication)

        var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kCurrentProcess))
        let result = TransformProcessType(&psn, transformState)

        if result == 0 {
            DebugLogger.shared.info("✓ Dock visibility updated using TransformProcessType", source: "SettingsStore")
        } else {
            DebugLogger.shared
                .warning(
                    "⚠️ TransformProcessType failed (error: \(result)). This is expected on some macOS versions.",
                    source: "SettingsStore"
                )
            DebugLogger.shared.debug(
                "   The setting is saved and will be applied when possible.",
                source: "SettingsStore"
            )
        }

        // Method 2: Try to notify the system of the change
        // This may help with some system caches
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.setActivationPolicy(visible ? .regular : .accessory)
            DebugLogger.shared.info(
                "✓ Activation policy updated to: \(visible ? "regular" : "accessory")",
                source: "SettingsStore"
            )
        }

        // Store the intended state for reference
        UserDefaults.standard.set(visible, forKey: "IntendedDockVisibility")
        DebugLogger.shared.info("✓ Dock visibility preference saved: \(visible)", source: "SettingsStore")
        #endif
    }
}
