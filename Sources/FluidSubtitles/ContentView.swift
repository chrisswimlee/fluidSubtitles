//
//  ContentView.swift
//  fluid
//
//  Created by Barathwaj Anandan on 7/30/25.
//

import AppKit
import AVFoundation
import Combine
import CoreAudio
import CoreGraphics
import Security
import SwiftUI


// MARK: - Minimal FluidAudio ASR Service (finalized text, macOS)

// MARK: - Saved Provider Model

// Removed deprecated inline service and model

// NOTE: Streaming and AI response parsing is now handled by LLMClient

// swiftlint:disable type_body_length file_length function_body_length cyclomatic_complexity
// Tracked grandfather: app shell. New routing belongs in ContentView+*.swift.
struct ContentView: View {
    static let aiProcessingStatusDelayNanoseconds: UInt64 = 500_000_000

    enum ActiveRecordingMode: String {
        case none
        case dictate
        case promptMode
    }

    enum DictationOutputRoute: String {
        case normal
        case onboardingSandbox
    }

    @EnvironmentObject var appServices: AppServices
    @StateObject var mouseTracker = MousePositionTracker()
    @EnvironmentObject var menuBarManager: MenuBarManager
    @ObservedObject var settings = SettingsStore.shared

    /// Computed properties to access shared services from AppServices container
    /// This maintains backward compatibility with the existing code while
    /// removing the duplicate service instances that cause startup crashes.
    var asr: ASRService {
        self.appServices.asr
    }

    var audioObserver: AudioHardwareObserver {
        self.appServices.audioObserver
    }

    @Environment(\.theme) var theme
    @Environment(\.accessibilityReduceMotion) var accessibilityReduceMotion
    @State var hotkeyManager: GlobalHotkeyManager? = nil
    @State var hotkeyManagerInitialized: Bool = false

    @State var appear = false
    @State var accessibilityEnabled = false
    @State var primaryDictationShortcuts: [HotkeyShortcut] = SettingsStore.shared.primaryDictationShortcuts
    @State var promptModeHotkeyShortcut: HotkeyShortcut = SettingsStore.shared.promptModeHotkeyShortcut
    @State var cancelRecordingHotkeyShortcut: HotkeyShortcut = SettingsStore.shared.cancelRecordingHotkeyShortcut
    @State var pasteLastTranscriptionHotkeyShortcut: HotkeyShortcut? = SettingsStore.shared.pasteLastTranscriptionHotkeyShortcut
    @State var isPasteLastTranscriptionShortcutEnabled: Bool = SettingsStore.shared.pasteLastTranscriptionShortcutEnabled
    @State var translationInsertHotkeyShortcut: HotkeyShortcut? = SettingsStore.shared.translationInsertHotkeyShortcut
    @State var isTranslationInsertHotkeyEnabled: Bool = SettingsStore.shared.translationInsertHotkeyEnabled
    @State var captionListenHotkeyShortcut: HotkeyShortcut? = SettingsStore.shared.captionListenHotkeyShortcut
    @State var isCaptionListenHotkeyEnabled: Bool = SettingsStore.shared.captionListenHotkeyEnabled
    @State var isPromptModeShortcutEnabled: Bool = SettingsStore.shared.promptModeShortcutEnabled
    @State var promptModeOverrideText: String? // System prompt text to use when in prompt mode
    @State var activeDictationShortcutSlot: SettingsStore.DictationShortcutSlot? = nil
    @State var activeRecordingMode: ActiveRecordingMode = .none
    @State var pendingAIReprocessText: String? = nil
    @State var activeShortcutRecordingTarget: ShortcutRecordingTarget? = nil
    @State var currentRecordingModifierKeyCodes: Set<UInt16> = []
    @State var pendingModifierKeyCodes: Set<UInt16> = []
    @State var pendingModifierFlags: NSEvent.ModifierFlags = []
    @State var pendingModifierKeyCode: UInt16?
    @State var pendingModifierOnly = false
    @State var shortcutRecordingMessage: String? = nil
    @State var shortcutCaptureMonitor: Any?
    @FocusState var isTranscriptionFocused: Bool

    @State var selectedSidebarItem: SidebarItem?
    @State var previousSidebarItem: SidebarItem? = nil // Track previous for mode transitions
    @State var settingsNavigation = SettingsNavigationState()
    @State var settingsSearchQuery = ""
    @State var settingsSearchScrollRequest = 0

    @State var isSettingsEntryHovered = false
    @State var isSettingsBackHovered = false
    @State var playgroundUsed: Bool = SettingsStore.shared.playgroundUsed
    @State var settingsAISection: AIEnhancementConfigurationSection = .providers
    @State var recordingAppInfo: (name: String, bundleId: String, windowTitle: String)? = nil
    @State var recordingPrecedingText: String = ""
    @State var recordingFocusTarget: TypingService.CapturedFocusTarget? = nil

    // Audio Settings Tab State
    @State var visualizerNoiseThreshold: Double = SettingsStore.shared.visualizerNoiseThreshold
    @State var inputDevices: [AudioDevice.Device] = []
    @State var outputDevices: [AudioDevice.Device] = []
    // Populated by gated audio initialization; querying Core Audio while SwiftUI
    // constructs this view can race AttributeGraph metadata processing.
    @State var selectedInputUID: String = ""
    @State var selectedOutputUID: String = SettingsStore.shared.preferredOutputDeviceUID ?? ""

    // AI Prompts Tab State
    @State var aiInputText: String = ""
    @State var aiOutputText: String = ""
    @State var isCallingAI: Bool = false
    @State var openAIBaseURL: String = ""

    @State var enableDebugLogs: Bool = SettingsStore.shared.enableDebugLogs
    @State var hotkeyMode: HotkeyActivationMode = SettingsStore.shared.hotkeyMode
    @State var enableStreamingPreview: Bool = SettingsStore.shared.enableStreamingPreview
    @State var copyToClipboard: Bool = SettingsStore.shared.copyTranscriptionToClipboard

    // Preferences Tab State
    @State var launchAtStartup: Bool = SettingsStore.shared.launchAtStartup
    @State var showInDock: Bool = SettingsStore.shared.showInDock
    @State var showRestartPrompt: Bool = false
    @State var didOpenAccessibilityPane: Bool = false
    let accessibilityRestartFlagKey = "fluidSubtitles_AccessibilityRestartPending"
    let hasAutoRestartedForAccessibilityKey = "fluidSubtitles_HasAutoRestartedForAccessibility"
    @State var accessibilityPollingTask: Task<Void, Never>?
    @State var accessibilityGuidePanel: NSPanel?
    @State var accessibilityGuideMonitorTask: Task<Void, Never>?
    @State var accessibilityGuideRequestID: UUID?
    @State var prewarmDictationTask: Task<Void, Never>?
    @State var overlayLifecycleID: UInt64 = 0
    @State var spokenSendAutoStopTask: Task<Void, Never>?
    @State var spokenSendAutoStopTriggered = false
    @State var spokenSendCountdownStartedAt: TimeInterval?
    @State var spokenSendLastVoiceActivityAt: TimeInterval = 0
    @State var spokenSendVoiceActivityCancellable: AnyCancellable?

    var isRecordingAnyShortcutCapture: Bool {
        self.activeShortcutRecordingTarget != nil
    }

    // MARK: - Voice Recognition Model Management

    // Models scoped by provider (name -> [models])
    @State var availableModelsByProvider: [String: [String]] = [:]
    @State var selectedModelByProvider: [String: String] = [:]
    @State var availableModels: [String] = [] // derived from currentProvider
    @State var selectedModel: String = "" // derived from currentProvider
    @State var showingAddModel: Bool = false
    @State var newModelName: String = ""

    // Model Reasoning Configuration
    @State var showingReasoningConfig: Bool = false
    @State var editingReasoningParamName: String = "reasoning_effort"
    @State var editingReasoningParamValue: String = "low"
    @State var editingReasoningEnabled: Bool = false

    // MARK: - Provider Management

    @State var providerAPIKeys: [String: String] = [:] // [providerKey: apiKey]
    @State var currentProvider: String = "" // canonical key: "openai" | "groq" | "custom:<id>"

    @State var savedProviders: [SettingsStore.SavedProvider] = []
    @State var selectedProviderID: String = SettingsStore.shared.selectedProviderID
    @State var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        let layout = AnyView(
            Group {
                if self.settings.shouldShowOnboarding {
                    self.onboardingOnlyView
                } else {
                    NavigationSplitView(columnVisibility: self.$columnVisibility) {
                        self.sidebarContent
                            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
                    } detail: {
                        self.detailView
                    }
                    .navigationSplitViewStyle(.balanced)
                }
            }
        )

        let tracked = layout.withMouseTracking(self.mouseTracker)
        let env = tracked.environmentObject(self.mouseTracker)
        let nav = env.onChange(of: self.menuBarManager.requestedNavigationDestination) { _, destination in
            self.handleMenuBarNavigation(destination)
        }
        let sized = nav.fluidWindowSizing(self.windowSizing)

        let observed = self.applyShortcutStateChanges(to: sized)

        return observed
            .background(TranslationSessionHost())
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                self.refreshAccessibilityPermissionState()
            }
            .onReceive(NotificationCenter.default.publisher(for: .openCustomDictionaryFromVoiceEngine)) { _ in
                self.navigateToApp(.customDictionary)
            }
            .onReceive(NotificationCenter.default.publisher(for: .appNavigationRequested)) { _ in
                self.handlePendingAppNavigation()
            }
            .onReceive(NotificationCenter.default.publisher(for: .dictationPromptShortcutsChanged)) { _ in
                self.hotkeyManager?.updatePromptShortcutAssignments(SettingsStore.shared.dictationPromptShortcutAssignments())
            }
            .onReceive(NotificationCenter.default.publisher(for: .settingsBackupDidRestore)) { _ in
                self.reloadSettingsStateAfterBackupRestore()
            }
            .onReceive(self.asr.$partialTranscription) { text in
                self.handleSpokenSendPartialTranscription(text)
            }
            .toolbar {
                if !self.settings.shouldShowOnboarding {
                    ToolbarItemGroup(placement: .primaryAction) {
                        self.todayStatsButton

                        self.themePreferenceButton

                        Button(action: self.openIssueReportingPage) {
                            Image(systemName: "ladybug.fill")
                        }
                        .help("Report an issue")
                        .accessibilityLabel("Report an issue")
                    }
                }
            }
            .toolbar(removing: .sidebarToggle)
            .overlay(alignment: .center) {}
            .alert(
                self.asr.errorTitle,
                isPresented: Binding(
                    get: { self.asr.showError },
                    set: { self.asr.showError = $0 }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(self.asr.errorMessage)
            }
            .onChange(of: self.audioObserver.changeTick) { _, _ in
                // Hardware change detected → refresh device lists
                self.refreshDevices()

                if let sysOut = AudioDevice.getDefaultOutputDevice()?.uid {
                    self.selectedOutputUID = sysOut
                }
            }
            .onChange(of: self.audioObserver.inputAvailabilityTick) { _, _ in
                self.refreshInputDevices()
            }
            .onDisappear {
                Task { await self.asr.stopWithoutTranscription() }
                self.cancelPrewarmDictationIfNeeded()
                // Note: Overlay lifecycle is now managed by MenuBarManager
                // Note: NotchContentState handlers capture self (a struct value copy) and are
                // intentionally kept alive so the overlay remains fully functional when the
                // settings window is closed. No retain cycle risk since ContentView is a value type.

                // Stop accessibility polling
                self.finishAccessibilityPermissionFlow()
                self.removeShortcutCaptureMonitor()
            }
            .onChange(of: self.primaryDictationShortcuts) { _, newValue in
                SettingsStore.shared.primaryDictationShortcuts = newValue
                let storedShortcuts = SettingsStore.shared.primaryDictationShortcuts
                if storedShortcuts != newValue {
                    self.primaryDictationShortcuts = storedShortcuts
                    return
                }

                let display = storedShortcuts.map(\.displayString).joined(separator: ", ")
                DebugLogger.shared.debug("Primary dictation shortcuts changed to \(display)", source: "ContentView")
                self.hotkeyManager?.updatePrimaryShortcuts(storedShortcuts)

                // Update initialization status after shortcut change
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.hotkeyManagerInitialized = self.hotkeyManager?.validateEventTapHealth() ?? false
                    DebugLogger.shared.debug(
                        "Hotkey manager initialized: \(self.hotkeyManagerInitialized)",
                        source: "ContentView"
                    )
                }
            }
            .onChange(of: self.selectedSidebarItem) { _, newValue in
                self.handleModeTransition(from: self.previousSidebarItem, to: newValue)
                self.previousSidebarItem = newValue
            }
    }

    func applyShortcutStateChanges<Content: View>(to view: Content) -> some View {
        view
            .onAppear {
                self.handleContentAppear()
            }
            .onChange(of: self.accessibilityEnabled) { _, enabled in
                if enabled {
                    self.finishAccessibilityPermissionFlow()
                }

                if enabled && self.hotkeyManager != nil && !self.hotkeyManagerInitialized {
                    DebugLogger.shared.debug("Accessibility enabled, reinitializing hotkey manager", source: "ContentView")
                    self.hotkeyManager?.reinitialize()
                }
            }
            .onChange(of: self.selectedModel) { _, newValue in
                if newValue != "__ADD_MODEL__" {
                    self.selectedModelByProvider[self.currentProvider] = newValue
                    SettingsStore.shared.selectedModelByProvider = self.selectedModelByProvider
                }
            }
            .onChange(of: self.selectedProviderID) { _, newValue in
                SettingsStore.shared.selectedProviderID = newValue
            }
            .onChange(of: self.activeShortcutRecordingTarget) { _, _ in
                self.hotkeyManager?.resetModifierOnlyShortcutTracking()
            }
            .onChange(of: self.isPromptModeShortcutEnabled) { _, newValue in
                self.handlePromptShortcutEnabledChange(newValue)
            }
            .onChange(of: self.pasteLastTranscriptionHotkeyShortcut) { _, newValue in
                SettingsStore.shared.pasteLastTranscriptionHotkeyShortcut = newValue
                self.hotkeyManager?.refreshMouseShortcutTapIfNeeded()
            }
            .onChange(of: self.isPasteLastTranscriptionShortcutEnabled) { _, newValue in
                self.handlePasteLastTranscriptionShortcutEnabledChange(newValue)
            }
            .onChange(of: self.translationInsertHotkeyShortcut) { _, newValue in
                SettingsStore.shared.translationInsertHotkeyShortcut = newValue
            }
            .onChange(of: self.isTranslationInsertHotkeyEnabled) { _, newValue in
                SettingsStore.shared.translationInsertHotkeyEnabled = newValue
                if !newValue, self.activeShortcutRecordingTarget == .translateInsert {
                    self.clearShortcutRecordingMode()
                }
            }
            .onChange(of: self.captionListenHotkeyShortcut) { _, newValue in
                SettingsStore.shared.captionListenHotkeyShortcut = newValue
            }
            .onChange(of: self.isCaptionListenHotkeyEnabled) { _, newValue in
                SettingsStore.shared.captionListenHotkeyEnabled = newValue
                if !newValue, self.activeShortcutRecordingTarget == .captionListen {
                    self.clearShortcutRecordingMode()
                }
            }
    }

    func handlePasteLastTranscriptionShortcutEnabledChange(_ isEnabled: Bool) {
        SettingsStore.shared.pasteLastTranscriptionShortcutEnabled = isEnabled
        self.hotkeyManager?.refreshMouseShortcutTapIfNeeded()
        if !isEnabled, self.activeShortcutRecordingTarget == .pasteLast {
            self.clearShortcutRecordingMode()
        }
    }

    func handlePromptShortcutEnabledChange(_ isEnabled: Bool) {
        SettingsStore.shared.promptModeShortcutEnabled = isEnabled
        self.hotkeyManager?.updatePromptModeShortcutEnabled(isEnabled)

        if !isEnabled {
            if self.activeShortcutRecordingTarget == .secondaryDictation {
                self.clearShortcutRecordingMode()
            }

            if self.activeRecordingMode == .promptMode {
                if self.asr.isRunning {
                    Task { await self.asr.stopWithoutTranscription() }
                }
                self.cancelPrewarmDictationIfNeeded()
                self.clearActiveRecordingMode()
                self.menuBarManager.setOverlayMode(.dictation)
            }
        }
    }

    func handleContentAppear() {
        self.appear = true
        self.refreshAccessibilityPermissionState()

        Task {
            await AudioStartupGate.shared.scheduleOpenAfterInitialUISettled()
        }

        self.handleMenuBarNavigation(self.menuBarManager.requestedNavigationDestination)
        if UserDefaults.standard.bool(forKey: self.accessibilityRestartFlagKey) {
            UserDefaults.standard.set(false, forKey: self.accessibilityRestartFlagKey)
            self.showRestartPrompt = false
        }

        if self.accessibilityEnabled {
            self.finishAccessibilityPermissionFlow()
        }

        if self.selectedSidebarItem == nil, !self.settingsNavigation.isPresented {
            self.selectedSidebarItem = .liveTranslation
        }
        self.handlePendingAppNavigation()

        if !self.accessibilityEnabled {
            UserDefaults.standard.set(false, forKey: self.hasAutoRestartedForAccessibilityKey)
        }

        self.menuBarManager.initializeMenuBar()
        self.scheduleDelayedAudioInitialization()
        self.configureNotchCallbacks()
        self.startAccessibilityPolling()
        self.initializeHotkeyManagerIfNeeded()

        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await self.preloadASRModel()
        }

        self.loadProviderState()
        self.installShortcutCaptureMonitor()
    }

    func scheduleDelayedAudioInitialization() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            DebugLogger.shared.info("🚦 Startup delay complete, signaling UI ready...", source: "ContentView")
            self.appServices.signalUIReady()

            Task { @MainActor in
                await AudioStartupGate.shared.scheduleOpenAfterInitialUISettled()
                await AudioStartupGate.shared.waitUntilOpen()

                DebugLogger.shared.info("🔊 Starting gated audio initialization...", source: "ContentView")
                self.audioObserver.startObserving()
                await self.asr.initialize()
                self.menuBarManager.configure(asrService: self.appServices.asr)
                self.refreshDevices()

                if self.selectedOutputUID.isEmpty, let defOut = AudioDevice.getDefaultOutputDevice()?.uid {
                    self.selectedOutputUID = defOut
                }

                if let prefOut = SettingsStore.shared.preferredOutputDeviceUID,
                   !prefOut.isEmpty,
                   outputDevices.first(where: { $0.uid == prefOut }) != nil
                {
                    self.selectedOutputUID = prefOut
                }

                DebugLogger.shared.info("✅ Audio subsystems initialized", source: "ContentView")
            }
        }
    }

    func configureNotchCallbacks() {}

    func loadProviderState() {
        self.selectedProviderID = SettingsStore.shared.selectedProviderID
        self.updateCurrentProvider()

        self.enableDebugLogs = SettingsStore.shared.enableDebugLogs
        self.availableModelsByProvider = SettingsStore.shared.availableModelsByProvider
        self.selectedModelByProvider = SettingsStore.shared.selectedModelByProvider
        self.providerAPIKeys = SettingsStore.shared.providerAPIKeys
        self.savedProviders = SettingsStore.shared.savedProviders

        var normalized: [String: [String]] = [:]
        for (key, models) in self.availableModelsByProvider {
            let lower = key.lowercased()
            let newKey = ModelRepository.shared.isBuiltIn(lower) ? lower : (key.hasPrefix("custom:") ? key : "custom:\(key)")
            let clean = Array(Set(models.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })).sorted()
            if !clean.isEmpty {
                normalized[newKey] = clean
            }
        }
        self.availableModelsByProvider = normalized
        SettingsStore.shared.availableModelsByProvider = normalized

        var normalizedSel: [String: String] = [:]
        for (key, model) in self.selectedModelByProvider {
            let lower = key.lowercased()
            let newKey = ModelRepository.shared.isBuiltIn(lower) ? lower : (key.hasPrefix("custom:") ? key : "custom:\(key)")
            if let list = normalized[newKey], list.contains(model) {
                normalizedSel[newKey] = model
            }
        }
        self.selectedModelByProvider = normalizedSel
        SettingsStore.shared.selectedModelByProvider = normalizedSel

        if let saved = savedProviders.first(where: { $0.id == selectedProviderID }) {
            self.availableModels = saved.models
            self.openAIBaseURL = saved.baseURL
        } else if let stored = availableModelsByProvider[currentProvider], !stored.isEmpty {
            self.availableModels = stored
        } else {
            self.availableModels = ModelRepository.shared.defaultModels(for: self.providerKey(for: self.selectedProviderID))
        }

        if let sel = selectedModelByProvider[currentProvider], availableModels.contains(sel) {
            self.selectedModel = sel
        } else if let first = availableModels.first {
            self.selectedModel = first
        }
    }

    func installShortcutCaptureMonitor() {
        self.removeShortcutCaptureMonitor()
        self.shortcutCaptureMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { event in
            self.handleShortcutCaptureEvent(event)
        }
    }

    func removeShortcutCaptureMonitor() {
        guard let monitor = self.shortcutCaptureMonitor else { return }
        NSEvent.removeMonitor(monitor)
        self.shortcutCaptureMonitor = nil
    }

    func handleShortcutCaptureEvent(_ event: NSEvent) -> NSEvent? {
        let eventModifiers = event.modifierFlags.intersection([.function, .command, .option, .control, .shift])
        let isRecordingAnyShortcut = self.isRecordingAnyShortcutCapture
        let recordingTarget = self.activeShortcutRecordingTarget

        if event.type == .keyDown {
            return self.handleShortcutKeyDownEvent(event, modifiers: eventModifiers, isRecordingAnyShortcut: isRecordingAnyShortcut, recordingTarget: recordingTarget)
        } else if event.type == .flagsChanged {
            return self.handleShortcutFlagsChangedEvent(event, modifiers: eventModifiers, isRecordingAnyShortcut: isRecordingAnyShortcut, recordingTarget: recordingTarget)
        } else if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown {
            return self.handleShortcutMouseDownEvent(event, modifiers: eventModifiers, isRecordingAnyShortcut: isRecordingAnyShortcut, recordingTarget: recordingTarget)
        }

        return event
    }

    func handleShortcutKeyDownEvent(
        _ event: NSEvent,
        modifiers eventModifiers: NSEvent.ModifierFlags,
        isRecordingAnyShortcut: Bool,
        recordingTarget: ShortcutRecordingTarget?
    ) -> NSEvent? {
        guard isRecordingAnyShortcut else {
            if self.cancelRecordingHotkeyShortcut.matches(keyCode: event.keyCode, modifiers: eventModifiers),
               self.handleCancelShortcut()
            {
                return nil
            }
            self.shortcutRecordingMessage = nil
            self.resetPendingShortcutState()
            return event
        }

        let keyCode = event.keyCode
        if keyCode == 53, recordingTarget != .cancel {
            DebugLogger.shared.debug("NSEvent monitor: Escape pressed, cancelling shortcut recording", source: "ContentView")
            self.clearShortcutRecordingMode()
            return nil
        }

        let newShortcut = HotkeyShortcut(keyCode: keyCode, modifierFlags: self.pendingModifierFlags.union(eventModifiers))
        DebugLogger.shared.debug("NSEvent monitor: Recording new shortcut: \(newShortcut.displayString)", source: "ContentView")

        if let recordingTarget,
           let conflictMessage = self.shortcutConflictMessage(for: newShortcut, target: recordingTarget)
        {
            self.shortcutRecordingMessage = conflictMessage
            self.resetPendingShortcutState()
            DebugLogger.shared.debug("NSEvent monitor: Shortcut conflict while recording: \(conflictMessage)", source: "ContentView")
            return nil
        }

        self.shortcutRecordingMessage = nil
        if let recordingTarget {
            self.assignRecordedShortcut(newShortcut, to: recordingTarget)
        }
        self.resetPendingShortcutState()
        DebugLogger.shared.debug("NSEvent monitor: Finished recording shortcut", source: "ContentView")
        return nil
    }

    func handleShortcutMouseDownEvent(
        _ event: NSEvent,
        modifiers eventModifiers: NSEvent.ModifierFlags,
        isRecordingAnyShortcut: Bool,
        recordingTarget: ShortcutRecordingTarget?
    ) -> NSEvent? {
        guard isRecordingAnyShortcut else {
            self.shortcutRecordingMessage = nil
            self.resetPendingShortcutState()
            return event
        }

        let newShortcut = HotkeyShortcut(mouseButton: event.buttonNumber, modifierFlags: self.pendingModifierFlags.union(eventModifiers))
        DebugLogger.shared.debug("NSEvent monitor: Recording new mouse shortcut: \(newShortcut.displayString)", source: "ContentView")

        if newShortcut.isUnmodifiedLeftOrRightClick, let mouseButton = newShortcut.mouseButton {
            self.shortcutRecordingMessage = "\(HotkeyShortcut.mouseButtonToString(mouseButton)) needs a modifier key"
            self.resetPendingShortcutState()
            return event
        }

        if let recordingTarget,
           let conflictMessage = self.shortcutConflictMessage(for: newShortcut, target: recordingTarget)
        {
            self.shortcutRecordingMessage = conflictMessage
            self.resetPendingShortcutState()
            DebugLogger.shared.debug("NSEvent monitor: Mouse shortcut conflict while recording: \(conflictMessage)", source: "ContentView")
            return nil
        }

        self.shortcutRecordingMessage = nil
        if let recordingTarget {
            self.assignRecordedShortcut(newShortcut, to: recordingTarget)
        }
        self.resetPendingShortcutState()
        DebugLogger.shared.debug("NSEvent monitor: Finished recording mouse shortcut", source: "ContentView")
        return nil
    }

    func handleShortcutFlagsChangedEvent(
        _ event: NSEvent,
        modifiers eventModifiers: NSEvent.ModifierFlags,
        isRecordingAnyShortcut: Bool,
        recordingTarget: ShortcutRecordingTarget?
    ) -> NSEvent? {
        guard isRecordingAnyShortcut else {
            self.shortcutRecordingMessage = nil
            self.resetPendingShortcutState()
            return event
        }

        let changedModifierFlag = HotkeyShortcut.modifierFlag(forKeyCode: event.keyCode)

        if eventModifiers.isEmpty {
            if self.pendingModifierOnly, let modifierKeyCode = pendingModifierKeyCode {
                let newShortcut = HotkeyShortcut(
                    keyCode: modifierKeyCode,
                    modifierFlags: self.pendingModifierFlags,
                    modifierKeyCodes: Array(self.pendingModifierKeyCodes)
                )
                DebugLogger.shared.debug("NSEvent monitor: Recording modifier-only shortcut: \(newShortcut.displayString)", source: "ContentView")

                if let recordingTarget,
                   let conflictMessage = self.shortcutConflictMessage(for: newShortcut, target: recordingTarget)
                {
                    self.shortcutRecordingMessage = conflictMessage
                    self.resetPendingShortcutState()
                    DebugLogger.shared.debug("NSEvent monitor: Modifier shortcut conflict while recording: \(conflictMessage)", source: "ContentView")
                    return nil
                }

                self.shortcutRecordingMessage = nil
                if let recordingTarget {
                    self.assignRecordedShortcut(newShortcut, to: recordingTarget)
                }
                self.resetPendingShortcutState()
                DebugLogger.shared.debug("NSEvent monitor: Finished recording modifier shortcut", source: "ContentView")
                return nil
            }

            self.resetPendingShortcutState()
            DebugLogger.shared.debug("NSEvent monitor: Modifiers released without recording, continuing to wait", source: "ContentView")
            return nil
        }

        if let changedModifierFlag {
            let isRelease = self.currentRecordingModifierKeyCodes.contains(event.keyCode)

            if isRelease {
                self.currentRecordingModifierKeyCodes.remove(event.keyCode)
            } else if eventModifiers.contains(changedModifierFlag) {
                self.currentRecordingModifierKeyCodes.insert(event.keyCode)
                self.pendingModifierKeyCodes.insert(event.keyCode)
                self.pendingModifierFlags = self.pendingModifierFlags.union(eventModifiers)
                self.pendingModifierKeyCode = event.keyCode
                self.pendingModifierOnly = true
                DebugLogger.shared.debug("NSEvent monitor: Modifier key pressed during recording, pending modifiers: \(self.pendingModifierFlags)", source: "ContentView")
            }
        }
        return nil
    }

    func currentDictationAIModelInfo(
        dictationSlot: SettingsStore.DictationShortcutSlot? = nil,
        appBundleID: String? = nil
    ) -> (provider: String?, model: String?) {
        let route = DictationProviderRoute.resolve(
            settings: SettingsStore.shared,
            dictationSlot: dictationSlot,
            appBundleID: appBundleID
        )
        let providerOut = route.providerKey.isEmpty ? nil : route.providerKey
        let modelOut = route.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : route.model
        return (provider: providerOut, model: modelOut)
    }

    func currentTranscriptionModelInfo() -> (provider: String, model: String) {
        let selectedModel = SettingsStore.shared.selectedSpeechModel
        return (
            provider: selectedModel.provider.rawValue.lowercased(),
            model: selectedModel.rawValue
        )
    }

    // MARK: - Mode Transition Handler

    /// Centralized handler for sidebar mode transitions to ensure proper cleanup and state management
    func handleModeTransition(from oldValue: SidebarItem?, to newValue: SidebarItem?) {
        DebugLogger.shared.debug("Mode transition: \(String(describing: oldValue)) → \(String(describing: newValue))", source: "ContentView")

        if oldValue != newValue {
            self.clearShortcutRecordingMode()
        }

        self.menuBarManager.setOverlayMode(.dictation)
    }

    @MainActor
    func handleMenuBarNavigation(_ destination: MenuBarNavigationDestination?) {
        guard let destination else { return }
        guard !self.settings.shouldShowOnboarding else { return }

        switch destination {
        case .liveTranslation:
            self.navigateToApp(.liveTranslation)
        case .customDictionary:
            self.navigateToApp(.customDictionary)
        case .microphoneSettings:
            self.openSettings(.audio)
        case .settings:
            self.openSettings(.translation)
        }
    }

    func handlePendingAppNavigation() {
        guard let destination = AppNavigationRouter.shared.consumePendingDestination() else { return }

        switch destination {
        case .aiEnhancements:
            self.navigateToApp(.aiEnhancements)
        case .history:
            self.navigateToApp(.history)
        }
    }

    func navigateToApp(_ destination: SidebarItem) {
        if destination == .aiEnhancements {
            self.settingsAISection = .providers
            self.openSettings(.aiProviders)
            return
        }
        if destination == .cleanupStyles {
            self.settingsAISection = .advancedPrompts
            self.openSettings(.aiProviders)
            return
        }

        self.clearShortcutRecordingMode()
        self.resetSettingsSearch()
        self.settingsNavigation.leaveForApp()
        self.selectedSidebarItem = destination
    }

    func openSettings(_ section: SettingsSection) {
        self.clearShortcutRecordingMode()
        self.resetSettingsSearch()
        self.settingsNavigation.present(section, returningTo: self.selectedSidebarItem)
    }

    func closeSettings() {
        self.clearShortcutRecordingMode()
        self.resetSettingsSearch()
        self.selectedSidebarItem = self.settingsNavigation.dismiss()
    }

    func resetSettingsSearch() {
        self.settingsSearchQuery = ""
        self.settingsSearchScrollRequest += 1
    }

    func resetPendingShortcutState() {
        self.currentRecordingModifierKeyCodes = []
        self.pendingModifierKeyCodes = []
        self.pendingModifierFlags = []
        self.pendingModifierKeyCode = nil
        self.pendingModifierOnly = false
    }

    func shortcutConflictMessage(for shortcut: HotkeyShortcut, target: ShortcutRecordingTarget) -> String? {
        if shortcut.isMouseShortcut {
            guard target.allowsMouseShortcut else {
                return "Mouse clicks can only be assigned to Primary Dictation or Paste Last Transcription"
            }

            if shortcut.isUnmodifiedLeftOrRightClick, let mouseButton = shortcut.mouseButton {
                return "\(HotkeyShortcut.mouseButtonToString(mouseButton)) needs a modifier key"
            }
        }

        let replacingPrimaryIndex = target.primaryDictationReplacementIndex
        for (index, configuredShortcut) in self.primaryDictationShortcuts.enumerated() where replacingPrimaryIndex != index {
            if configuredShortcut == shortcut {
                return "Duplicate with Primary Dictation Shortcut"
            }
            if shortcut.conflictsWith(configuredShortcut) {
                return "Overlaps Primary Dictation Shortcut — use a different modifier key"
            }
        }

        var configuredShortcuts: [(ShortcutRecordingTarget, HotkeyShortcut)] = [
            (.cancel, self.cancelRecordingHotkeyShortcut),
        ]
        if self.isPromptModeShortcutEnabled {
            configuredShortcuts.append((.secondaryDictation, self.promptModeHotkeyShortcut))
        }
        let optionalConfiguredShortcuts: [(ShortcutRecordingTarget, HotkeyShortcut?)] = [
            (.pasteLast, self.pasteLastTranscriptionHotkeyShortcut),
            (.translateInsert, self.translationInsertHotkeyShortcut),
            (.captionListen, self.captionListenHotkeyShortcut),
        ]

        for (otherTarget, configuredShortcut) in configuredShortcuts where otherTarget != target {
            if configuredShortcut == shortcut {
                return "Duplicate with \(otherTarget.title)"
            }
            if shortcut.conflictsWith(configuredShortcut) {
                return "Overlaps \(otherTarget.title) — use a different modifier key"
            }
        }
        for (otherTarget, configuredShortcut) in optionalConfiguredShortcuts where otherTarget != target {
            guard let configuredShortcut else { continue }
            if configuredShortcut == shortcut {
                return "Duplicate with \(otherTarget.title)"
            }
            if shortcut.conflictsWith(configuredShortcut) {
                return "Overlaps \(otherTarget.title) — use a different modifier key"
            }
        }

        let targetPromptKey = target.promptConfigurationKey
        for assignment in SettingsStore.shared.dictationPromptShortcutAssignments() {
            guard let key = SettingsStore.shared.dictationPromptConfigurationKey(for: assignment.selection),
                  key != targetPromptKey
            else {
                continue
            }
            if assignment.shortcut == shortcut {
                return "Duplicate with Prompt Shortcut"
            }
            if shortcut.conflictsWith(assignment.shortcut) {
                return "Overlaps Prompt Shortcut — use a different modifier key"
            }
        }

        return nil
    }

    func assignRecordedShortcut(_ shortcut: HotkeyShortcut, to target: ShortcutRecordingTarget) {
        self.applyRecordedShortcut(shortcut, to: target)
        if target.enablesFeatureOnAssignment {
            self.setShortcutTargetEnabled(true, for: target)
        }
        self.setShortcutRecording(false, for: target)
    }

    func applyRecordedShortcut(_ shortcut: HotkeyShortcut, to target: ShortcutRecordingTarget) {
        switch target {
        case let .primaryDictation(edit):
            self.applyPrimaryDictationShortcut(shortcut, edit: edit)
        case .secondaryDictation:
            self.promptModeHotkeyShortcut = shortcut
            SettingsStore.shared.promptModeHotkeyShortcut = shortcut
            self.hotkeyManager?.updatePromptModeShortcut(shortcut)
        case .cancel:
            self.cancelRecordingHotkeyShortcut = shortcut
            SettingsStore.shared.cancelRecordingHotkeyShortcut = shortcut
        case .pasteLast:
            // The hotkey manager reads this shortcut directly from SettingsStore, so no manager update is needed.
            self.pasteLastTranscriptionHotkeyShortcut = shortcut
            SettingsStore.shared.pasteLastTranscriptionHotkeyShortcut = shortcut
        case .translateInsert:
            self.translationInsertHotkeyShortcut = shortcut
            SettingsStore.shared.translationInsertHotkeyShortcut = shortcut
        case .captionListen:
            self.captionListenHotkeyShortcut = shortcut
            SettingsStore.shared.captionListenHotkeyShortcut = shortcut
        case let .dictationPrompt(key):
            guard let selection = SettingsStore.shared.dictationPromptSelection(forConfigurationKey: key) else { return }
            var configuration = SettingsStore.shared.dictationPromptConfiguration(for: selection)
            configuration.shortcut = shortcut
            SettingsStore.shared.setDictationPromptConfiguration(configuration, for: selection)
            self.hotkeyManager?.updatePromptShortcutAssignments(SettingsStore.shared.dictationPromptShortcutAssignments())
        case .newPrompt:
            NotificationCenter.default.post(
                name: .newPromptShortcutRecorded,
                object: nil,
                userInfo: ["shortcut": shortcut]
            )
        }
    }

    func applyPrimaryDictationShortcut(_ shortcut: HotkeyShortcut, edit: PrimaryDictationShortcutEdit) {
        var shortcuts = self.primaryDictationShortcuts
        switch edit {
        case .add:
            shortcuts.append(shortcut)
        case let .replace(index):
            if shortcuts.indices.contains(index) {
                shortcuts[index] = shortcut
            } else {
                shortcuts.append(shortcut)
            }
        }
        self.primaryDictationShortcuts = shortcuts
    }

    func setShortcutTargetEnabled(_ enabled: Bool, for target: ShortcutRecordingTarget) {
        switch target {
        case .secondaryDictation:
            self.isPromptModeShortcutEnabled = enabled
            SettingsStore.shared.promptModeShortcutEnabled = enabled
            self.hotkeyManager?.updatePromptModeShortcutEnabled(enabled)
        case .pasteLast:
            self.isPasteLastTranscriptionShortcutEnabled = enabled
            SettingsStore.shared.pasteLastTranscriptionShortcutEnabled = enabled
        case .translateInsert:
            self.isTranslationInsertHotkeyEnabled = enabled
            SettingsStore.shared.translationInsertHotkeyEnabled = enabled
        case .captionListen:
            self.isCaptionListenHotkeyEnabled = enabled
            SettingsStore.shared.captionListenHotkeyEnabled = enabled
        case .primaryDictation, .cancel, .dictationPrompt, .newPrompt:
            break
        }
    }

    func setShortcutRecording(_ isRecording: Bool, for target: ShortcutRecordingTarget) {
        if isRecording {
            self.activeShortcutRecordingTarget = target
        } else if self.activeShortcutRecordingTarget == target {
            self.activeShortcutRecordingTarget = nil
        }
    }

    func clearShortcutRecordingMode() {
        self.activeShortcutRecordingTarget = nil
        self.shortcutRecordingMessage = nil
        self.resetPendingShortcutState()
    }

    func openIssueReportingPage() {
        guard let url = FluidProduct.issuesURL else { return }
        NSWorkspace.shared.open(url)
    }

    var sidebarContent: some View {
        ZStack {
            // Keep both sidebars mounted so navigation feedback never waits on view construction.
            self.appSidebarView
                .opacity(self.settingsNavigation.isPresented ? 0 : 1)
                .offset(x: self.settingsNavigation.isPresented ? -self.sidebarTransitionDistance : 0)
                .allowsHitTesting(!self.settingsNavigation.isPresented)
                .accessibilityHidden(self.settingsNavigation.isPresented)

            self.settingsSidebarView
                .background(self.theme.palette.sidebarBackground)
                .opacity(self.settingsNavigation.isPresented ? 1 : 0)
                .offset(x: self.settingsNavigation.isPresented ? 0 : self.sidebarTransitionDistance)
                .allowsHitTesting(self.settingsNavigation.isPresented)
                .accessibilityHidden(!self.settingsNavigation.isPresented)
        }
        .clipped()
        .navigationTitle(self.settingsNavigation.isPresented ? "Settings" : FluidProduct.displayName)
        .tint(self.theme.palette.accent)
        .animation(self.modeTransitionAnimation, value: self.settingsNavigation.isPresented)
    }



    var aiEnhancementConfigurationSectionBinding: Binding<AIEnhancementConfigurationSection> {
        Binding(
            get: {
                if self.settingsNavigation.selectedSection == .aiProviders {
                    return self.settingsAISection
                }
                return self.selectedSidebarItem?.aiEnhancementConfigurationSection ?? self.settingsAISection
            },
            set: { section in
                self.settingsAISection = section
                if self.settingsNavigation.selectedSection == .aiProviders {
                    return
                }
                guard self.selectedSidebarItem != section.sidebarItem else { return }
                self.navigateToApp(section.sidebarItem)
            }
        )
    }

    var onboardingOnlyView: some View {
        OnboardingFlowView(
            currentStep: Binding(
                get: { self.settings.onboardingCurrentStep },
                set: { self.settings.onboardingCurrentStep = $0 }
            ),
            accessibilityEnabled: self.accessibilityEnabled,
            accessibilitySetupInProgress: self.didOpenAccessibilityPane,
            finishOnboarding: {
                self.completeOnboardingIfPossible()
            },
            finishOnboardingAtTranslate: {
                PresenterCaptionController.shared.setVisible(true)
                self.completeOnboardingIfPossible(selecting: .liveTranslation)
            },
            openAccessibilitySettings: self.openAccessibilitySettings,
            restartApp: self.restartApp,
            startRecording: self.startRecording,
            startCaptionListening: self.startCaptionListening,
            stopAndProcessTranscription: { await self.stopAndProcessTranscription() },
            menuBarManager: self.menuBarManager,
            activeShortcutRecordingTarget: self.$activeShortcutRecordingTarget,
            shortcutRecordingMessage: self.$shortcutRecordingMessage,
            theme: self.theme
        )
        .environmentObject(self.appServices)
    }

    // MARK: - Welcome Guide

    var welcomeView: some View {
        WelcomeView(
            selectedSidebarItem: self.$selectedSidebarItem,
            accessibilityEnabled: self.accessibilityEnabled,
            openAccessibilitySettings: self.openAccessibilitySettings
        )
    }

    // MARK: - Microphone Permission View (Kept inline for RecordingView)

    var microphonePermissionView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                // Status indicator
                Circle()
                    .fill(self.asr.micStatus == .authorized ? self.theme.palette.success : self.theme.palette.warning)
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 4) {
                    Text(self.labelFor(status: self.asr.micStatus))
                        .fontWeight(.medium)
                        .foregroundStyle(self.asr.micStatus == .authorized ? self.theme.palette.primaryText : self.theme.palette.warning)

                    if self.asr.micStatus != .authorized {
                        Text("Microphone access is required for voice recording")
                            .font(self.theme.typography.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()

                self.microphoneActionButton
            }

            // Step-by-step instructions when microphone is not authorized
            if self.asr.micStatus != .authorized {
                self.microphoneInstructionsView
            }
        }
    }

    var windowSizing: FluidWindowSizing {
        let window = self.theme.metrics.window
        if self.settings.shouldShowOnboarding {
            return .minimum(width: window.onboardingMinWidth, height: window.onboardingMinHeight)
        }
        return .minimum(width: window.mainMinWidth, height: window.mainMinHeight)
    }

    var microphoneActionButton: some View {
        Group {
            if self.asr.micStatus == .notDetermined {
                Button {
                    self.asr.requestMicAccess()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "mic.fill")
                        Text("Grant Access")
                            .fontWeight(.medium)
                    }
                }
                .buttonStyle(GlassButtonStyle())
                .buttonHoverEffect()
            } else if self.asr.micStatus == .denied {
                Button {
                    self.asr.openSystemSettingsForMic()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "gear")
                        Text("Open Settings")
                            .fontWeight(.medium)
                    }
                }
                .buttonStyle(GlassButtonStyle())
                .buttonHoverEffect()
            }
        }
    }

    var microphoneInstructionsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(self.theme.palette.accent)
                    .font(self.theme.typography.caption)
                Text("How to enable microphone access:")
                    .font(self.theme.typography.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                if self.asr.micStatus == .notDetermined {
                    self.instructionStep(number: "1", text: "Click **Grant Access** above")
                    self.instructionStep(number: "2", text: "Choose **Allow** in the system dialog")
                } else if self.asr.micStatus == .denied {
                    self.instructionStep(number: "1", text: "Click **Open Settings** above")
                    self.instructionStep(number: "2", text: "Find **\(FluidProduct.displayName)** in the microphone list")
                    self.instructionStep(number: "3", text: "Toggle **\(FluidProduct.displayName) ON** to allow access")
                }
            }
            .padding(.leading, 4)
        }
        .padding(12)
        .background(self.theme.palette.accent.opacity(0.12))
        .cornerRadius(8)
    }

    func instructionStep(number: String, text: String) -> some View {
        HStack(spacing: 8) {
            Text(number + ".")
                .font(self.theme.typography.captionSmall)
                .foregroundStyle(self.theme.palette.accent)
                .fontWeight(.semibold)
                .frame(width: 16)
            Text(text)
                .font(self.theme.typography.caption)
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Preferences View

    @ViewBuilder
    var preferencesView: some View {
        if self.isSettingsSearchActive, self.settingsSearchResults.isEmpty {
            ContentUnavailableView {
                Label("No Settings Found", systemImage: "magnifyingglass")
            } description: {
                Text("No settings match “\(self.settingsSearchQuery)”.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        } else if self.settingsNavigation.selectedSection == .aiProviders {
            AIEnhancementSettingsScreen(
                menuBarManager: self.menuBarManager,
                theme: self.theme,
                selectedConfigurationSection: self.aiEnhancementConfigurationSectionBinding,
                activeShortcutRecordingTarget: self.$activeShortcutRecordingTarget,
                shortcutRecordingMessage: self.$shortcutRecordingMessage
            )
        } else {
            SettingsView(
                selectedSection: self.settingsNavigation.selectedSection ?? .general,
                searchResults: self.settingsSearchResults,
                searchScrollRequest: self.settingsSearchScrollRequest,
                microphonePreferenceCoordinator: self.appServices.microphonePreferenceCoordinator,
                appear: self.$appear,
                visualizerNoiseThreshold: self.$visualizerNoiseThreshold,
                selectedInputUID: self.$selectedInputUID,
                selectedOutputUID: self.$selectedOutputUID,
                inputDevices: self.$inputDevices,
                outputDevices: self.$outputDevices,
                accessibilityEnabled: self.$accessibilityEnabled,
                primaryDictationShortcuts: self.$primaryDictationShortcuts,
                activeShortcutRecordingTarget: self.$activeShortcutRecordingTarget,
                shortcutRecordingMessage: self.$shortcutRecordingMessage,
                cancelRecordingShortcut: self.$cancelRecordingHotkeyShortcut,
                pasteLastTranscriptionShortcut: self.$pasteLastTranscriptionHotkeyShortcut,
                pasteLastTranscriptionShortcutEnabled: self.$isPasteLastTranscriptionShortcutEnabled,
                hotkeyManagerInitialized: self.$hotkeyManagerInitialized,
                hotkeyMode: self.$hotkeyMode,
                enableStreamingPreview: self.$enableStreamingPreview,
                copyToClipboard: self.$copyToClipboard,
                hotkeyManager: self.hotkeyManager,
                menuBarManager: self.menuBarManager,
                startRecording: self.startCaptionListening,
                stopListening: { await self.stopAndProcessTranscription() },
                refreshDevices: self.refreshDevices,
                openAccessibilitySettings: self.openAccessibilitySettings,
                restartApp: self.restartApp,
                revealAppInFinder: self.revealAppInFinder,
                openApplicationsFolder: self.openApplicationsFolder
            )
        }
    }

    var recordingView: some View {
        RecordingView(
            appear: self.$appear,
            stopAndProcessTranscription: { await self.stopAndProcessTranscription() },
            startRecording: self.startRecording
        )
    }

    // MARK: - Stats View

    var statsView: some View {
        StatsView()
    }

    // Audio settings merged into SettingsView

    func refreshDevices() {
        // Query CoreAudio off the main thread — during device topology changes, synchronous
        // CoreAudio calls on main can deadlock while the HAL is still settling.
        DispatchQueue.global(qos: .userInitiated).async {
            let inputs = AudioDevice.listInputDevicesRefreshingLiveness()
            let outputs = AudioDevice.listOutputDevices()
            let defaultInputUID = AudioDevice.getDefaultInputDevice()?.uid
            DispatchQueue.main.async {
                self.inputDevices = inputs
                self.outputDevices = outputs
                if let selectedInput = self.appServices.microphonePreferenceCoordinator
                    .reconcileMicrophoneSelection(
                        availableInputs: inputs,
                        defaultInputUID: defaultInputUID
                    )
                {
                    self.selectedInputUID = selectedInput.uid
                }
            }
        }
    }

    func refreshInputDevices() {
        DispatchQueue.global(qos: .userInitiated).async {
            let inputs = AudioDevice.listInputDevicesRefreshingLiveness()
            let defaultInputUID = AudioDevice.getDefaultInputDevice()?.uid
            DispatchQueue.main.async {
                self.inputDevices = inputs
                if let selectedInput = self.appServices.microphonePreferenceCoordinator
                    .reconcileMicrophoneSelection(
                        availableInputs: inputs,
                        defaultInputUID: defaultInputUID
                    )
                {
                    self.selectedInputUID = selectedInput.uid
                }
            }
        }
    }

    // MARK: - Model Management Functions

    func saveModels() {
        SettingsStore.shared.availableModels = self.availableModels
    }

    // MARK: - Provider Management Functions

    func providerKey(for providerID: String) -> String {
        let trimmed = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Built-in providers use their ID directly
        if ModelRepository.shared.isBuiltIn(trimmed) { return trimmed }
        // Saved providers use their stable id with "custom:" prefix (if not already present)
        if trimmed.hasPrefix("custom:") { return trimmed }
        return "custom:\(trimmed)"
    }

    func updateCurrentProvider() {
        // Map baseURL to canonical key for built-ins; else keep existing
        let url = self.openAIBaseURL.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if url.contains("openai.com") { self.currentProvider = "openai"; return }
        if url.contains("groq.com") { self.currentProvider = "groq"; return }
        // For saved/custom, keep current or derive from selectedProviderID
        self.currentProvider = self.providerKey(for: self.selectedProviderID)
    }

    func saveSavedProviders() {
        let storedProviders = SettingsStore.shared.savedProviders
        if self.savedProviders.isEmpty, !storedProviders.isEmpty {
            DebugLogger.shared.warning(
                "Skipped stale empty savedProviders write from ContentView.",
                source: "ContentView"
            )
            return
        }
        SettingsStore.shared.savedProviders = self.savedProviders
    }

    // MARK: - App Detection and Context-Aware Prompts

    func getCurrentAppInfo() -> (name: String, bundleId: String, windowTitle: String) {
        if let frontmostApp = NSWorkspace.shared.frontmostApplication {
            let name = frontmostApp.localizedName ?? "Unknown"
            let bundleId = frontmostApp.bundleIdentifier ?? "unknown"
            let title = self.getFrontmostWindowTitle(ownerPid: frontmostApp.processIdentifier) ?? ""
            return (name: name, bundleId: bundleId, windowTitle: title)
        }
        return (name: "Unknown", bundleId: "unknown", windowTitle: "")
    }

    func isSpokenSendBlockedApp(
        _ appInfo: (name: String, bundleId: String, windowTitle: String)
    ) -> Bool {
        let identity = "\(appInfo.name) \(appInfo.bundleId)".lowercased()
        return identity.contains("terminal")
            || identity.contains("iterm")
            || identity.contains("warp")
            || identity.contains("ghostty")
            || identity.contains("kitty")
            || identity.contains("alacritty")
    }

    func deliverSpokenSend(
        _ outputPlan: DictationLiteralOutputPlan,
        targetPID: pid_t?,
        textReadyAt: TimeInterval
    ) async -> TypingService.DeliveryOutcome {
        let sendsExistingDraft = outputPlan.plainText.isEmpty
        let outcome = await self.asr.typeOutputPlanToActiveFieldAndWait(
            outputPlan,
            preferredTargetPID: targetPID,
            textReadyAt: textReadyAt,
            postInsertionKey: self.settings.spokenSendKey,
            requiredFocusTarget: self.recordingFocusTarget
        )
        if outcome.didDispatchAction {
            NotchContentState.shared.setSpokenSendIndicatorState(.sent)
            try? await Task.sleep(nanoseconds: 350_000_000)
            return outcome
        }

        NotchContentState.shared.setSpokenSendIndicatorState(.failed)
        DebugLogger.shared.warning(
            "Spoken Send skipped because delivery safety checks did not pass",
            source: "ContentView"
        )
        let message = outcome.didInsert
            ? "Text inserted — send skipped"
            : sendsExistingDraft ? "Couldn't send" : "Couldn't insert or send"
        NotchOverlayManager.shared.updateTranscriptionText(message)
        try? await Task.sleep(nanoseconds: 650_000_000)
        return outcome
    }

    /// Best-effort frontmost window title lookup for the current app
    func getFrontmostWindowTitle(ownerPid: pid_t) -> String? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in windowInfo {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid == ownerPid else { continue }
            if let name = info[kCGWindowName as String] as? String, name.isEmpty == false {
                return name
            }
        }
        return nil
    }

    func captureRecordingTargetContext() {
        // Capture the focused target PID BEFORE any overlay/UI changes.
        // Used to restore focus when the user interacts with overlay dropdowns.
        let focusTarget = TypingService.captureSystemFocusTarget()
        self.recordingFocusTarget = focusTarget
        let focusedPID = focusTarget?.pid
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        NotchContentState.shared.recordingTargetPID = focusedPID

        let info = self.getCurrentAppInfo()
        self.recordingAppInfo = info
        DebugLogger.shared.debug(
            "Captured recording app context: app=\(info.name), bundleId=\(info.bundleId), title=\(info.windowTitle)",
            source: "ContentView"
        )
    }

    func captureRecordingFormattingContextIfNeeded() {
        // Capture text before the caret only when formatting needs focused-field context.
        if SettingsStore.shared.needsDictationFormattingContext {
            self.recordingPrecedingText = TypingService.textBeforeCursorInFocusedField()
            DebugLogger.shared.debug(
                "Captured preceding text for continuous dictation (chars=\(self.recordingPrecedingText.count))",
                source: "ContentView"
            )
        } else {
            self.recordingPrecedingText = ""
        }
    }

    func captureRecordingContext() {
        self.captureRecordingTargetContext()
        self.captureRecordingFormattingContextIfNeeded()
    }

    func resolveTypingTargetPID() -> (pid: pid_t?, shouldRestoreOriginalFocus: Bool) {
        let originalPID = NotchContentState.shared.recordingTargetPID
        let currentFocusedPID = TypingService.captureSystemFocusedPID()
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier

        let selfBundleID = Bundle.main.bundleIdentifier
        if let currentFocusedPID,
           let app = NSRunningApplication(processIdentifier: currentFocusedPID),
           app.bundleIdentifier != selfBundleID
        {
            return (currentFocusedPID, currentFocusedPID == originalPID)
        }

        return (originalPID, true)
    }

    // MARK: - Commented out app-specific prompts - using general processing only

    /*
     func getContextualPrompt(for appInfo: (name: String, bundleId: String, windowTitle: String)) -> String {
         let appName = appInfo.name
         let bundleId = appInfo.bundleId.lowercased()
         let windowTitle = appInfo.windowTitle.lowercased()

         // Code editors and IDEs
         if bundleId.contains("xcode") || bundleId.contains("vscode") || bundleId.contains("sublime") ||
            bundleId.contains("atom") || bundleId.contains("jetbrains") || bundleId.contains("cursor") ||
            bundleId.contains("vim") || bundleId.contains("emacs") || appName.lowercased().contains("code")
         {
             return "Clean up this transcribed text for code editor \(appName). Make the smallest necessary mechanical edits; do not add or invent content or answer questions. Remove fillers and false starts. Correct programming terms and obvious transcription errors. Preserve meaning and tone."
         }

         // Email applications
         else if bundleId.contains("mail") || bundleId.contains("outlook") || bundleId.contains("thunderbird") ||
                 bundleId.contains("airmail") || bundleId.contains("spark")
         {
             return "Clean up this transcribed text for email app \(appName). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Fix grammar, punctuation, and capitalization while preserving meaning and tone."
         }

         // Messaging and chat applications
         else if bundleId.contains("messages") || bundleId.contains("slack") || bundleId.contains("discord") ||
                 bundleId.contains("telegram") || bundleId.contains("whatsapp") || bundleId.contains("signal") ||
                 bundleId.contains("teams") || bundleId.contains("zoom")
         {
             return "Clean up this transcribed text for messaging app \(appName). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Fix basic grammar and clarity while keeping the casual tone."
         }

         // Document editors and word processors
         else if bundleId.contains("pages") || bundleId.contains("word") || bundleId.contains("docs") ||
                 bundleId.contains("writer") || bundleId.contains("notion") || bundleId.contains("bear") ||
                 bundleId.contains("ulysses") || bundleId.contains("scrivener")
         {
             return "Clean up this transcribed text for document editor \(appName). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Fix grammar, punctuation, and structure while preserving meaning."
         }

         // Note-taking applications
         else if bundleId.contains("notes") || bundleId.contains("obsidian") || bundleId.contains("roam") ||
                 bundleId.contains("logseq") || bundleId.contains("evernote") || bundleId.contains("onenote")
         {
             return "Clean up this transcribed text for note-taking app \(appName). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Fix grammar and organize into clear, readable notes without adding information."
         }

         // Browsers (various web apps). Include: Safari, Chrome, Firefox, Edge, Arc, Brave, Dia, Comet
         else if bundleId.contains("safari") || bundleId.contains("chrome") || bundleId.contains("firefox") ||
                 bundleId.contains("edge") || bundleId.contains("arc") || bundleId.contains("brave") ||
                 bundleId.contains("dia") || bundleId.contains("comet") ||
                 appName.lowercased().contains("safari") || appName.lowercased().contains("chrome") ||
                 appName.lowercased().contains("arc") || appName.lowercased().contains("brave") ||
                 appName.lowercased().contains("dia") || appName.lowercased().contains("comet")
         {
             // Infer common web apps from window title for better context
             if let inferred = inferWebContext(from: windowTitle, appName: appName) {
                 return inferred
             }
             return "Clean up this transcribed text for web browser \(appName). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Fix grammar and basic formatting while preserving meaning."
         }

         // Terminal and command line tools
         else if bundleId.contains("terminal") || bundleId.contains("iterm") || bundleId.contains("console") ||
                 appName.lowercased().contains("terminal")
         {
             return "Clean up this transcribed text for terminal \(appName). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Fix command syntax, file paths, and technical terms without adding options or commands."
         }

         // Social media and creative apps
         else if bundleId.contains("twitter") || bundleId.contains("facebook") || bundleId.contains("instagram") ||
                 bundleId.contains("tiktok") || bundleId.contains("linkedin")
         {
             return "Clean up this transcribed text for social media app \(appName). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Fix basic grammar while keeping the natural, engaging tone."
         }

         // Default fallback
         else
         {
             return "Clean up this transcribed text for \(appName). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Fix grammar, punctuation, and formatting while preserving meaning and tone."
         }
     }
     */

    /*
     /// Infer web-app specific prompt from a browser window title
     func inferWebContext(from windowTitle: String, appName: String) -> String? {
         let title = windowTitle
         // Email (Gmail, Outlook Web)
         if title.contains("gmail") || title.contains("inbox") || title.contains("outlook") {
             return "Clean up this transcribed text for email app \(appName) (web). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Fix grammar, punctuation, and capitalization while preserving meaning."
         }
         // Messaging (Slack, Discord, Teams, Telegram, WhatsApp)
         if title.contains("slack") || title.contains("discord") || title.contains("teams") || title.contains("telegram") || title.contains("whatsapp") {
             return "Clean up this transcribed text for messaging app \(appName) (web). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Fix basic grammar and clarity while keeping the casual tone."
         }
         // Documents (Google Docs/Sheets, Notion, Confluence)
         if title.contains("google docs") || title.contains("docs") || title.contains("notion") || title.contains("confluence") || title.contains("google sheets") || title.contains("sheet") {
             return "Clean up this transcribed text for a document editor in \(appName). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Improve grammar, structure, and readability without adding information."
         }
         // Code (GitHub, Stack Overflow, online IDEs)
         if title.contains("github") || title.contains("stack overflow") || title.contains("stackexchange") || title.contains("replit") || title.contains("codesandbox") {
             return "Clean up this transcribed text for code-related context in \(appName). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Correct programming terms and obvious errors without adding explanations."
         }
         // Project/issue tracking (Jira, Linear, Asana)
         if title.contains("jira") || title.contains("linear") || title.contains("asana") || title.contains("clickup") {
             return "Clean up this transcribed text for project management context in \(appName). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Keep the text concise and clear without adding commentary."
         }
         return nil
     }
     */

    // NOTE: Thinking token filtering is now handled by LLMClient.stripThinkingTags()


    // MARK: - Streaming Response Handler (DEPRECATED - Now handled by LLMClient)

    // This method is no longer used - LLMClient.call() handles streaming internally


    // MARK: - ASR Model Management

    /// Manual download trigger - downloads models when user clicks button
    func downloadModels() async {
        DebugLogger.shared.debug("User initiated model download", source: "ContentView")

        do {
            try await self.asr.ensureAsrReady()
            DebugLogger.shared.info("Model download completed successfully", source: "ContentView")
        } catch {
            DebugLogger.shared.error("Failed to download models: \(error)", source: "ContentView")
        }
    }

    /// Delete models from disk
    func deleteModels() async {
        DebugLogger.shared.debug("User initiated model deletion", source: "ContentView")

        do {
            try await self.asr.clearModelCache()
            DebugLogger.shared.info("Models deleted successfully", source: "ContentView")
        } catch {
            DebugLogger.shared.error("Failed to delete models: \(error)", source: "ContentView")
        }
    }

    // MARK: - ASR Model Preloading

    func preloadASRModel() async {
        // DEPRECATED: No longer auto-loads on startup - models downloaded manually
        DebugLogger.shared.debug("Skipping auto-preload - models downloaded manually via UI", source: "ContentView")
    }

    // MARK: - Model Management

    func addNewModel() {
        guard !self.newModelName.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else { return }

        let modelName = self.newModelName.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let key = self.providerKey(for: self.selectedProviderID)

        // Get current list or start fresh if empty
        var list = self.availableModelsByProvider[key] ?? self.availableModels
        if list.isEmpty {
            list = []
        }

        // Add the new model if not already in list
        if !list.contains(modelName) {
            list.append(modelName)
        }

        // Update state
        self.availableModelsByProvider[key] = list
        SettingsStore.shared.availableModelsByProvider = self.availableModelsByProvider

        // Update saved provider if exists
        if let providerIndex = savedProviders.firstIndex(where: { $0.id == selectedProviderID }) {
            let updatedProvider = SettingsStore.SavedProvider(
                id: self.savedProviders[providerIndex].id,
                name: self.savedProviders[providerIndex].name,
                baseURL: self.savedProviders[providerIndex].baseURL,
                models: list
            )
            self.savedProviders[providerIndex] = updatedProvider
            self.saveSavedProviders()
        }

        // Update UI state
        self.availableModels = list
        self.selectedModel = modelName
        self.selectedModelByProvider[key] = modelName
        SettingsStore.shared.selectedModelByProvider = self.selectedModelByProvider

        // Close the add model UI
        self.showingAddModel = false
        self.newModelName = ""
    }

    func initializeHotkeyManagerIfNeeded() {
        NotchContentState.shared.onPromptModeSwitchRequested = { mode in
            self.handleLivePromptModeSwitch(mode)
        }
        NotchContentState.shared.onOverlayModeSwitchRequested = { mode in
            self.handleLiveOverlayModeSwitch(mode)
        }
        NotchContentState.shared.onReprocessLastRequested = {
            self.reprocessLastDictation()
        }
        NotchContentState.shared.onCopyLastRequested = {
            self.copyLastDictationFromHistory()
        }
        NotchContentState.shared.onPasteLastRequested = {
            self.pasteLastDictationFromHistory()
        }
        NotchContentState.shared.onUndoLastAIRequested = {
            self.undoLastAIProcessingFromHistory()
        }
        NotchContentState.shared.onOpenPreferencesRequested = {
            self.menuBarManager.openPreferencesFromUI()
        }
        NotchContentState.shared.onCancelRequested = {
            _ = self.handleCancelShortcut()
        }
        NotchContentState.shared.onDictationPromptSelectionRequested = { selection in
            guard selection != .privateAI || PrivateAIProviderPromptFormat.isAvailable() else { return }
            let slot = self.activeDictationShortcutSlot ?? .primary
            SettingsStore.shared.setDictationPromptSelection(selection, for: slot)
            self.applyDictationShortcutSelectionContext(for: slot)
        }

        guard self.hotkeyManager == nil else { return }

        self.hotkeyManager = GlobalHotkeyManager(
            asrService: self.asr,
            primaryShortcuts: self.primaryDictationShortcuts,
            promptModeShortcut: self.promptModeHotkeyShortcut,
            promptShortcutAssignments: SettingsStore.shared.dictationPromptShortcutAssignments(),
            promptModeShortcutEnabled: self.isPromptModeShortcutEnabled,
            startRecordingCallback: {
                DebugLogger.shared.debug("ContentView: startRecordingCallback invoked by hotkey", source: "ContentView")
                self.startRecording()
            },
            dictationModeCallback: {
                DebugLogger.shared.info("Dictate mode triggered", source: "ContentView")
                DebugLogger.shared.debug(
                    "ContentView: selected model for dictate hotkey=\(SettingsStore.shared.selectedSpeechModel.displayName)",
                    source: "ContentView"
                )
                self.beginDictationRecording(for: .primary, mode: .dictate)
            },
            stopAndProcessCallback: {
                let route = self.currentDictationOutputRouteForHotkeyStop()
                DebugLogger.shared.info("Hotkey stop callback using route: \(route.rawValue)", source: "ContentView")
                await self.stopAndProcessTranscription(route: route)
            },
            promptModeCallback: {
                DebugLogger.shared.info("Prompt mode triggered", source: "ContentView")
                self.beginDictationRecording(for: .secondary, mode: .promptMode)
            },
            promptSelectionCallback: { selection in
                DebugLogger.shared.info("Prompt selection shortcut triggered", source: "ContentView")
                self.beginDictationRecording(for: selection, mode: .promptMode)
            },
            isDictateRecordingProvider: {
                self.activeRecordingMode == .dictate
            },
            isPromptModeRecordingProvider: {
                self.activeRecordingMode == .promptMode
            },
            isShortcutCaptureActiveProvider: {
                self.isRecordingAnyShortcutCapture
            }
        )

        self.hotkeyManagerInitialized = self.hotkeyManager?.validateEventTapHealth() ?? false

        self.hotkeyManager?.setHotkeyMode(self.hotkeyMode)

        // Set cancel callback for Escape key handling (closes transient UI, resets recording state)
        // Returns true if it handled something (so GlobalHotkeyManager knows to consume the event)
        self.hotkeyManager?.setCancelCallback {
            var handled = false

            // The suggestion panel is non-activating, so its Escape key arrives
            // through the global event tap while the target app stays focused.
            if DictionaryCorrectionOverlayController.shared.isPresented {
                DebugLogger.shared.debug("Cancel callback: closing dictionary suggestion", source: "ContentView")
                DictionaryCorrectionOverlayController.shared.dismiss()
                return true
            }

            // Reset recording mode flags
            if self.activeRecordingMode != .none {
                self.cancelPrewarmDictationIfNeeded()
                self.clearActiveRecordingMode()
                handled = true
            }

            if LiveTranslationController.shared.isSessionActive {
                LiveTranslationController.shared.cancelSession()
                handled = true
            }

            return handled
        }

        // Re-insert the most recent transcription on demand (no clipboard involved).
        self.hotkeyManager?.setPasteLastTranscriptionCallback {
            self.pasteLastDictationFromHistory()
        }
        self.hotkeyManager?.setTranslateInsertCallback {
            LiveTranslationController.shared.startInsertListening()
        }
        self.hotkeyManager?.setCaptionListenCallback {
            LiveTranslationController.shared.toggleCaptionListening()
        }

        LiveTranslationController.shared.subscriber.confirmTranscript = {
            await self.asr.confirmStreamingTranscript()
        }
        LiveTranslationController.shared.onStartCaptionListening = {
            self.startCaptionListening()
        }
        LiveTranslationController.shared.onStartInsertListening = {
            self.startInsertTranslationListening()
        }
        LiveTranslationController.shared.onStopListening = {
            await self.stopAndProcessTranscription()
        }
        LiveTranslationController.shared.onInsertCaption = { text in
            self.insertCaptionIntoFrontmostApp(text)
        }
        LiveTranslationController.shared.onAccessibilityNeeded = {
            self.openAccessibilitySettings()
        }
        LiveTranslationController.shared.restoreTheaterIfNeeded()

        // Monitor initialization status
        Task {
            // Give some time for initialization
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds

            await MainActor.run {
                self.hotkeyManagerInitialized = self.hotkeyManager?.validateEventTapHealth() ?? false
                DebugLogger.shared.debug("Initial hotkey manager health check: \(self.hotkeyManagerInitialized)", source: "ContentView")

                // If still not initialized and accessibility is enabled, try reinitializing
                if !self.hotkeyManagerInitialized && self.accessibilityEnabled {
                    self.hotkeyManagerInitialized = self.hotkeyManager?.validateEventTapHealth() ?? false
                    DebugLogger.shared.debug("Initial hotkey manager health check: \(self.hotkeyManagerInitialized)", source: "ContentView")

                    // If still not initialized and accessibility is enabled, try reinitializing
                    if !self.hotkeyManagerInitialized && self.accessibilityEnabled {
                        DebugLogger.shared.debug("Hotkey manager not healthy, attempting reinitalization", source: "ContentView")
                        self.hotkeyManager?.reinitialize()
                    }
                }
            }
        }
    }

    @discardableResult
    func handleCancelShortcut() -> Bool {
        var handled = false

        if DictionaryCorrectionOverlayController.shared.isPresented {
            DebugLogger.shared.debug("Cancel shortcut: closing dictionary suggestion", source: "ContentView")
            DictionaryCorrectionOverlayController.shared.dismiss()
            return true
        }

        if self.asr.isRunningOrStarting {
            DebugLogger.shared.debug("Cancel shortcut: cancelling ASR recording", source: "ContentView")
            Task {
                await self.asr.stopWithoutTranscription()
            }
            self.cancelPrewarmDictationIfNeeded()
            LiveTranslationController.shared.cancelSession()
            handled = true
        }

        if NotchOverlayManager.shared.isBottomOverlayVisible || NotchOverlayManager.shared.isOverlayVisible {
            DebugLogger.shared.debug("Cancel shortcut: hiding recording overlay", source: "ContentView")
            NotchOverlayManager.shared.hide()
            handled = true
        }

        return handled
    }

    // MARK: - Model Management Helpers

    func isCustomModel(_ model: String) -> Bool {
        // Non-removable defaults are the provider's default models
        return !ModelRepository.shared.defaultModels(for: self.currentProvider).contains(model)
    }

    /// Check if the current model has a reasoning config (either custom or auto-detected)
    func hasReasoningConfigForCurrentModel() -> Bool {
        let providerKey = self.providerKey(for: self.selectedProviderID)

        // Check for custom config first
        if SettingsStore.shared.hasCustomReasoningConfig(forModel: self.selectedModel, provider: providerKey) {
            if let config = SettingsStore.shared.getReasoningConfig(forModel: selectedModel, provider: providerKey) {
                return config.isEnabled
            }
        }

        // Check for auto-detected models
        let modelLower = self.selectedModel.lowercased()
        return modelLower.hasPrefix("gpt-5") || modelLower.contains("gpt-5.") ||
            modelLower.hasPrefix("o1") || modelLower.hasPrefix("o3") ||
            modelLower.contains("gpt-oss") || modelLower.hasPrefix("openai/") ||
            (modelLower.contains("deepseek") && modelLower.contains("reasoner"))
    }

    func removeModel(_ model: String) {
        // Don't remove if it's currently selected
        if self.selectedModel == model {
            // Switch to first available model that's not the one being removed
            if let firstOther = availableModels.first(where: { $0 != model }) {
                self.selectedModel = firstOther
            }
        }

        // Remove from current provider's model list
        self.availableModels.removeAll { $0 == model }

        // Update the stored models for this provider
        let key = self.providerKey(for: self.selectedProviderID)
        self.availableModelsByProvider[key] = self.availableModels
        SettingsStore.shared.availableModelsByProvider = self.availableModelsByProvider

        // If this is a saved custom provider, update its models array too
        if let providerIndex = savedProviders.firstIndex(where: { $0.id == selectedProviderID }) {
            let updatedProvider = SettingsStore.SavedProvider(
                id: self.savedProviders[providerIndex].id,
                name: self.savedProviders[providerIndex].name,
                baseURL: self.savedProviders[providerIndex].baseURL,
                models: self.availableModels
            )
            self.savedProviders[providerIndex] = updatedProvider
            self.saveSavedProviders()
        }

        // Update selected model mapping for this provider
        self.selectedModelByProvider[key] = self.selectedModel
        SettingsStore.shared.selectedModelByProvider = self.selectedModelByProvider
    }

    // Deprecated: hotkey persistence is handled via SettingsStore
}

// SidebarItem enum moved to top of file

// AudioDevice and AudioHardwareObserver moved to Services/AudioDeviceService.swift

