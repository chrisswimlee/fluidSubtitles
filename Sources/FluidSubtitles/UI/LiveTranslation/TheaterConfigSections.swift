import AVFoundation
import SwiftUI

/// Theater mode picker, shared by the Setup Wizard and Home so they can't drift.
struct TheaterModeSection: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var controller = LiveTranslationController.shared

    var accessibilityIdentifier: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Theater mode")
                .font(self.theme.typography.bodyStrong)
                .foregroundStyle(self.theme.palette.primaryText)
            TheaterWordPicker(
                accessibilityLabel: "Theater mode",
                accessibilityIdentifier: self.accessibilityIdentifier,
                options: Array(TheaterSessionMode.allCases),
                title: { $0.displayName },
                selection: Binding(
                    get: { self.settings.theaterSessionMode },
                    set: { self.controller.applyTheaterSessionMode($0) }
                )
            )
            .help(TheaterReadiness.modeStopsListen)
            Text(self.settings.theaterSessionMode.help)
                .font(self.theme.typography.bodySmall)
                .foregroundStyle(self.theme.palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Spoken-line picker, shared by Home, Settings, and the Setup Wizard. Stays visible and
/// disabled (rather than disappearing) when the pair is the same language, so
/// the control's absence is never mistaken for a bug.
struct TheaterSpokenLineSection: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var settings = SettingsStore.shared

    var accessibilityIdentifier: String

    var body: some View {
        TheaterSettingRow(
            title: TheaterReadiness.spokenLineTitle,
            detail: SpokenLanguageResolver.isSameLanguagePair()
                ? TheaterReadiness.spokenLineSameLanguage
                : self.settings.theaterSpokenLineMode.help
        ) {
            TheaterSpokenLinePicker(accessibilityIdentifier: self.accessibilityIdentifier)
                .disabled(SpokenLanguageResolver.isSameLanguagePair())
        }
    }
}

/// "Before you Listen" checklist, shared by Home and the Setup Wizard's Ready
/// step so a user can't finish the wizard without seeing what's still missing.
struct TheaterReadinessChecklist: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var appServices: AppServices
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var controller = LiveTranslationController.shared

    var openVoiceEngine: (() -> Void)?
    var openTranslationEngine: (() -> Void)?

    private var asr: ASRService { self.appServices.asr }

    private var snapshot: TheaterReadyGate.Snapshot {
        TheaterReadyGate.liveSnapshot(
            pack: self.controller.packAvailability,
            microphone: self.asr.micStatus,
            firstCaptionPrinted: self.settings.theaterListenUsed
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FluidSectionHeader(title: "Before you Listen", systemImage: "checklist")
            self.readyRow(TheaterEngineCopy.voiceTitle, done: self.snapshot.voiceEngineReady)
            if self.settings.theaterSessionMode == .translation {
                self.readyRow(TheaterEngineCopy.translationTitle, done: self.snapshot.languagePackReady)
            }
            self.readyRow("Microphone", done: self.snapshot.microphoneAllowed)
            Text(self.snapshot.nextAction)
                .font(self.theme.typography.bodySmall)
                .foregroundStyle(self.theme.palette.warning)
                .fixedSize(horizontal: false, vertical: true)
            if !self.snapshot.voiceEngineReady, let openVoiceEngine {
                Button("Voice Engine", action: openVoiceEngine)
                    .buttonStyle(.theaterText)
            }
            if self.settings.theaterSessionMode == .translation,
               !self.snapshot.languagePackReady,
               let openTranslationEngine
            {
                Button("Translation Engine", action: openTranslationEngine)
                    .buttonStyle(.theaterText)
            }
            if !self.snapshot.microphoneAllowed {
                Button(self.asr.micStatus == .notDetermined ? "Allow" : "Open Settings") {
                    if self.asr.micStatus == .notDetermined {
                        self.asr.requestMicAccess()
                    } else {
                        self.asr.openSystemSettingsForMic()
                    }
                }
                .buttonStyle(.theaterText)
            }
        }
        .task {
            await self.controller.refreshPackAvailability()
        }
    }

    private func readyRow(_ title: String, done: Bool) -> some View {
        Label(title, systemImage: done ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(done ? self.theme.palette.accent : self.theme.palette.secondaryText)
    }
}
