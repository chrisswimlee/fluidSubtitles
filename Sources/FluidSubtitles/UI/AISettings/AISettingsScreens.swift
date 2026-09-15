import AppKit
import SwiftUI

struct VoiceEngineSettingsScreen: View {
    let appServices: AppServices
    let theme: AppTheme

    @StateObject private var viewModel: VoiceEngineSettingsViewModel

    init(appServices: AppServices, theme: AppTheme) {
        self.appServices = appServices
        self.theme = theme
        _viewModel = StateObject(wrappedValue: VoiceEngineSettingsViewModel(
            settings: SettingsStore.shared,
            appServices: appServices
        ))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VoiceEngineSettingsView(
                    viewModel: self.viewModel,
                    settings: self.viewModel.settings,
                    theme: self.theme
                )
                .fluidPageContent()
                .id(Self.pageTopID)
            }
            .defaultScrollAnchor(.top)
            .onAppear {
                self.revealPageTop(using: proxy)
            }
        }
    }

    private static let pageTopID = "voice-engine-page-top"

    private func revealPageTop(using proxy: ScrollViewProxy) {
        proxy.scrollTo(Self.pageTopID, anchor: .top)
        DispatchQueue.main.async {
            NSApp.keyWindow?.makeFirstResponder(nil)
            proxy.scrollTo(Self.pageTopID, anchor: .top)
        }
    }
}

struct AIEnhancementSettingsScreen: View {
    let menuBarManager: MenuBarManager
    let theme: AppTheme
    @Binding var selectedConfigurationSection: AIEnhancementConfigurationSection
    @Binding var activeShortcutRecordingTarget: ShortcutRecordingTarget?
    @Binding var shortcutRecordingMessage: String?

    @StateObject private var viewModel: AIEnhancementSettingsViewModel

    init(
        menuBarManager: MenuBarManager,
        theme: AppTheme,
        selectedConfigurationSection: Binding<AIEnhancementConfigurationSection> = .constant(.providers),
        activeShortcutRecordingTarget: Binding<ShortcutRecordingTarget?> = .constant(nil),
        shortcutRecordingMessage: Binding<String?> = .constant(nil)
    ) {
        self.menuBarManager = menuBarManager
        self.theme = theme
        _selectedConfigurationSection = selectedConfigurationSection
        _activeShortcutRecordingTarget = activeShortcutRecordingTarget
        _shortcutRecordingMessage = shortcutRecordingMessage
        _viewModel = StateObject(wrappedValue: AIEnhancementSettingsViewModel(
            settings: SettingsStore.shared,
            menuBarManager: menuBarManager,
            promptTest: DictationPromptTestCoordinator.shared
        ))
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                AIEnhancementSettingsView(
                    viewModel: self.viewModel,
                    settings: self.viewModel.settings,
                    promptTest: self.viewModel.promptTest,
                    theme: self.theme,
                    selectedConfigurationSection: self.$selectedConfigurationSection,
                    activeShortcutRecordingTarget: self.$activeShortcutRecordingTarget,
                    shortcutRecordingMessage: self.$shortcutRecordingMessage
                )
            }
            .fluidPageContent()
        }
    }
}
