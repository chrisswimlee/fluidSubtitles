import AppKit
import ApplicationServices
import Combine
import CryptoKit
import Foundation
import ServiceManagement
import SwiftUI
#if canImport(FluidAudio)
import FluidAudio
#endif

// swiftlint:disable type_body_length function_body_length cyclomatic_complexity
// Tracked grandfather: settings core. New keys belong in SettingsStore+*.swift.
final class SettingsStore: ObservableObject {
    static let microphonePriorityMigrationVersion = 4

    static let shared = SettingsStore()
    static let automaticWhisperLanguageCode = "auto"
    static let transcriptionPreviewCharLimitRange: ClosedRange<Int> = 50...800
    static let transcriptionPreviewCharLimitStep = 50
    static let defaultTranscriptionPreviewCharLimit = 150
    static let privateAIContextTokenLimitRange: ClosedRange<Int> = 2048...8192
    static let privateAIContextTokenLimitStep = 512
    static let defaultPrivateAIContextTokenLimit = 4096
    static let privateAIDictationSystemOverheadTokens = 1280
    static let privateAIDictationMinimumOutputTokens = 256
    static let privateAIDictationRoundTripTokenCost = 2.75
    private static let privateAIDenseSegmentByteThreshold = 12
    private static let privateAIDenseBytesPerToken = 2
    static let privateAIBackendPreferenceDefaultsKey = "FluidIntelligenceBackendPreference"
    private static let forcedOnboardingResetIntroducedAt = Date(timeIntervalSince1970: 1_782_091_732)
    let defaults = UserDefaults.standard
    let keychain = KeychainService.shared
    var launchAtStartupEnabled = false
    var launchAtStartupErrorMessage: String?
    var launchAtStartupStatusMessage =
        "\(FluidProduct.displayName) reflects the actual macOS login item state. Unsigned or development builds may fail to enable this."

    private init() {
        self.migrateTranscriptionStartSoundIfNeeded()
        self.ensureDebugLoggingDefaults()
        self.migrateProviderAPIKeysIfNeeded()
        self.scrubSavedProviderAPIKeys()
        self.migrateDictationPromptProfilesIfNeeded()
        self.migrateLegacyDictationAIPreferenceIfNeeded()
        self.migrateSecondaryPromptShortcutIfNeeded()
        self.retireLegacySecondaryPromptShortcutIfNeeded()
        self.normalizePromptSelectionsIfNeeded()
        self.purgeRetiredAppleIntelligenceState()
        self.repairForcedOnboardingResetIfNeeded()
        self.migrateOverlayBottomOffsetTo50IfNeeded()
        self.migratePrivateAIContextDefaultTo4KIfNeeded()
        self.refreshLaunchAtStartupStatus(clearError: true, logMismatch: false)
    }

    static func clampPrivateAIContextTokenLimit(_ value: Int) -> Int {
        min(max(value, self.privateAIContextTokenLimitRange.lowerBound), self.privateAIContextTokenLimitRange.upperBound)
    }

    static func estimatedPrivateAIDictationWords(for contextTokenLimit: Int) -> Int {
        let availableTokens = max(0, Self.clampPrivateAIContextTokenLimit(contextTokenLimit) - Self.privateAIDictationSystemOverheadTokens)
        let inputTokens = Double(availableTokens) / Self.privateAIDictationRoundTripTokenCost
        return max(100, Int((inputTokens * 0.75 / 50).rounded(.up)) * 50)
    }

    struct PrivateAIDictationTokenBudget: Equatable {
        let maxOutputTokens: Int
        let hasSufficientHeadroom: Bool
    }

    static func privateAIDictationTokenBudget(forInputText inputText: String, contextTokenLimit: Int) -> PrivateAIDictationTokenBudget {
        let estimatedInputTokens = self.estimatedPrivateAIInputTokens(for: inputText)
        let requestedOutputTokens = max(
            Self.privateAIDictationMinimumOutputTokens,
            Int((Double(estimatedInputTokens) * 1.15).rounded(.up)) + 64
        )
        let availableOutputTokens = Self.clampPrivateAIContextTokenLimit(contextTokenLimit)
            - Self.privateAIDictationSystemOverheadTokens
            - estimatedInputTokens
        return PrivateAIDictationTokenBudget(
            maxOutputTokens: min(requestedOutputTokens, max(Self.privateAIDictationMinimumOutputTokens, availableOutputTokens)),
            hasSufficientHeadroom: availableOutputTokens >= requestedOutputTokens
        )
    }

    private static func estimatedPrivateAIInputTokens(for inputText: String) -> Int {
        let segments = inputText.split { $0.isWhitespace || $0.isNewline }
        let wordBasedEstimate = Int((Double(segments.count) / 0.75).rounded(.up))
        // Keep the existing prose estimate, but charge long unbroken input by UTF-8 size so
        // URLs, identifiers, and languages without whitespace cannot look like a single token.
        let denseSegmentEstimate = segments.reduce(into: 0) { estimate, segment in
            let byteCount = segment.utf8.count
            if byteCount > Self.privateAIDenseSegmentByteThreshold {
                estimate += (byteCount + Self.privateAIDenseBytesPerToken - 1)
                    / Self.privateAIDenseBytesPerToken
            } else {
                estimate += 1
            }
        }
        return max(1, max(wordBasedEstimate, denseSegmentEstimate))
    }

    static func privateAIMaxOutputTokens(forInputText inputText: String, contextTokenLimit: Int) -> Int {
        self.privateAIDictationTokenBudget(
            forInputText: inputText,
            contextTokenLimit: contextTokenLimit
        ).maxOutputTokens
    }

    enum PrivateAIBackendPreference: String, Codable, CaseIterable, Identifiable {
        case auto
        case llama
        case mlx

        var id: String { self.rawValue }

        /// Default backend when no preference is stored.
        /// Apple Silicon → MLX (fastest Fluid-1 path). Intel → llama.cpp.
        static var systemDefault: PrivateAIBackendPreference {
            CPUArchitecture.isAppleSilicon ? .mlx : .llama
        }

        var displayName: String {
            switch self {
            case .auto: return Self.systemDefault.displayName
            case .llama: return "llama.cpp (Compatibility)"
            case .mlx: return "MLX (Recommended)"
            }
        }

        var detail: String {
            switch self {
            case .auto:
                return Self.systemDefault.detail
            case .llama:
                return CPUArchitecture.isAppleSilicon
                    ? "Optional and slower than MLX. Replaces MLX after verification."
                    : "Recommended compatibility backend for Intel Macs."
            case .mlx:
                return "Recommended and faster than llama.cpp. Replaces it after verification."
            }
        }
    }

    // MARK: - Model Reasoning Configuration

    /// Configuration for model-specific reasoning/thinking parameters
    struct ModelReasoningConfig: Codable, Equatable {
        /// The parameter name to use (e.g., "reasoning_effort", "enable_thinking", "thinking")
        var parameterName: String

        /// The value to use for the parameter (e.g., "low", "medium", "high", "none", "true")
        var parameterValue: String

        /// Whether this config is enabled (allows disabling without deleting)
        var isEnabled: Bool

        init(parameterName: String = "reasoning_effort", parameterValue: String = "low", isEnabled: Bool = true) {
            self.parameterName = parameterName
            self.parameterValue = parameterValue
            self.isEnabled = isEnabled
        }

        /// Common presets for different model types
        static let openAIGPT5 = ModelReasoningConfig(
            parameterName: "reasoning_effort",
            parameterValue: "low",
            isEnabled: true
        )
        static let openAIO1 = ModelReasoningConfig(
            parameterName: "reasoning_effort",
            parameterValue: "medium",
            isEnabled: true
        )
        static let groqGPTOSS = ModelReasoningConfig(
            parameterName: "reasoning_effort",
            parameterValue: "low",
            isEnabled: true
        )
        static let deepSeekReasoner = ModelReasoningConfig(
            parameterName: "enable_thinking",
            parameterValue: "true",
            isEnabled: true
        )
        static let disabled = ModelReasoningConfig(parameterName: "", parameterValue: "", isEnabled: false)
    }

    struct SavedProvider: Codable, Identifiable, Hashable {
        let id: String
        let name: String
        let baseURL: String
        let apiKey: String
        let models: [String]

        init(id: String = UUID().uuidString, name: String, baseURL: String, apiKey: String = "", models: [String] = []) {
            self.id = id
            self.name = name
            self.baseURL = baseURL
            self.apiKey = apiKey
            self.models = models
        }
    }

    var enableAIProcessing: Bool {
        get { self.defaults.bool(forKey: Keys.enableAIProcessing) }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.enableAIProcessing)
        }
    }

    /// Show the main window when macOS launches the app at login (default: ON, matching
    /// current behavior). When off, login launches boot silently in the menu bar. Manual
    /// launches always show the window. Default-true semantics so existing installs keep
    /// their current behavior.
    var showMainWindowAtLoginLaunch: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.showMainWindowAtLoginLaunch)
            if value == nil { return true }
            return self.defaults.bool(forKey: Keys.showMainWindowAtLoginLaunch)
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.showMainWindowAtLoginLaunch)
        }
    }

    var privateAIInterestCaptured: Bool {
        get { self.defaults.bool(forKey: Keys.privateAIInterestCaptured) }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.privateAIInterestCaptured)
        }
    }

    var availableModels: [String] {
        get { (self.defaults.array(forKey: Keys.availableAIModels) as? [String]) ?? [] }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.availableAIModels)
        }
    }

    var availableModelsByProvider: [String: [String]] {
        get { (self.defaults.dictionary(forKey: Keys.availableModelsByProvider) as? [String: [String]]) ?? [:] }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.availableModelsByProvider)
        }
    }

    var enableDebugLogs: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.enableDebugLogs)
            if value == nil { return true }
            return self.defaults.bool(forKey: Keys.enableDebugLogs)
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.enableDebugLogs)
        }
    }

    private func ensureDebugLoggingDefaults() {
        if self.defaults.object(forKey: Keys.enableDebugLogs) == nil {
            self.defaults.set(true, forKey: Keys.enableDebugLogs)
        }
    }

    var selectedModel: String? {
        get { self.defaults.string(forKey: Keys.selectedAIModel) }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.selectedAIModel)
        }
    }

    var selectedModelByProvider: [String: String] {
        get { (self.defaults.dictionary(forKey: Keys.selectedModelByProvider) as? [String: String]) ?? [:] }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.selectedModelByProvider)
        }
    }

    var providerAPIKeys: [String: String] {
        get { (try? self.keychain.fetchAllKeys()) ?? [:] }
        set {
            objectWillChange.send()
            do {
                _ = try self.saveProviderAPIKeys(newValue)
            } catch {
                self.logProviderAPIKeyPersistenceFailure(error)
            }
        }
    }

    @discardableResult
    func saveProviderAPIKeys(_ values: [String: String]) throws -> [String: String] {
        let trimmed = self.sanitizeAPIKeys(values)
        try self.keychain.storeAllKeys(trimmed)
        return try self.keychain.fetchAllKeys()
    }

    /// Securely retrieve API key for a provider, handling custom prefix logic
    func getAPIKey(for providerID: String) -> String? {
        let keys = self.providerAPIKeys
        // Try exact match first
        if let key = keys[providerID] { return key }

        // Try canonical key format (custom:ID)
        let canonical = self.canonicalProviderKey(for: providerID)
        return keys[canonical]
    }

    var selectedProviderID: String {
        get { self.availableSelectedProviderID(for: self.defaults.string(forKey: Keys.selectedProviderID)) }
        set {
            objectWillChange.send()
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                self.defaults.removeObject(forKey: Keys.selectedProviderID)
            } else {
                self.defaults.set(trimmed, forKey: Keys.selectedProviderID)
            }
        }
    }

    func purgeRetiredAppleIntelligenceState() {
        let retiredProviderIDs = Set(["apple-intelligence", "apple-intelligence-disabled"])
        let rawSelectedProviderID = self.defaults.string(forKey: Keys.selectedProviderID)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let rawSelectedProviderID, retiredProviderIDs.contains(rawSelectedProviderID) {
            self.selectedProviderID = ""
            self.selectedModel = nil
        }

        var fingerprints = self.verifiedProviderFingerprints
        var availableModels = self.availableModelsByProvider
        var selectedModels = self.selectedModelByProvider
        for providerID in retiredProviderIDs {
            fingerprints.removeValue(forKey: providerID)
            availableModels.removeValue(forKey: providerID)
            selectedModels.removeValue(forKey: providerID)
            fingerprints.removeValue(forKey: "custom:\(providerID)")
            availableModels.removeValue(forKey: "custom:\(providerID)")
            selectedModels.removeValue(forKey: "custom:\(providerID)")
        }
        if fingerprints != self.verifiedProviderFingerprints {
            self.verifiedProviderFingerprints = fingerprints
        }
        if availableModels != self.availableModelsByProvider {
            self.availableModelsByProvider = availableModels
        }
        if selectedModels != self.selectedModelByProvider {
            self.selectedModelByProvider = selectedModels
        }

        let configurations = self.dictationPromptConfigurations.compactMapValues { configuration in
            let providerID = configuration.providerID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard retiredProviderIDs.contains(providerID) else { return configuration }
            guard configuration.shortcut != nil else { return nil }
            return DictationPromptConfiguration(shortcut: configuration.shortcut)
        }
        if configurations != self.dictationPromptConfigurations {
            self.dictationPromptConfigurations = configurations
        }
    }

    var privateAIPrefixKVCacheEnabled: Bool {
        get { self.defaults.object(forKey: PrivateAIProviderFeature.shared.prefixCacheDefaultsKey) as? Bool ?? true }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: PrivateAIProviderFeature.shared.prefixCacheDefaultsKey)
        }
    }

    var privateAIBoostEnabled: Bool {
        get { self.defaults.object(forKey: PrivateAIProviderFeature.shared.boostDefaultsKey) as? Bool ?? true }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: PrivateAIProviderFeature.shared.boostDefaultsKey)
        }
    }

    var privateAIBackendPreference: PrivateAIBackendPreference {
        get {
            let rawValue = self.defaults.string(forKey: Keys.privateAIBackendPreference)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            var preference = rawValue.flatMap(PrivateAIBackendPreference.init(rawValue:))
                ?? PrivateAIBackendPreference.systemDefault
            if preference == .auto {
                preference = PrivateAIBackendPreference.systemDefault
            }
            if preference == .mlx, CPUArchitecture.isIntel {
                return .llama
            }
            return preference
        }
        set {
            objectWillChange.send()
            var preference = newValue == .auto ? PrivateAIBackendPreference.systemDefault : newValue
            if preference == .mlx, CPUArchitecture.isIntel {
                preference = .llama
            }
            self.defaults.set(preference.rawValue, forKey: Keys.privateAIBackendPreference)
        }
    }

    var privateAIContextTokenLimit: Int {
        get {
            let value = self.defaults.integer(forKey: Keys.privateAIContextTokenLimit)
            return Self.clampPrivateAIContextTokenLimit(value == 0 ? Self.defaultPrivateAIContextTokenLimit : value)
        }
        set {
            objectWillChange.send()
            self.defaults.set(Self.clampPrivateAIContextTokenLimit(newValue), forKey: Keys.privateAIContextTokenLimit)
        }
    }

    private func migratePrivateAIContextDefaultTo4KIfNeeded() {
        guard self.defaults.bool(forKey: Keys.privateAIContextDefaultMigratedTo4K) == false else { return }
        let storedValue = self.defaults.object(forKey: Keys.privateAIContextTokenLimit) as? Int
        if storedValue == nil || storedValue == Self.privateAIContextTokenLimitRange.lowerBound {
            self.defaults.set(Self.defaultPrivateAIContextTokenLimit, forKey: Keys.privateAIContextTokenLimit)
        }
        self.defaults.set(true, forKey: Keys.privateAIContextDefaultMigratedTo4K)
    }

    var savedProviders: [SavedProvider] {
        get {
            guard let data = defaults.data(forKey: Keys.savedProviders),
                  let decoded = try? JSONDecoder().decode([SavedProvider].self, from: data) else { return [] }
            return decoded
        }
        set {
            objectWillChange.send()
            let sanitized = newValue.map { provider -> SavedProvider in
                if provider.apiKey.isEmpty { return provider }
                return SavedProvider(
                    id: provider.id,
                    name: provider.name,
                    baseURL: provider.baseURL,
                    apiKey: "",
                    models: provider.models
                )
            }
            if let encoded = try? JSONEncoder().encode(sanitized) {
                self.defaults.set(encoded, forKey: Keys.savedProviders)
            }
        }
    }

    /// Check if the current AI provider is fully configured (API key/baseURL + selected model)
    var isAIConfigured: Bool {
        let providerID = self.selectedProviderID

        // Get base URL to check for local endpoints
        var baseURL = ""
        if let saved = self.savedProviders.first(where: { $0.id == providerID }) {
            baseURL = saved.baseURL
        } else {
            baseURL = ModelRepository.shared.defaultBaseURL(for: providerID)
        }

        let isLocal = ModelRepository.shared.isLocalEndpoint(baseURL)

        // Check for API key and selected model
        let key = self.canonicalProviderKey(for: providerID)
        let hasApiKey = !(self.providerAPIKeys[key]?.isEmpty ?? true)

        let selectedModel = self.selectedModelByProvider[key]
        let hasSelectedModel = !(selectedModel?.isEmpty ?? true)
        let hasDefaultModel = !ModelRepository.shared.defaultModels(for: providerID).isEmpty
        let hasModel = hasSelectedModel || hasDefaultModel

        return (isLocal || hasApiKey) && hasModel
    }

    /// The base URL for the currently selected AI provider
    var activeBaseURL: String {
        let providerID = self.selectedProviderID
        if let saved = self.savedProviders.first(where: { $0.id == providerID }) {
            return saved.baseURL
        }
        return ModelRepository.shared.defaultBaseURL(for: providerID)
    }

    var hotkeyShortcut: HotkeyShortcut {
        get {
            self.primaryDictationShortcuts.first ?? Self.defaultPrimaryDictationShortcut
        }
        set {
            objectWillChange.send()
            let shortcuts = Self.normalizedPrimaryDictationShortcuts([newValue], fallback: Self.defaultPrimaryDictationShortcut)
            self.storePrimaryDictationShortcuts(shortcuts)
            self.storeLegacyHotkeyShortcut(shortcuts[0])
        }
    }

    var primaryDictationShortcutDisplayString: String {
        let displays = self.primaryDictationShortcuts
            .map(\.displayString)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return displays.isEmpty ? Self.defaultPrimaryDictationShortcut.displayString : displays.joined(separator: " / ")
    }

    var primaryDictationShortcuts: [HotkeyShortcut] {
        get {
            let fallback = self.legacyHotkeyShortcut
            if let data = defaults.data(forKey: Keys.primaryDictationShortcutsKey),
               let shortcuts = try? JSONDecoder().decode([HotkeyShortcut].self, from: data)
            {
                return Self.normalizedPrimaryDictationShortcuts(shortcuts, fallback: fallback)
            }
            return [fallback]
        }
        set {
            objectWillChange.send()
            let shortcuts = Self.normalizedPrimaryDictationShortcuts(newValue, fallback: self.legacyHotkeyShortcut)
            self.storePrimaryDictationShortcuts(shortcuts)
            self.storeLegacyHotkeyShortcut(shortcuts[0])
        }
    }

    private static var defaultPrimaryDictationShortcut: HotkeyShortcut {
        HotkeyShortcut(keyCode: 61, modifierFlags: [])
    }

    private var legacyHotkeyShortcut: HotkeyShortcut {
        if let data = defaults.data(forKey: Keys.hotkeyShortcutKey),
           let shortcut = try? JSONDecoder().decode(HotkeyShortcut.self, from: data)
        {
            return shortcut
        }
        return Self.defaultPrimaryDictationShortcut
    }

    private static func normalizedPrimaryDictationShortcuts(
        _ shortcuts: [HotkeyShortcut],
        fallback: HotkeyShortcut
    ) -> [HotkeyShortcut] {
        var unique: [HotkeyShortcut] = []
        for shortcut in shortcuts where !unique.contains(shortcut) {
            unique.append(shortcut)
        }
        if unique.isEmpty {
            unique.append(fallback)
        }
        return unique
    }

    private func storePrimaryDictationShortcuts(_ shortcuts: [HotkeyShortcut]) {
        if let data = try? JSONEncoder().encode(shortcuts) {
            self.defaults.set(data, forKey: Keys.primaryDictationShortcutsKey)
        }
    }

    private func storeLegacyHotkeyShortcut(_ shortcut: HotkeyShortcut) {
        if let data = try? JSONEncoder().encode(shortcut) {
            self.defaults.set(data, forKey: Keys.hotkeyShortcutKey)
        }
    }

    var pressAndHoldMode: Bool {
        get { self.defaults.object(forKey: Keys.hotkeyMode) != nil ? self.hotkeyMode == .hold : self.defaults.bool(forKey: Keys.pressAndHoldMode) } set { self.hotkeyMode = newValue ? .hold : .toggle }
    }

    var hotkeyMode: HotkeyActivationMode {
        get { self.defaults.string(forKey: Keys.hotkeyMode).flatMap(HotkeyActivationMode.init(rawValue:)) ?? (self.defaults.bool(forKey: Keys.pressAndHoldMode) ? .hold : .toggle) }
        set { objectWillChange.send(); self.defaults.set(newValue.rawValue, forKey: Keys.hotkeyMode); self.defaults.set(newValue == .hold, forKey: Keys.pressAndHoldMode) }
    }

    var enableStreamingPreview: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.enableStreamingPreview)
            return value as? Bool ?? true // Default to true (enabled)
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.enableStreamingPreview)
        }
    }

    /// Legacy kill switch. Translation sessions are gated by LiveTranslationController.isSessionActive.
    var liveTranslationEnabled: Bool {
        get { self.defaults.object(forKey: Keys.liveTranslationEnabled) as? Bool ?? false }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.liveTranslationEnabled)
        }
    }

    /// Dictation shortcut. Types what you said. Does not translate.
    var listeningHotkeyEnabled: Bool {
        get { self.defaults.object(forKey: Keys.listeningHotkeyEnabled) as? Bool ?? false }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.listeningHotkeyEnabled)
        }
    }

    var theaterWindowEnabled: Bool {
        get { self.defaults.bool(forKey: Keys.theaterWindowEnabled) }
        set {
            let previous = self.defaults.bool(forKey: Keys.theaterWindowEnabled)
            guard previous != newValue else { return }
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.theaterWindowEnabled)
        }
    }

    var translationInsertHotkeyEnabled: Bool {
        get { self.defaults.bool(forKey: Keys.translationInsertHotkeyEnabled) }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.translationInsertHotkeyEnabled)
        }
    }

    var translationInsertHotkeyShortcut: HotkeyShortcut? {
        get {
            if let data = self.defaults.data(forKey: Keys.translationInsertHotkeyShortcut),
               let shortcut = try? JSONDecoder().decode(HotkeyShortcut.self, from: data)
            {
                return shortcut
            }
            return nil
        }
        set {
            objectWillChange.send()
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                self.defaults.set(data, forKey: Keys.translationInsertHotkeyShortcut)
            } else {
                self.defaults.removeObject(forKey: Keys.translationInsertHotkeyShortcut)
            }
        }
    }

    var captionListenHotkeyEnabled: Bool {
        get { self.defaults.bool(forKey: Keys.captionListenHotkeyEnabled) }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.captionListenHotkeyEnabled)
        }
    }

    var captionListenHotkeyShortcut: HotkeyShortcut? {
        get {
            if let data = self.defaults.data(forKey: Keys.captionListenHotkeyShortcut),
               let shortcut = try? JSONDecoder().decode(HotkeyShortcut.self, from: data)
            {
                return shortcut
            }
            return nil
        }
        set {
            objectWillChange.send()
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                self.defaults.set(data, forKey: Keys.captionListenHotkeyShortcut)
            } else {
                self.defaults.removeObject(forKey: Keys.captionListenHotkeyShortcut)
            }
        }
    }

    var theaterHideChrome: Bool {
        get { self.defaults.bool(forKey: Keys.theaterHideChrome) }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.theaterHideChrome)
        }
    }

    var theaterHighContrast: Bool {
        get { self.defaults.bool(forKey: Keys.theaterHighContrast) }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.theaterHighContrast)
        }
    }

    var theaterAppearance: String {
        get {
            TheaterAppearance.resolved(self.defaults.string(forKey: Keys.theaterAppearance)).rawValue
        }
        set {
            objectWillChange.send()
            self.defaults.set(TheaterAppearance.resolved(newValue).rawValue, forKey: Keys.theaterAppearance)
        }
    }

    var theaterWindowFrame: String {
        get { self.defaults.string(forKey: Keys.theaterWindowFrame) ?? "" }
        set {
            self.defaults.set(newValue, forKey: Keys.theaterWindowFrame)
        }
    }

    var theaterScreenName: String {
        get { self.defaults.string(forKey: Keys.theaterScreenName) ?? "" }
        set {
            self.defaults.set(newValue, forKey: Keys.theaterScreenName)
        }
    }

    var theaterBoardSnapshot: TheaterBoardSnapshot? {
        get {
            guard let data = self.defaults.data(forKey: Keys.theaterBoardSnapshot) else { return nil }
            return try? JSONDecoder().decode(TheaterBoardSnapshot.self, from: data)
        }
        set {
            objectWillChange.send()
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                self.defaults.set(data, forKey: Keys.theaterBoardSnapshot)
            } else {
                self.defaults.removeObject(forKey: Keys.theaterBoardSnapshot)
            }
        }
    }

    var translationSourceLanguageID: String {
        get {
            let stored = self.defaults.string(forKey: Keys.translationSourceLanguageID)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let stored, let language = TranslationLanguageCatalog.language(id: stored) {
                return language.id
            }
            if let language = TranslationLanguageCatalog.language(id: self.onboardingSelectedLanguageID) {
                return language.id
            }
            return TranslationLanguageCatalog.english.id
        }
        set {
            objectWillChange.send()
            let id = TranslationLanguageCatalog.language(id: newValue)?.id
                ?? TranslationLanguageCatalog.english.id
            self.defaults.set(id, forKey: Keys.translationSourceLanguageID)
        }
    }

    var translationTargetLanguageID: String {
        get {
            let stored = self.defaults.string(forKey: Keys.translationTargetLanguageID)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let stored, let language = TranslationLanguageCatalog.language(id: stored) {
                return language.id
            }
            let sourceID = self.translationSourceLanguageID
            let source = TranslationLanguageCatalog.language(id: sourceID) ?? TranslationLanguageCatalog.english
            return TranslationLanguageCatalog.defaultTarget(forSource: source).id
        }
        set {
            objectWillChange.send()
            let sourceID = self.translationSourceLanguageID
            let id = TranslationLanguageCatalog.language(id: newValue)?.id
                ?? TranslationLanguageCatalog.defaultTarget(
                    forSource: TranslationLanguageCatalog.language(id: sourceID) ?? TranslationLanguageCatalog.english
                ).id
            self.defaults.set(id, forKey: Keys.translationTargetLanguageID)
        }
    }

    var translationShowSource: Bool {
        get { self.defaults.object(forKey: Keys.translationShowSource) as? Bool ?? true }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.translationShowSource)
        }
    }

    static let presenterFontSizeRange: ClosedRange<Int> = 18...72

    var presenterFontSize: Int {
        get {
            let value = self.defaults.object(forKey: Keys.presenterFontSize) as? Int ?? 42
            return min(Self.presenterFontSizeRange.upperBound, max(Self.presenterFontSizeRange.lowerBound, value))
        }
        set {
            objectWillChange.send()
            self.defaults.set(
                min(Self.presenterFontSizeRange.upperBound, max(Self.presenterFontSizeRange.lowerBound, newValue)),
                forKey: Keys.presenterFontSize
            )
        }
    }

    var presenterFontFamily: String {
        get {
            let stored = self.defaults.string(forKey: Keys.presenterFontFamily)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return TheaterTypeface.resolved(stored).rawValue
        }
        set {
            objectWillChange.send()
            self.defaults.set(TheaterTypeface.resolved(newValue).rawValue, forKey: Keys.presenterFontFamily)
        }
    }

    /// Reuses finalized Parakeet windows so long recordings only process their remaining tail at stop.
    /// Experimental and enabled by default; users can fall back to full-buffer finalization.
    var experimentalParakeetUnifiedFinalEnabled: Bool {
        get { self.defaults.object(forKey: Keys.experimentalParakeetUnifiedFinalEnabled) as? Bool ?? true }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.experimentalParakeetUnifiedFinalEnabled)
        }
    }

    /// Shows optional ASR and AI performance details in transcription history.
    var showHistoryPerformanceMetrics: Bool {
        get { self.defaults.object(forKey: Keys.showHistoryPerformanceMetrics) as? Bool ?? false }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.showHistoryPerformanceMetrics)
        }
    }

    /// Skips clearly silent recordings up to four seconds before invoking ASR.
    /// Opt-in so quiet speech keeps the existing transcription behavior by default.
    var skipSilentRecordingsEnabled: Bool {
        get { self.defaults.object(forKey: Keys.skipSilentRecordingsEnabled) as? Bool ?? false }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.skipSilentRecordingsEnabled)
        }
    }

    var enableAIStreaming: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.enableAIStreaming)
            return value as? Bool ?? true // Default to true (enabled)
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.enableAIStreaming)
        }
    }

    /// Direct Core Audio is the required capture backend. Legacy persisted
    /// preferences are intentionally ignored because AVAudioEngine can block or
    /// crash while audio devices are changing.
    var experimentalDirectAudioCaptureEnabled: Bool { true }

    var copyTranscriptionToClipboard: Bool {
        get { self.defaults.bool(forKey: Keys.copyTranscriptionToClipboard) }
        set { self.defaults.set(newValue, forKey: Keys.copyTranscriptionToClipboard) }
    }

    var preferredInputDeviceUID: String? {
        get { self.defaults.string(forKey: Keys.preferredInputDeviceUID) }
        set { self.defaults.set(newValue, forKey: Keys.preferredInputDeviceUID) }
    }

    var microphonePriority: [MicrophonePriorityEntry] {
        get {
            guard let data = self.defaults.data(forKey: Keys.microphonePriority),
                  let entries = try? JSONDecoder().decode([MicrophonePriorityEntry].self, from: data)
            else { return [] }
            return Self.normalizedMicrophonePriority(entries)
        }
        set {
            let entries = Self.normalizedMicrophonePriority(newValue)
            guard entries != self.microphonePriority else { return }
            objectWillChange.send()
            if let data = try? JSONEncoder().encode(entries) {
                self.defaults.set(data, forKey: Keys.microphonePriority)
            } else {
                self.defaults.removeObject(forKey: Keys.microphonePriority)
            }
            if let firstUID = entries.first?.uid {
                self.preferredInputDeviceUID = firstUID
            }
        }
    }

    var suppressedMicrophoneUIDs: Set<String> {
        get { Set(self.defaults.stringArray(forKey: Keys.suppressedMicrophoneUIDs) ?? []) }
        set {
            if newValue.isEmpty {
                self.defaults.removeObject(forKey: Keys.suppressedMicrophoneUIDs)
            } else {
                self.defaults.set(newValue.sorted(), forKey: Keys.suppressedMicrophoneUIDs)
            }
        }
    }

    var preferredOutputDeviceUID: String? {
        get { self.defaults.string(forKey: Keys.preferredOutputDeviceUID) }
        set { self.defaults.set(newValue, forKey: Keys.preferredOutputDeviceUID) }
    }

    var storedMicSelectionModeForMigration: MicrophoneSelectionMode {
        guard let rawValue = self.defaults.string(forKey: Keys.microphoneSelectionMode),
              let mode = MicrophoneSelectionMode(rawValue: rawValue)
        else { return .system }
        return mode
    }

    var hasStoredMicSelectionModeForMigration: Bool {
        self.defaults.object(forKey: Keys.microphoneSelectionMode) != nil
    }

    var microphoneSelectionMode: MicrophoneSelectionMode {
        get {
            guard let rawValue = self.defaults.string(forKey: Keys.microphoneSelectionMode),
                  let mode = MicrophoneSelectionMode(rawValue: rawValue)
            else { return .manual }
            return mode
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.microphoneSelectionMode)
        }
    }

    func recordInputDeviceSelection(_ uid: String, name: String? = nil) {
        guard uid.isEmpty == false else { return }

        var suppressedUIDs = self.suppressedMicrophoneUIDs
        suppressedUIDs.remove(uid)
        self.suppressedMicrophoneUIDs = suppressedUIDs

        var entries = self.microphonePriority.filter { $0.uid != uid }
        let existingName = self.microphonePriority.first { $0.uid == uid }?.name
        entries.insert(
            MicrophonePriorityEntry(uid: uid, name: name ?? existingName ?? "Microphone"),
            at: 0
        )
        self.microphonePriority = entries
        self.microphoneSelectionMode = .manual
    }

    func reconcileMicrophonePriority(with devices: [AudioDevice.Device]) {
        var entries = self.microphonePriority
        let preferredUID = self.preferredInputDeviceUID
        let suppressedUIDs = self.suppressedMicrophoneUIDs

        if entries.isEmpty,
           let preferredUID,
           preferredUID.isEmpty == false
        {
            let name = devices.first { $0.uid == preferredUID }?.name ?? "Previously selected microphone"
            entries.append(MicrophonePriorityEntry(uid: preferredUID, name: name))
        }

        var knownUIDs = Set(entries.map(\.uid))
        let newEntries = devices.compactMap { device -> MicrophonePriorityEntry? in
            guard suppressedUIDs.contains(device.uid) == false,
                  knownUIDs.insert(device.uid).inserted
            else { return nil }
            return MicrophonePriorityEntry(uid: device.uid, name: device.name)
        }
        if newEntries.isEmpty == false {
            // Keep the user's first choice stable while making a newly connected
            // microphone the immediate fallback. Its position remains persisted
            // when the device later disconnects.
            entries.insert(contentsOf: newEntries, at: min(1, entries.count))
        }

        let namesByUID = Dictionary(
            devices.map { ($0.uid, $0.name) },
            uniquingKeysWith: { current, _ in current }
        )
        entries = entries.map { entry in
            MicrophonePriorityEntry(uid: entry.uid, name: namesByUID[entry.uid] ?? entry.name)
        }
        self.microphonePriority = entries
    }

    func removeMicrophoneFromPriority(uid: String, isConnected: Bool) {
        guard uid.isEmpty == false else { return }

        var suppressedUIDs = self.suppressedMicrophoneUIDs
        if isConnected {
            suppressedUIDs.insert(uid)
        } else {
            suppressedUIDs.remove(uid)
        }
        self.suppressedMicrophoneUIDs = suppressedUIDs

        let entries = self.microphonePriority.filter { $0.uid != uid }
        self.microphonePriority = entries
        if entries.isEmpty {
            self.preferredInputDeviceUID = nil
        }
    }

    func restoreRemovedMicrophones(with devices: [AudioDevice.Device]) {
        self.suppressedMicrophoneUIDs = []
        self.reconcileMicrophonePriority(with: devices)
    }

    func reorderMicrophonePriority(fromOffsets: IndexSet, toOffset: Int) {
        var entries = self.microphonePriority
        entries.move(fromOffsets: fromOffsets, toOffset: toOffset)
        self.microphonePriority = entries
    }

    func moveMicrophonePriority(uid: String, before targetUID: String) {
        guard uid != targetUID else { return }
        var entries = self.microphonePriority
        guard let sourceIndex = entries.firstIndex(where: { $0.uid == uid }),
              let targetIndex = entries.firstIndex(where: { $0.uid == targetUID })
        else { return }

        let entry = entries.remove(at: sourceIndex)
        let adjustedTargetIndex = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
        entries.insert(entry, at: adjustedTargetIndex)
        self.microphonePriority = entries
    }

    func moveMicrophonePriority(uid: String, by offset: Int) {
        var entries = self.microphonePriority
        guard let sourceIndex = entries.firstIndex(where: { $0.uid == uid }) else { return }
        let destination = min(max(sourceIndex + offset, 0), entries.count - 1)
        guard destination != sourceIndex else { return }
        entries.swapAt(sourceIndex, destination)
        self.microphonePriority = entries
    }

    private static func normalizedMicrophonePriority(
        _ entries: [MicrophonePriorityEntry]
    ) -> [MicrophonePriorityEntry] {
        var seen = Set<String>()
        return entries.filter { entry in
            entry.uid.isEmpty == false && seen.insert(entry.uid).inserted
        }
    }

    var microphoneSelectionMigrationVersion: Int {
        get { self.defaults.integer(forKey: Keys.microphoneSelectionMigrationVersion) }
        set { self.defaults.set(newValue, forKey: Keys.microphoneSelectionMigrationVersion) }
    }

    var visualizerNoiseThreshold: Double {
        get {
            let value = self.defaults.double(forKey: Keys.visualizerNoiseThreshold)
            return value == 0.0 ? 0.4 : value // Default to 0.4 if not set
        }
        set {
            // Clamp between 0.0 and 0.95 to avoid division by zero issues in visualizers
            let clamped = max(min(newValue, 0.95), 0.0)
            self.defaults.set(clamped, forKey: Keys.visualizerNoiseThreshold)
        }
    }

    // MARK: - Initialization Methods

    func initializeAppSettings() {
        #if os(macOS)
        self.refreshLaunchAtStartupStatus(clearError: true)

        // Apply dock visibility setting on app launch
        let dockVisible = self.showInDock
        DebugLogger.shared.info("Initializing app with dock visibility: \(dockVisible)", source: "SettingsStore")

        // Set activation policy based on saved preference
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(dockVisible ? .regular : .accessory)
        }
        #endif
    }

    var showInDock: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.showInDock)
            return value as? Bool ?? true // Default to true if not set
        }
        set {
            self.defaults.set(newValue, forKey: Keys.showInDock)
            // Update dock visibility
            self.updateDockVisibility(newValue)
        }
    }

    /// Issue #162 wording: hide app from Dock and Cmd+Tab when enabled.
    /// Backed by existing `showInDock` storage to keep this change minimal.
    var hideFromDockAndAppSwitcher: Bool {
        get { !self.showInDock }
        set { self.showInDock = !newValue }
    }

    var autoUpdateCheckEnabled: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.autoUpdateCheckEnabled)
            return value as? Bool ?? true // Default to enabled
        }
        set {
            self.defaults.set(newValue, forKey: Keys.autoUpdateCheckEnabled)
        }
    }

    var lastUpdateCheckDate: Date? {
        get {
            return self.defaults.object(forKey: Keys.lastUpdateCheckDate) as? Date
        }
        set {
            self.defaults.set(newValue, forKey: Keys.lastUpdateCheckDate)
        }
    }

    // MARK: - Update Check Helper

    func shouldCheckForUpdates() -> Bool {
        guard self.autoUpdateCheckEnabled else { return false }

        guard let lastCheck = lastUpdateCheckDate else {
            // Never checked before, should check
            return true
        }

        // Check if more than 1 hour has passed
        let hourInSeconds: TimeInterval = 60 * 60
        return Date().timeIntervalSince(lastCheck) >= hourInSeconds
    }

    func updateLastCheckDate() {
        self.lastUpdateCheckDate = Date()
    }

    // MARK: - Update Prompt Snooze

    /// Date until which update prompts are snoozed (user clicked "Later")
    var updatePromptSnoozedUntil: Date? {
        get { self.defaults.object(forKey: Keys.updatePromptSnoozedUntil) as? Date }
        set { self.defaults.set(newValue, forKey: Keys.updatePromptSnoozedUntil) }
    }

    /// The version that was snoozed (to allow prompting for newer versions)
    var snoozedUpdateVersion: String? {
        get { self.defaults.string(forKey: Keys.snoozedUpdateVersion) }
        set { self.defaults.set(newValue, forKey: Keys.snoozedUpdateVersion) }
    }

    /// Check if we should show the update prompt for a given version
    /// Returns false if user snoozed this version within the last 24 hours
    func shouldShowUpdatePrompt(forVersion version: String) -> Bool {
        // If a different (newer) version is available, always show
        if let snoozedVersion = snoozedUpdateVersion, snoozedVersion != version {
            return true
        }

        // Check if snooze period has expired
        guard let snoozedUntil = updatePromptSnoozedUntil else {
            return true // Never snoozed, show prompt
        }

        return Date() >= snoozedUntil
    }

    /// Snooze update prompts for 24 hours for the given version
    func snoozeUpdatePrompt(forVersion version: String) {
        let snoozeUntil = Date().addingTimeInterval(24 * 60 * 60) // 24 hours
        self.updatePromptSnoozedUntil = snoozeUntil
        self.snoozedUpdateVersion = version
        DebugLogger.shared.info("Update prompt snoozed for version \(version) until \(snoozeUntil)", source: "SettingsStore")
    }

    /// Clear the snooze (e.g., when update is installed)
    func clearUpdateSnooze() {
        self.updatePromptSnoozedUntil = nil
        self.snoozedUpdateVersion = nil
    }

    var playgroundUsed: Bool {
        get { self.defaults.bool(forKey: Keys.playgroundUsed) }
        set { self.defaults.set(newValue, forKey: Keys.playgroundUsed) }
    }

    var theaterListenUsed: Bool {
        get { self.defaults.bool(forKey: Keys.theaterListenUsed) }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.theaterListenUsed)
        }
    }

    var onboardingCompleted: Bool {
        get {
            if self.defaults.object(forKey: Keys.onboardingCompleted) == nil {
                return true
            }
            return self.defaults.bool(forKey: Keys.onboardingCompleted)
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.onboardingCompleted)
            if newValue {
                self.defaults.set(false, forKey: Keys.manualOnboardingResetRequested)
                self.defaults.removeObject(forKey: Keys.manualOnboardingResetRequestedAt)
            }
        }
    }

    var onboardingCurrentStep: Int {
        get {
            let raw = self.defaults.integer(forKey: Keys.onboardingCurrentStep)
            return max(0, min(4, raw))
        }
        set {
            objectWillChange.send()
            let clamped = max(0, min(4, newValue))
            self.defaults.set(clamped, forKey: Keys.onboardingCurrentStep)
        }
    }

    var onboardingAISkipped: Bool {
        get { self.defaults.bool(forKey: Keys.onboardingAISkipped) }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.onboardingAISkipped)
        }
    }

    var onboardingPlaygroundValidated: Bool {
        get { self.defaults.bool(forKey: Keys.onboardingPlaygroundValidated) }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.onboardingPlaygroundValidated)
        }
    }

    var onboardingPlaygroundSkipped: Bool {
        get { self.defaults.bool(forKey: Keys.onboardingPlaygroundSkipped) }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.onboardingPlaygroundSkipped)
        }
    }

    var onboardingSelectedLanguageID: String {
        get {
            let stored = self.defaults.string(forKey: Keys.onboardingSelectedLanguageID)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let stored, let language = TranslationLanguageCatalog.language(id: stored) {
                return language.id
            }
            return TranslationLanguageCatalog.english.id
        }
        set {
            objectWillChange.send()
            let id = TranslationLanguageCatalog.language(id: newValue)?.id
                ?? TranslationLanguageCatalog.english.id
            self.defaults.set(id, forKey: Keys.onboardingSelectedLanguageID)
        }
    }

    var selectedAppleSpeechLocaleIdentifier: String {
        get {
            let stored = self.defaults.string(forKey: Keys.selectedAppleSpeechLocaleIdentifier)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let stored, !stored.isEmpty {
                return stored
            }
            return Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        }
        set {
            objectWillChange.send()
            let normalized = newValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "_", with: "-")
            self.defaults.set(normalized.isEmpty ? "en-US" : normalized, forKey: Keys.selectedAppleSpeechLocaleIdentifier)
        }
    }

    var selectedAppleSpeechLocale: Locale {
        Locale(identifier: self.selectedAppleSpeechLocaleIdentifier)
    }

    var shouldShowOnboarding: Bool {
        !self.onboardingCompleted
    }

    var shouldPromptAccessibilityOnLaunch: Bool {
        !self.shouldShowOnboarding
    }

    func bootstrapOnboardingState(isTrueFirstOpen: Bool) {
        guard self.defaults.object(forKey: Keys.onboardingCompleted) == nil else { return }

        objectWillChange.send()

        let hasLegacyUsageSignals = self.hasLegacyUsageSignals()
        let shouldShowForThisInstall = isTrueFirstOpen && !hasLegacyUsageSignals

        if shouldShowForThisInstall {
            self.defaults.set(false, forKey: Keys.onboardingCompleted)
            self.defaults.set(0, forKey: Keys.onboardingCurrentStep)
            self.defaults.set(false, forKey: Keys.onboardingAISkipped)
            self.defaults.set(false, forKey: Keys.onboardingPlaygroundValidated)
            self.defaults.set(false, forKey: Keys.onboardingPlaygroundSkipped)
            self.defaults.set("en", forKey: Keys.onboardingSelectedLanguageID)
        } else {
            self.defaults.set(true, forKey: Keys.onboardingCompleted)
            self.defaults.set(0, forKey: Keys.onboardingCurrentStep)
            self.defaults.set(false, forKey: Keys.onboardingAISkipped)
            self.defaults.set(false, forKey: Keys.onboardingPlaygroundValidated)
            self.defaults.set(false, forKey: Keys.onboardingPlaygroundSkipped)
            self.defaults.set("en", forKey: Keys.onboardingSelectedLanguageID)
        }
    }

    func resetOnboardingProgress() {
        objectWillChange.send()
        self.defaults.set(false, forKey: Keys.onboardingCompleted)
        self.defaults.set(true, forKey: Keys.manualOnboardingResetRequested)
        self.defaults.set(Date(), forKey: Keys.manualOnboardingResetRequestedAt)
        self.defaults.set(0, forKey: Keys.onboardingCurrentStep)
        self.defaults.set(false, forKey: Keys.onboardingAISkipped)
        self.defaults.set(false, forKey: Keys.onboardingPlaygroundValidated)
        self.defaults.set(false, forKey: Keys.onboardingPlaygroundSkipped)
        self.defaults.set("en", forKey: Keys.onboardingSelectedLanguageID)
        self.defaults.set(false, forKey: Keys.playgroundUsed)
        self.defaults.set(false, forKey: Keys.theaterListenUsed)
    }

    private func repairForcedOnboardingResetIfNeeded() {
        // 1.6.2 briefly used OnboardingGeneration to force every install through onboarding.
        // Restore existing users who were reset by that migration while keeping fresh installs intact.
        let hadOpenedBeforeForcedReset = (self.defaults.object(forKey: "AnalyticsFirstOpenAt") as? Date).map {
            $0 < Self.forcedOnboardingResetIntroducedAt
        } ?? false
        let hasExistingInstallSignal = self.hasLegacyUsageSignals() || hadOpenedBeforeForcedReset
        let hasCurrentManualReset = self.defaults.bool(forKey: Keys.manualOnboardingResetRequested)
            && self.defaults.object(forKey: Keys.manualOnboardingResetRequestedAt) != nil
        guard self.defaults.object(forKey: Keys.onboardingGeneration) != nil,
              self.defaults.bool(forKey: Keys.onboardingCompleted) == false,
              !hasCurrentManualReset,
              hasExistingInstallSignal
        else { return }

        objectWillChange.send()
        self.defaults.set(true, forKey: Keys.onboardingCompleted)
        self.defaults.set(false, forKey: Keys.manualOnboardingResetRequested)
        self.defaults.removeObject(forKey: Keys.manualOnboardingResetRequestedAt)
        self.defaults.set(0, forKey: Keys.onboardingCurrentStep)
        self.defaults.set(false, forKey: Keys.onboardingAISkipped)
        self.defaults.set(false, forKey: Keys.onboardingPlaygroundValidated)
        self.defaults.set(false, forKey: Keys.onboardingPlaygroundSkipped)
    }

    private func hasLegacyUsageSignals() -> Bool {
        if self.defaults.object(forKey: Keys.playgroundUsed) != nil { return true }
        if self.defaults.object(forKey: Keys.hotkeyShortcutKey) != nil { return true }
        if self.defaults.object(forKey: Keys.primaryDictationShortcutsKey) != nil { return true }
        if let rawSpeechModel = self.defaults.string(forKey: Keys.selectedSpeechModel),
           rawSpeechModel != SpeechModel.defaultModel.rawValue
        {
            return true
        }
        if self.defaults.object(forKey: Keys.selectedProviderID) != nil { return true }
        if self.defaults.object(forKey: Keys.customDictionaryEntries) != nil { return true }
        if !self.savedProviders.isEmpty { return true }
        return false
    }

    // MARK: - Prompt Mode Settings (Transcribe with Prompt)

    var promptModeShortcutEnabled: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.promptModeShortcutEnabled)
            return value as? Bool ?? false
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.promptModeShortcutEnabled)
        }
    }

    var promptModeHotkeyShortcut: HotkeyShortcut {
        get {
            if let data = defaults.data(forKey: Keys.promptModeHotkeyShortcut),
               let shortcut = try? JSONDecoder().decode(HotkeyShortcut.self, from: data)
            {
                return shortcut
            }
            // Default to Right Shift (keyCode 60) so it does not collide with Command.
            return HotkeyShortcut(keyCode: 60, modifierFlags: [])
        }
        set {
            objectWillChange.send()
            if let data = try? JSONEncoder().encode(newValue) {
                self.defaults.set(data, forKey: Keys.promptModeHotkeyShortcut)
            }
        }
    }

    var promptModeSelectedPromptID: String? {
        get {
            let value = self.defaults.string(forKey: Keys.promptModeSelectedPromptID)
            return value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true ? nil : value
        }
        set {
            objectWillChange.send()
            if let id = newValue?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
                self.defaults.set(id, forKey: Keys.promptModeSelectedPromptID)
            } else {
                self.defaults.removeObject(forKey: Keys.promptModeSelectedPromptID)
            }
        }
    }

    var isSecondaryDictationPromptOff: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.secondaryDictationPromptOff)
            return value as? Bool ?? false
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.secondaryDictationPromptOff)
        }
    }

    var cancelRecordingHotkeyShortcut: HotkeyShortcut {
        get {
            if let data = defaults.data(forKey: Keys.cancelRecordingHotkeyShortcut),
               let shortcut = try? JSONDecoder().decode(HotkeyShortcut.self, from: data)
            {
                return shortcut
            }
            return HotkeyShortcut(keyCode: 53, modifierFlags: [])
        }
        set {
            objectWillChange.send()
            if let data = try? JSONEncoder().encode(newValue) {
                self.defaults.set(data, forKey: Keys.cancelRecordingHotkeyShortcut)
            }
        }
    }

    // MARK: - Paste Last Transcription Settings

    /// Whether the "Paste Last Transcription" global hotkey is active. Opt-in and off by default.
    var pasteLastTranscriptionShortcutEnabled: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.pasteLastTranscriptionShortcutEnabled)
            return value as? Bool ?? false
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.pasteLastTranscriptionShortcutEnabled)
        }
    }

    /// The shortcut that re-inserts the most recent transcription into the focused field.
    /// Unbound (nil) by default so it never collides with an existing shortcut until the user assigns one.
    var pasteLastTranscriptionHotkeyShortcut: HotkeyShortcut? {
        get {
            if let data = defaults.data(forKey: Keys.pasteLastTranscriptionHotkeyShortcut),
               let shortcut = try? JSONDecoder().decode(HotkeyShortcut.self, from: data)
            {
                return shortcut
            }
            return nil
        }
        set {
            objectWillChange.send()
            guard let newValue else {
                self.defaults.removeObject(forKey: Keys.pasteLastTranscriptionHotkeyShortcut)
                return
            }
            if let data = try? JSONEncoder().encode(newValue) {
                self.defaults.set(data, forKey: Keys.pasteLastTranscriptionHotkeyShortcut)
            }
        }
    }

    // MARK: - Model Reasoning Configuration

    /// Per-model reasoning configuration storage
    /// Key format: "provider:model" (e.g., "openai:gpt-5.1", "groq:gpt-oss-120b")
    var modelReasoningConfigs: [String: ModelReasoningConfig] {
        get {
            guard let data = defaults.data(forKey: Keys.modelReasoningConfigs),
                  let decoded = try? JSONDecoder().decode([String: ModelReasoningConfig].self, from: data)
            else {
                return [:]
            }
            return decoded
        }
        set {
            objectWillChange.send()
            if let encoded = try? JSONEncoder().encode(newValue) {
                self.defaults.set(encoded, forKey: Keys.modelReasoningConfigs)
            }
        }
    }

    /// Get reasoning config for a specific model, with smart defaults for known models
    func getReasoningConfig(forModel model: String, provider: String) -> ModelReasoningConfig? {
        let key = "\(provider):\(model)"

        // First check if user has a custom config
        if let customConfig = modelReasoningConfigs[key] {
            return customConfig.isEnabled ? customConfig : nil
        }

        // Apply smart defaults for known model patterns
        let modelLower = model.lowercased()

        // OpenAI gpt-5.x models
        if modelLower.hasPrefix("gpt-5") || modelLower.contains("gpt-5.") {
            return .openAIGPT5
        }

        // OpenAI o-series reasoning models
        if modelLower.hasPrefix("o1") || modelLower.hasPrefix("o3") || modelLower.hasPrefix("o4") {
            return .openAIO1
        }

        // Groq gpt-oss models
        if modelLower.contains("gpt-oss") || modelLower.hasPrefix("openai/") {
            return .groqGPTOSS
        }

        // DeepSeek reasoner models
        if modelLower.contains("deepseek"), modelLower.contains("reasoner") {
            return .deepSeekReasoner
        }

        // No reasoning config needed for standard models (gpt-4.x, claude, llama, etc.)
        return nil
    }

    /// Set reasoning config for a specific model
    func setReasoningConfig(_ config: ModelReasoningConfig?, forModel model: String, provider: String) {
        let key = "\(provider):\(model)"
        var configs = self.modelReasoningConfigs

        if let config = config {
            configs[key] = config
        } else {
            configs.removeValue(forKey: key)
        }

        self.modelReasoningConfigs = configs
    }

    /// Check if a model has a custom (user-defined) reasoning config
    func hasCustomReasoningConfig(forModel model: String, provider: String) -> Bool {
        let key = "\(provider):\(model)"
        return self.modelReasoningConfigs[key] != nil
    }

    /// Global check if a model is a reasoning model (requires special params/max_completion_tokens)
    func isReasoningModel(_ model: String) -> Bool {
        // Drop a provider/namespace prefix (e.g. OpenRouter's "openai/") so the
        // family checks below match prefixed reasoning IDs like "openai/o3"
        // without also matching every non-reasoning "openai/*" model (e.g.
        // "openai/gpt-4o"), which would strip its temperature control.
        var modelLower = model.lowercased()
        if let slash = modelLower.firstIndex(of: "/") {
            modelLower = String(modelLower[modelLower.index(after: slash)...])
        }
        return modelLower.hasPrefix("gpt-5") ||
            modelLower.contains("gpt-5.") ||
            modelLower.hasPrefix("o1") ||
            modelLower.hasPrefix("o3") ||
            modelLower.hasPrefix("o4") ||
            modelLower.contains("gpt-oss") ||
            (modelLower.contains("deepseek") && modelLower.contains("reasoner"))
    }

    /// Whether the model rejects the `temperature` parameter.
    /// Covers reasoning models plus Anthropic models that have deprecated temperature
    /// (Opus 4.7+, Sonnet 5, Fable/Mythos 5 — Sonnet 4.6 and older still accept it).
    func isTemperatureUnsupported(_ model: String) -> Bool {
        if self.isReasoningModel(model) { return true }
        // Normalize version separators so dotted IDs (e.g. OpenRouter's
        // anthropic/claude-opus-4.8) match the hyphenated forms below.
        let modelLower = model.lowercased().replacingOccurrences(of: ".", with: "-")
        return modelLower.contains("claude-opus-4-7")
            || modelLower.contains("claude-opus-4-8")
            || modelLower.contains("claude-sonnet-5")
            || modelLower.contains("claude-fable")
            || modelLower.contains("claude-mythos")
    }

    /// Stored verification fingerprints per provider key (hash of baseURL + apiKey).
    var verifiedProviderFingerprints: [String: String] {
        get {
            guard let data = self.defaults.data(forKey: Keys.verifiedProviderFingerprints),
                  let decoded = try? JSONDecoder().decode([String: String].self, from: data)
            else {
                return [:]
            }
            return decoded
        }
        set {
            objectWillChange.send()
            if let encoded = try? JSONEncoder().encode(newValue) {
                self.defaults.set(encoded, forKey: Keys.verifiedProviderFingerprints)
            } else {
                self.defaults.removeObject(forKey: Keys.verifiedProviderFingerprints)
            }
        }
    }

    /// Stored verification fingerprints per private model ID. Provider-level fingerprints remain
    /// for backward compatibility, while this map allows Dictation and Edit Mode to use different
    /// installed models without invalidating each other.
    var verifiedPrivateAIModelFingerprints: [String: String] {
        get {
            guard let data = self.defaults.data(forKey: Keys.verifiedPrivateAIModelFingerprints),
                  let decoded = try? JSONDecoder().decode([String: String].self, from: data)
            else {
                return [:]
            }
            return decoded
        }
        set {
            objectWillChange.send()
            if let encoded = try? JSONEncoder().encode(newValue) {
                self.defaults.set(encoded, forKey: Keys.verifiedPrivateAIModelFingerprints)
            } else {
                self.defaults.removeObject(forKey: Keys.verifiedPrivateAIModelFingerprints)
            }
        }
    }

    // MARK: - Stats Settings

    /// User's typing speed in words per minute (for time saved calculation)
    var userTypingWPM: Int {
        get {
            let value = self.defaults.integer(forKey: Keys.userTypingWPM)
            return value > 0 ? value : 40 // Default to 40 WPM
        }
        set {
            objectWillChange.send()
            self.defaults.set(max(1, min(200, newValue)), forKey: Keys.userTypingWPM) // Clamp 1-200
        }
    }

    /// When enabled, weekends (Saturday/Sunday) don't break the usage streak
    var weekendsDontBreakStreak: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.weekendsDontBreakStreak)
            return value as? Bool ?? true // Default to true (weekends don't break streak)
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.weekendsDontBreakStreak)
        }
    }

    // MARK: - Custom Dictation Prompt

    /// Custom system prompt for dictation mode. When empty, uses the default built-in prompt.
    var customDictationPrompt: String {
        get { self.defaults.string(forKey: Keys.customDictationPrompt) ?? "" }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.customDictationPrompt)
        }
    }

    /// Whether to save transcription history for stats tracking
    /// When disabled, transcriptions are not stored and stats won't update
    var saveTranscriptionHistory: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.saveTranscriptionHistory)
            return value as? Bool ?? true // Default to true (save history)
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.saveTranscriptionHistory)
        }
    }

    /// Stores actual microphone audio locally alongside dictation history.
    var saveAudioWithTranscriptionHistory: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.saveAudioWithTranscriptionHistory)
            return value as? Bool ?? false
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.saveAudioWithTranscriptionHistory)
        }
    }

    var audioHistoryBudgetGB: Double {
        get {
            let value = self.defaults.double(forKey: Keys.audioHistoryBudgetGB)
            return value > 0 ? max(0.1, value) : 4.0
        }
        set {
            objectWillChange.send()
            self.defaults.set(max(0.1, newValue), forKey: Keys.audioHistoryBudgetGB)
        }
    }

    var audioHistoryBudgetBytes: Int64 {
        DictationAudioHistoryStore.bytes(forGigabytes: self.audioHistoryBudgetGB)
    }

    /// Whether to show a native notification when AI post-processing fails and raw text is used
    var notifyAIProcessingFailures: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.notifyAIProcessingFailures)
            return value as? Bool ?? true
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.notifyAIProcessingFailures)
        }
    }

    /// Whether transient microphone selection and availability alerts are shown.
    var showMicrophoneChangeAlerts: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.showMicrophoneChangeAlerts)
            return value as? Bool ?? true
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.showMicrophoneChangeAlerts)
        }
    }
}

