//
//  SettingsStore+PromptProfiles.swift
//  Fluid
//
//  Dictation prompt profiles and routing leftovers.
//

import Combine
import Foundation

extension SettingsStore {
    // MARK: - Prompt Profiles (Unified)

    enum PromptMode: String, Codable, CaseIterable, Identifiable {
        case dictate
        case edit
        case write
        case rewrite

        var id: String {
            self.rawValue
        }

        static var visiblePromptModes: [PromptMode] {
            [.dictate]
        }

        var normalized: PromptMode {
            switch self {
            case .dictate:
                return .dictate
            case .edit, .write, .rewrite:
                return .dictate
            }
        }

        var displayName: String {
            "Dictate"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let raw = (try? container.decode(String.self).lowercased()) ?? Self.dictate.rawValue
            switch raw {
            case "dictate", "edit", "write", "rewrite":
                self = .dictate
            default:
                self = .dictate
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(self.normalized.rawValue)
        }
    }

    enum DictationShortcutSlot: String, Codable, CaseIterable, Identifiable {
        case primary
        case secondary

        var id: String {
            self.rawValue
        }

        var displayName: String {
            switch self {
            case .primary:
                return "Primary Dictation Shortcut"
            case .secondary:
                return "Secondary Dictation Shortcut"
            }
        }
    }

    enum MicrophoneSelectionMode: String, Codable, CaseIterable, Identifiable {
        case system
        case manual

        var id: String {
            self.rawValue
        }

        var displayName: String {
            switch self {
            case .system:
                return "Use macOS Default"
            case .manual:
                return "Use Preferred Microphone"
            }
        }
    }

    struct MicrophonePriorityEntry: Codable, Hashable, Identifiable {
        let uid: String
        var name: String

        var id: String { self.uid }
    }

    enum DictationPromptSelection: Equatable {
        case off, `default`, privateAI
        case profile(String)
    }

    struct DictationPromptProfile: Codable, Identifiable, Hashable {
        let id: String
        var name: String
        var prompt: String
        var mode: PromptMode
        var includeContext: Bool
        var createdAt: Date
        var updatedAt: Date

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case prompt
            case mode
            case includeContext
            case createdAt
            case updatedAt
        }

        init(
            id: String = UUID().uuidString,
            name: String,
            prompt: String,
            mode: PromptMode = .dictate,
            includeContext: Bool = false,
            createdAt: Date = Date(),
            updatedAt: Date = Date()
        ) {
            self.id = id
            self.name = name
            self.prompt = prompt
            self.mode = mode
            self.includeContext = includeContext
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decode(String.self, forKey: .id)
            self.name = try container.decode(String.self, forKey: .name)
            self.prompt = try container.decode(String.self, forKey: .prompt)
            self.mode = try (container.decodeIfPresent(PromptMode.self, forKey: .mode) ?? .dictate).normalized
            self.includeContext = try container.decodeIfPresent(Bool.self, forKey: .includeContext) ?? false
            self.createdAt = try container.decode(Date.self, forKey: .createdAt)
            self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        }
    }

    struct AppPromptBinding: Codable, Identifiable, Hashable {
        let id: String
        var mode: PromptMode
        var appBundleID: String
        var appName: String
        var promptID: String?
        var createdAt: Date
        var updatedAt: Date

        enum CodingKeys: String, CodingKey {
            case id
            case mode
            case appBundleID
            case appName
            case promptID
            case createdAt
            case updatedAt
        }

        init(
            id: String = UUID().uuidString,
            mode: PromptMode,
            appBundleID: String,
            appName: String,
            promptID: String?,
            createdAt: Date = Date(),
            updatedAt: Date = Date()
        ) {
            self.id = id
            self.mode = mode.normalized
            self.appBundleID = Self.normalizeBundleID(appBundleID)
            let trimmedName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
            self.appName = trimmedName.isEmpty ? self.appBundleID : trimmedName
            let trimmedPromptID = promptID?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.promptID = (trimmedPromptID?.isEmpty == true) ? nil : trimmedPromptID
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decode(String.self, forKey: .id)
            self.mode = try (container.decodeIfPresent(PromptMode.self, forKey: .mode) ?? .dictate).normalized
            let rawBundleID = try container.decodeIfPresent(String.self, forKey: .appBundleID) ?? ""
            self.appBundleID = Self.normalizeBundleID(rawBundleID)
            let rawName = try container.decodeIfPresent(String.self, forKey: .appName) ?? ""
            let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            self.appName = trimmedName.isEmpty ? self.appBundleID : trimmedName
            let rawPromptID = try container.decodeIfPresent(String.self, forKey: .promptID)
            let trimmedPromptID = rawPromptID?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.promptID = (trimmedPromptID?.isEmpty == true) ? nil : trimmedPromptID
            self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
            self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        }

        static func normalizeBundleID(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    struct DictationPromptConfiguration: Codable, Equatable {
        var shortcut: HotkeyShortcut?
        var providerID: String
        var modelName: String

        init(shortcut: HotkeyShortcut? = nil, providerID: String = "", modelName: String = "") {
            self.shortcut = shortcut
            self.providerID = providerID
            self.modelName = modelName
        }
    }

    enum PromptResolutionSource: String {
        case appBindingProfile
        case appBindingDefault
        case selectedProfile
        case defaultOverride
        case builtInDefault
    }

    struct PromptResolution {
        let source: PromptResolutionSource
        let profile: DictationPromptProfile?
        let appBinding: AppPromptBinding?
        let promptBody: String
        let systemPrompt: String
    }

    /// User-defined dictation prompt profiles (named system prompts for dictation enhancement).
    /// The built-in default prompt is not stored here.
    var dictationPromptProfiles: [DictationPromptProfile] {
        get {
            guard let data = self.defaults.data(forKey: Keys.dictationPromptProfiles),
                  let decoded = try? JSONDecoder().decode([DictationPromptProfile].self, from: data)
            else {
                return []
            }
            return decoded
        }
        set {
            objectWillChange.send()
            if let encoded = try? JSONEncoder().encode(newValue) {
                self.defaults.set(encoded, forKey: Keys.dictationPromptProfiles)
            } else {
                // If encoding fails, avoid writing corrupt data.
                self.defaults.removeObject(forKey: Keys.dictationPromptProfiles)
            }
        }
    }

    /// Per-app prompt routing rules keyed by mode + app bundle identifier.
    /// `promptID == nil` means force Default prompt for that mode in the matched app.
    var appPromptBindings: [AppPromptBinding] {
        get {
            guard let data = self.defaults.data(forKey: Keys.appPromptBindings),
                  let decoded = try? JSONDecoder().decode([AppPromptBinding].self, from: data)
            else {
                return []
            }
            return decoded
        }
        set {
            objectWillChange.send()
            if let encoded = try? JSONEncoder().encode(newValue) {
                self.defaults.set(encoded, forKey: Keys.appPromptBindings)
            } else {
                self.defaults.removeObject(forKey: Keys.appPromptBindings)
            }
        }
    }

    var dictationPromptConfigurations: [String: DictationPromptConfiguration] {
        get {
            guard let data = self.defaults.data(forKey: Keys.dictationPromptConfigurations),
                  let decoded = try? JSONDecoder().decode([String: DictationPromptConfiguration].self, from: data)
            else {
                return [:]
            }
            return decoded
        }
        set {
            objectWillChange.send()
            if let encoded = try? JSONEncoder().encode(newValue) {
                self.defaults.set(encoded, forKey: Keys.dictationPromptConfigurations)
            } else {
                self.defaults.removeObject(forKey: Keys.dictationPromptConfigurations)
            }
        }
    }

    /// Selected dictation prompt profile ID. `nil` means "Default".
    var selectedDictationPromptID: String? {
        get {
            let value = self.defaults.string(forKey: Keys.selectedDictationPromptID)
            return value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true ? nil : value
        }
        set {
            objectWillChange.send()
            if let id = newValue?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
                self.defaults.set(id, forKey: Keys.selectedDictationPromptID)
            } else {
                self.defaults.removeObject(forKey: Keys.selectedDictationPromptID)
            }
        }
    }

    var isDictationPromptOff: Bool {
        get { self.defaults.bool(forKey: Keys.dictationPromptOff) }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.dictationPromptOff)
        }
    }

    var sendCustomPromptOnly: Bool {
        get { self.defaults.bool(forKey: Keys.sendCustomPromptOnly) }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.sendCustomPromptOnly)
        }
    }

    var isEditPromptOff: Bool {
        get { self.defaults.bool(forKey: Keys.editPromptOff) }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.editPromptOff)
        }
    }

    var dictationPromptSelection: DictationPromptSelection {
        self.dictationPromptSelection(for: .primary)
    }

    func setDictationPromptSelection(_ selection: DictationPromptSelection) {
        self.setDictationPromptSelection(selection, for: .primary)
    }

    func dictationPromptSelection(for slot: DictationShortcutSlot) -> DictationPromptSelection {
        if self.isDictationPromptOff(for: slot) { return .off }
        if let promptID = self.selectedDictationPromptID(for: slot) {
            if promptID == PrivateAIProviderPromptFormat.promptSelectionID {
                return PrivateAIProviderPromptFormat.isAvailable(settings: self) ? .privateAI : .default
            }
            return .profile(promptID)
        }
        return .default
    }

    func setDictationPromptSelection(_ selection: DictationPromptSelection, for slot: DictationShortcutSlot) {
        let selectedID: String?
        switch selection {
        case .off, .default:
            selectedID = nil
        case .privateAI:
            selectedID = PrivateAIProviderPromptFormat.promptSelectionID
        case let .profile(promptID):
            selectedID = promptID
        }
        self.setDictationPromptOff(selection == .off, for: slot)
        self.setSelectedDictationPromptID(selectedID, for: slot)
    }

    func dictationPromptConfigurationKey(for selection: DictationPromptSelection) -> String? {
        switch selection {
        case .off:
            return nil
        case .privateAI:
            return "__privateAI__"
        case .default:
            return "__default__"
        case let .profile(promptID):
            let trimmed = promptID.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : "profile:\(trimmed)"
        }
    }

    func dictationPromptSelection(forConfigurationKey key: String) -> DictationPromptSelection? {
        if key == "__privateAI__" {
            return .privateAI
        }
        if key == "__default__" {
            return .default
        }
        if key.hasPrefix("profile:") {
            let id = String(key.dropFirst("profile:".count))
            guard self.dictationPromptProfiles.contains(where: { $0.id == id && $0.mode.normalized == .dictate }) else { return nil }
            return .profile(id)
        }
        return nil
    }

    func dictationPromptConfiguration(for selection: DictationPromptSelection) -> DictationPromptConfiguration {
        guard let key = self.dictationPromptConfigurationKey(for: selection) else {
            return DictationPromptConfiguration()
        }
        return self.dictationPromptConfigurations[key] ?? DictationPromptConfiguration()
    }

    func setDictationPromptConfiguration(_ configuration: DictationPromptConfiguration, for selection: DictationPromptSelection) {
        guard let key = self.dictationPromptConfigurationKey(for: selection) else { return }
        let providerID = configuration.providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelName = configuration.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        var configurations = self.dictationPromptConfigurations
        if configuration.shortcut == nil, providerID.isEmpty, modelName.isEmpty {
            configurations.removeValue(forKey: key)
        } else {
            configurations[key] = DictationPromptConfiguration(
                shortcut: configuration.shortcut,
                providerID: providerID,
                modelName: modelName
            )
        }
        self.dictationPromptConfigurations = configurations
    }

    func removeDictationPromptConfiguration(for selection: DictationPromptSelection) {
        guard let key = self.dictationPromptConfigurationKey(for: selection) else { return }
        var configurations = self.dictationPromptConfigurations
        configurations.removeValue(forKey: key)
        self.dictationPromptConfigurations = configurations
    }

    func dictationPromptShortcutAssignments() -> [(selection: DictationPromptSelection, shortcut: HotkeyShortcut)] {
        self.dictationPromptConfigurations.compactMap { key, configuration in
            guard let shortcut = configuration.shortcut else { return nil }
            if key == "__default__" {
                return (.default, shortcut)
            }
            if key == "__privateAI__" {
                return (.privateAI, shortcut)
            }
            if key.hasPrefix("profile:") {
                let id = String(key.dropFirst("profile:".count))
                guard self.dictationPromptProfiles.contains(where: { $0.id == id && $0.mode.normalized == .dictate }) else { return nil }
                return (.profile(id), shortcut)
            }
            return nil
        }
    }

    /// Convenience: currently selected profile, or nil if Default/invalid selection.
    var selectedDictationPromptProfile: DictationPromptProfile? {
        self.selectedPromptProfile(for: .dictate)
    }

    /// Selected edit prompt profile ID. `nil` means "Default Edit".
    var selectedEditPromptID: String? {
        get {
            if let value = self.defaults.string(forKey: Keys.selectedEditPromptID),
               value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            {
                return value
            }
            if let legacyRewrite = self.defaults.string(forKey: Keys.selectedRewritePromptID),
               legacyRewrite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            {
                return legacyRewrite
            }
            if let legacyWrite = self.defaults.string(forKey: Keys.selectedWritePromptID),
               legacyWrite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            {
                return legacyWrite
            }
            return nil
        }
        set {
            objectWillChange.send()
            if let id = newValue?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
                self.defaults.set(id, forKey: Keys.selectedEditPromptID)
            } else {
                self.defaults.removeObject(forKey: Keys.selectedEditPromptID)
            }
            // Normalize to the new key only.
            self.defaults.removeObject(forKey: Keys.selectedWritePromptID)
            self.defaults.removeObject(forKey: Keys.selectedRewritePromptID)
        }
    }

    /// Legacy alias retained for compatibility.
    var selectedWritePromptID: String? {
        get { self.selectedEditPromptID }
        set { self.selectedEditPromptID = newValue }
    }

    /// Legacy alias retained for compatibility.
    var selectedRewritePromptID: String? {
        get { self.selectedEditPromptID }
        set { self.selectedEditPromptID = newValue }
    }

    func selectedPromptID(for mode: PromptMode) -> String? {
        switch mode.normalized {
        case .dictate:
            if self.selectedDictationPromptID == PrivateAIProviderPromptFormat.promptSelectionID,
               !PrivateAIProviderPromptFormat.isAvailable(settings: self) { return nil }
            return self.selectedDictationPromptID
        case .edit:
            return self.selectedEditPromptID
        case .write, .rewrite:
            return self.selectedEditPromptID
        }
    }

    func selectedDictationPromptID(for slot: DictationShortcutSlot) -> String? {
        switch slot {
        case .primary:
            return self.selectedDictationPromptID
        case .secondary:
            return self.promptModeSelectedPromptID
        }
    }

    func setSelectedDictationPromptID(_ id: String?, for slot: DictationShortcutSlot) {
        switch slot {
        case .primary:
            self.selectedDictationPromptID = id
        case .secondary:
            self.promptModeSelectedPromptID = id
        }
    }

    func isDictationPromptOff(for slot: DictationShortcutSlot) -> Bool {
        switch slot {
        case .primary:
            return self.isDictationPromptOff
        case .secondary:
            return self.isSecondaryDictationPromptOff
        }
    }

    func setDictationPromptOff(_ isOff: Bool, for slot: DictationShortcutSlot) {
        switch slot {
        case .primary:
            self.isDictationPromptOff = isOff
        case .secondary:
            self.isSecondaryDictationPromptOff = isOff
        }
    }

    func isPromptOff(for mode: PromptMode) -> Bool {
        switch mode.normalized {
        case .dictate:
            return self.isDictationPromptOff
        case .edit, .write, .rewrite:
            return self.isEditPromptOff
        }
    }

    func setPromptOff(_ isOff: Bool, for mode: PromptMode) {
        switch mode.normalized {
        case .dictate:
            self.setDictationPromptSelection(isOff ? .off : .default)
        case .edit, .write, .rewrite:
            self.isEditPromptOff = isOff
        }
    }

    func selectedDictationPromptProfile(for slot: DictationShortcutSlot) -> DictationPromptProfile? {
        guard let id = self.selectedDictationPromptID(for: slot) else { return nil }
        return self.dictationPromptProfiles.first(where: { $0.id == id && $0.mode.normalized == .dictate })
    }

    func resolvedDictationPromptProfile(for slot: DictationShortcutSlot, appBundleID: String?) -> DictationPromptProfile? {
        switch self.dictationPromptSelection(for: slot) {
        case .off:
            return nil
        case let .profile(promptID):
            return self.dictationPromptProfiles.first(where: { $0.id == promptID && $0.mode.normalized == .dictate })
        case .default, .privateAI:
            guard let binding = self.appPromptBinding(for: .dictate, appBundleID: appBundleID) else { return nil }
            let promptID = binding.promptID
            return self.dictationPromptProfiles.first {
                $0.id == promptID && $0.mode.normalized == .dictate
            }
        }
    }

    func isAppDictationPromptBindingActive(for slot: DictationShortcutSlot, appBundleID: String?) -> Bool {
        let selection = self.dictationPromptSelection(for: slot)
        guard Self.dictationSelectionSupportsAppOverride(selection) else { return false }
        return self.hasAppPromptBinding(for: .dictate, appBundleID: appBundleID)
    }

    static func dictationSelectionSupportsAppOverride(_ selection: DictationPromptSelection) -> Bool {
        selection == .default || selection == .privateAI
    }

    func dictationPromptDisplayName(for slot: DictationShortcutSlot, appBundleID: String?) -> String {
        switch self.dictationPromptSelection(for: slot) {
        case .off:
            return "Off"
        case .default:
            if let profile = self.resolvedDictationPromptProfile(for: slot, appBundleID: appBundleID) {
                let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? "Untitled" : name
            }
            return "Default"
        case .privateAI:
            if self.isAppDictationPromptBindingActive(for: slot, appBundleID: appBundleID) {
                if let profile = self.resolvedDictationPromptProfile(for: slot, appBundleID: appBundleID) {
                    let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    return name.isEmpty ? "Untitled" : name
                }
                return "Default"
            }
            return PrivateAIProviderFeature.displayName
        case let .profile(promptID):
            guard let profile = self.dictationPromptProfiles.first(where: { $0.id == promptID && $0.mode.normalized == .dictate }) else {
                return "Default"
            }
            let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "Untitled" : name
        }
    }

    func setSelectedPromptID(_ id: String?, for mode: PromptMode) {
        switch mode.normalized {
        case .dictate:
            if let id {
                self.setDictationPromptSelection(.profile(id))
            } else {
                self.setDictationPromptSelection(.default)
            }
        case .edit:
            self.isEditPromptOff = false
            self.selectedEditPromptID = id
        case .write, .rewrite:
            self.isEditPromptOff = false
            self.selectedEditPromptID = id
        }
    }

    func promptProfiles(for mode: PromptMode) -> [DictationPromptProfile] {
        let target = mode.normalized
        return self.dictationPromptProfiles.filter { $0.mode.normalized == target }
    }

    func selectedPromptProfile(for mode: PromptMode) -> DictationPromptProfile? {
        guard let id = self.selectedPromptID(for: mode) else { return nil }
        let target = mode.normalized
        return self.dictationPromptProfiles.first(where: { $0.id == id && $0.mode.normalized == target })
    }

    func appPromptBindings(for mode: PromptMode) -> [AppPromptBinding] {
        let target = mode.normalized
        return self.appPromptBindings.filter { $0.mode.normalized == target }
    }

    func appPromptBinding(for mode: PromptMode, appBundleID: String?) -> AppPromptBinding? {
        guard let normalizedBundleID = Self.normalizeAppBundleID(appBundleID) else { return nil }
        let target = mode.normalized
        return self.appPromptBindings.first {
            $0.mode.normalized == target &&
                $0.appBundleID == normalizedBundleID
        }
    }

    func hasAppPromptBinding(for mode: PromptMode, appBundleID: String?) -> Bool {
        self.appPromptBinding(for: mode, appBundleID: appBundleID) != nil
    }

    func upsertAppPromptBinding(
        for mode: PromptMode,
        appBundleID: String,
        appName: String,
        promptID: String?
    ) {
        guard let normalizedBundleID = Self.normalizeAppBundleID(appBundleID) else { return }

        let normalizedMode = mode.normalized
        let trimmedName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty ? normalizedBundleID : trimmedName
        let cleanedPromptID = promptID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPromptID = (cleanedPromptID?.isEmpty == true) ? nil : cleanedPromptID
        let now = Date()

        var bindings = self.appPromptBindings
        if let idx = bindings.firstIndex(where: {
            $0.mode.normalized == normalizedMode &&
                $0.appBundleID == normalizedBundleID
        }) {
            bindings[idx].mode = normalizedMode
            bindings[idx].appName = resolvedName
            bindings[idx].promptID = resolvedPromptID
            bindings[idx].updatedAt = now
        } else {
            bindings.append(
                AppPromptBinding(
                    mode: normalizedMode,
                    appBundleID: normalizedBundleID,
                    appName: resolvedName,
                    promptID: resolvedPromptID,
                    createdAt: now,
                    updatedAt: now
                )
            )
        }

        self.appPromptBindings = bindings
    }

    func removeAppPromptBinding(id: String) {
        var bindings = self.appPromptBindings
        bindings.removeAll { $0.id == id }
        self.appPromptBindings = bindings
    }

    func removeAppPromptBinding(for mode: PromptMode, appBundleID: String?) {
        guard let normalizedBundleID = Self.normalizeAppBundleID(appBundleID) else { return }
        let normalizedMode = mode.normalized
        var bindings = self.appPromptBindings
        bindings.removeAll {
            $0.mode.normalized == normalizedMode &&
                $0.appBundleID == normalizedBundleID
        }
        self.appPromptBindings = bindings
    }

    /// Re-run prompt/profile normalization after profile mutations.
    func reconcilePromptStateAfterProfileChanges() {
        self.normalizePromptSelectionsIfNeeded()
        self.normalizeDictationPromptConfigurationsIfNeeded()
    }

    static func normalizeAppBundleID(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    /// Optional override for the built-in default dictation system prompt.
    /// - nil: use the built-in default prompt
    /// - empty string: use an empty system prompt
    /// - otherwise: use the provided text as the default prompt
    var defaultDictationPromptOverride: String? {
        get {
            // Distinguish "not set" from "set to empty string"
            guard self.defaults.object(forKey: Keys.defaultDictationPromptOverride) != nil else {
                return nil
            }
            return self.defaults.string(forKey: Keys.defaultDictationPromptOverride) ?? ""
        }
        set {
            objectWillChange.send()
            if let value = newValue {
                self.defaults.set(value, forKey: Keys.defaultDictationPromptOverride) // allow empty
            } else {
                self.defaults.removeObject(forKey: Keys.defaultDictationPromptOverride)
            }
        }
    }

    /// Optional override for the built-in default edit system prompt.
    var defaultEditPromptOverride: String? {
        get {
            if self.defaults.object(forKey: Keys.defaultEditPromptOverride) != nil {
                return self.defaults.string(forKey: Keys.defaultEditPromptOverride) ?? ""
            }
            if self.defaults.object(forKey: Keys.defaultRewritePromptOverride) != nil {
                return self.defaults.string(forKey: Keys.defaultRewritePromptOverride) ?? ""
            }
            if self.defaults.object(forKey: Keys.defaultWritePromptOverride) != nil {
                return self.defaults.string(forKey: Keys.defaultWritePromptOverride) ?? ""
            }
            return nil
        }
        set {
            objectWillChange.send()
            if let value = newValue {
                self.defaults.set(value, forKey: Keys.defaultEditPromptOverride)
            } else {
                self.defaults.removeObject(forKey: Keys.defaultEditPromptOverride)
            }
            // Normalize to the new key only.
            self.defaults.removeObject(forKey: Keys.defaultWritePromptOverride)
            self.defaults.removeObject(forKey: Keys.defaultRewritePromptOverride)
        }
    }

    /// Legacy alias retained for compatibility.
    var defaultWritePromptOverride: String? {
        get { self.defaultEditPromptOverride }
        set { self.defaultEditPromptOverride = newValue }
    }

    /// Legacy alias retained for compatibility.
    var defaultRewritePromptOverride: String? {
        get { self.defaultEditPromptOverride }
        set { self.defaultEditPromptOverride = newValue }
    }

    func defaultPromptOverride(for mode: PromptMode) -> String? {
        switch mode.normalized {
        case .dictate:
            return self.defaultDictationPromptOverride
        case .edit:
            return self.defaultEditPromptOverride
        case .write, .rewrite:
            return self.defaultEditPromptOverride
        }
    }

    func setDefaultPromptOverride(_ value: String?, for mode: PromptMode) {
        switch mode.normalized {
        case .dictate:
            self.defaultDictationPromptOverride = value
        case .edit:
            self.defaultEditPromptOverride = value
        case .write, .rewrite:
            self.defaultEditPromptOverride = value
        }
    }

    /// Hidden base prompt: role/intent only (not exposed in UI).
    static func baseDictationPromptText() -> String {
        """
        You are a voice-to-text dictation cleaner. Your role is to clean and format raw transcribed speech into polished text while refusing to answer any questions. Never answer questions about yourself or anything else.

        ## Core Rules:
        1. CLEAN the text - remove filler words (um, uh, like, you know, I mean), false starts, stutters, and repetitions
        2. FORMAT properly - add correct punctuation, capitalization, and structure
        3. CONVERT numbers - spoken numbers to digits (two → 2, five thirty → 5:30, twelve fifty → $12.50)
        4. EXECUTE commands - handle "new line", "period", "comma", "bold X", "header X", "bullet point", etc.
        5. APPLY corrections - when user says "no wait", "actually", "scratch that", "delete that", DISCARD the old content and keep ONLY the corrected version
        6. PRESERVE intent - keep the user's meaning, just clean the delivery
        7. EXPAND abbreviations - thx → thanks, pls → please, u → you, ur → your/you're, gonna → going to

        ## Critical:
        - Output ONLY the cleaned text
        - Do NOT answer questions - just clean them
        - DO NOT EVER ANSWER TO QUESTIONS
        - Do NOT add explanations or commentary
        - Do NOT wrap in quotes unless the input had quotes
        - Do NOT add filler words (um, uh) to the output
        - PRESERVE ordinals in lists: "first call client, second review contract" → keep "First" and "Second"
        - PRESERVE politeness words: "please", "thank you" at end of sentences
        """
    }

    /// Hidden base prompt for edit mode (role/intent only).
    static func baseEditPromptText() -> String {
        """
        You are a helpful writing assistant. The user may ask you to write new text or edit selected text.

        Output ONLY what the user requested. Do not add explanations or preamble.
        """
    }

    /// Legacy wrappers retained for compatibility.
    static func baseWritePromptText() -> String {
        self.baseEditPromptText()
    }

    /// Legacy wrappers retained for compatibility.
    static func baseRewritePromptText() -> String {
        self.baseEditPromptText()
    }

    static func basePromptText(for mode: PromptMode) -> String {
        switch mode.normalized {
        case .dictate:
            return self.baseDictationPromptText()
        case .edit:
            return self.baseEditPromptText()
        case .write, .rewrite:
            return self.baseEditPromptText()
        }
    }

    /// Built-in default dictation prompt body that users may view/edit.
    static func defaultDictationPromptBodyText() -> String {
        """
        ## Self-Corrections:
        When user corrects themselves, DISCARD everything before the correction trigger:
        - Triggers: "no", "wait", "actually", "scratch that", "delete that", "no no", "cancel", "never mind", "sorry", "oops"
        - Example: "buy milk no wait buy water" → "Buy water." (NOT "Buy milk. Buy water.")
        - Example: "tell John no actually tell Sarah" → "Tell Sarah."
        - If correction cancels entirely: "send email no wait cancel that" → "" (empty)

        ## Multi-Command Chains:
        When multiple commands are chained, execute ALL of them in sequence:
        - "make X bold no wait make Y bold" → **Y** (correction + formatting)
        - "header shopping bullet milk no eggs" → # Shopping\n- Eggs (header + correction + bullet)
        - "the price is fifty no sixty dollars" → The price is $60. (correction + number)

        ## Emojis:
        - Convert spoken emoji names: "smiley face" → 😊 (NOT 😀), "thumbs up" → 👍, "heart emoji" → ❤️, "fire emoji" → 🔥
        - Keep emojis if user includes them
        - Do NOT add emojis unless user explicitly asks for them (e.g., "joke about cats" → NO 😺)
        """
    }

    /// Built-in default edit prompt body.
    static func defaultEditPromptBodyText() -> String {
        """
        Your job:
        - If the user asks for new content, write it directly.
        - If selected context is provided, apply the instruction to that context.
        - Preserve intent and requested tone/style/format.
        - Output only the final text, without explanations.

        Example requests:
        - "Write an email to my boss asking for time off"
        - "Draft a reply saying I'll be there at 5"
        - "Rewrite this to sound more professional"
        - "Make this shorter and clearer"
        """
    }

    /// Legacy wrappers retained for compatibility.
    static func defaultWritePromptBodyText() -> String {
        self.defaultEditPromptBodyText()
    }

    /// Legacy wrappers retained for compatibility.
    static func defaultRewritePromptBodyText() -> String {
        self.defaultEditPromptBodyText()
    }

    static func defaultPromptBodyText(for mode: PromptMode) -> String {
        switch mode.normalized {
        case .dictate:
            return self.defaultDictationPromptBodyText()
        case .edit:
            return self.defaultEditPromptBodyText()
        case .write, .rewrite:
            return self.defaultEditPromptBodyText()
        }
    }

    /// Join hidden base with a body, avoiding duplicate base text.
    static func combineBasePrompt(with body: String) -> String {
        self.combineBasePrompt(for: .dictate, with: body)
    }

    /// Join hidden base with a body for a given mode, avoiding duplicate base text.
    static func combineBasePrompt(for mode: PromptMode, with body: String) -> String {
        let base = self.basePromptText(for: mode).trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)

        // If body already starts with base, return as-is to avoid double-prepending.
        if trimmedBody.lowercased().hasPrefix(base.lowercased()) {
            return trimmedBody
        }

        // If body is empty, return just the base.
        guard !trimmedBody.isEmpty else { return base }

        return "\(base)\n\n\(trimmedBody)"
    }

    /// Remove the hidden base prompt prefix if it was persisted previously.
    static func stripBaseDictationPrompt(from text: String) -> String {
        self.stripBasePrompt(for: .dictate, from: text)
    }

    /// Remove a hidden base prompt prefix for a given mode if it was persisted previously.
    static func stripBasePrompt(for mode: PromptMode, from text: String) -> String {
        let base = self.basePromptText(for: mode).trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try exact and case-insensitive prefix removal
        if trimmed.hasPrefix(base) {
            let bodyStart = trimmed.index(trimmed.startIndex, offsetBy: base.count)
            return trimmed[bodyStart...].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let range = trimmed.lowercased().range(of: base.lowercased()), range.lowerBound == trimmed.lowercased().startIndex {
            let idx = trimmed.index(trimmed.startIndex, offsetBy: base.count)
            return trimmed[idx...].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return trimmed
    }

    /// Built-in default dictation system prompt shared across the app.
    static func defaultDictationPromptText() -> String {
        self.defaultSystemPromptText(for: .dictate)
    }

    static func defaultSystemPromptText(for mode: PromptMode) -> String {
        self.combineBasePrompt(for: mode, with: self.defaultPromptBodyText(for: mode))
    }

    static func contextTemplateText() -> String {
        """
        Use the following selected context to improve your response:
        {context}
        """
    }

    static func runtimeContextBlock(context: String, template: String) -> String {
        let trimmedContext = context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContext.isEmpty else { return "" }
        if template.contains("{context}") {
            return template.replacingOccurrences(of: "{context}", with: trimmedContext)
        }
        return "\(template)\n\(trimmedContext)"
    }

    func promptResolution(for mode: PromptMode, appBundleID: String? = nil) -> PromptResolution {
        let normalizedMode = mode.normalized

        if let binding = self.appPromptBinding(for: normalizedMode, appBundleID: appBundleID) {
            if let promptID = binding.promptID,
               let profile = self.dictationPromptProfiles.first(where: {
                   $0.id == promptID &&
                       $0.mode.normalized == normalizedMode
               })
            {
                let body = Self.stripBasePrompt(for: normalizedMode, from: profile.prompt)
                if !body.isEmpty {
                    return PromptResolution(
                        source: .appBindingProfile,
                        profile: profile,
                        appBinding: binding,
                        promptBody: body,
                        systemPrompt: self.systemPrompt(forCustomProfileBody: body, mode: normalizedMode)
                    )
                }
            }

            return self.defaultPromptResolution(
                for: normalizedMode,
                source: .appBindingDefault,
                appBinding: binding
            )
        }

        if self.promptRoutingScope(for: normalizedMode) == .selectedAppsOnly {
            return self.defaultPromptResolution(
                for: normalizedMode,
                source: .builtInDefault,
                appBinding: nil,
                allowDefaultOverride: false
            )
        }

        if let profile = self.selectedPromptProfile(for: normalizedMode) {
            let body = Self.stripBasePrompt(for: normalizedMode, from: profile.prompt)
            if !body.isEmpty {
                return PromptResolution(
                    source: .selectedProfile,
                    profile: profile,
                    appBinding: nil,
                    promptBody: body,
                    systemPrompt: self.systemPrompt(forCustomProfileBody: body, mode: normalizedMode)
                )
            }
        }

        return self.defaultPromptResolution(for: normalizedMode, source: .defaultOverride, appBinding: nil)
    }

    func resolvedPromptProfile(for mode: PromptMode, appBundleID: String? = nil) -> DictationPromptProfile? {
        self.promptResolution(for: mode, appBundleID: appBundleID).profile
    }

    func effectiveDictationPromptBody(for slot: DictationShortcutSlot, appBundleID: String? = nil) -> String {
        if self.promptRoutingScope(for: .dictate) == .selectedAppsOnly {
            guard self.dictationPromptSelection(for: slot) != .off else { return "" }
            return self.effectivePromptBody(for: .dictate, appBundleID: appBundleID)
        }

        switch self.dictationPromptSelection(for: slot) {
        case .off:
            return ""
        case .default, .privateAI:
            return self.effectivePromptBody(for: .dictate, appBundleID: appBundleID)
        case let .profile(promptID):
            guard let profile = self.dictationPromptProfiles.first(where: { $0.id == promptID && $0.mode.normalized == .dictate }) else {
                return self.effectivePromptBody(for: .dictate, appBundleID: appBundleID)
            }
            let body = Self.stripBasePrompt(for: .dictate, from: profile.prompt)
            if !body.isEmpty {
                return body
            }
            return self.effectivePromptBody(for: .dictate, appBundleID: appBundleID)
        }
    }

    func effectiveDictationSystemPrompt(for slot: DictationShortcutSlot, appBundleID: String? = nil) -> String {
        if self.promptRoutingScope(for: .dictate) == .selectedAppsOnly {
            guard self.dictationPromptSelection(for: slot) != .off else { return "" }
            return self.effectiveSystemPrompt(for: .dictate, appBundleID: appBundleID)
        }

        switch self.dictationPromptSelection(for: slot) {
        case .off, .default, .privateAI:
            return self.effectiveSystemPrompt(for: .dictate, appBundleID: appBundleID)
        case let .profile(promptID):
            guard let profile = self.dictationPromptProfiles.first(where: { $0.id == promptID && $0.mode.normalized == .dictate }) else {
                return self.effectiveSystemPrompt(for: .dictate, appBundleID: appBundleID)
            }
            let body = Self.stripBasePrompt(for: .dictate, from: profile.prompt)
            if !body.isEmpty {
                return self.systemPrompt(forCustomProfileBody: body, mode: .dictate)
            }
            return self.effectiveSystemPrompt(for: .dictate, appBundleID: appBundleID)
        }
    }

    func effectivePromptBody(for mode: PromptMode, appBundleID: String? = nil) -> String {
        self.promptResolution(for: mode, appBundleID: appBundleID).promptBody
    }

    func effectiveSystemPrompt(for mode: PromptMode, appBundleID: String? = nil) -> String {
        self.promptResolution(for: mode, appBundleID: appBundleID).systemPrompt
    }

    func effectivePromptSource(for mode: PromptMode, appBundleID: String? = nil) -> PromptResolutionSource {
        self.promptResolution(for: mode, appBundleID: appBundleID).source
    }

    /// Literal placeholder that gets substituted with the raw transcription
    /// when composing the user message for a dictation enhancement call.
    static let transcriptPlaceholder = "${transcript}"

    /// Compose the user-turn string for a dictation enhancement call by folding
    /// the transcript into the prompt template. If the template contains the
    /// `${transcript}` placeholder, the placeholder is replaced; otherwise
    /// the transcript is appended after a blank line, matching the pre-PR
    /// behaviour of sending the transcript as a separate user message.
    static func renderDictationUserMessage(promptText: String, transcript: String) -> String {
        if promptText.contains(self.transcriptPlaceholder) {
            return promptText.replacingOccurrences(of: self.transcriptPlaceholder, with: transcript)
        }
        let trimmedPrompt = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPrompt.isEmpty { return transcript }
        return promptText + "\n\n" + transcript
    }

    func defaultPromptResolution(
        for mode: PromptMode,
        source: PromptResolutionSource,
        appBinding: AppPromptBinding?,
        allowDefaultOverride: Bool = true
    ) -> PromptResolution {
        if allowDefaultOverride, let override = self.defaultPromptOverride(for: mode) {
            let trimmedOverride = override.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedOverride.isEmpty {
                return PromptResolution(
                    source: source,
                    profile: nil,
                    appBinding: appBinding,
                    promptBody: "",
                    systemPrompt: override
                )
            }

            let body = Self.stripBasePrompt(for: mode, from: trimmedOverride)
            return PromptResolution(
                source: source,
                profile: nil,
                appBinding: appBinding,
                promptBody: body,
                systemPrompt: Self.combineBasePrompt(for: mode, with: body)
            )
        }

        let defaultBody = Self.defaultPromptBodyText(for: mode)
        let fallbackSource: PromptResolutionSource = source == .defaultOverride ? .builtInDefault : source
        return PromptResolution(
            source: fallbackSource,
            profile: nil,
            appBinding: appBinding,
            promptBody: defaultBody,
            systemPrompt: Self.combineBasePrompt(for: mode, with: defaultBody)
        )
    }

    func systemPrompt(forCustomProfileBody body: String, mode: PromptMode) -> String {
        let normalizedMode = mode.normalized
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedMode == .dictate, self.sendCustomPromptOnly {
            return trimmedBody
        }
        return Self.combineBasePrompt(for: normalizedMode, with: trimmedBody)
    }

    /// System prompt for a dictation-shortcut prompt override, honoring
    /// "Send Custom Prompt Only" the same way the effective-prompt paths do.
    func shortcutOverrideSystemPrompt(for profile: DictationPromptProfile, mode: PromptMode = .dictate) -> String {
        self.systemPrompt(
            forCustomProfileBody: Self.stripBasePrompt(for: mode, from: profile.prompt),
            mode: mode
        )
    }

}
