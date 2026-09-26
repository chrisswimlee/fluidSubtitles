import SwiftUI

/// Voice Engine (speech to text) and Translation Engine (Apple Translation) on one card.
struct TheaterEngineCards: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var controller = LiveTranslationController.shared

    var openVoiceEngine: (() -> Void)?
    var openTranslationEngine: (() -> Void)?
    var showsVoiceSection = true
    var showsVoiceCustomize = true
    var showsTranslationCustomize = true
    var showsPurpose = true

    var body: some View {
        ThemedCard(style: .standard, hoverEffect: false) {
            VStack(alignment: .leading, spacing: 16) {
                if self.showsVoiceSection {
                    self.engineSection(
                        title: TheaterEngineCopy.voiceTitle,
                        systemImage: "waveform",
                        purpose: self.showsPurpose ? TheaterEngineCopy.voicePurpose : nil,
                        engineName: TheaterEngineCopy.voiceEngineName(self.settings.selectedSpeechModel),
                        running: self.voiceRunningLine,
                        runningIsWarning: SpokenLanguageResolver.voiceEngineMismatchMessage() != nil,
                        accessibilityIdentifier: "theater.voiceEngine"
                    ) {
                        if self.showsVoiceCustomize, let openVoiceEngine {
                            Button(TheaterEngineCopy.voiceTitle, action: openVoiceEngine)
                                .buttonStyle(.theaterText)
                                .accessibilityIdentifier("theater.customizeVoiceEngine")
                        }
                    }

                    Divider().opacity(0.25)
                }

                self.engineSection(
                    title: TheaterEngineCopy.translationTitle,
                    systemImage: "translate",
                    purpose: self.showsPurpose ? TheaterEngineCopy.translationPurpose : nil,
                    engineName: TheaterEngineCopy.translationName(),
                    running: self.translationRunningLine,
                    runningIsWarning: self.translationRunningIsWarning,
                    accessibilityIdentifier: "theater.translationEngine"
                ) {
                    if self.showsTranslationCustomize, let openTranslationEngine {
                        Button(TheaterEngineCopy.translationTitle, action: openTranslationEngine)
                            .buttonStyle(.theaterText)
                            .accessibilityIdentifier("theater.customizeTranslationEngine")
                    }
                }
            }
        }
        .accessibilityIdentifier("theater.engines")
        .task {
            await self.controller.refreshPackAvailability()
        }
        .onChange(of: self.settings.theaterSessionMode) { _, _ in
            Task { await self.controller.refreshPackAvailability() }
        }
        .onChange(of: self.settings.translationSourceLanguageID) { _, _ in
            Task { await self.controller.refreshPackAvailability() }
        }
        .onChange(of: self.settings.translationTargetLanguageID) { _, _ in
            Task { await self.controller.refreshPackAvailability() }
        }
    }

    private var voiceRunningLine: String {
        if !self.showsPurpose, SpokenLanguageResolver.voiceEngineMismatchMessage() != nil {
            return ""
        }
        return TheaterEngineCopy.voiceRunningLine()
    }

    private var translationRunningLine: String {
        TheaterEngineCopy.translationRunningLine(
            mode: self.settings.theaterSessionMode,
            sameLanguage: SpokenLanguageResolver.isSameLanguagePair(),
            pack: self.controller.packAvailability,
            engine: self.settings.theaterTranslationEngine
        )
    }

    private var translationRunningIsWarning: Bool {
        guard self.settings.theaterSessionMode == .translation,
              !SpokenLanguageResolver.isSameLanguagePair()
        else { return false }
        switch self.controller.packAvailability {
        case .supported, .unsupported, .unknown:
            return true
        case .installed:
            return false
        }
    }

    private func engineSection<Accessory: View>(
        title: String,
        systemImage: String,
        purpose: String?,
        engineName: String,
        running: String,
        runningIsWarning: Bool,
        accessibilityIdentifier: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                FluidSectionHeader(title: title, systemImage: systemImage)
                Spacer(minLength: 12)
                accessory()
            }
            if let purpose {
                Text(purpose)
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(engineName)
                .font(self.theme.typography.bodyStrong)
                .foregroundStyle(self.theme.palette.primaryText)
                .accessibilityIdentifier("\(accessibilityIdentifier).name")
            if !running.isEmpty {
                Text(running)
                    .font(self.theme.typography.caption)
                    .foregroundStyle(
                        runningIsWarning ? self.theme.palette.warning : self.theme.palette.secondaryText
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
