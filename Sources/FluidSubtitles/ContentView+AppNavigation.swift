//
//  ContentView+AppNavigation.swift
//  Fluid
//
//  Sidebar and detail routing for Theater and settings.
//

import AVFoundation
import SwiftUI

extension ContentView {
    var appSidebarView: some View {
        List(selection: self.$selectedSidebarItem) {
            Section {
                self.sidebarNavigationLink(.liveTranslation, title: "Theater", systemImage: "rectangle.on.rectangle")
            } header: {
                self.sidebarSectionHeader("Captions")
            }

            Section {
                self.sidebarNavigationLink(.voiceEngine, title: "Voice Engine", systemImage: "waveform")
                self.sidebarNavigationLink(.translationEngine, title: "Translation Engine", systemImage: "globe")
                self.sidebarNavigationLink(.customDictionary, title: "Custom Dictionary", systemImage: "text.book.closed.fill")
            } header: {
                self.sidebarSectionHeader("Setup")
            }

            Section {
                self.sidebarNavigationLink(.history, title: "History", systemImage: "clock.arrow.circlepath")
                self.sidebarNavigationLink(.stats, title: "Stats", systemImage: "chart.bar.fill")
            } header: {
                self.sidebarSectionHeader("Activity")
            }

            Section {
                self.sidebarNavigationLink(.welcome, title: "Getting Started", systemImage: "house.fill")
                self.sidebarNavigationLink(.changelog, title: "Changelog", systemImage: "doc.text.magnifyingglass")
                self.sidebarNavigationLink(.feedback, title: "Feedback", systemImage: "envelope.fill")
            } header: {
                self.sidebarSectionHeader("Help")
            }
        }
        .listStyle(.sidebar)
        .accentColor(self.theme.palette.accent)
        .animation(nil, value: self.selectedSidebarItem)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            self.settingsEntryButton
        }
    }

    var settingsSidebarView: some View {
        VStack(spacing: 0) {
            Button {
                self.closeSettings()
            } label: {
                HStack(spacing: self.theme.metrics.spacing.sm) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 18, height: 28)

                    Text("Back to app")
                        .font(self.theme.typography.sidebarItem)

                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
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

            List(selection: Binding(
                get: { self.settingsNavigation.selectedSection },
                set: { newValue in
                    guard let newValue else { return }
                    if self.settingsNavigation.isLeaving(.dictation, for: newValue)
                        || self.settingsNavigation.isLeaving(.translation, for: newValue)
                        || self.settingsNavigation.isLeaving(.aiProviders, for: newValue)
                    {
                        self.clearShortcutRecordingMode()
                    }
                    self.settingsNavigation.selectedSection = newValue
                    self.settingsSearchScrollRequest += 1
                }
            )) {
                ForEach(self.filteredSettingsSections) { section in
                    let isSelected = self.settingsNavigation.selectedSection == section
                    NavigationLink(value: section) {
                        HStack(spacing: self.theme.metrics.spacing.sm) {
                            Image(systemName: section.systemImage)
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.secondary)
                                .frame(width: 18)

                            Text(section.title)
                                .foregroundStyle(isSelected ? Color.white : Color.primary)
                        }
                        .font(self.theme.typography.sidebarItem)
                    }
                    .sidebarOptionHover(
                        isSelected: isSelected,
                        reduceMotion: self.accessibilityReduceMotion
                    )
                }
            }
            .listStyle(.sidebar)
            .accentColor(self.theme.palette.accent)
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
        guard self.isSettingsSearchActive else { return SettingsSection.allCases }
        let matchingSections = Set(self.settingsSearchResults.map(\.section))
        return SettingsSection.allCases.filter(matchingSections.contains)
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
            .filter { self.isSettingsSearchTargetAvailable($0.target) }
    }

    func isSettingsSearchTargetAvailable(_ target: SettingsSearchTarget) -> Bool {
        switch target {
        case .microphonePermission:
            return self.asr.micStatus != .authorized
        case .accessibilityPermission:
            return !self.accessibilityEnabled
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
                Image(systemName: "gearshape")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                Text("Settings")

                Spacer(minLength: self.theme.metrics.spacing.sm)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(self.theme.typography.sidebarItem)
            .padding(.horizontal, self.theme.metrics.spacing.md)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
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

    func sidebarNavigationLink(_ item: SidebarItem, title: String, systemImage: String) -> some View {
        let isSelected = self.selectedSidebarItem == item
        return NavigationLink(value: item) {
            HStack(spacing: self.theme.metrics.spacing.sm) {
                Image(nsImage: SidebarSymbolCache.image(named: systemImage))
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.secondary)
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)

                Text(title)
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
            }
            .font(self.theme.typography.sidebarItem)
            .padding(.vertical, self.theme.metrics.spacing.xs / 2)
        }
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
            Color(nsColor: .windowBackgroundColor)
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
