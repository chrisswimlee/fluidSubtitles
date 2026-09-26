import SwiftUI

/// Voice Engine picker. One row per engine: what it hears, then Use or Download.
struct TheaterVoiceEngineList: View {
    @ObservedObject var viewModel: VoiceEngineSettingsViewModel
    @Environment(\.theme) private var theme

    var body: some View {
        ThemedCard(style: .standard, hoverEffect: false) {
            VStack(alignment: .leading, spacing: 18) {
                FluidPageHeader(
                    systemImage: "waveform",
                    title: TheaterEngineCopy.voiceTitle,
                    subtitle: "Sharpens speech into text. It follows I speak. Apple Speech is enough to try."
                )

                Text(SpokenLanguageResolver.stageEngineSummary(settings: self.viewModel.settings))
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(
                        SpokenLanguageResolver.voiceEngineMismatchMessage(settings: self.viewModel.settings) == nil
                            ? self.theme.palette.secondaryText
                            : self.theme.palette.warning
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("voiceEngine.summary")

                ForEach(TheaterVoiceEngineGroup.all) { group in
                    let models = group.models
                    if !models.isEmpty {
                        self.section(group.title, models: models)
                    }
                }

                if self.viewModel.settings.selectedSpeechModel.supportsCustomVocabulary {
                    self.customWordsRow
                }
            }
        }
        .accessibilityIdentifier("voiceEngine.list")
    }

    private func section(_ title: String, models: [SettingsStore.SpeechModel]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(self.theme.typography.sectionTitle)
                .foregroundStyle(self.theme.palette.primaryText)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(models) { model in
                    self.row(model)
                }
            }
        }
    }

    private func row(_ model: SettingsStore.SpeechModel) -> some View {
        TheaterSideBySide(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(TheaterEngineCopy.voiceEngineName(model))
                    .font(self.theme.typography.bodyStrong)
                    .foregroundStyle(self.theme.palette.primaryText)
                Text(TheaterEngineCopy.voiceEngineDetail(model))
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } trailing: {
            self.actions(for: model)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voiceEngine.\(model.rawValue)")
    }

    @ViewBuilder
    private func actions(for model: SettingsStore.SpeechModel) -> some View {
        let blocked = self.viewModel.areSpeechModelActionsBlocked
        if self.viewModel.downloadingModel == model {
            HStack(spacing: 8) {
                if let progress = self.viewModel.asr.downloadProgress, !self.viewModel.isCancellingModelDownload {
                    ProgressView(value: progress)
                        .controlSize(.small)
                        .frame(width: 72)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(self.viewModel.isCancellingModelDownload ? "Cancelling…" : "Cancel") {
                    self.viewModel.cancelSpeechModelDownload()
                }
                .buttonStyle(.theaterText)
                .disabled(self.viewModel.isCancellingModelDownload)
            }
        } else if self.viewModel.isActiveSpeechModel(model), model.isInstalled, !self.viewModel.asr.isAsrReady,
                  self.viewModel.asr.isLoadingModel || self.viewModel.asr.isDownloadingModel
        {
            Text(self.viewModel.asr.modelPreparationStatusText)
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
                .lineLimit(2)
        } else {
            HStack(spacing: 8) {
                if self.viewModel.isActiveSpeechModel(model), model.isInstalled {
                    Text("In use")
                        .font(self.theme.typography.captionStrong)
                        .foregroundStyle(self.theme.palette.accent)
                        .accessibilityIdentifier("voiceEngine.inUse")
                } else if model.isInstalled {
                    Button("Use") {
                        self.viewModel.activateSpeechModel(model)
                    }
                    .buttonStyle(.theaterTextProminent)
                    .disabled(blocked)
                    .accessibilityIdentifier("voiceEngine.use.\(model.rawValue)")
                } else {
                    if model.requiresExternalArtifacts, model.externalCoreMLSpec?.sourceURL != nil {
                        Button("Model page") {
                            self.viewModel.openExternalModelSource(for: model)
                        }
                        .buttonStyle(.theaterText)
                        .disabled(blocked)
                    }
                    Button("Download") {
                        self.viewModel.downloadSpeechModel(model)
                    }
                    .buttonStyle(.theaterTextProminent)
                    .disabled(blocked)
                    .accessibilityIdentifier("voiceEngine.download.\(model.rawValue)")
                }

                if model.isInstalled, model.provider != .apple {
                    Button("Remove") {
                        self.viewModel.deleteSpeechModel(model)
                    }
                    .buttonStyle(.theaterTextDestructive)
                    .disabled(blocked)
                    .accessibilityLabel("Remove \(TheaterEngineCopy.voiceEngineName(model))")
                }
            }
        }
    }

    private var customWordsRow: some View {
        TheaterSideBySide(spacing: 12) {
            Text("Names and uncommon words for Parakeet live in Custom Dictionary.")
                .font(self.theme.typography.bodySmall)
                .foregroundStyle(self.theme.palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        } trailing: {
            Button("Custom Dictionary") {
                NotificationCenter.default.post(name: .openCustomDictionaryFromVoiceEngine, object: nil)
            }
            .buttonStyle(.theaterText)
            .accessibilityIdentifier("voiceEngine.customDictionary")
        }
    }
}

private struct TheaterVoiceEngineGroup: Identifiable {
    let title: String
    let models: [SettingsStore.SpeechModel]

    var id: String { self.title }

    static var all: [TheaterVoiceEngineGroup] {
        let available = SettingsStore.SpeechModel.availableModels
        func pick(_ matches: (SettingsStore.SpeechModel) -> Bool) -> [SettingsStore.SpeechModel] {
            available.filter(matches)
        }
        return [
            TheaterVoiceEngineGroup(title: "On this Mac", models: pick { $0.provider == .apple }),
            TheaterVoiceEngineGroup(
                title: "Parakeet",
                models: pick { $0 == .parakeetTDT || $0 == .parakeetTDTv2 || $0 == .parakeetRealtime }
            ),
            TheaterVoiceEngineGroup(title: "Whisper", models: pick(\.isWhisperModel)),
            TheaterVoiceEngineGroup(
                title: "Other",
                models: pick { model in
                    model.provider != .apple && !model.isWhisperModel
                        && model != .parakeetTDT && model != .parakeetTDTv2 && model != .parakeetRealtime
                }
            ),
        ]
    }
}

extension Notification.Name {
    static let openCustomDictionaryFromVoiceEngine = Notification.Name("OpenCustomDictionaryFromVoiceEngine")
}
