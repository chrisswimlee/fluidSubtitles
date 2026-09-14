//
//  SettingsView.swift
//  fluid
//
//  App preferences and audio device settings
//

import AppKit
import AVFoundation
import PromiseKit
import SwiftUI
import UniformTypeIdentifiers

// swiftlint:disable type_body_length function_body_length cyclomatic_complexity
// Tracked grandfather: settings form. New rows belong in a focused view.
struct SettingsView: View {
    struct ShortcutRowContent {
        let icon: String
        let iconColor: Color
        let title: String
        let description: String
    }

    @EnvironmentObject var appServices: AppServices
    var asr: ASRService {
        self.appServices.asr
    }

    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var theme
    @Environment(\.accessibilityReduceMotion) var accessibilityReduceMotion
    @ObservedObject var settings = SettingsStore.shared
    let selectedSection: SettingsSection
    let searchResults: [SettingsSearchResult]
    let searchScrollRequest: Int
    @ObservedObject var microphonePreferenceCoordinator: MicrophonePreferenceCoordinator
    @Binding var appear: Bool
    @Binding var visualizerNoiseThreshold: Double
    @Binding var selectedInputUID: String
    @Binding var selectedOutputUID: String
    @Binding var inputDevices: [AudioDevice.Device]
    @Binding var outputDevices: [AudioDevice.Device]
    @Binding var accessibilityEnabled: Bool
    @Binding var primaryDictationShortcuts: [HotkeyShortcut]
    @Binding var activeShortcutRecordingTarget: ShortcutRecordingTarget?
    @Binding var shortcutRecordingMessage: String?
    @Binding var cancelRecordingShortcut: HotkeyShortcut
    @Binding var pasteLastTranscriptionShortcut: HotkeyShortcut?
    @Binding var pasteLastTranscriptionShortcutEnabled: Bool
    @Binding var hotkeyManagerInitialized: Bool
    @Binding var hotkeyMode: HotkeyActivationMode
    @Binding var enableStreamingPreview: Bool
    @Binding var copyToClipboard: Bool

    // CRITICAL FIX: Cache default device names to avoid CoreAudio calls during view body evaluation.
    // Querying AudioDevice.getDefaultInputDevice() in the view body triggers HALSystem::InitializeShell()
    // which races with SwiftUI's AttributeGraph metadata processing and causes EXC_BAD_ACCESS crashes.
    @State var cachedDefaultInputUID: String = ""
    @State var cachedDefaultOutputName: String = ""

    @State var rollbackVersion: String = ""
    @State var isRollingBack: Bool = false
    @State var audioHistoryBudgetText: String = Self.audioBudgetText(for: SettingsStore.shared.audioHistoryBudgetGB)
    @State var audioHistoryUsageBytes: Int64 = 0
    @State var draggedMicrophoneUID: String?
    @State var hoveredMicrophoneUID: String?
    @State var searchScrollCoordinator = SettingsSearchScrollCoordinator()

    let hotkeyManager: GlobalHotkeyManager?
    let menuBarManager: MenuBarManager
    let startRecording: () -> Void
    var stopListening: () async -> Void = {}
    let refreshDevices: () -> Void
    let openAccessibilitySettings: () -> Void
    let restartApp: () -> Void
    let revealAppInFinder: () -> Void
    let openApplicationsFolder: () -> Void

    func isRecording(_ target: ShortcutRecordingTarget) -> Bool {
        self.activeShortcutRecordingTarget == target
    }

    var currentAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    var appDisplayName: String {
        Bundle.main.fluidAppDisplayName
    }

    var launchAtStartupBinding: Binding<Bool> {
        Binding(
            get: { self.settings.launchAtStartupEnabled },
            set: { self.settings.setLaunchAtStartup($0) }
        )
    }

    func dictationPromptSelectionBinding(for slot: SettingsStore.DictationShortcutSlot) -> Binding<String> {
        Binding(
            get: {
                switch self.settings.dictationPromptSelection(for: slot) {
                case .off:
                    return "__OFF__"
                case .default:
                    return "__DEFAULT__"
                case .privateAI:
                    return PrivateAIProviderPromptFormat.promptSelectionID
                case let .profile(id):
                    return id
                }
            },
            set: { newValue in
                switch newValue {
                case "__OFF__":
                    self.settings.setDictationPromptSelection(.off, for: slot)
                case "__DEFAULT__":
                    self.settings.setDictationPromptSelection(.default, for: slot)
                case PrivateAIProviderPromptFormat.promptSelectionID:
                    guard PrivateAIProviderPromptFormat.isAvailable(settings: self.settings) else { return }
                    self.settings.setDictationPromptSelection(.privateAI, for: slot)
                default:
                    self.settings.setDictationPromptSelection(.profile(newValue), for: slot)
                }
            }
        )
    }

    @ViewBuilder
    func dictationPromptPicker(for slot: SettingsStore.DictationShortcutSlot) -> some View {
        let profiles = self.settings.promptProfiles(for: .dictate)
        let privateAIAvailable = PrivateAIProviderPromptFormat.isAvailable(settings: self.settings)
        HStack {
            Text("AI Prompt")
                .font(self.theme.typography.bodySmall)
                .foregroundStyle(self.settingsSecondaryText)
                .padding(.leading, 30)
            Spacer()
            Picker("", selection: self.dictationPromptSelectionBinding(for: slot)) {
                Section("ON-DEVICE") {
                    Text("Fast — No cleanup").tag("__OFF__")
                    if PrivateFeatures.privateAIProvider {
                        Text("Cleanup — Fluid-1")
                            .tag(PrivateAIProviderPromptFormat.promptSelectionID)
                            .disabled(!privateAIAvailable)
                    }
                }
                Section("EXTERNAL") {
                    Text("Cleanup").tag("__DEFAULT__")
                    ForEach(profiles) { profile in
                        Text(profile.name.isEmpty ? "Untitled" : profile.name)
                            .tag(profile.id)
                    }
                }
            }
            .frame(width: 220)
        }
        .padding(.bottom, 4)
    }

    var body: some View {
        SettingsPersistentScrollView(
            theme: self.theme,
            colorScheme: self.colorScheme,
            searchScrollCoordinator: self.searchScrollCoordinator,
            searchScrollTarget: self.selectedSectionSearchResults.first?.target,
            searchScrollRequest: self.searchScrollRequest
        ) {
            VStack(spacing: 16) {
                FluidPageHeader(
                    systemImage: self.selectedSection.systemImage,
                    title: self.selectedSection.title,
                    subtitle: self.selectedSection == .translation
                        ? FluidProduct.tagline
                        : nil
                ) {
                    if self.selectedSection == .translation {
                        HStack(spacing: 8) {
                            OpenTheaterButton()
                            TheaterListenButton()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .settingsSearchTarget(self.selectedSection.searchTarget)

                LiveTranslationSettingsView(
                    recordTranslateShortcut: {
                        if self.isRecording(.translateInsert) {
                            self.shortcutRecordingMessage = nil
                            self.activeShortcutRecordingTarget = nil
                        } else {
                            self.shortcutRecordingMessage = nil
                            self.activeShortcutRecordingTarget = .translateInsert
                        }
                    },
                    isRecordingTranslateShortcut: self.isRecording(.translateInsert),
                    recordListenShortcut: {
                        if self.isRecording(.captionListen) {
                            self.shortcutRecordingMessage = nil
                            self.activeShortcutRecordingTarget = nil
                        } else {
                            self.shortcutRecordingMessage = nil
                            self.activeShortcutRecordingTarget = .captionListen
                        }
                    },
                    isRecordingListenShortcut: self.isRecording(.captionListen),
                    shortcutRecordingMessage: (self.isRecording(.translateInsert) || self.isRecording(.captionListen))
                        ? self.shortcutRecordingMessage
                        : nil
                )
                    .shownInSettingsSection(.translation, selectedSection: self.selectedSection)

                // Startup Card
                ThemedCard(style: .standard) {
                    VStack(alignment: .leading, spacing: 14) {
                        FluidSectionHeader(title: "Startup", systemImage: "power")

                        VStack(spacing: 16) {
                            // Launch at startup
                            self.settingsToggleRow(
                                title: "Launch at startup",
                                description: "Automatically start \(FluidProduct.displayName) when you log in",
                                footnote: self.settings.launchAtStartupStatusMessage,
                                errorMessage: self.settings.launchAtStartupErrorMessage,
                                isOn: self.launchAtStartupBinding
                            )
                            .settingsSearchTarget(.launchAtStartup)
                            Divider().opacity(0.2)

                            // Show window when launched at login
                            self.settingsToggleRow(
                                title: "Show window when launched at login",
                                description: "When off, \(FluidProduct.displayName) starts silently in the menu bar at login. Opening the app yourself always shows the window.",
                                isOn: Binding(
                                    get: { SettingsStore.shared.showMainWindowAtLoginLaunch },
                                    set: { SettingsStore.shared.showMainWindowAtLoginLaunch = $0 }
                                )
                            )
                            .settingsSearchTarget(.showWindowAtLogin)
                            Divider().opacity(0.2)

                            // Hide from Dock & App Switcher
                            self.settingsToggleRow(
                                title: "Hide from Dock & App Switcher",
                                description: "Keep \(FluidProduct.displayName) in the menu bar only (hides Dock icon and Cmd+Tab entry)",
                                footnote: "Note: May require app restart to take effect.",
                                isOn: Binding(
                                    get: { SettingsStore.shared.hideFromDockAndAppSwitcher },
                                    set: { SettingsStore.shared.hideFromDockAndAppSwitcher = $0 }
                                )
                            )
                            .settingsSearchTarget(.dockVisibility)
                            Divider().opacity(0.2)

                            // Accent Color
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .center) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Accent Color")
                                            .font(self.theme.typography.bodyStrong)
                                            .foregroundStyle(self.settingsTitleText)
                                        Text("Pick a preset accent color for the app.")
                                            .font(self.theme.typography.bodySmall)
                                            .foregroundStyle(self.settingsSecondaryText)
                                    }

                                    Spacer()

                                    HStack(spacing: 10) {
                                        ForEach(SettingsStore.AccentColorOption.allCases) { option in
                                            let isSelected = self.settings.accentColorOption == option
                                            Button {
                                                self.settings.accentColorOption = option
                                            } label: {
                                                Circle()
                                                    .fill(Color(hex: option.hex) ?? .gray)
                                                    .frame(width: 16, height: 16)
                                                    .overlay(
                                                        Circle()
                                                            .stroke(
                                                                isSelected ? self.theme.palette.accent : self.theme.palette.cardBorder.opacity(0.5),
                                                                lineWidth: isSelected ? 2 : 1
                                                            )
                                                    )
                                                    .padding(4)
                                            }
                                            .buttonStyle(.plain)
                                            .accessibilityLabel(option.rawValue)
                                            .help(option.rawValue)
                                        }
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 4)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(self.theme.palette.contentBackground)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                    .stroke(self.theme.palette.cardBorder.opacity(0.4), lineWidth: 1)
                                            )
                                    )
                                }
                            }
                            .settingsSearchTarget(.accentColor)
                            Divider().opacity(0.2)

                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Transcription Sounds")
                                        .font(self.theme.typography.bodyStrong)
                                        .foregroundStyle(self.settingsTitleText)
                                    Text("Choose the sound cue for recording. Some cues include an end sound.")
                                        .font(self.theme.typography.bodySmall)
                                        .foregroundStyle(self.settingsSecondaryText)
                                }

                                Spacer()

                                Picker("", selection: Binding(
                                    get: { SettingsStore.shared.transcriptionStartSound },
                                    set: { newValue in
                                        SettingsStore.shared.transcriptionStartSound = newValue
                                        TranscriptionSoundPlayer.shared.playPreview(sound: newValue)
                                    }
                                )) {
                                    ForEach(SettingsStore.TranscriptionStartSound.allCases) { option in
                                        Text(option.displayName).tag(option)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 170, alignment: .trailing)
                            }
                            .settingsSearchTarget(.transcriptionSounds)

                            if SettingsStore.shared.transcriptionStartSound != .none {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Volume")
                                            .font(self.theme.typography.bodyStrong)
                                            .foregroundStyle(self.settingsTitleText)
                                        Text("Adjust the recording sound cue volume.")
                                            .font(self.theme.typography.bodySmall)
                                            .foregroundStyle(self.settingsSecondaryText)
                                    }

                                    Spacer()

                                    Slider(
                                        value: Binding(
                                            get: { Double(SettingsStore.shared.transcriptionSoundVolume) },
                                            set: { SettingsStore.shared.transcriptionSoundVolume = Float($0) }
                                        ),
                                        in: 0...1,
                                        step: 0.05
                                    ) { editing in
                                        if !editing {
                                            TranscriptionSoundPlayer.shared.playPreviewAtVolume(
                                                SettingsStore.shared.transcriptionSoundVolume
                                            )
                                        }
                                    }
                                    .frame(width: 150)
                                }

                                self.settingsToggleRow(
                                    title: "Independent Volume",
                                    description: "Sound volume stays constant regardless of system volume. Mute is still respected.",
                                    footnote: "Temporarily changes system volume during playback, which may briefly affect other audio.",
                                    isOn: Binding(
                                        get: { SettingsStore.shared.transcriptionSoundIndependentVolume },
                                        set: { SettingsStore.shared.transcriptionSoundIndependentVolume = $0 }
                                    )
                                )
                            }

                            Divider().opacity(0.2)

                            // Automatic Updates
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .center) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Automatic Updates")
                                            .font(self.theme.typography.bodyStrong)
                                            .foregroundStyle(self.settingsTitleText)
                                        Text("Check for updates automatically once per hour")
                                            .font(self.theme.typography.bodySmall)
                                            .foregroundStyle(self.settingsSecondaryText)
                                    }

                                    Spacer()

                                    Toggle("", isOn: Binding(
                                        get: { SettingsStore.shared.autoUpdateCheckEnabled },
                                        set: { SettingsStore.shared.autoUpdateCheckEnabled = $0 }
                                    ))
                                    .toggleStyle(.switch)
                                    .tint(self.theme.palette.accent)
                                    .labelsHidden()
                                }

                                HStack(alignment: .center) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Beta Releases")
                                            .font(self.theme.typography.bodyStrong)
                                            .foregroundStyle(self.settingsTitleText)
                                        Text("Opt in to preview builds that may be unstable")
                                            .font(self.theme.typography.bodySmall)
                                            .foregroundStyle(self.settingsSecondaryText)
                                    }

                                    Spacer()

                                    Toggle("", isOn: Binding(
                                        get: { SettingsStore.shared.betaReleasesEnabled },
                                        set: { SettingsStore.shared.betaReleasesEnabled = $0 }
                                    ))
                                    .toggleStyle(.switch)
                                    .tint(self.theme.palette.accent)
                                    .labelsHidden()
                                }

                                if SettingsStore.shared.betaReleasesEnabled {
                                    Text("Beta opt-in enabled. Update checks include both stable and beta builds.")
                                        .font(.caption)
                                        .foregroundStyle(self.theme.palette.warning)
                                }

                                if let lastCheck = SettingsStore.shared.lastUpdateCheckDate {
                                    Text("Last checked: \(lastCheck.formatted(date: .abbreviated, time: .shortened))")
                                        .font(self.theme.typography.bodySmall)
                                        .foregroundStyle(self.settingsSecondaryText)
                                }

                                Text("Current version: \(self.currentAppVersion)")
                                    .font(self.theme.typography.bodySmall)
                                    .foregroundStyle(self.settingsSecondaryText)

                                Link("Made by \(FluidProduct.authorName) — \(FluidProduct.authorSiteHost)", destination: FluidProduct.authorURL)
                                    .font(self.theme.typography.bodySmall)
                            }
                            .settingsSearchTarget(.automaticUpdates)

                            // Update Buttons
                            HStack(spacing: 10) {
                                Button("Check for Updates") {
                                    Task { @MainActor in
                                        do {
                                            let includePrerelease = SettingsStore.shared.betaReleasesEnabled
                                            let repository = try SimpleUpdater.shared.publishedRepository()
                                            try await SimpleUpdater.shared.checkAndUpdate(
                                                owner: repository.owner,
                                                repo: repository.repo,
                                                includePrerelease: includePrerelease
                                            )
                                        } catch SimpleUpdateError.updateAlreadyInProgress {
                                            DebugLogger.shared.info(
                                                "Update installation already in progress",
                                                source: "SettingsView"
                                            )
                                        } catch {
                                            let msg = NSAlert()
                                            if let pmkError = error as? PMKError, pmkError.isCancelled {
                                                let isBeta = SettingsStore.shared.betaReleasesEnabled
                                                msg.messageText = isBeta ? "You're Up To Date (Beta)" : "You're Up To Date"
                                                msg.informativeText = isBeta
                                                    ? "You're already running the latest build available in the beta channel."
                                                    : "You're already running the latest version of \(FluidProduct.displayName)."
                                            } else {
                                                msg.messageText = "Update Check Failed"
                                                msg.informativeText = "Unable to check for updates. Please try again later.\n\nError: \(error.localizedDescription)"
                                            }
                                            msg.alertStyle = .informational
                                            msg.runModal()
                                        }
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(self.theme.palette.accent)
                                .controlSize(.regular)

                                Button("Release Notes") {
                                    if let url = FluidProduct.releasesURL {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                                .disabled(FluidProduct.releasesURL == nil)
                                .buttonStyle(.bordered)
                                .controlSize(.regular)

                                Button(self.rollbackVersion.isEmpty ? "Rollback" : "Rollback to \(self.rollbackVersion)") {
                                    guard !self.isRollingBack else { return }

                                    let infoText = self.rollbackVersion.isEmpty ? "your previously installed version" : self.rollbackVersion
                                    let targetVersion = self.rollbackVersion
                                    let confirm = NSAlert()
                                    confirm.messageText = "Rollback to \(infoText)?"
                                    confirm.informativeText = "This will restore a previous app version and relaunch \(FluidProduct.displayName)."
                                    confirm.alertStyle = .warning
                                    confirm.addButton(withTitle: "Rollback")
                                    confirm.addButton(withTitle: "Cancel")

                                    guard confirm.runModal() == .alertFirstButtonReturn else { return }

                                    self.isRollingBack = true
                                    Task {
                                        defer {
                                            Task { @MainActor in
                                                self.isRollingBack = false
                                            }
                                        }

                                        do {
                                            try await SimpleUpdater.shared.rollbackToLatestBackup()
                                            await MainActor.run {
                                                let success = NSAlert()
                                                success.messageText = "Rollback Successful"
                                                success.informativeText = "Rolled back to \(targetVersion). \(FluidProduct.displayName) will relaunch shortly."
                                                success.alertStyle = .informational
                                                success.addButton(withTitle: "Report Bug")
                                                success.addButton(withTitle: "OK")
                                                let response = success.runModal()
                                                if response == .alertFirstButtonReturn {
                                                    self.openIssueReportingPage()
                                                }
                                            }
                                        } catch {
                                            await MainActor.run {
                                                let fail = NSAlert()
                                                fail.messageText = "Rollback Failed"
                                                fail.informativeText = error.localizedDescription
                                                fail.alertStyle = .critical
                                                fail.addButton(withTitle: "OK")
                                                fail.runModal()
                                                self.refreshRollbackState()
                                            }
                                        }
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)
                                .disabled(self.rollbackVersion.isEmpty || self.isRollingBack)
                                .opacity(self.isRollingBack ? 0.7 : 1.0)

                                Button("Get Previous Builds") {
                                    self.openPreviousBuildPicker()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)
                            }
                            .padding(.top, 12)

                            if self.rollbackVersion.isEmpty {
                                Text("No rollback backup found.")
                                    .font(self.theme.typography.bodySmall)
                                    .foregroundStyle(self.settingsSecondaryText)
                            } else {
                                Text("Rollback target: \(self.rollbackVersion)")
                                    .font(self.theme.typography.bodySmall)
                                    .foregroundStyle(self.settingsSecondaryText)
                            }
                        }
                    }
                    .padding(16)
                }
                .shownInSettingsSection(.general, selectedSection: self.selectedSection)

                if self.asr.micStatus != .authorized {
                    // Only surface microphone permission when the user needs to act.
                    ThemedCard(style: .standard) {
                        VStack(alignment: .leading, spacing: 14) {
                            FluidSectionHeader(title: "Microphone Permission", systemImage: "mic.fill")

                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(self.theme.palette.warning)
                                        .frame(width: 8, height: 8)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(
                                            self.asr.micStatus == .denied
                                                ? "Microphone access denied"
                                                : "Microphone access not determined"
                                        )
                                        .font(self.theme.typography.bodyStrong)
                                        .foregroundStyle(self.theme.palette.warning)

                                        Text("Microphone access is required for voice recording")
                                            .font(self.theme.typography.bodySmall)
                                            .foregroundStyle(self.settingsSecondaryText)
                                    }
                                    Spacer()

                                    if self.asr.micStatus == .notDetermined {
                                        Button {
                                            self.asr.requestMicAccess()
                                        } label: {
                                            Label("Grant Access", systemImage: "mic.fill")
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .tint(self.theme.palette.accent)
                                        .controlSize(.regular)
                                    } else if self.asr.micStatus == .denied {
                                        Button {
                                            self.asr.openSystemSettingsForMic()
                                        } label: {
                                            Label("Open Settings", systemImage: "gear")
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.regular)
                                    }
                                }

                                self.instructionsBox(
                                    title: "How to enable microphone access:",
                                    steps: self.asr.micStatus == .notDetermined
                                        ? ["Click **Grant Access** above", "Choose **Allow** in the system dialog"]
                                        : [
                                            "Click **Open Settings** above",
                                            "Find **\(self.appDisplayName)** in the microphone list",
                                            "Toggle **\(self.appDisplayName) ON** to allow access",
                                        ]
                                )
                            }
                        }
                        .padding(16)
                    }
                    .settingsSearchTarget(.microphonePermission)
                    .shownInSettingsSection(.dictation, selectedSection: self.selectedSection)
                }

                // Global Hotkey Card
                ThemedCard(style: .standard) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 8) {
                            FluidSectionHeader(title: "Global Hotkey", systemImage: "keyboard")

                            Spacer()

                            if self.accessibilityEnabled {
                                if self.isRecordingAnyShortcut {
                                    Text("Recording…")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.orange)
                                } else if self.hotkeyManagerInitialized {
                                    HStack(spacing: 6) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Color.fluidGreen)
                                            .font(.caption)
                                        Text("Active")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(self.settingsSecondaryText)
                                    }
                                } else {
                                    Text("Initializing…")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(self.settingsSecondaryText)
                                }
                            }
                        }
                        .settingsSearchTarget(.globalHotkey)

                        if self.accessibilityEnabled {
                            VStack(alignment: .leading, spacing: 12) {
                                if self.isRecordingAnyShortcut {
                                    HStack(spacing: 8) {
                                        Image(systemName: "hand.point.up.left.fill")
                                            .foregroundStyle(.orange)
                                        Text("Press your new hotkey combination now…")
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                    }
                                } else if !self.hotkeyManagerInitialized {
                                    HStack(spacing: 8) {
                                        ProgressView()
                                            .controlSize(.small)
                                            .fixedSize()
                                        Text("Hotkey initializing…")
                                            .font(.caption)
                                            .foregroundStyle(self.settingsSecondaryText)
                                    }
                                }

                                // MARK: - Shortcuts Section

                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Shortcuts")
                                        .font(self.theme.typography.bodySmallStrong)
                                        .foregroundStyle(self.settingsTitleText)

                                    Text("Listening starts from the Theater page. A keyboard shortcut is optional.")
                                        .font(.caption)
                                        .foregroundStyle(self.settingsTertiaryText)

                                    if SettingsStore.shared.listeningHotkeyEnabled {
                                        self.primaryDictationShortcutsList()
                                            .settingsSearchTarget(.primaryDictationShortcuts)
                                        self.dictationPromptPicker(for: .primary)
                                        Divider().opacity(0.2).padding(.vertical, 4)
                                    }

                                    self.shortcutRow(
                                        content: .init(
                                            icon: "xmark.circle.fill",
                                            iconColor: .secondary,
                                            title: "Cancel Recording",
                                            description: "Cancel the current recording or dismiss the active recording overlay"
                                        ),
                                        shortcut: self.cancelRecordingShortcut,
                                        isRecording: self.isRecording(.cancel),
                                        isAnyRecordingActive: self.isRecordingAnyShortcut,
                                        recordingMessage: self.isRecording(.cancel) ? self.shortcutRecordingMessage : nil,
                                        onChangePressed: {
                                            DebugLogger.shared.debug("Starting to record new cancel shortcut", source: "SettingsView")
                                            self.shortcutRecordingMessage = nil
                                            self.activeShortcutRecordingTarget = .cancel
                                        }
                                    )
                                    .settingsSearchTarget(.cancelRecordingShortcut)
                                    Divider().opacity(0.2).padding(.vertical, 4)

                                    self.shortcutRow(
                                        content: .init(
                                            icon: "arrow.down.doc",
                                            iconColor: .secondary,
                                            title: "Paste Last Transcription",
                                            description: "Re-insert your most recent transcription without using the clipboard"
                                        ),
                                        shortcut: self.pasteLastTranscriptionShortcut,
                                        isRecording: self.isRecording(.pasteLast),
                                        isAnyRecordingActive: self.isRecordingAnyShortcut,
                                        recordingMessage: self.isRecording(.pasteLast) ? self.shortcutRecordingMessage : nil,
                                        isEnabled: self.$pasteLastTranscriptionShortcutEnabled,
                                        requiresShortcutToEnable: true,
                                        onChangePressed: {
                                            DebugLogger.shared.debug("Starting to record new paste last transcription shortcut", source: "SettingsView")
                                            self.shortcutRecordingMessage = nil
                                            self.activeShortcutRecordingTarget = .pasteLast
                                        },
                                        onRemovePressed: {
                                            if self.activeShortcutRecordingTarget == .pasteLast {
                                                self.shortcutRecordingMessage = nil
                                                self.activeShortcutRecordingTarget = nil
                                            }
                                            self.pasteLastTranscriptionShortcut = nil
                                            self.pasteLastTranscriptionShortcutEnabled = false
                                        }
                                    )
                                    .settingsSearchTarget(.pasteLastTranscriptionShortcut)
                                }
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(self.theme.palette.elevatedCardBackground)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .stroke(self.theme.palette.cardBorder.opacity(0.45), lineWidth: 1)
                                        )
                                )
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(self.theme.palette.warning)
                                        .frame(width: 8, height: 8)

                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Image(systemName: "exclamationmark.triangle.fill")
                                                .foregroundStyle(self.theme.palette.warning)
                                            Text("Accessibility is only for typing into other apps")
                                                .font(self.theme.typography.bodyStrong)
                                                .foregroundStyle(self.theme.palette.warning)
                                        }
                                        Text("Theater captions do not need this. Enable it to type a translation or dictation into another app.")
                                            .font(self.theme.typography.bodySmall)
                                            .foregroundStyle(self.settingsSecondaryText)
                                    }
                                    Spacer()

                                    Button("Open Accessibility Settings") {
                                        self.openAccessibilitySettings()
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(self.theme.palette.accent)
                                    .controlSize(.regular)
                                }

                                self.instructionsBox(
                                    title: "Follow these steps to enable Accessibility:",
                                    steps: [
                                        "Click **Open Accessibility Settings** above",
                                        "In the Accessibility window, click the **+ button**",
                                        "Select **\(self.appDisplayName)**; use **Reveal in Finder** below if needed",
                                        "Click **Open**, then toggle **\(self.appDisplayName) ON** in the list",
                                    ],
                                    warningStyle: true
                                )

                                HStack(spacing: 10) {
                                    Button("Reveal in Finder") {
                                        self.revealAppInFinder()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)

                                    Button("Open Applications") {
                                        self.openApplicationsFolder()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                            .settingsSearchTarget(.accessibilityPermission)
                        }

                                // MARK: - Options Section

                                VStack(spacing: 12) {
                                    self.optionToggleRow(
                                        title: "Start listening with a keyboard shortcut",
                                        description: "Dictation. Types what you said. Does not translate.",
                                        isOn: Binding(
                                            get: { SettingsStore.shared.listeningHotkeyEnabled },
                                            set: { newValue in
                                                SettingsStore.shared.listeningHotkeyEnabled = newValue
                                                self.hotkeyManager?.updatePrimaryShortcuts(self.primaryDictationShortcuts)
                                            }
                                        )
                                    )
                                    .settingsSearchTarget(.activationMode)
                                    Divider().opacity(0.2)

                                    if SettingsStore.shared.listeningHotkeyEnabled {
                                        HStack(alignment: .center) {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text("Shortcut behavior")
                                                    .font(self.theme.typography.bodyStrong)
                                                    .foregroundStyle(self.settingsTitleText)
                                                Text(self.hotkeyMode.description)
                                                    .font(self.theme.typography.bodySmall)
                                                    .foregroundStyle(self.settingsSecondaryText)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)

                                            Picker("", selection: self.$hotkeyMode) {
                                                ForEach(HotkeyActivationMode.allCases) { mode in
                                                    Text(mode.displayName).tag(mode)
                                                }
                                            }
                                            .pickerStyle(.menu)
                                            .frame(width: 170, alignment: .trailing)
                                        }
                                        .onChange(of: self.hotkeyMode) { _, newValue in
                                            SettingsStore.shared.hotkeyMode = newValue
                                            self.hotkeyManager?.setHotkeyMode(newValue)
                                        }
                                        Divider().opacity(0.2)
                                    }

                                    self.optionToggleRow(
                                        title: "Copy to Clipboard",
                                        description: "Automatically copy transcribed text to clipboard as a backup.",
                                        isOn: self.$copyToClipboard
                                    )
                                    .onChange(of: self.copyToClipboard) { _, newValue in
                                        SettingsStore.shared.copyTranscriptionToClipboard = newValue
                                    }
                                    .settingsSearchTarget(.copyToClipboard)
                                    Divider().opacity(0.2)

                                    HStack(alignment: .center) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Text Insertion Mode")
                                                .font(self.theme.typography.bodyStrong)
                                                .foregroundStyle(self.settingsTitleText)
                                            Text(SettingsStore.shared.textInsertionMode.description)
                                                .font(self.theme.typography.bodySmall)
                                                .foregroundStyle(self.settingsSecondaryText)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                        Picker("", selection: Binding(
                                            get: { SettingsStore.shared.textInsertionMode },
                                            set: { SettingsStore.shared.textInsertionMode = $0 }
                                        )) {
                                            ForEach(SettingsStore.TextInsertionMode.allCases) { mode in
                                                Text(mode.displayName).tag(mode)
                                            }
                                        }
                                        .pickerStyle(.menu)
                                        .frame(width: 170, alignment: .trailing)
                                    }
                                    .settingsSearchTarget(.textInsertionMode)
                                    Divider().opacity(0.2)

                                    self.spokenSendSettings
                                        .settingsSearchTarget(.spokenSend)
                                    Divider().opacity(0.2)

                                    self.optionToggleRow(
                                        title: "Save Transcription History",
                                        description: "Save transcriptions for stats tracking. Disable for privacy.",
                                        isOn: Binding(
                                            get: { SettingsStore.shared.saveTranscriptionHistory },
                                            set: {
                                                SettingsStore.shared.saveTranscriptionHistory = $0
                                                self.refreshAudioHistoryUsage()
                                            }
                                        )
                                    )
                                    .settingsSearchTarget(.transcriptionHistory)
                                    Divider().opacity(0.2)

                                    self.optionToggleRow(
                                        title: "Save Audio With History",
                                        description: "Store actual microphone audio locally with dictation history. Disabled by default.",
                                        isOn: Binding(
                                            get: { SettingsStore.shared.saveAudioWithTranscriptionHistory },
                                            set: {
                                                SettingsStore.shared.saveAudioWithTranscriptionHistory = $0
                                                self.refreshAudioHistoryUsage()
                                            }
                                        )
                                    )
                                    .disabled(!SettingsStore.shared.saveTranscriptionHistory)
                                    .settingsSearchTarget(.audioHistory)

                                    if SettingsStore.shared.saveTranscriptionHistory,
                                       SettingsStore.shared.saveAudioWithTranscriptionHistory
                                    {
                                        self.audioHistoryControls()
                                            .padding(.top, 2)
                                            .settingsSearchTarget(.audioStorage)
                                        Divider().opacity(0.2)
                                    } else {
                                        Divider().opacity(0.2)
                                    }

                                    self.optionToggleRow(
                                        title: "Weekends Don't Break Streak",
                                        description: "Skip Saturday and Sunday when calculating usage streaks. Perfect for weekday-only users.",
                                        isOn: Binding(
                                            get: { SettingsStore.shared.weekendsDontBreakStreak },
                                            set: { SettingsStore.shared.weekendsDontBreakStreak = $0 }
                                        )
                                    )
                                    .settingsSearchTarget(.usageStreak)
                                    Divider().opacity(0.2)

                                    self.optionToggleRow(
                                        title: "Skip Silent Recordings",
                                        description: "Avoid transcription when a recording up to four seconds contains only clear silence. Disabled by default to preserve quiet speech.",
                                        isOn: Binding(
                                            get: { SettingsStore.shared.skipSilentRecordingsEnabled },
                                            set: { SettingsStore.shared.skipSilentRecordingsEnabled = $0 }
                                        )
                                    )
                                    .settingsSearchTarget(.skipSilentRecordings)
                                    Divider().opacity(0.2)

                                    self.optionToggleRow(
                                        title: "Pause Media During Transcription",
                                        description: "Automatically pause currently playing audio/video when transcription starts. Resumes only if \(FluidProduct.displayName) paused it.",
                                        isOn: Binding(
                                            get: { SettingsStore.shared.pauseMediaDuringTranscription },
                                            set: { SettingsStore.shared.pauseMediaDuringTranscription = $0 }
                                        )
                                    )
                                    .settingsSearchTarget(.pauseMedia)
                                    Divider().opacity(0.2)

                                    DictionarySuggestionsSettingsRow()
                                        .settingsSearchTarget(.dictionarySuggestions)
                                }
                                .padding(12)
                    }
                    .padding(16)
                }
                .shownInSettingsSection(.dictation, selectedSection: self.selectedSection)

                ThemedCard(style: .standard) {
                    VStack(alignment: .leading, spacing: 14) {
                        FluidSectionHeader(title: "Text Formatting", systemImage: "textformat")

                        VStack(spacing: 16) {
                            self.settingsToggleRow(
                                title: "Lowercase First Letter",
                                description: "Start each transcription with a lowercase letter.",
                                isOn: Binding(
                                    get: { self.settings.gaavLowercaseFirstLetterEnabled },
                                    set: { self.settings.gaavLowercaseFirstLetterEnabled = $0 }
                                )
                            )
                            Divider().opacity(0.2)

                            self.settingsToggleRow(
                                title: "Remove Trailing Period",
                                description: "Drop a final period from transcriptions.",
                                isOn: Binding(
                                    get: { self.settings.gaavRemoveTrailingPeriodEnabled },
                                    set: { self.settings.gaavRemoveTrailingPeriodEnabled = $0 }
                                )
                            )
                            Divider().opacity(0.2)

                            self.settingsToggleRow(
                                title: "Slash Commands & @ Formatting",
                                description: "Convert spoken slash commands and supported @ mentions into symbols.",
                                isOn: Binding(
                                    get: { self.settings.literalDictationFormattingEnabled },
                                    set: { self.settings.literalDictationFormattingEnabled = $0 }
                                )
                            )
                            Divider().opacity(0.2)

                            self.settingsToggleRow(
                                title: "Space Between Dictations",
                                description: "Add spacing when consecutive dictations are joined.",
                                isOn: Binding(
                                    get: { self.settings.continuousDictationSpacingEnabled },
                                    set: { self.settings.continuousDictationSpacingEnabled = $0 }
                                )
                            )
                            Divider().opacity(0.2)

                            self.settingsToggleRow(
                                title: "Smart Capitalization",
                                description: "Use text before the cursor to choose uppercase or lowercase.",
                                isOn: Binding(
                                    get: { self.settings.contextAwareCapitalizationEnabled },
                                    set: { self.settings.contextAwareCapitalizationEnabled = $0 }
                                )
                            )
                        }
                    }
                    .padding(16)
                }
                .settingsSearchTarget(.textFormatting)
                .shownInSettingsSection(.dictation, selectedSection: self.selectedSection)

                // Notification Settings Card
                ThemedCard(style: .standard) {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 12) {
                            self.optionToggleRow(
                                title: "AI Enhancement Failures",
                                description: "Notify when AI Enhancement fails and raw transcription is typed.",
                                isOn: Binding(
                                    get: { SettingsStore.shared.notifyAIProcessingFailures },
                                    set: { SettingsStore.shared.notifyAIProcessingFailures = $0 }
                                )
                            )
                            .settingsSearchTarget(.aiEnhancementFailures)

                            Divider().opacity(0.2)

                            self.optionToggleRow(
                                title: "Microphone Changes",
                                description: "Show an alert when \(FluidProduct.displayName) changes or loses its microphone.",
                                isOn: Binding(
                                    get: { self.settings.showMicrophoneChangeAlerts },
                                    set: { enabled in
                                        self.settings.showMicrophoneChangeAlerts = enabled
                                        if enabled == false {
                                            MicrophoneChangeOverlayController.shared.hide()
                                        }
                                    }
                                )
                            )
                            .settingsSearchTarget(.microphoneChanges)
                        }
                    }
                    .padding(16)
                }
                .shownInSettingsSection(.notifications, selectedSection: self.selectedSection)

                // Audio Devices Card
                ThemedCard(style: .standard) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            FluidSectionHeader(title: "Audio Devices", systemImage: "speaker.wave.2.fill")

                            Spacer()

                            Button {
                                self.refreshDevices()
                                // Update cached default device names on refresh
                                let defaultInput = AudioDevice.getDefaultInputDevice()
                                self.cachedDefaultInputUID = defaultInput?.uid ?? ""
                                self.cachedDefaultOutputName = AudioDevice.getDefaultOutputDevice()?.name ?? ""
                            } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            self.microphonePrioritySection
                                .settingsSearchTarget(.inputDevicePriority)
                                .onChange(of: self.inputDevices) { _, newDevices in
                                    let defaultInput = AudioDevice.getDefaultInputDevice()
                                    self.cachedDefaultInputUID = defaultInput?.uid ?? ""
                                    guard newDevices.isEmpty == false else { return }
                                    if let selectedInput = self.appServices.microphonePreferenceCoordinator
                                        .reconcileMicrophoneSelection(
                                            availableInputs: newDevices,
                                            defaultInputUID: self.cachedDefaultInputUID
                                        )
                                    {
                                        self.selectedInputUID = selectedInput.uid
                                    }
                                }

                            HStack {
                                Text("Output Device")
                                    .font(self.theme.typography.bodyStrong)
                                    .foregroundStyle(self.settingsTitleText)
                                Spacer()
                                Picker("", selection: self.$selectedOutputUID) {
                                    // Handle empty state gracefully
                                    if self.outputDevices.isEmpty {
                                        Text("Loading...").tag("")
                                    } else {
                                        ForEach(self.outputDevices, id: \.uid) { dev in
                                            // Add "(System Default)" tag using cached name to avoid CoreAudio calls during layout
                                            let isSystemDefault = !self.cachedDefaultOutputName.isEmpty && dev.name == self.cachedDefaultOutputName
                                            Text(isSystemDefault ? "\(dev.name) (System Default)" : dev.name).tag(dev.uid)
                                        }
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 240)
                                .disabled(self.asr.isRunning) // Disable device changes during recording
                                .onChange(of: self.selectedOutputUID) { oldUID, newUID in
                                    guard !newUID.isEmpty else { return }

                                    // Prevent device changes during active recording
                                    if self.asr.isRunning {
                                        DebugLogger.shared.warning("Cannot change output device during recording", source: "SettingsView")
                                        // Revert to previous value
                                        self.selectedOutputUID = oldUID
                                        return
                                    }

                                    SettingsStore.shared.preferredOutputDeviceUID = newUID
                                    _ = AudioDevice.setDefaultOutputDevice(uid: newUID)
                                }
                                // Sync selection when devices load or change
                                .onChange(of: self.outputDevices) { _, newDevices in
                                    // Update cached default device name when device list changes
                                    self.cachedDefaultOutputName = AudioDevice.getDefaultOutputDevice()?.name ?? ""

                                    if !newDevices.isEmpty {
                                        let currentValid = newDevices.contains { $0.uid == self.selectedOutputUID }
                                        if !currentValid {
                                            if let prefUID = SettingsStore.shared.preferredOutputDeviceUID,
                                               newDevices.contains(where: { $0.uid == prefUID })
                                            {
                                                self.selectedOutputUID = prefUID
                                            } else if let defaultUID = AudioDevice.getDefaultOutputDevice()?.uid,
                                                      newDevices.contains(where: { $0.uid == defaultUID })
                                            {
                                                self.selectedOutputUID = defaultUID
                                            } else {
                                                self.selectedOutputUID = newDevices.first?.uid ?? ""
                                            }
                                        }
                                    }
                                }
                            }
                            .settingsSearchTarget(.outputDevice)

                            self.microphoneQualityGuidance
                        }
                    }
                    .padding(16)
                }
                .shownInSettingsSection(.audio, selectedSection: self.selectedSection)

                // Overlay Settings Card
                ThemedCard(style: .standard) {
                    VStack(alignment: .leading, spacing: 14) {
                        FluidSectionHeader(title: "Recording Overlay", systemImage: "rectangle.on.rectangle")
                        Text("This is the dictation recording chip. It is not Theater.")
                            .font(self.theme.typography.bodySmall)
                            .foregroundStyle(self.settingsSecondaryText)
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Sensitivity")
                                        .font(self.theme.typography.bodyStrong)
                                        .foregroundStyle(self.settingsTitleText)
                                    Text("Control how sensitive the audio visualizer is to sound input")
                                        .font(self.theme.typography.bodySmall)
                                        .foregroundStyle(self.settingsSecondaryText)
                                }

                                Spacer()

                                Button("Reset") {
                                    self.visualizerNoiseThreshold = 0.4
                                    SettingsStore.shared.visualizerNoiseThreshold = self.visualizerNoiseThreshold
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .settingsSearchTarget(.overlaySensitivity)

                            HStack(spacing: 10) {
                                Text("More")
                                    .font(.caption)
                                    .foregroundStyle(self.settingsSecondaryText)
                                    .frame(width: 36, alignment: .trailing)

                                Slider(value: self.$visualizerNoiseThreshold, in: 0.01...0.8, step: 0.01)
                                    .controlSize(.regular)

                                Text("Less")
                                    .font(.caption)
                                    .foregroundStyle(self.settingsSecondaryText)
                                    .frame(width: 36, alignment: .leading)

                                Text(String(format: "%.2f", self.visualizerNoiseThreshold))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(self.settingsTertiaryText)
                                    .frame(width: 36)
                            }

                            Divider().padding(.vertical, 8)

                            // Overlay Position
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Overlay Position")
                                        .font(self.theme.typography.bodyStrong)
                                        .foregroundStyle(self.settingsTitleText)
                                    Text("Where the recording indicator appears on screen")
                                        .font(self.theme.typography.bodySmall)
                                        .foregroundStyle(self.settingsSecondaryText)
                                }

                                Spacer()

                                Picker("", selection: self.$settings.overlayPosition) {
                                    ForEach(SettingsStore.OverlayPosition.allCases, id: \.self) { position in
                                        Text(position.displayName).tag(position)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 170, alignment: .trailing)
                            }
                            .settingsSearchTarget(.overlayPosition)

                            Divider().padding(.vertical, 8)

                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Transcription Preview Length")
                                            .font(self.theme.typography.bodyStrong)
                                            .foregroundStyle(self.settingsTitleText)
                                        Text("How many recent characters appear in the notch/pill preview")
                                            .font(self.theme.typography.bodySmall)
                                            .foregroundStyle(self.settingsSecondaryText)
                                    }

                                    Spacer()

                                    Text("\(self.settings.transcriptionPreviewCharLimit) chars")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(self.settingsSecondaryText)
                                }

                                HStack(spacing: 10) {
                                    Text("Less")
                                        .font(.caption)
                                        .foregroundStyle(self.settingsSecondaryText)
                                        .frame(width: 36, alignment: .trailing)

                                    Slider(
                                        value: Binding(
                                            get: { Double(self.settings.transcriptionPreviewCharLimit) },
                                            set: { self.settings.transcriptionPreviewCharLimit = Int($0.rounded()) }
                                        ),
                                        in: Double(SettingsStore.transcriptionPreviewCharLimitRange.lowerBound)...Double(SettingsStore.transcriptionPreviewCharLimitRange.upperBound),
                                        step: Double(SettingsStore.transcriptionPreviewCharLimitStep)
                                    )
                                    .controlSize(.regular)

                                    Text("More")
                                        .font(.caption)
                                        .foregroundStyle(self.settingsSecondaryText)
                                        .frame(width: 36, alignment: .leading)
                                }
                            }
                            .settingsSearchTarget(.transcriptionPreviewLength)

                            Divider().padding(.vertical, 4)

                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(self.settings.overlayPosition == .bottom ? "Overlay Size" : "Notch Style")
                                        .font(self.theme.typography.bodyStrong)
                                        .foregroundStyle(self.settingsTitleText)
                                    Text(
                                        self.settings.overlayPosition == .bottom
                                            ? "How large the recording indicator appears"
                                            : "Choose the regular notch or the compact layout"
                                    )
                                    .font(self.theme.typography.bodySmall)
                                    .foregroundStyle(self.settingsSecondaryText)
                                }

                                Spacer()

                                if self.settings.overlayPosition == .bottom {
                                    Picker("", selection: self.$settings.overlaySize) {
                                        ForEach(SettingsStore.OverlaySize.allCases, id: \.self) { size in
                                            Text(size.displayName).tag(size)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .frame(width: 170, alignment: .trailing)
                                } else {
                                    Picker("", selection: self.$settings.notchPresentationMode) {
                                        ForEach(SettingsStore.NotchPresentationMode.allCases, id: \.self) { mode in
                                            Text(mode.displayName).tag(mode)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .frame(width: 170, alignment: .trailing)
                                }
                            }
                            .settingsSearchTarget(.overlayStyle)

                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Live Preview")
                                        .font(self.theme.typography.bodyStrong)
                                        .foregroundStyle(self.settingsTitleText)
                                    Text("Show transcription text in the overlay while you speak")
                                        .font(self.theme.typography.bodySmall)
                                        .foregroundStyle(self.settingsSecondaryText)
                                }

                                Spacer()

                                Toggle("", isOn: self.$enableStreamingPreview)
                                    .labelsHidden()
                                    .onChange(of: self.enableStreamingPreview) { _, newValue in
                                        SettingsStore.shared.enableStreamingPreview = newValue
                                    }
                            }
                            .settingsSearchTarget(.livePreview)

                            // Bottom overlay specific settings (only show when bottom is selected)
                            if self.settings.overlayPosition == .bottom {
                                Divider().padding(.vertical, 4)

                                // Bottom Offset
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Bottom Offset")
                                            .font(self.theme.typography.bodyStrong)
                                            .foregroundStyle(self.settingsTitleText)
                                        Text("Distance from bottom of screen")
                                            .font(self.theme.typography.bodySmall)
                                            .foregroundStyle(self.settingsSecondaryText)
                                    }

                                    Spacer()

                                    HStack(spacing: 6) {
                                        Slider(value: self.$settings.overlayBottomOffset, in: 20...500)
                                            .frame(width: 110)
                                            .controlSize(.small)

                                        Text("\(Int(self.settings.overlayBottomOffset)) px")
                                            .font(.caption.monospaced())
                                            .foregroundStyle(self.settingsSecondaryText)
                                            .frame(width: 54, alignment: .trailing)
                                    }
                                    .frame(width: 170, alignment: .trailing)
                                }
                                .settingsSearchTarget(.bottomOffset)
                            }

                            if self.asr.isRunning {
                                Text("Settings are disabled during active recording")
                                    .font(.caption)
                                    .foregroundStyle(self.settingsSecondaryText)
                                    .italic()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 4)
                            }
                        }
                    }
                    .padding(16)
                }
                .settingsSearchTarget(.overlay)
                .shownInSettingsSection(.dictation, selectedSection: self.selectedSection)

                // Backup & Restore Card
                ThemedCard(style: .standard) {
                    self.backupUtilityRow()
                        .padding(16)
                }
                .settingsSearchTarget(.backupAndRestore)
                .shownInSettingsSection(.dataAndDiagnostics, selectedSection: self.selectedSection)

                // Debug Settings Card
                ThemedCard(style: .standard) {
                    VStack(alignment: .leading, spacing: 14) {
                        FluidSectionHeader(title: "Debug Settings", systemImage: "ladybug.fill")

                        VStack(alignment: .leading, spacing: 8) {
                            self.settingsToggleRow(
                                title: "Show Debug Logs in App",
                                description: "File logs are always collected for diagnostics.",
                                isOn: Binding(
                                    get: { SettingsStore.shared.enableDebugLogs },
                                    set: { SettingsStore.shared.enableDebugLogs = $0 }
                                )
                            )

                            Divider().padding(.vertical, 8)

                            Button {
                                let url = FileLogger.shared.currentLogFileURL()
                                if FileManager.default.fileExists(atPath: url.path) {
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                } else {
                                    DebugLogger.shared.info("Log file not found at \(url.path)", source: "SettingsView")
                                }
                            } label: {
                                Label("Reveal Log File", systemImage: "doc.richtext")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)

                            Text("The debug log contains detailed information about app operations and can help with troubleshooting.")
                                .font(self.theme.typography.bodySmall)
                                .foregroundStyle(self.settingsSecondaryText)
                            Text("Crash diagnostics are written to Library/Logs/fluidSubtitles/fluidSubtitles.log by default.")
                                .font(self.theme.typography.bodySmall)
                                .foregroundStyle(self.settingsSecondaryText)
                        }
                    }
                    .padding(16)
                }
                .settingsSearchTarget(.debugLogs)
                .shownInSettingsSection(.dataAndDiagnostics, selectedSection: self.selectedSection)

                ThemedCard(style: .standard) {
                    VStack(alignment: .leading, spacing: 14) {
                        self.settingsToggleRow(
                            title: "Faster Long Dictation",
                            description: "For long recordings, reuse completed live windows and process only the remaining tail when you stop.",
                            footnote: "Parakeet only. Falls back to normal transcription if reuse is unavailable or fails.",
                            isOn: Binding(
                                get: { SettingsStore.shared.experimentalParakeetUnifiedFinalEnabled },
                                set: { SettingsStore.shared.experimentalParakeetUnifiedFinalEnabled = $0 }
                            )
                        )

                        Divider().padding(.vertical, 4)

                        self.settingsToggleRow(
                            title: "Show Performance in History",
                            description: "Display transcription time and optional cleanup time.",
                            isOn: Binding(
                                get: { SettingsStore.shared.showHistoryPerformanceMetrics },
                                set: { SettingsStore.shared.showHistoryPerformanceMetrics = $0 }
                            )
                        )
                        .settingsSearchTarget(.historyPerformance)

                        Divider().padding(.vertical, 4)

                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Run Onboarding Again")
                                    .font(self.theme.typography.bodyStrong)
                                    .foregroundStyle(self.settingsTitleText)
                                Text("Replay the first-run Theater setup. Your models and settings stay.")
                                    .font(self.theme.typography.bodySmall)
                                    .foregroundStyle(self.settingsSecondaryText)
                            }
                            Spacer()
                            Button("Run Onboarding") {
                                self.settings.resetOnboardingProgress()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(16)
                }
                .settingsSearchTarget(.fasterLongDictation)
                .shownInSettingsSection(.experimental, selectedSection: self.selectedSection)
            }
            .fluidPageContent()
            .environment(\.settingsSearchPresentation, self.settingsSearchPresentation)
        }
        .id(self.selectedSection)
        .task(id: self.selectedSection) {
            await self.prepareSelectedSection()
        }
        .onChange(of: self.visualizerNoiseThreshold) { _, newValue in
            SettingsStore.shared.visualizerNoiseThreshold = newValue
        }
    }

    func refreshRollbackState() {
        self.rollbackVersion = SimpleUpdater.shared.latestRollbackVersion() ?? ""
    }

    func openIssueReportingPage() {
        guard let url = FluidProduct.issuesURL else { return }
        NSWorkspace.shared.open(url)
    }

    func exportBackup() {
        Task { await self.performBackupExport() }
    }

    func performBackupExport() async {
        do {
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = BackupService.shared.suggestedFilename()

            guard panel.runModal() == .OK, let url = panel.url else { return }

            let document = try await BackupService.shared.makeBackupDocument()
            let data = try BackupService.shared.encode(document)
            try data.write(to: url, options: .atomic)

            self.presentInfoAlert(
                title: "Backup Exported",
                message: "Saved your \(FluidProduct.displayName) backup to:\n\(url.path)"
            )
        } catch {
            self.presentErrorAlert(
                title: "Backup Export Failed",
                message: error.localizedDescription
            )
        }
    }

    func importBackup() {
        Task { await self.performBackupImport() }
    }

    func performBackupImport() async {
        do {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.json]

            guard panel.runModal() == .OK, let url = panel.url else { return }

            let data = try Data(contentsOf: url)
            let document = try BackupService.shared.decode(data)

            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short

            let confirm = NSAlert()
            confirm.messageText = "Import this backup?"
            confirm.informativeText = """
            This replaces your current settings, prompt profiles, and stats history.

            Exported: \(formatter.string(from: document.exportedAt))
            API keys are not included and will not be changed.
            """
            confirm.alertStyle = .warning
            confirm.addButton(withTitle: "Import")
            confirm.addButton(withTitle: "Cancel")

            guard confirm.runModal() == .alertFirstButtonReturn else { return }

            try await BackupService.shared.restore(document)
            self.syncLocalSettingsAfterBackupRestore()

            self.presentInfoAlert(
                title: "Backup Imported",
                message: "Your settings, prompt profiles, and stats were restored successfully."
            )
        } catch {
            self.presentErrorAlert(
                title: "Backup Import Failed",
                message: error.localizedDescription
            )
        }
    }

    func syncLocalSettingsAfterBackupRestore() {
        self.refreshAudioHistoryUsage()
    }

    func refreshAudioHistoryUsage() {
        self.audioHistoryUsageBytes = DictationAudioHistoryStore.shared.audioUsageBytes()
        self.audioHistoryBudgetText = Self.audioBudgetText(for: SettingsStore.shared.audioHistoryBudgetGB)
    }

    func applyAudioHistoryBudget() {
        let normalized = self.audioHistoryBudgetText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value > 0 else {
            self.presentErrorAlert(title: "Invalid Budget", message: "Enter a positive number of GB.")
            self.refreshAudioHistoryUsage()
            return
        }

        let newBudget = max(0.1, value)
        let newBudgetBytes = DictationAudioHistoryStore.bytes(forGigabytes: newBudget)
        if self.audioHistoryUsageBytes > newBudgetBytes {
            let confirm = NSAlert()
            confirm.messageText = "Prune saved audio?"
            confirm.informativeText = """
            This budget is below current audio usage. \(FluidProduct.displayName) will delete the oldest saved audio first and keep transcript history.
            """
            confirm.alertStyle = .warning
            confirm.addButton(withTitle: "Apply and Prune")
            confirm.addButton(withTitle: "Cancel")
            guard confirm.runModal() == .alertFirstButtonReturn else {
                self.refreshAudioHistoryUsage()
                return
            }
        }

        SettingsStore.shared.audioHistoryBudgetGB = newBudget
        let pruned = TranscriptionHistoryStore.shared.pruneAudioToBudget()
        self.refreshAudioHistoryUsage()
        if pruned > 0 {
            self.presentInfoAlert(title: "Audio Pruned", message: "Deleted oldest saved audio from \(pruned) history entries.")
        }
    }

    func deleteSavedAudio() {
        let confirm = NSAlert()
        confirm.messageText = "Delete saved audio?"
        confirm.informativeText = "This removes saved dictation audio only. Transcript history stays intact."
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: "Delete Audio")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        let removed = TranscriptionHistoryStore.shared.deleteAllSavedAudio()
        self.refreshAudioHistoryUsage()
        self.presentInfoAlert(title: "Audio Deleted", message: "Removed audio from \(removed) history entries.")
    }

    func exportAudioZip() {
        Task { @MainActor in
            do {
                let entries = try await TranscriptionHistoryStore.shared.entriesWithSavedAudio()
                guard entries.contains(where: {
                    DictationAudioHistoryStore.shared.audioFileExists(for: $0)
                }) else {
                    throw DictationAudioHistoryError.noAudioEntries
                }

                let panel = NSSavePanel()
                panel.canCreateDirectories = true
                panel.allowedContentTypes = [.zip]
                panel.nameFieldStringValue = DictationAudioHistoryStore.shared.suggestedAudioExportFilename()

                guard panel.runModal() == .OK, let url = panel.url else { return }
                try DictationAudioHistoryStore.shared.exportAudioArchive(
                    entries: entries,
                    to: url
                )
                self.presentInfoAlert(title: "Audio Export Saved", message: "Saved your dictation audio export to:\n\(url.path)")
            } catch {
                self.presentErrorAlert(title: "Audio Export Failed", message: error.localizedDescription)
            }
        }
    }

    func presentInfoAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func presentErrorAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func openPreviousBuildPicker() {
        Task { @MainActor in
            do {
                let repository = try SimpleUpdater.shared.publishedRepository()
                let options = try await SimpleUpdater.shared.fetchRecentReleaseBuildOptions(
                    owner: repository.owner,
                    repo: repository.repo,
                    limit: 3,
                    includePrerelease: SettingsStore.shared.betaReleasesEnabled
                )
                self.presentPreviousBuildPicker(options)
            } catch {
                self.openAllReleasesPage()
            }
        }
    }

    func presentPreviousBuildPicker(_ options: [SimpleUpdater.ReleaseBuildOption]) {
        guard !options.isEmpty else {
            self.openAllReleasesPage()
            return
        }

        let picker = NSAlert()
        picker.messageText = "Download Previous Build"
        picker.informativeText = "No local rollback backup was found. Choose a recent release build:"
        picker.alertStyle = .informational

        for option in options {
            picker.addButton(withTitle: option.version)
        }
        picker.addButton(withTitle: "All Releases")
        picker.addButton(withTitle: "Cancel")

        let response = picker.runModal()
        let first = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let index = response.rawValue - first

        if index >= 0, index < options.count {
            NSWorkspace.shared.open(options[index].url)
            return
        }
        if index == options.count {
            self.openAllReleasesPage()
        }
    }

    func openAllReleasesPage() {
        guard let url = FluidProduct.releasesURL else { return }
        NSWorkspace.shared.open(url)
    }

}

struct MicrophonePriorityDropDelegate: DropDelegate {
    let targetUID: String
    let settings: SettingsStore
    @Binding var draggedUID: String?
    let reorderAnimation: Animation?
    let onDropCompleted: () -> Void

    func validateDrop(info _: DropInfo) -> Bool {
        self.draggedUID != nil
    }

    func dropEntered(info _: DropInfo) {
        guard let draggedUID = self.draggedUID,
              draggedUID != self.targetUID
        else { return }

        let entries = self.settings.microphonePriority
        guard let sourceIndex = entries.firstIndex(where: { $0.uid == draggedUID }),
              let targetIndex = entries.firstIndex(where: { $0.uid == self.targetUID })
        else { return }

        withAnimation(self.reorderAnimation) {
            self.settings.reorderMicrophonePriority(
                fromOffsets: IndexSet(integer: sourceIndex),
                toOffset: targetIndex > sourceIndex ? targetIndex + 1 : targetIndex
            )
        }
    }

    func dropUpdated(info _: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info _: DropInfo) -> Bool {
        self.draggedUID = nil
        self.onDropCompleted()
        return true
    }
}

private extension View {
    @ViewBuilder
    func shownInSettingsSection(_ section: SettingsSection, selectedSection: SettingsSection) -> some View {
        if section == selectedSection {
            self
        }
    }
}

