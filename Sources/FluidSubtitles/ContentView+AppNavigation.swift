//
//  ContentView+AppNavigation.swift
//  Fluid
//
//  Sidebar and detail routing for Theater and settings.
//

import AppKit
import AVFoundation
import SwiftUI

extension ContentView {
    var appSidebarView: some View {
        VStack(spacing: 0) {
            TheaterSidebarIdentity()
            self.sidebarLinks
                .frame(maxHeight: .infinity)
            self.settingsEntryButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(SidebarVibrancy())
        .animation(nil, value: self.selectedSidebarItem)
    }

    var sidebarLinks: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                self.sidebarSectionHeader("Board")
                self.sidebarNavigationLink(.liveTranslation, title: "Theater", systemImage: "captions.bubble")

                self.sidebarSectionHeader("Setup")
                Button {
                    self.settings.startSetupWizard()
                } label: {
                    self.sidebarRowLabel(
                        title: TheaterSetupWizard.title,
                        systemImage: "checklist",
                        isSelected: false
                    )
                }
                .buttonStyle(.plain)
                .sidebarOptionHover(isSelected: false, reduceMotion: self.accessibilityReduceMotion)
                .help(TheaterSetupWizard.welcomeDetail)
                .accessibilityLabel(TheaterSetupWizard.title)
                .accessibilityIdentifier("sidebar.setupWizard")
                self.sidebarNavigationLink(.voiceEngine, title: "Voice Engine", systemImage: "waveform")
                self.sidebarNavigationLink(.translationEngine, title: "Translation Engine", systemImage: "translate")
                self.sidebarNavigationLink(.customDictionary, title: "Custom Dictionary", systemImage: "text.book.closed.fill")

                self.sidebarSectionHeader("Activity")
                self.sidebarNavigationLink(.history, title: "History", systemImage: "clock.arrow.circlepath")
                self.sidebarNavigationLink(.stats, title: "Stats", systemImage: "chart.bar.fill")

                self.sidebarSectionHeader("Help")
                self.sidebarNavigationLink(.welcome, title: "Getting Started", systemImage: "book.closed")
                self.sidebarNavigationLink(.changelog, title: "Changelog", systemImage: "list.bullet.rectangle")
                self.sidebarNavigationLink(.feedback, title: "Feedback", systemImage: "envelope.fill")
            }
            .padding(.horizontal, self.theme.metrics.spacing.md)
            .padding(.bottom, self.theme.metrics.spacing.md)
        }
    }

    var settingsSidebarView: some View {
        VStack(spacing: 0) {
            Button {
                self.closeSettings()
            } label: {
                Text("Back")
                    .font(self.theme.typography.sidebarItem)
                .padding(.horizontal, self.theme.metrics.spacing.md)
                .padding(.top, self.theme.metrics.spacing.sm)
                .padding(.bottom, self.theme.metrics.spacing.xs)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(SidebarChromeButtonStyle(
                isHovered: self.isSettingsBackHovered,
                reduceMotion: self.accessibilityReduceMotion
            ))
            .onHover { self.isSettingsBackHovered = $0 }
            .help("Back to \(FluidProduct.displayName)")
            .accessibilityLabel("Back to \(FluidProduct.displayName)")

            SettingsSearchField(text: Binding(
                get: { self.settingsSearchQuery },
                set: { self.updateSettingsSearchQuery($0) }
            ), isActive: self.settingsNavigation.isPresented)
                .frame(height: 24)
                .padding(.horizontal, self.theme.metrics.spacing.md)
                .padding(.top, self.theme.metrics.spacing.xs)
                .padding(.bottom, self.theme.metrics.spacing.sm)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(self.filteredSettingsSections) { section in
                        let isSelected = self.settingsNavigation.selectedSection == section
                        let rowColor = isSelected
                            ? TheaterButtonInk.onAccent
                            : self.theme.palette.secondaryText
                        Button {
                            self.selectSettingsSection(section)
                        } label: {
                            Text(section.title)
                                .font(self.theme.typography.sidebarItem)
                                .fontWeight(isSelected ? .medium : .regular)
                                .foregroundStyle(rowColor)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(section.title)
                        .sidebarOptionHover(
                            isSelected: isSelected,
                            reduceMotion: self.accessibilityReduceMotion
                        )
                    }
                }
                .padding(.horizontal, self.theme.metrics.spacing.md)
            }
            .animation(nil, value: self.settingsNavigation.selectedSection)
        }
    }

    var isSettingsSearchActive: Bool {
        !self.settingsSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var settingsSearchResults: [SettingsSearchResult] {
        self.availableSettingsSearchResults(for: self.settingsSearchQuery)
    }

    var filteredSettingsSections: [SettingsSection] {
        let sections = SettingsSection.productSections
        guard self.isSettingsSearchActive else { return sections }
        let matchingSections = Set(self.settingsSearchResults.map(\.section))
        return sections.filter(matchingSections.contains)
    }

    func updateSettingsSearchQuery(_ query: String) {
        self.settingsSearchQuery = query
        self.settingsSearchScrollRequest += 1

        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let results = self.availableSettingsSearchResults(for: query)
        self.settingsNavigation.selectedSection = SettingsSearchIndex.preferredSection(
            current: self.settingsNavigation.selectedSection,
            results: results
        )
    }

    func availableSettingsSearchResults(for query: String) -> [SettingsSearchResult] {
        SettingsSearchIndex.results(for: query)
            .filter { SettingsSection.productSections.contains($0.section) }
            .filter { self.isSettingsSearchTargetAvailable($0.target) }
    }

    func isSettingsSearchTargetAvailable(_ target: SettingsSearchTarget) -> Bool {
        switch target {
        case .microphonePermission:
            return self.asr.micStatus != .authorized
        case .accessibilityPermission:
            return !self.accessibilityEnabled
        case .historyRetention:
            return SettingsStore.shared.saveTranscriptionHistory
        case .audioStorage:
            return SettingsStore.shared.saveTranscriptionHistory &&
                SettingsStore.shared.saveAudioWithTranscriptionHistory
        case .bottomOffset:
            return self.settings.overlayPosition == .bottom
        default:
            return true
        }
    }

    var settingsEntryButton: some View {
        Button {
            self.openSettings(.translation)
        } label: {
            HStack(spacing: self.theme.metrics.spacing.sm) {
                SettingsIconTile(systemName: "gearshape", size: 16)
                Text("Settings")
                    .font(self.theme.typography.sidebarItem)
            }
            .padding(.horizontal, self.theme.metrics.spacing.md)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarChromeButtonStyle(
            isHovered: self.isSettingsEntryHovered,
            reduceMotion: self.accessibilityReduceMotion
        ))
        .onHover { self.isSettingsEntryHovered = $0 }
        .help("Settings")
        .accessibilityLabel("Settings")
    }

    var modeTransitionAnimation: Animation {
        let duration = self.settingsNavigation.isPresented ? 0.16 : 0.1
        return self.accessibilityReduceMotion
            ? .easeOut(duration: 0.08)
            : .snappy(duration: duration, extraBounce: 0)
    }

    var sidebarTransitionDistance: CGFloat {
        self.accessibilityReduceMotion ? 0 : 8
    }

    func sidebarSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(self.theme.typography.sidebarSection)
            .foregroundStyle(.secondary)
            .textCase(nil)
            .padding(.top, self.theme.metrics.spacing.sm)
            .padding(.bottom, self.theme.metrics.spacing.xs)
    }

    func selectSettingsSection(_ section: SettingsSection) {
        if self.settingsNavigation.isLeaving(.dictation, for: section)
            || self.settingsNavigation.isLeaving(.translation, for: section)
            || self.settingsNavigation.isLeaving(.aiProviders, for: section)
        {
            self.clearShortcutRecordingMode()
        }
        self.settingsNavigation.selectedSection = section
        self.settingsSearchScrollRequest += 1
    }

    func sidebarRowLabel(title: String, systemImage: String, isSelected: Bool) -> some View {
        let rowColor = isSelected ? TheaterButtonInk.onAccent : self.theme.palette.secondaryText
        return HStack(spacing: self.theme.metrics.spacing.sm) {
            SettingsIconTile(
                systemName: systemImage,
                size: 16,
                emphasized: isSelected,
                tint: isSelected ? rowColor : nil
            )
            Text(title)
                .font(self.theme.typography.sidebarItem)
                .fontWeight(isSelected ? .medium : .regular)
                .foregroundStyle(rowColor)
        }
        .padding(.vertical, self.theme.metrics.spacing.xs / 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    func sidebarNavigationLink(_ item: SidebarItem, title: String, systemImage: String) -> some View {
        let isSelected = self.selectedSidebarItem == item
        return Button {
            self.selectedSidebarItem = item
        } label: {
            self.sidebarRowLabel(title: title, systemImage: systemImage, isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .sidebarOptionHover(
            isSelected: isSelected,
            reduceMotion: self.accessibilityReduceMotion
        )
        .accessibilityIdentifier(item.accessibilityIdentifier)
    }

    var themePreferenceButton: some View {
        Button {
            self.settings.themePreference = self.nextThemePreference(after: self.settings.themePreference)
        } label: {
            Image(systemName: self.settings.themePreference.systemImageName)
        }
        .help("Theme: \(self.settings.themePreference.displayName)")
        .accessibilityLabel("Theme")
    }

    func nextThemePreference(after preference: SettingsStore.ThemePreference) -> SettingsStore.ThemePreference {
        switch preference {
        case .system: return .light
        case .light: return .dark
        case .dark: return .system
        }
    }

    var todayStatsButton: some View {
        TodayStatsToolbarButton(typingWPM: self.settings.userTypingWPM) {
            self.navigateToApp(.stats)
        }
    }

    var detailView: some View {
        ZStack {
            self.theme.palette.windowBackground
                .ignoresSafeArea()

            // Preserve the app destination so Back never waits on expensive detail initialization.
            self.appDetailContent
                .opacity(self.settingsNavigation.isPresented ? 0 : 1)
                .offset(x: self.settingsNavigation.isPresented ? -6 : 0)
                .allowsHitTesting(!self.settingsNavigation.isPresented)
                .accessibilityHidden(self.settingsNavigation.isPresented)

            if self.settingsNavigation.isPresented {
                self.preferencesView
                    .transition(self.settingsDetailTransition)
            }
        }
        .animation(self.modeTransitionAnimation, value: self.settingsNavigation.isPresented)
    }

    var settingsDetailTransition: AnyTransition {
        if self.accessibilityReduceMotion {
            return .opacity
        }
        return .offset(x: 8).combined(with: .opacity)
    }

    var appDetailContent: AnyView {
        switch self.selectedSidebarItem ?? .liveTranslation {
        case .liveTranslation:
            return AnyView(LiveTranslationHomeView(
                openVoiceEngine: {
                    self.navigateToApp(.voiceEngine)
                },
                openTranslationEngine: {
                    self.navigateToApp(.translationEngine)
                }
            ))
        case .welcome:
            return AnyView(self.welcomeView)
        case .voiceEngine:
            return AnyView(VoiceEngineSettingsScreen(
                appServices: self.appServices,
                theme: self.theme
            ))
        case .translationEngine:
            return AnyView(TranslationEngineSettingsScreen(theme: self.theme))
        case .aiEnhancements, .cleanupStyles:
            return AnyView(AIEnhancementSettingsScreen(
                menuBarManager: self.menuBarManager,
                theme: self.theme,
                selectedConfigurationSection: self.aiEnhancementConfigurationSectionBinding,
                activeShortcutRecordingTarget: self.$activeShortcutRecordingTarget,
                shortcutRecordingMessage: self.$shortcutRecordingMessage
            ))
        case .customDictionary:
            return AnyView(CustomDictionaryView())
        case .stats:
            return AnyView(self.statsView)
        case .feedback:
            return AnyView(FeedbackView())
        case .changelog:
            return AnyView(ChangelogView())
        case .history:
            return AnyView(TranscriptionHistoryView())
        }
    }

}
