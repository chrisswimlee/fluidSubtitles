//
//  SettingsView+Rows.swift
//  fluid
//
//  Settings form rows and local helpers.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension SettingsView {
    // MARK: - Helper Views

    func settingsToggleRow(
        title: String,
        description: String,
        footnote: String? = nil,
        errorMessage: String? = nil,
        isOn: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(self.theme.typography.bodyStrong)
                        .foregroundStyle(self.settingsTitleText)
                    Text(description)
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.settingsSecondaryText)
                }

                Spacer()

                Toggle(title, isOn: isOn)
                    .toggleStyle(.switch)
                    .tint(self.theme.palette.accent)
                    .labelsHidden()
                    .accessibilityLabel(title)
            }

            if let footnote = footnote {
                Text(footnote)
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.settingsSecondaryText)
            }

            if let errorMessage = errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(self.theme.palette.warning)
            }
        }
    }

    func backupUtilityRow() -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "externaldrive.fill")
                .font(.headline)
                .foregroundStyle(.primary)
                .frame(width: 24, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text("Backup & Restore")
                    .font(self.theme.typography.bodyStrong)
                    .foregroundStyle(self.settingsTitleText)
                Text("Export or import settings, prompt profiles, history, and stats. API keys excluded.")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.settingsSecondaryText)
            }

            Spacer(minLength: 16)

            HStack(spacing: 8) {
                Button(action: self.exportBackup) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .tint(self.theme.palette.accent)
                .controlSize(.regular)

                Button(action: self.importBackup) {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
    }

    func audioHistoryControls() -> some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Audio Storage")
                        .font(self.theme.typography.bodyStrong)
                        .foregroundStyle(self.settingsTitleText)
                    Text("Audio history: \(DictationAudioHistoryStore.formattedGigabytes(self.audioHistoryUsageBytes)) / \(Self.audioBudgetText(for: SettingsStore.shared.audioHistoryBudgetGB)) GB Budget")
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.settingsSecondaryText)

                    ProgressView(value: self.audioHistoryUsageFraction())
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 220)
                }

                Spacer(minLength: 16)

                HStack(spacing: 8) {
                    Text("Budget")
                        .font(.caption)
                        .foregroundStyle(self.settingsSecondaryText)

                    TextField("4", text: self.$audioHistoryBudgetText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 58)

                    Text("GB")
                        .font(.caption)
                        .foregroundStyle(self.settingsSecondaryText)

                    Button("Apply") {
                        self.applyAudioHistoryBudget()
                    }
                    .controlSize(.small)
                }
            }

            Divider().opacity(0.2)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Export Audio")
                        .font(self.theme.typography.bodyStrong)
                        .foregroundStyle(self.settingsTitleText)
                    Text("ZIP with manifest.jsonl and WAV audio.")
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.settingsSecondaryText)
                }

                Spacer(minLength: 16)

                Button {
                    self.exportAudioZip()
                } label: {
                    Label("Export ZIP", systemImage: "square.and.arrow.up")
                }
                .controlSize(.small)

                Button(role: .destructive) {
                    self.deleteSavedAudio()
                } label: {
                    Label("Delete Audio", systemImage: "trash")
                }
                .controlSize(.small)
                .disabled(self.audioHistoryUsageBytes <= 0)
            }
        }
    }

    static func audioBudgetText(for value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
    }

    func audioHistoryUsageFraction() -> Double {
        let budget = SettingsStore.shared.audioHistoryBudgetBytes
        guard budget > 0 else { return 0 }
        return min(1, Double(self.audioHistoryUsageBytes) / Double(budget))
    }

    func optionToggleRow(
        title: String,
        description: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(self.theme.typography.bodyStrong)
                    .foregroundStyle(self.settingsTitleText)
                Text(description)
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.settingsSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .tint(self.theme.palette.accent)
                .labelsHidden()
        }
    }

    func instructionsBox(
        title: String,
        steps: [String],
        warningStyle: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(warningStyle ? self.theme.palette.warning : self.theme.palette.accent)
                    .font(.caption)
                Text(title)
                    .font(self.theme.typography.bodySmallStrong)
                    .foregroundStyle(self.settingsTitleText)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.caption)
                            .foregroundStyle(warningStyle ? self.theme.palette.warning : self.theme.palette.accent)
                            .fontWeight(.semibold)
                            .frame(width: 16, alignment: .trailing)
                        Text(.init(step))
                            .font(.caption)
                            .foregroundStyle(.primary)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill((warningStyle ? self.theme.palette.warning : self.theme.palette.accent).opacity(0.12))
        )
    }

    @ViewBuilder
    func primaryDictationShortcutsList() -> some View {
        let addTarget = ShortcutRecordingTarget.primaryDictation(.add)
        let isAdding = self.isRecording(addTarget)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "mic.fill")
                    .foregroundStyle(self.settingsSecondaryText)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Primary Dictation Shortcuts")
                        .font(self.theme.typography.bodyStrong)
                        .foregroundStyle(self.settingsTitleText)
                    Text("Use any keyboard shortcut, auxiliary mouse button, or modified click.")
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.settingsSecondaryText)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    if isAdding {
                        self.shortcutRecordingMessage = nil
                        self.activeShortcutRecordingTarget = nil
                    } else {
                        DebugLogger.shared.debug("Starting to record new primary dictation shortcut", source: "SettingsView")
                        self.shortcutRecordingMessage = nil
                        self.activeShortcutRecordingTarget = addTarget
                    }
                } label: {
                    Label(isAdding ? "Cancel" : "Add shortcut", systemImage: isAdding ? "xmark" : "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!isAdding && self.isRecordingAnyShortcut)
            }

            ForEach(Array(self.primaryDictationShortcuts.enumerated()), id: \.offset) { index, shortcut in
                self.primaryDictationShortcutRow(shortcut: shortcut, index: index)
            }

            if isAdding {
                self.primaryDictationShortcutCaptureStatus(for: addTarget)
            }
        }
    }

    @ViewBuilder
    func primaryDictationShortcutRow(shortcut: HotkeyShortcut, index: Int) -> some View {
        let target = ShortcutRecordingTarget.primaryDictation(.replace(index))
        let isRecording = self.isRecording(target)

        HStack(spacing: 10) {
            Color.clear
                .frame(width: 20)

            if isRecording {
                self.shortcutCapturePill()
            } else {
                self.shortcutDisplayPill(shortcut.displayString)
            }

            Button(isRecording ? "Cancel" : "Change") {
                if isRecording {
                    self.shortcutRecordingMessage = nil
                    self.activeShortcutRecordingTarget = nil
                } else {
                    DebugLogger.shared.debug("Starting to record replacement primary dictation shortcut", source: "SettingsView")
                    self.shortcutRecordingMessage = nil
                    self.activeShortcutRecordingTarget = target
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!isRecording && self.isRecordingAnyShortcut)

            Button("Remove") {
                guard self.primaryDictationShortcuts.count > 1,
                      self.primaryDictationShortcuts.indices.contains(index)
                else { return }
                self.primaryDictationShortcuts.remove(at: index)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(self.primaryDictationShortcuts.count <= 1 || self.isRecordingAnyShortcut)

            if isRecording,
               let recordingMessage = self.shortcutRecordingMessage,
               !recordingMessage.isEmpty
            {
                Text(recordingMessage)
                    .font(.caption)
                    .foregroundStyle(self.theme.palette.warning)
            }
        }
    }

    func primaryDictationShortcutCaptureStatus(for target: ShortcutRecordingTarget) -> some View {
        HStack(spacing: 10) {
            Color.clear
                .frame(width: 20)

            self.shortcutCapturePill()

            if self.isRecording(target),
               let recordingMessage = self.shortcutRecordingMessage,
               !recordingMessage.isEmpty
            {
                Text(recordingMessage)
                    .font(.caption)
                    .foregroundStyle(self.theme.palette.warning)
            }
        }
    }

    func shortcutCapturePill() -> some View {
        Text("Press shortcut...")
            .font(.caption.weight(.medium))
            .foregroundStyle(.orange)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.orange.opacity(0.2))
            )
    }

    func shortcutDisplayPill(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospaced().weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.quaternary.opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(.primary.opacity(0.15), lineWidth: 1)
                    )
            )
    }

    @ViewBuilder
    func shortcutRow(
        content: ShortcutRowContent,
        shortcut: HotkeyShortcut?,
        isRecording: Bool,
        isAnyRecordingActive: Bool,
        recordingMessage: String? = nil,
        isEnabled: Binding<Bool>? = nil,
        requiresShortcutToEnable: Bool = false,
        onChangePressed: @escaping () -> Void,
        onRemovePressed: (() -> Void)? = nil
    ) -> some View {
        let enabledValue = isEnabled?.wrappedValue ?? true
        let hasShortcut = shortcut != nil
        let enableToggleDisabled = isAnyRecordingActive || (requiresShortcutToEnable && !hasShortcut)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: content.icon)
                    .foregroundStyle(content.iconColor)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(content.title)
                        .font(self.theme.typography.bodyStrong)
                        .foregroundStyle(self.settingsTitleText)
                    Text(content.description)
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.settingsSecondaryText)
                        .lineLimit(1)
                }

                Spacer()

                if let isEnabled {
                    Toggle("", isOn: isEnabled)
                        .toggleStyle(.switch)
                        .tint(self.theme.palette.accent)
                        .labelsHidden()
                        .disabled(enableToggleDisabled)
                }
            }

            HStack(spacing: 10) {
                Color.clear
                    .frame(width: 20)

                if isRecording {
                    self.shortcutCapturePill()
                } else {
                    self.shortcutDisplayPill(shortcut?.displayString ?? "Not set")
                }

                Button(isRecording ? "Cancel" : "Change") {
                    if isRecording {
                        self.shortcutRecordingMessage = nil
                        self.activeShortcutRecordingTarget = nil
                    } else {
                        onChangePressed()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!isRecording && (isAnyRecordingActive || (!enabledValue && hasShortcut)))

                if let onRemovePressed {
                    Button("Remove") {
                        onRemovePressed()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!hasShortcut || isAnyRecordingActive)
                }

                if isRecording, let recordingMessage, !recordingMessage.isEmpty {
                    Text(recordingMessage)
                        .font(.caption)
                        .foregroundStyle(self.theme.palette.warning)
                }
            }
        }
        .opacity(enabledValue ? 1 : 0.7)
    }
}

extension SettingsView {
    var isRecordingAnyShortcut: Bool {
        self.activeShortcutRecordingTarget != nil
    }

    var selectedSectionSearchResults: [SettingsSearchResult] {
        self.searchResults.filter { $0.section == self.selectedSection }
    }

    var settingsSearchPresentation: SettingsSearchPresentation? {
        guard let primaryTarget = self.selectedSectionSearchResults.first?.target else { return nil }
        return SettingsSearchPresentation(
            matchedTargets: Set(self.selectedSectionSearchResults.map(\.target)),
            primaryTarget: primaryTarget,
            scrollCoordinator: self.searchScrollCoordinator
        )
    }

    var settingsTitleText: Color {
        Color(nsColor: .labelColor)
    }

    var settingsSecondaryText: Color {
        self.colorScheme == .light ? Color(nsColor: .labelColor).opacity(0.90) : self.theme.palette.primaryText.opacity(0.82)
    }

    var settingsTertiaryText: Color {
        self.colorScheme == .light ? Color(nsColor: .labelColor).opacity(0.85) : self.theme.palette.secondaryText
    }

    var microphonePrioritySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Input Device Priority")
                    .font(self.theme.typography.bodyStrong)
                    .foregroundStyle(self.settingsTitleText)

                Spacer()

                if self.settings.suppressedMicrophoneUIDs.isEmpty == false {
                    Button {
                        self.settings.restoreRemovedMicrophones(with: self.inputDevices)
                        self.refreshActiveInputSelection()
                    } label: {
                        Label("Restore Removed", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.plain)
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.accent)
                    .disabled(self.isMicrophonePriorityEditingDisabled)
                }
            }

            VStack(spacing: 0) {
                if self.settings.microphonePriority.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "mic.slash")
                            .foregroundStyle(self.settingsSecondaryText)
                        Text(self.inputDevices.isEmpty ? "No microphones available" : "No microphones in priority")
                            .font(self.theme.typography.bodySmall)
                            .foregroundStyle(self.settingsSecondaryText)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 42)
                } else {
                    ForEach(Array(self.settings.microphonePriority.enumerated()), id: \.element.uid) { index, entry in
                        if index > 0 {
                            Divider().opacity(0.55)
                        }
                        self.microphonePriorityRow(entry, rank: index + 1)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(self.theme.palette.cardBackground.opacity(self.colorScheme == .light ? 0.72 : 0.52))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(self.theme.palette.cardBorder.opacity(0.7), lineWidth: 1)
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text("\(FluidProduct.displayName) tries microphones from top to bottom. Drag to reorder; unavailable devices keep their place.")
                .font(self.theme.typography.bodySmall)
                .foregroundStyle(self.settingsSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    func microphonePriorityRow(
        _ entry: SettingsStore.MicrophonePriorityEntry,
        rank: Int
    ) -> some View {
        let connectedDevice = self.inputDevices.first { $0.uid == entry.uid }
        let isAvailable = connectedDevice.map {
            self.appServices.microphonePreferenceCoordinator.isInputDeviceAvailable($0)
        } ?? false
        let isActive = entry.uid == self.microphonePreferenceCoordinator.confirmedActiveInputUID && isAvailable
        let isHovered = self.hoveredMicrophoneUID == entry.uid

        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(self.settingsTertiaryText.opacity(self.isMicrophonePriorityEditingDisabled ? 0.35 : 0.72))
                .frame(width: 18, height: 30)
                .contentShape(Rectangle())
                .onDrag {
                    self.draggedMicrophoneUID = entry.uid
                    return NSItemProvider(object: entry.uid as NSString)
                } preview: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(self.theme.palette.cardBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(self.theme.palette.cardBorder.opacity(0.8), lineWidth: 1)
                            )

                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(self.settingsTitleText)
                    }
                    .frame(width: 30, height: 30)
                    .shadow(color: Color.black.opacity(0.18), radius: 5, y: 2)
                }
                .allowsHitTesting(self.isMicrophonePriorityEditingDisabled == false)
                .accessibilityHidden(true)

            Text("\(rank).")
                .font(self.theme.typography.bodySmall)
                .foregroundStyle(self.settingsSecondaryText)
                .monospacedDigit()
                .frame(width: 22, alignment: .trailing)

            Text(entry.name)
                .font(self.theme.typography.bodyStrong)
                .foregroundStyle(isAvailable ? self.settingsTitleText : self.settingsSecondaryText)
                .lineLimit(1)

            Spacer(minLength: 8)

            if isHovered {
                Button(role: .destructive) {
                    self.removeMicrophonePriorityEntry(entry)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .systemRed).opacity(0.82))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(self.isMicrophonePriorityEditingDisabled)
                .help("Remove \(entry.name) from microphone priority")
                .accessibilityLabel("Remove \(entry.name)")
                .transition(.opacity)
            } else if isActive {
                Circle()
                    .fill(Color(nsColor: .systemGreen))
                    .frame(width: 7, height: 7)
                    .shadow(color: Color(nsColor: .systemGreen).opacity(0.45), radius: 3)
                    .accessibilityLabel("Active microphone")
            } else if isAvailable == false {
                Text("Unavailable")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.settingsSecondaryText)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 42)
        .contentShape(Rectangle())
        .opacity(isAvailable ? 1 : 0.62)
        .onHover { isHovering in
            let animation: Animation? = self.accessibilityReduceMotion ? nil : .easeOut(duration: 0.12)
            withAnimation(animation) {
                if isHovering {
                    self.hoveredMicrophoneUID = entry.uid
                } else if self.hoveredMicrophoneUID == entry.uid {
                    self.hoveredMicrophoneUID = nil
                }
            }
        }
        .onDrop(
            of: [UTType.plainText.identifier],
            delegate: MicrophonePriorityDropDelegate(
                targetUID: entry.uid,
                settings: self.settings,
                draggedUID: self.$draggedMicrophoneUID,
                reorderAnimation: self.accessibilityReduceMotion ? nil : .easeInOut(duration: 0.16),
                onDropCompleted: self.refreshActiveInputSelection
            )
        )
        .contextMenu {
            Button("Move Up") {
                self.settings.moveMicrophonePriority(uid: entry.uid, by: -1)
                self.refreshActiveInputSelection()
            }
            .disabled(self.isMicrophonePriorityEditingDisabled || rank == 1)

            Button("Move Down") {
                self.settings.moveMicrophonePriority(uid: entry.uid, by: 1)
                self.refreshActiveInputSelection()
            }
            .disabled(self.isMicrophonePriorityEditingDisabled || rank == self.settings.microphonePriority.count)

            Divider()

            Button("Remove from Priority", role: .destructive) {
                self.removeMicrophonePriorityEntry(entry)
            }
            .disabled(self.isMicrophonePriorityEditingDisabled)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Priority \(rank), \(entry.name)")
        .accessibilityValue(isActive ? "Active" : (isAvailable ? "Available" : "Unavailable"))
        .accessibilityAction(named: "Move up") {
            guard self.isMicrophonePriorityEditingDisabled == false, rank > 1 else { return }
            self.settings.moveMicrophonePriority(uid: entry.uid, by: -1)
            self.refreshActiveInputSelection()
        }
        .accessibilityAction(named: "Move down") {
            guard self.isMicrophonePriorityEditingDisabled == false,
                  rank < self.settings.microphonePriority.count
            else { return }
            self.settings.moveMicrophonePriority(uid: entry.uid, by: 1)
            self.refreshActiveInputSelection()
        }
        .accessibilityAction(named: "Remove from priority") {
            guard self.isMicrophonePriorityEditingDisabled == false else { return }
            self.removeMicrophonePriorityEntry(entry)
        }
    }

    var isMicrophonePriorityEditingDisabled: Bool {
        self.asr.isRunning || self.asr.isStarting
    }

    func refreshActiveInputSelection() {
        // Reuse the existing off-main hardware refresh so the green active
        // indicator and next capture resolve from live Core Audio.
        self.refreshDevices()
    }

    func removeMicrophonePriorityEntry(_ entry: SettingsStore.MicrophonePriorityEntry) {
        self.hoveredMicrophoneUID = nil
        self.settings.removeMicrophoneFromPriority(
            uid: entry.uid,
            isConnected: self.inputDevices.contains { $0.uid == entry.uid }
        )
        self.refreshActiveInputSelection()
    }

    var selectedInputDevice: AudioDevice.Device? {
        guard let confirmedUID = self.microphonePreferenceCoordinator.confirmedActiveInputUID else {
            return nil
        }
        return self.inputDevices.first { $0.uid == confirmedUID }
    }

    @ViewBuilder
    var microphoneQualityGuidance: some View {
        if self.selectedInputDevice?.isBluetooth == true {
            self.microphoneQualityGuidanceRow(
                message: "Bluetooth microphone mode can reduce headphone playback quality. Prefer a wired, USB, or display microphone when available.",
                systemImage: "exclamationmark.triangle.fill",
                color: self.theme.palette.warning
            )
        } else {
            self.microphoneQualityGuidanceRow(
                message: "This order applies only to \(FluidProduct.displayName) and does not change your macOS input.",
                systemImage: "info.circle",
                color: self.settingsSecondaryText
            )
        }
    }

    func microphoneQualityGuidanceRow(
        message: String,
        systemImage: String,
        color: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
            Text(message)
                .font(self.theme.typography.bodySmall)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension SettingsView {
    func prepareSelectedSection() async {
        do {
            try await Task.sleep(nanoseconds: self.accessibilityReduceMotion ? 120_000_000 : 240_000_000)
        } catch {
            return
        }

        guard !Task.isCancelled else { return }
        switch self.selectedSection {
        case .general:
            self.refreshRollbackState()
            self.settings.refreshLaunchAtStartupStatus(clearError: true, logMismatch: false)
        case .audio:
            await self.prepareAudioSettings()
        case .dictation:
            await self.refreshAudioHistoryUsageInBackground()
        case .notifications, .aiProviders, .dataAndDiagnostics, .experimental, .translation:
            break
        }
    }

    func prepareAudioSettings() async {
        // Keep Core Audio initialization out of the navigation transaction.
        await AudioStartupGate.shared.scheduleOpenAfterInitialUISettled()
        await AudioStartupGate.shared.waitUntilOpen()
        guard !Task.isCancelled else { return }

        self.refreshDevices()

        if !self.inputDevices.isEmpty {
            let defaultInput = AudioDevice.getDefaultInputDevice()
            self.cachedDefaultInputUID = defaultInput?.uid ?? ""
            if let selectedInput = self.appServices.microphonePreferenceCoordinator
                .reconcileMicrophoneSelection(
                    availableInputs: self.inputDevices,
                    defaultInputUID: self.cachedDefaultInputUID
                )
            {
                self.selectedInputUID = selectedInput.uid
            }
        }

        if !self.outputDevices.isEmpty {
            let outputValid = self.outputDevices.contains { $0.uid == self.selectedOutputUID }
            if !outputValid || self.selectedOutputUID.isEmpty {
                if let prefUID = SettingsStore.shared.preferredOutputDeviceUID,
                   self.outputDevices.contains(where: { $0.uid == prefUID })
                {
                    self.selectedOutputUID = prefUID
                } else if let defaultUID = AudioDevice.getDefaultOutputDevice()?.uid,
                          self.outputDevices.contains(where: { $0.uid == defaultUID })
                {
                    self.selectedOutputUID = defaultUID
                } else {
                    self.selectedOutputUID = self.outputDevices.first?.uid ?? ""
                }
            }
        }

        // Cache hardware names outside body evaluation to avoid the Core Audio/AttributeGraph race.
        let defaultInput = AudioDevice.getDefaultInputDevice()
        self.cachedDefaultInputUID = defaultInput?.uid ?? ""
        self.cachedDefaultOutputName = AudioDevice.getDefaultOutputDevice()?.name ?? ""
    }

    func refreshAudioHistoryUsageInBackground() async {
        let usageBytes = await Task.detached(priority: .utility) {
            DictationAudioHistoryStore.shared.audioUsageBytes()
        }.value
        guard !Task.isCancelled else { return }

        self.audioHistoryUsageBytes = usageBytes
        self.audioHistoryBudgetText = Self.audioBudgetText(for: SettingsStore.shared.audioHistoryBudgetGB)
    }
}
