import AppKit
import Combine
import SwiftUI

@MainActor
final class VoiceEngineSettingsViewModel: ObservableObject {
    let settings: SettingsStore
    private let appServices: AppServices
    private var cancellables = Set<AnyCancellable>()

    var asr: ASRService { self.appServices.asr }

    var areSpeechModelActionsBlocked: Bool {
        self.asr.isRunning
            || self.downloadingModel != nil
            || self.asr.hasActiveModelDownload
            || self.asr.hasActiveModelPreparation
            || self.asr.isCancellingModelPreparation
            || (!self.asr.isAsrReady && (self.asr.isDownloadingModel || self.asr.isLoadingModel))
    }

    @Published var modelSortOption: ModelSortOption = .provider
    @Published var providerFilter: SpeechProviderFilter = .all
    @Published var englishOnlyFilter: Bool = false
    @Published var installedOnlyFilter: Bool = false
    @Published var showSpeechFilters: Bool = false

    @Published var selectedSpeechProvider: SettingsStore.SpeechModel.Provider
    @Published var previewSpeechModel: SettingsStore.SpeechModel
    @Published var showAdvancedSpeechInfo: Bool = false
    @Published var suppressSpeechProviderSync: Bool = false
    @Published var skipNextSpeechModelSync: Bool = false

    var downloadingModel: SettingsStore.SpeechModel? {
        guard let modelID = self.asr.downloadingModelId else { return nil }
        return SettingsStore.SpeechModel.allCases.first { $0.id == modelID }
    }

    var downloadProgress: Double {
        self.asr.downloadProgress ?? 0.0
    }

    var isCancellingModelDownload: Bool {
        self.asr.isCancellingModelDownload
    }

    init(settings: SettingsStore, appServices: AppServices) {
        self.settings = settings
        self.appServices = appServices
        self.previewSpeechModel = settings.selectedSpeechModel
        self.selectedSpeechProvider = settings.selectedSpeechModel.provider
        appServices.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.objectWillChange.send()
                }
            }
            .store(in: &self.cancellables)
    }

    func onAppear() {
        if SpokenLanguageResolver.syncSpokenEngineToTheater(settings: self.settings),
           !self.asr.isRunningOrStarting
        {
            self.asr.resetTranscriptionProvider()
        }
        self.previewSpeechModel = self.settings.selectedSpeechModel
        self.selectedSpeechProvider = self.settings.selectedSpeechModel.provider

        Task {
            await self.asr.checkIfModelsExistAsync()
        }
    }

    func handleSelectedSpeechModelChange(_ newValue: SettingsStore.SpeechModel) {
        if self.skipNextSpeechModelSync {
            self.skipNextSpeechModelSync = false
            return
        }
        guard !self.suppressSpeechProviderSync else { return }
        self.previewSpeechModel = newValue
        self.setSelectedSpeechProvider(newValue.provider)
    }

    var filteredSpeechModels: [SettingsStore.SpeechModel] {
        var models = SettingsStore.SpeechModel.availableModels

        switch self.providerFilter {
        case .all:
            break
        case .nvidia:
            models = models.filter { $0.provider == .nvidia }
        case .apple:
            models = models.filter { $0.provider == .apple }
        case .cohere:
            models = models.filter { $0.provider == .cohere }
        case .openai:
            models = models.filter { $0.provider == .openai }
        }

        if self.englishOnlyFilter {
            models = models.filter { model in
                let label = model.languageSupport.lowercased()
                let title = model.humanReadableName.lowercased()
                return label.contains("english only") || title.contains("english")
            }
        }

        if self.installedOnlyFilter {
            models = models.filter { $0.isInstalled }
        }

        switch self.modelSortOption {
        case .provider:
            models.sort { $0.brandName.localizedCaseInsensitiveCompare($1.brandName) == .orderedAscending }
        case .accuracy:
            models.sort { $0.accuracyPercent > $1.accuracyPercent }
        case .speed:
            models.sort { $0.speedPercent > $1.speedPercent }
        }

        return models
    }

    func activateSpeechModel(_ model: SettingsStore.SpeechModel) {
        guard !self.areSpeechModelActionsBlocked else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            self.settings.selectedSpeechModel = model
            self.previewSpeechModel = model
            self.setSelectedSpeechProvider(model.provider)
        }
        SpokenLanguageResolver.pinSpokenEngineToSource(settings: self.settings)
        self.asr.resetTranscriptionProvider()
        Task {
            do {
                try await self.asr.ensureAsrReady()
            } catch is CancellationError {
                DebugLogger.shared.info("Model activation cancelled: \(model.displayName)", source: "AISettingsView")
            } catch {
                DebugLogger.shared.error("Failed to prepare model after activation: \(error)", source: "AISettingsView")
                self.asr.errorTitle = "Model Activation Failed"
                self.asr.errorMessage = error.localizedDescription
                self.asr.showError = true
            }
        }
    }

    func downloadSpeechModel(_ model: SettingsStore.SpeechModel) {
        guard !self.areSpeechModelActionsBlocked else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.asr.downloadModel(model, progressHandler: nil)
                DebugLogger.shared.info("Model download completed: \(model.displayName)", source: "VoiceEngineVM")
            } catch is CancellationError {
                DebugLogger.shared.info("Model download cancelled: \(model.displayName)", source: "VoiceEngineVM")
            } catch {
                DebugLogger.shared.error("Failed to download model \(model.displayName): \(error)", source: "VoiceEngineVM")
                self.asr.errorTitle = "Model Download Failed"
                self.asr.errorMessage = error.localizedDescription
                self.asr.showError = true
            }
        }
    }

    func cancelSpeechModelDownload() {
        guard self.downloadingModel != nil, !self.isCancellingModelDownload else { return }
        self.asr.cancelModelDownload()
    }

    func cancelActiveModelPreparation() {
        self.asr.cancelModelPreparation()
    }

    func deleteSpeechModel(_ model: SettingsStore.SpeechModel) {
        guard !self.areSpeechModelActionsBlocked else { return }
        let previousActive = self.settings.selectedSpeechModel

        Task {
            let shouldRestore = previousActive != model
            await MainActor.run {
                if shouldRestore {
                    self.suppressSpeechProviderSync = true
                }
                self.settings.selectedSpeechModel = model
                self.asr.resetTranscriptionProvider()
            }

            defer {
                Task { @MainActor in
                    guard shouldRestore else { return }
                    self.skipNextSpeechModelSync = true
                    self.settings.selectedSpeechModel = previousActive
                    self.asr.resetTranscriptionProvider()
                    if self.previewSpeechModel == model {
                        self.previewSpeechModel = model
                    }
                    self.suppressSpeechProviderSync = false
                }
            }

            await self.deleteModels()
        }
    }

    func isActiveSpeechModel(_ model: SettingsStore.SpeechModel) -> Bool {
        self.settings.selectedSpeechModel == model
    }

    var modelDescriptionText: String {
        let model = self.settings.selectedSpeechModel
        switch model {
        case .appleSpeech:
            return "Apple Speech uses built-in macOS recognition. No download. It hears every supported language on Intel and Apple Silicon."
        case .appleSpeechAnalyzer:
            return "Apple Speech Analyzer is on-device recognition for the languages this Mac includes. Requires macOS 26+. Other languages use Apple Speech or Whisper."
        case .parakeetTDT:
            return "Parakeet TDT v3 is the fast English engine on Apple Silicon. Other languages use Apple Speech or Whisper."
        case .parakeetTDTv2:
            return "Parakeet TDT v2 is English-only on Apple Silicon."
        case .parakeetRealtime:
            return "Parakeet Flash streams English with live partial text. Other languages need another Voice Engine."
        case .qwen3Asr:
            return "Qwen3 ASR is a local model for Korean, English, Thai, or Japanese. Higher memory. Requires macOS 15+."
        case .cohereTranscribeSixBit:
            return "Cohere Transcribe is a local CoreML engine for Cohere's languages. Pick the language before Listen."
        case .nemotronOffline:
            return "Nemotron 3.5 is slower and more accurate for most supported languages. Thai is experimental. Malay and Indonesian need Apple Speech or Whisper."
        case .nemotronStreaming, .nemotronStreaming320:
            return "Nemotron Speech 3.5 streams most supported languages. Thai is experimental. Malay and Indonesian need Apple Speech or Whisper."
        default:
            return "Whisper works on any Mac for every supported language."
        }
    }

    func downloadModels() async {
        do {
            try await self.asr.ensureAsrReady()
        } catch is CancellationError {
            DebugLogger.shared.info("Model download cancelled", source: "AISettingsView")
        } catch {
            DebugLogger.shared.error("Failed to download models: \(error)", source: "AISettingsView")
            self.asr.errorTitle = "Model Download Failed"
            self.asr.errorMessage = error.localizedDescription
            self.asr.showError = true
        }
    }

    func deleteModels() async {
        do {
            try await self.asr.clearModelCache()
            let model = self.settings.selectedSpeechModel
            if model.requiresExternalArtifacts {
                self.settings.setExternalCoreMLArtifactsDirectory(nil, for: model)
                self.asr.resetTranscriptionProvider()
            }
        } catch {
            DebugLogger.shared.error("Failed to delete models: \(error)", source: "AISettingsView")
        }
    }

    func setSelectedSpeechProvider(_ provider: SettingsStore.SpeechModel.Provider) {
        self.selectedSpeechProvider = provider
    }

    func openExternalModelSource(for model: SettingsStore.SpeechModel) {
        guard let url = model.externalCoreMLSpec?.sourceURL else { return }
        NSWorkspace.shared.open(url)
    }
}
