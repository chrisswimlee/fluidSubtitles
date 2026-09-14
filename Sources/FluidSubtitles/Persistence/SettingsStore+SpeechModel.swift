//
//  SettingsStore+SpeechModel.swift
//  Fluid
//
//  Voice Engine catalog and the selected speech model.
//

import Combine
import Foundation
#if canImport(FluidAudio)
import FluidAudio
#endif

extension SettingsStore {
    // MARK: - Speech Model (Unified ASR Model Selection)

    /// Unified speech recognition model selection.
    /// Replaces the old TranscriptionProviderOption + WhisperModelSize dual-setting.
    enum SpeechModel: String, CaseIterable, Identifiable, Codable {
        /// Temporarily disabled in UI/runtime while Parakeet word boosting work is prioritized.
        /// Flip to `true` in a future round to re-enable Qwen without deleting implementation.
        static let qwenPreviewEnabled = false

        // MARK: - FluidAudio Models (Apple Silicon Only)

        case parakeetTDT = "parakeet-tdt"
        case parakeetTDTv2 = "parakeet-tdt-v2"
        case parakeetRealtime = "parakeet-realtime"
        case qwen3Asr = "qwen3-asr"
        case cohereTranscribeSixBit = "cohere-transcribe-6bit"
        case nemotronOffline = "nemotron-3.5-offline"
        case nemotronStreaming = "nemotron-3.5-streaming"
        case nemotronStreaming320 = "nemotron-3.5-streaming-320"

        // MARK: - Apple Native

        case appleSpeech = "apple-speech"
        case appleSpeechAnalyzer = "apple-speech-analyzer"

        // MARK: - Whisper Models (Universal)

        case whisperTiny = "whisper-tiny"
        case whisperBase = "whisper-base"
        case whisperSmall = "whisper-small"
        case whisperMedium = "whisper-medium"
        case whisperLargeTurbo = "whisper-large-turbo"
        case whisperLarge = "whisper-large"

        var id: String {
            rawValue
        }

        // MARK: - Display Properties

        var displayName: String {
            switch self {
            case .parakeetTDT: return "Parakeet TDT v3 (Multilingual)"
            case .parakeetTDTv2: return "Parakeet TDT v2 (English Only)"
            case .parakeetRealtime: return "Parakeet Flash (Beta)"
            case .qwen3Asr: return "Qwen3 ASR (Beta)"
            case .cohereTranscribeSixBit: return "Cohere Transcribe"
            case .nemotronOffline: return "Nemotron 3.5 Multilingual"
            case .nemotronStreaming: return "Nemotron Speech 3.5 - Ultra Fast Low Latency"
            case .nemotronStreaming320: return "Nemotron Speech 3.5 - Ultra Fast Low Latency"
            case .appleSpeech: return "Apple ASR Legacy"
            case .appleSpeechAnalyzer: return "Apple Speech - macOS 26+"
            case .whisperTiny: return "Whisper Tiny"
            case .whisperBase: return "Whisper Base"
            case .whisperSmall: return "Whisper Small"
            case .whisperMedium: return "Whisper Medium"
            case .whisperLargeTurbo: return "Whisper Large Turbo"
            case .whisperLarge: return "Whisper Large"
            }
        }

        var languageSupport: String {
            switch self {
            case .parakeetTDT:
                return "English (not Korean or Thai)"
            case .parakeetTDTv2: return "English Only (Higher Accuracy)"
            case .parakeetRealtime: return "English Only (Live Streaming)"
            case .qwen3Asr: return "Korean, English, Thai"
            case .cohereTranscribeSixBit: return "English, Korean"
            case .nemotronOffline, .nemotronStreaming, .nemotronStreaming320:
                return "Korean, English, Thai"
            case .appleSpeech, .appleSpeechAnalyzer:
                return "Korean, English, Thai"
            case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLargeTurbo, .whisperLarge:
                return "Korean, English, Thai"
            }
        }

        var downloadSize: String {
            switch self {
            case .parakeetTDT: return "~460.9 MiB"
            case .parakeetTDTv2: return "~442.9 MiB"
            case .parakeetRealtime: return "~428.4 MiB"
            case .qwen3Asr: return "~2.0 GiB"
            case .cohereTranscribeSixBit: return "~1.54 GiB"
            case .nemotronOffline: return "~530.8 MiB"
            case .nemotronStreaming: return "~668.2 MiB"
            case .nemotronStreaming320: return "~668.2 MiB"
            case .appleSpeech: return "Built-in"
            case .appleSpeechAnalyzer: return "Built-in"
            case .whisperTiny: return "~43.9 MiB"
            case .whisperBase: return "~81.0 MiB"
            case .whisperSmall: return "~257.3 MiB"
            case .whisperMedium: return "~793.0 MiB"
            case .whisperLargeTurbo: return "~845.3 MiB"
            case .whisperLarge: return "~1.55 GiB"
            }
        }

        var expectedDownloadBytes: Int64 {
            switch self {
            case .parakeetTDT: return 483_288_717
            case .parakeetTDTv2: return 464_421_712
            case .parakeetRealtime: return 449_190_189
            case .qwen3Asr: return 2000 * 1024 * 1024
            case .cohereTranscribeSixBit: return 1_650_748_785
            case .nemotronOffline: return 556_552_620
            case .nemotronStreaming, .nemotronStreaming320: return 700_685_415
            case .whisperTiny: return 45_981_088
            case .whisperBase: return 84_962_880
            case .whisperSmall: return 269_751_136
            case .whisperMedium: return 831_538_144
            case .whisperLargeTurbo: return 886_381_760
            case .whisperLarge: return 1_668_741_440
            case .appleSpeech, .appleSpeechAnalyzer: return 0
            }
        }

        var requiresAppleSilicon: Bool {
            switch self {
            case .parakeetTDT, .parakeetTDTv2, .parakeetRealtime, .qwen3Asr, .cohereTranscribeSixBit, .nemotronOffline, .nemotronStreaming, .nemotronStreaming320: return true
            default: return false
            }
        }

        var isWhisperModel: Bool {
            switch self {
            case .parakeetTDT, .parakeetTDTv2, .parakeetRealtime, .qwen3Asr, .cohereTranscribeSixBit, .nemotronOffline, .nemotronStreaming, .nemotronStreaming320, .appleSpeech, .appleSpeechAnalyzer: return false
            default: return true
            }
        }

        /// The GGUF filename for transcribe.cpp Whisper models.
        var whisperModelFile: String? {
            switch self {
            case .whisperTiny: return "whisper-tiny-Q8_0.gguf"
            case .whisperBase: return "whisper-base-Q8_0.gguf"
            case .whisperSmall: return "whisper-small-Q8_0.gguf"
            case .whisperMedium: return "whisper-medium-Q8_0.gguf"
            case .whisperLargeTurbo: return "whisper-large-v3-turbo-Q8_0.gguf"
            case .whisperLarge: return "whisper-large-v3-Q8_0.gguf"
            default: return nil
            }
        }

        var legacyWhisperModelFile: String? {
            switch self {
            case .whisperTiny: return "ggml-tiny.bin"
            case .whisperBase: return "ggml-base.bin"
            case .whisperSmall: return "ggml-small.bin"
            case .whisperMedium: return "ggml-medium.bin"
            case .whisperLargeTurbo: return "ggml-large-v3-turbo.bin"
            case .whisperLarge: return "ggml-large-v3.bin"
            default: return nil
            }
        }

        static let legacyWhisperModelFiles: Set<String> = [
            "ggml-tiny.bin",
            "ggml-base.bin",
            "ggml-small.bin",
            "ggml-medium.bin",
            "ggml-large-v3-turbo.bin",
            "ggml-large-v3.bin",
        ]

        /// The short model name for whisper.cpp internal usage
        var whisperModelName: String? {
            switch self {
            case .whisperTiny: return "tiny"
            case .whisperBase: return "base"
            case .whisperSmall: return "small"
            case .whisperMedium: return "medium"
            case .whisperLargeTurbo: return "large-v3-turbo"
            case .whisperLarge: return "large-v3"
            default: return nil
            }
        }

        // MARK: - Architecture Filtering

        /// Requires macOS 26 (Tahoe) or later
        var requiresMacOS26: Bool {
            switch self {
            case .appleSpeechAnalyzer: return true
            default: return false
            }
        }

        /// Requires macOS 15 or later.
        var requiresMacOS15: Bool {
            switch self {
            case .qwen3Asr, .cohereTranscribeSixBit: return true
            default: return false
            }
        }

        /// Returns models available for the current Mac's architecture and OS
        static var availableModels: [SpeechModel] {
            allCases.filter { model in
                if model == .whisperLargeTurbo, !CPUArchitecture.isAppleSilicon {
                    return false
                }
                if model == .whisperLarge, !CPUArchitecture.isAppleSilicon {
                    return false
                }
                if model == .qwen3Asr, !Self.qwenPreviewEnabled {
                    return false
                }
                if model == .nemotronStreaming320 {
                    return false
                }
                // Filter by Apple Silicon requirement
                if model.requiresAppleSilicon, !CPUArchitecture.isAppleSilicon {
                    return false
                }
                // Filter by macOS 15 requirement
                if model.requiresMacOS15, #unavailable(macOS 15.0) {
                    return false
                }
                // Filter by macOS 26 requirement
                if model.requiresMacOS26 {
                    if #available(macOS 26.0, *) {
                        return true
                    } else {
                        return false
                    }
                }
                return true
            }
        }

        /// First launch: Apple Speech Analyzer on macOS 26, else Apple Speech, else architecture fallback.
        static var defaultModel: SpeechModel {
            if Self.availableModels.contains(.appleSpeechAnalyzer) {
                return .appleSpeechAnalyzer
            }
            if Self.availableModels.contains(.appleSpeech) {
                return .appleSpeech
            }
            return CPUArchitecture.isAppleSilicon ? .parakeetTDT : .whisperBase
        }

        // MARK: - UI Card Metadata

        /// Human-readable marketing name for the card UI
        var humanReadableName: String {
            switch self {
            case .parakeetTDT: return "Blazing Fast - Multilingual"
            case .parakeetTDTv2: return "Blazing Fast - English"
            case .parakeetRealtime: return "Flash Dictation"
            case .qwen3Asr: return "Qwen3 - Multilingual"
            case .cohereTranscribeSixBit: return "Cohere - High Accuracy"
            case .nemotronOffline: return "Nemotron 3.5 Multilingual"
            case .nemotronStreaming: return "Nemotron Speech 3.5 - Ultra Fast Low Latency"
            case .nemotronStreaming320: return "Nemotron Speech 3.5 - Ultra Fast Low Latency"
            case .appleSpeech: return "Apple ASR Legacy"
            case .appleSpeechAnalyzer: return "Apple Speech - macOS 26+"
            case .whisperTiny: return "Fast & Light"
            case .whisperBase: return "Standard Choice"
            case .whisperSmall: return "Balanced Speed & Accuracy"
            case .whisperMedium: return "Medium Quality"
            case .whisperLargeTurbo: return "Higher Quality but Faster"
            case .whisperLarge: return "Maximum Accuracy"
            }
        }

        /// One-line description for the card UI
        var cardDescription: String {
            switch self {
            case .parakeetTDT:
                return "Fast English transcription. Korean and Thai Listen need Apple Speech, Cohere, or Whisper."
            case .parakeetTDTv2:
                return "English-only. Fastest Parakeet for English Theater and dictation."
            case .parakeetRealtime:
                return "English-only streaming dictation with live partial text. Korean and Thai Listen need another Voice Engine."
            case .qwen3Asr:
                return "Local FluidAudio model for Korean, English, or Thai. Heavier memory footprint."
            case .cohereTranscribeSixBit:
                return "High-accuracy English and Korean. Pick the language before Listen."
            case .nemotronOffline:
                return "Slower, more accurate Nemotron for Korean, English, or Thai. Thai is experimental."
            case .nemotronStreaming:
                return "Streaming Nemotron for Korean, English, or Thai. Thai is experimental."
            case .nemotronStreaming320:
                return "Streaming Nemotron for Korean, English, or Thai. Thai is experimental."
            case .appleSpeech:
                return "Built-in macOS speech. No download. Works for Korean, English, and Thai."
            case .appleSpeechAnalyzer:
                return "On-device Speech Analyzer for Korean, English, and Thai. Requires a newer macOS."
            case .whisperTiny:
                return "Minimal resource usage. Best for older Macs or battery life."
            case .whisperBase:
                return "Good balance of speed and accuracy. Works on any Mac."
            case .whisperSmall:
                return "Better accuracy than Base. Moderate resource usage."
            case .whisperMedium:
                return "High accuracy for demanding tasks. Requires more memory."
            case .whisperLargeTurbo:
                return "Near-maximum accuracy with optimized speed."
            case .whisperLarge:
                return "Best possible accuracy. Large download and memory usage."
            }
        }

        /// Minimum recommended RAM in GB for this model to run safely
        var requiredMemoryGB: Double {
            switch self {
            case .parakeetTDT, .parakeetTDTv2, .parakeetRealtime:
                return 4.0
            case .qwen3Asr:
                return 8.0
            case .cohereTranscribeSixBit:
                return 8.0
            case .nemotronOffline, .nemotronStreaming, .nemotronStreaming320:
                return 8.0
            case .appleSpeech, .appleSpeechAnalyzer:
                return 2.0 // Built-in, minimal overhead
            case .whisperTiny:
                return 2.0
            case .whisperBase:
                return 3.0
            case .whisperSmall:
                return 4.0
            case .whisperMedium:
                return 5.0
            case .whisperLargeTurbo:
                return 6.0
            case .whisperLarge:
                return 8.0
            }
        }

        /// Warning text for models with high memory requirements, nil if no warning needed
        var memoryWarning: String? {
            switch self {
            case .qwen3Asr:
                return "⚠️ Requires 8GB+ RAM. Best on newer Apple Silicon Macs."
            case .whisperLarge:
                return "⚠️ Requires 10GB+ RAM. May crash on systems with limited memory."
            case .whisperLargeTurbo:
                return "⚠️ Requires 8GB+ RAM. May be unstable on some systems."
            case .whisperMedium:
                return "Requires 6GB+ RAM for stable operation."
            default:
                return nil
            }
        }

        /// Speed rating (1-5, higher is faster)
        var speedRating: Int {
            switch self {
            case .parakeetTDT: return 5
            case .parakeetTDTv2: return 5
            case .parakeetRealtime: return 5
            case .qwen3Asr: return 3
            case .cohereTranscribeSixBit: return 3
            case .nemotronOffline: return 3
            case .nemotronStreaming, .nemotronStreaming320: return 4
            case .appleSpeech: return 4
            case .appleSpeechAnalyzer: return 4
            case .whisperTiny: return 4
            case .whisperBase: return 4
            case .whisperSmall: return 3
            case .whisperMedium: return 2
            case .whisperLargeTurbo: return 3
            case .whisperLarge: return 1
            }
        }

        /// Accuracy rating (1-5, higher is more accurate)
        var accuracyRating: Int {
            switch self {
            case .parakeetTDT: return 5
            case .parakeetTDTv2: return 5
            case .parakeetRealtime: return 4
            case .qwen3Asr: return 4
            case .cohereTranscribeSixBit: return 5
            case .nemotronOffline: return 5
            case .nemotronStreaming, .nemotronStreaming320: return 4
            case .appleSpeech: return 4
            case .appleSpeechAnalyzer: return 4
            case .whisperTiny: return 2
            case .whisperBase: return 3
            case .whisperSmall: return 4
            case .whisperMedium: return 4
            case .whisperLargeTurbo: return 5
            case .whisperLarge: return 5
            }
        }

        /// Exact speed percentage (0.0 - 1.0) for the liquid bars
        var speedPercent: Double {
            switch self {
            case .parakeetTDT: return 1.0
            case .parakeetTDTv2: return 1.0
            case .parakeetRealtime: return 1.0
            case .qwen3Asr: return 0.45
            case .cohereTranscribeSixBit: return 0.85
            case .nemotronOffline: return 0.85
            case .nemotronStreaming, .nemotronStreaming320: return 1.0
            case .appleSpeech: return 0.60
            case .appleSpeechAnalyzer: return 0.85
            case .whisperTiny: return 0.90
            case .whisperBase: return 0.80
            case .whisperSmall: return 0.60
            case .whisperMedium: return 0.40
            case .whisperLargeTurbo: return 0.65
            case .whisperLarge: return 0.20
            }
        }

        /// Exact accuracy percentage (0.0 - 1.0) for the liquid bars
        var accuracyPercent: Double {
            switch self {
            case .parakeetTDT: return 0.92
            case .parakeetTDTv2: return 0.96
            case .parakeetRealtime: return 0.75
            case .qwen3Asr: return 0.90
            case .cohereTranscribeSixBit: return 0.98
            case .nemotronOffline: return 0.90
            case .nemotronStreaming, .nemotronStreaming320: return 0.85
            case .appleSpeech: return 0.60
            case .appleSpeechAnalyzer: return 0.80
            case .whisperTiny: return 0.40
            case .whisperBase: return 0.60
            case .whisperSmall: return 0.70
            case .whisperMedium: return 0.80
            case .whisperLargeTurbo: return 0.95
            case .whisperLarge: return 1.00
            }
        }

        /// Optional badge text for the card (e.g., "Recommended")
        var badgeText: String? {
            switch self {
            case .appleSpeechAnalyzer: return "Recommended"
            case .parakeetRealtime: return "Faster English"
            case .qwen3Asr: return "Beta"
            case .cohereTranscribeSixBit: return "New"
            case .nemotronOffline, .nemotronStreaming, .nemotronStreaming320: return "New + Beta"
            default: return nil
            }
        }

        /// Optimization level for Apple Silicon (for display)
        var appleSiliconOptimized: Bool {
            switch self {
            case .parakeetTDT, .parakeetTDTv2, .parakeetRealtime, .qwen3Asr, .cohereTranscribeSixBit, .nemotronOffline, .nemotronStreaming, .nemotronStreaming320, .appleSpeechAnalyzer:
                return true
            default:
                return false
            }
        }

        /// Whether this model supports real-time streaming/chunk processing.
        /// Large Whisper models are too slow for streaming, so they only do final transcription on stop.
        var supportsStreaming: Bool {
            switch self {
            case .qwen3Asr, .whisperMedium, .whisperLargeTurbo, .whisperLarge:
                return false // Too slow for real-time chunk processing
            default:
                return true // All other models support streaming
            }
        }

        var supportsPronunciationMatching: Bool {
            #if arch(arm64)
            switch self {
            case .parakeetTDT, .parakeetTDTv2:
                return true
            default:
                return false
            }
            #else
            return false
            #endif
        }

        /// Preview update cadence for real-time transcription.
        /// Models without native incremental decoding should use a slower interval.
        var streamingPreviewIntervalSeconds: Double {
            switch self {
            case .parakeetRealtime:
                return 0.2
            case .nemotronStreaming, .nemotronStreaming320:
                return 0.32
            case .cohereTranscribeSixBit:
                return 1.0
            default:
                return 0.6
            }
        }

        /// Minimum audio required before attempting a preview decode.
        /// Cohere performs better with a slightly larger prefix than the default 1 second.
        var minimumStreamingPreviewSeconds: Double {
            switch self {
            case .parakeetRealtime:
                return 0.2
            case .nemotronStreaming, .nemotronStreaming320:
                return 0.64
            case .cohereTranscribeSixBit:
                return 1.5
            default:
                return 1.0
            }
        }

        /// Provider category for tab grouping
        enum Provider: String, CaseIterable {
            case nvidia = "NVIDIA"
            case apple = "Apple"
            case openai = "OpenAI"
            case qwen = "Qwen"
            case cohere = "Cohere"
        }

        /// Which provider this model belongs to
        var provider: Provider {
            switch self {
            case .parakeetTDT, .parakeetTDTv2, .parakeetRealtime, .nemotronOffline, .nemotronStreaming, .nemotronStreaming320:
                return .nvidia
            case .appleSpeech, .appleSpeechAnalyzer:
                return .apple
            case .qwen3Asr:
                return .qwen
            case .cohereTranscribeSixBit:
                return .cohere
            case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLargeTurbo, .whisperLarge:
                return .openai
            }
        }

        /// Get models filtered by provider
        static func models(for provider: Provider) -> [SpeechModel] {
            self.availableModels.filter { $0.provider == provider }
        }

        /// Whether this model is built-in or already downloaded on disk
        var isInstalled: Bool {
            switch self {
            case .appleSpeech, .appleSpeechAnalyzer:
                return true
            case .parakeetTDT:
                #if canImport(FluidAudio)
                return Self.parakeetModelsExist(version: .v3)
                #else
                return false
                #endif
            case .parakeetTDTv2:
                #if canImport(FluidAudio)
                return Self.parakeetModelsExist(version: .v2)
                #else
                return false
                #endif
            case .parakeetRealtime:
                #if canImport(FluidAudio)
                return Self.parakeetRealtimeModelsExist()
                #else
                return false
                #endif
            case .qwen3Asr:
                #if canImport(FluidAudio) && ENABLE_QWEN
                if #available(macOS 15.0, *) {
                    return Qwen3AsrModels.modelsExist(at: Qwen3AsrModels.defaultCacheDirectory())
                }
                return false
                #else
                return false
                #endif
            case .cohereTranscribeSixBit:
                guard
                    let spec = self.externalCoreMLSpec,
                    let directory = SettingsStore.shared.externalCoreMLArtifactsDirectory(for: self)
                else {
                    return false
                }
                return spec.validatesInstalledArtifacts(at: directory)
            case .nemotronOffline, .nemotronStreaming, .nemotronStreaming320:
                let hint: String
                switch self {
                case .nemotronOffline:
                    hint = "nemotron-3.5-asr-offline-6bit-CoreML"
                default:
                    hint = "nemotron-3.5-asr-streaming320-int8-CoreML"
                }
                let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                    .appendingPathComponent(hint, isDirectory: true)
                #if arch(arm64)
                return directory.map { NemotronProvider.artifactsAreComplete(at: $0) } ?? false
                #else
                return false
                #endif
            default:
                // Whisper models
                guard let whisperFile = self.whisperModelFile else { return false }
                let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                    .appendingPathComponent("WhisperModels")
                let modelURL = directory?.appendingPathComponent(whisperFile)
                guard
                    let modelURL,
                    let attributes = try? FileManager.default.attributesOfItem(atPath: modelURL.path),
                    let size = attributes[.size] as? NSNumber,
                    size.int64Value > 0
                else {
                    return false
                }
                return size.int64Value == self.expectedDownloadBytes
            }
        }

        #if canImport(FluidAudio)
        static func parakeetModelsExist(version: AsrModelVersion) -> Bool {
            let directory = AsrModels.defaultCacheDirectory(for: version)
            let vocabulary = directory.appendingPathComponent(ModelNames.ASR.vocabularyFile)
            guard
                AsrModels.modelsExist(at: directory, version: version),
                HuggingFaceModelDownloader.artifactIsComplete(at: vocabulary, isDirectory: false)
            else {
                return false
            }

            return AsrModels.requiredModelNames.allSatisfy { modelName in
                HuggingFaceModelDownloader.artifactIsComplete(
                    at: directory.appendingPathComponent(modelName, isDirectory: true),
                    isDirectory: true
                )
            }
        }

        static func parakeetRealtimeModelsExist() -> Bool {
            let modelsDirectory = AsrModels.defaultCacheDirectory().deletingLastPathComponent()
            let modelDirectory = modelsDirectory
                .appendingPathComponent("parakeet-eou-streaming", isDirectory: true)
                .appendingPathComponent(Repo.parakeetEou160.folderName, isDirectory: true)

            return ModelNames.ParakeetEOU.requiredModels.allSatisfy { modelName in
                let artifact = modelDirectory.appendingPathComponent(modelName)
                return HuggingFaceModelDownloader.artifactIsComplete(
                    at: artifact,
                    isDirectory: modelName.hasSuffix(".mlmodelc")
                )
            }
        }
        #endif

        /// Brand/provider name for the model (NVIDIA, Apple, OpenAI)
        var brandName: String {
            switch self {
            case .parakeetTDT, .parakeetTDTv2, .parakeetRealtime, .nemotronOffline, .nemotronStreaming, .nemotronStreaming320:
                return "NVIDIA"
            case .qwen3Asr:
                return "Qwen"
            case .cohereTranscribeSixBit:
                return "Cohere"
            case .appleSpeech, .appleSpeechAnalyzer:
                return "Apple"
            case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLargeTurbo, .whisperLarge:
                return "OpenAI"
            }
        }

        /// Whether this model uses Apple's SF Symbol for branding (apple.logo)
        var usesAppleLogo: Bool {
            switch self {
            case .appleSpeech, .appleSpeechAnalyzer: return true
            default: return false
            }
        }

        /// Brand color for the provider badge
        var brandColorHex: String {
            switch self {
            case .parakeetTDT, .parakeetTDTv2, .parakeetRealtime, .nemotronOffline, .nemotronStreaming, .nemotronStreaming320:
                return "#76B900"
            case .qwen3Asr:
                return "#E67E22"
            case .cohereTranscribeSixBit:
                return "#FA6B3C"
            case .appleSpeech, .appleSpeechAnalyzer:
                return "#A2AAAD" // Apple Gray
            case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLargeTurbo, .whisperLarge:
                return "#10A37F" // OpenAI Teal
            }
        }
    }

    // MARK: - Transcription Provider (ASR)

    /// Available transcription providers
    enum TranscriptionProviderOption: String, CaseIterable, Identifiable {
        case auto
        case fluidAudio
        case whisper

        var id: String {
            rawValue
        }

        var displayName: String {
            switch self {
            case .auto: return "Automatic (Recommended)"
            case .fluidAudio: return "FluidAudio (Apple Silicon)"
            case .whisper: return "Whisper (Intel/Universal)"
            }
        }

        var description: String {
            switch self {
            case .auto: return "Uses FluidAudio on Apple Silicon, Whisper on Intel"
            case .fluidAudio: return "Fast CoreML-based transcription optimized for M-series chips"
            case .whisper: return "whisper.cpp - CPU-based, works on any Mac"
            }
        }
    }

    /// Selected transcription provider - defaults to "auto" which picks based on architecture
    var selectedTranscriptionProvider: TranscriptionProviderOption {
        get {
            guard let rawValue = defaults.string(forKey: Keys.selectedTranscriptionProvider),
                  let option = TranscriptionProviderOption(rawValue: rawValue)
            else {
                return .auto
            }
            return option
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.selectedTranscriptionProvider)
        }
    }

    /// Selected Whisper model size - defaults to "base"
    var whisperModelSize: WhisperModelSize {
        get {
            guard let rawValue = defaults.string(forKey: Keys.whisperModelSize),
                  let size = WhisperModelSize(rawValue: rawValue)
            else {
                return .base
            }
            return size
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.whisperModelSize)
        }
    }
}

extension SettingsStore.SpeechModel {
        var supportedLanguageCodes: String? {
        switch self {
        case .parakeetTDT, .parakeetTDTv2, .parakeetRealtime:
            return "EN"
        case .cohereTranscribeSixBit:
            return "EN, KO"
        case .nemotronOffline, .nemotronStreaming, .nemotronStreaming320:
            return "EN, KO, TH"
        case .appleSpeech, .appleSpeechAnalyzer:
            return "EN, KO, TH"
        case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLargeTurbo, .whisperLarge:
            return "EN, KO, TH"
        case .qwen3Asr:
            return "EN, KO, TH"
        }
    }
}

extension SettingsStore {
    enum CohereLanguage: String, CaseIterable, Identifiable, Codable {
        case arabic = "ar"
        case german = "de"
        case greek = "el"
        case english = "en"
        case spanish = "es"
        case french = "fr"
        case italian = "it"
        case japanese = "ja"
        case korean = "ko"
        case dutch = "nl"
        case polish = "pl"
        case portuguese = "pt"
        case vietnamese = "vi"
        case mandarinChinese = "zh"

        var id: String {
            self.rawValue
        }

        var displayName: String {
            switch self {
            case .arabic: return "Arabic"
            case .german: return "German"
            case .greek: return "Greek"
            case .english: return "English"
            case .spanish: return "Spanish"
            case .french: return "French"
            case .italian: return "Italian"
            case .japanese: return "Japanese"
            case .korean: return "Korean"
            case .dutch: return "Dutch"
            case .polish: return "Polish"
            case .portuguese: return "Portuguese"
            case .vietnamese: return "Vietnamese"
            case .mandarinChinese: return "Mandarin Chinese"
            }
        }

        var tokenString: String {
            "<|\(self.rawValue)|>"
        }
    }

    // MARK: - Unified Speech Model Selection

    /// The selected speech recognition model.
    /// This unified setting replaces the old TranscriptionProviderOption + WhisperModelSize combination.
    var selectedSpeechModel: SpeechModel {
        get {
            // Check if already using new system
            if let rawValue = defaults.string(forKey: Keys.selectedSpeechModel),
               let model = SpeechModel(rawValue: rawValue)
            {
                // If Qwen was previously selected, transparently fall back while preview is disabled.
                if model == .qwen3Asr, !SpeechModel.qwenPreviewEnabled {
                    return SpeechModel.defaultModel
                }
                if model == .nemotronStreaming320 {
                    return .nemotronStreaming
                }
                let requiresAppleSiliconWhisper = model == .whisperLargeTurbo || model == .whisperLarge
                if requiresAppleSiliconWhisper, !CPUArchitecture.isAppleSilicon {
                    return .whisperBase
                }
                // Validate model is available on this architecture
                if model.requiresAppleSilicon && !CPUArchitecture.isAppleSilicon {
                    return .whisperBase
                }
                if model.requiresMacOS15, #unavailable(macOS 15.0) {
                    return .whisperBase
                }
                if model.requiresMacOS26, #unavailable(macOS 26.0) {
                    return .whisperBase
                }
                return model
            }

            // Migration: Convert old settings to new SpeechModel
            return self.migrateToSpeechModel()
        }
        set {
            objectWillChange.send()
            let model = newValue == .nemotronStreaming320 ? SpeechModel.nemotronStreaming : newValue
            self.defaults.set(model.rawValue, forKey: Keys.selectedSpeechModel)
        }
    }

    /// The language Whisper should transcribe, or `nil` to detect it from each recording.
    /// Existing installs keep automatic detection until the user selects a language.
    var selectedWhisperLanguageCode: String? {
        get {
            Self.whisperLanguageCode(fromStoredValue: self.defaults.string(forKey: Keys.selectedWhisperLanguageCode))
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue ?? Self.automaticWhisperLanguageCode, forKey: Keys.selectedWhisperLanguageCode)
        }
    }

    static func whisperLanguageCode(fromStoredValue value: String?) -> String? {
        guard let value, value != self.automaticWhisperLanguageCode else { return nil }
        return VoiceEngineLanguageCatalog.whisperLanguage(forCode: value) == nil ? nil : value
    }

    static func whisperLanguageBackupValue(for languageCode: String?) -> String {
        languageCode ?? self.automaticWhisperLanguageCode
    }

    static func whisperLanguageCode(fromBackupValue value: String) -> String? {
        value == self.automaticWhisperLanguageCode ? nil : value
    }

    var selectedCohereLanguage: CohereLanguage {
        get {
            if let rawValue = self.defaults.string(forKey: Keys.selectedCohereLanguage),
               let language = CohereLanguage(rawValue: rawValue)
            {
                return language
            }
            return .english
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.selectedCohereLanguage)
        }
    }

    var selectedNemotronLanguage: NemotronLanguage {
        get {
            if let rawValue = self.defaults.string(forKey: Keys.selectedNemotronLanguage),
               let language = NemotronLanguage.supportedLanguage(rawValue: rawValue)
            {
                return language
            }
            return .english
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.selectedNemotronLanguage)
        }
    }

    func externalCoreMLArtifactsDirectory(for model: SpeechModel) -> URL? {
        guard let spec = model.externalCoreMLSpec else { return nil }
        let paths = self.defaults.dictionary(forKey: Keys.externalCoreMLArtifactsDirectories) as? [String: String] ?? [:]
        if let storedPath = paths[model.rawValue], storedPath.isEmpty == false {
            return URL(fileURLWithPath: storedPath, isDirectory: true)
        }

        let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let fallback = cachesDirectory?.appendingPathComponent(spec.artifactFolderHint, isDirectory: true)
        guard let fallback else { return nil }
        if FileManager.default.fileExists(atPath: fallback.path) {
            return fallback
        }
        return nil
    }

    func setExternalCoreMLArtifactsDirectory(_ directory: URL?, for model: SpeechModel) {
        guard model.requiresExternalArtifacts else { return }
        objectWillChange.send()
        var paths = self.defaults.dictionary(forKey: Keys.externalCoreMLArtifactsDirectories) as? [String: String] ?? [:]
        if let directory {
            paths[model.rawValue] = directory.standardizedFileURL.path
        } else {
            paths.removeValue(forKey: model.rawValue)
        }
        self.defaults.set(paths, forKey: Keys.externalCoreMLArtifactsDirectories)
    }

    /// Migrates old TranscriptionProviderOption + WhisperModelSize settings to new SpeechModel
    func migrateToSpeechModel() -> SpeechModel {
        let oldProvider = self.defaults.string(forKey: Keys.selectedTranscriptionProvider) ?? "auto"
        let oldWhisperSize = self.defaults.string(forKey: Keys.whisperModelSize) ?? "ggml-base.bin"

        let newModel: SpeechModel

        switch oldProvider {
        case "whisper":
            // Map old whisper size to new model
            switch oldWhisperSize {
            case "ggml-tiny.bin": newModel = .whisperTiny
            case "ggml-base.bin": newModel = .whisperBase
            case "ggml-small.bin": newModel = .whisperSmall
            case "ggml-medium.bin": newModel = .whisperMedium
            case "ggml-large-v3.bin": newModel = CPUArchitecture.isAppleSilicon ? .whisperLarge : .whisperBase
            default: newModel = .whisperBase
            }
        case "fluidAudio":
            newModel = CPUArchitecture.isAppleSilicon ? .parakeetTDT : .whisperBase
        default: // "auto"
            newModel = SpeechModel.defaultModel
        }

        // Persist the migrated value
        self.defaults.set(newModel.rawValue, forKey: Keys.selectedSpeechModel)
        DebugLogger.shared.info("Migrated speech model settings: \(oldProvider)/\(oldWhisperSize) -> \(newModel.rawValue)", source: "SettingsStore")

        return newModel
    }
}
