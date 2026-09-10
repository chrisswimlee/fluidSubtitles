import Foundation

/// Optional polish on a **finished** lecture line via the local MLX runner or LM Studio.
/// Never used while a clause is still open. Never on the live caption path.
@MainActor
final class LLMTranslationEngine: TranslationEngine {
    let name = "Local MLX (finished lines)"

    func isAvailable(settings: SettingsStore = .shared) -> Bool {
        if settings.mlxRunnerEnabled {
            return MLXRunnerService.shared.canServe
        }
        guard settings.llmTranslationPolishEnabled else { return false }
        let route = DictationProviderRoute.resolve(settings: settings)
        if route.usesPrivateAI { return false }
        return Self.isLocalEndpoint(route.baseURL) && !route.model.isEmpty
    }

    func translate(_ text: String, source: TranslationLanguage, target: TranslationLanguage) async throws -> String {
        try await self.polish(
            sourceText: text,
            draft: text,
            priorSource: [],
            priorCaptions: [],
            source: source,
            target: target
        )
    }

    func polish(
        sourceText: String,
        draft: String,
        priorSource: [String],
        priorCaptions: [String] = [],
        source: TranslationLanguage,
        target: TranslationLanguage
    ) async throws -> String {
        let settings = SettingsStore.shared
        guard self.isAvailable(settings: settings) else {
            throw TranslationEngineError(message: "Local caption polish is off or no local chat provider is configured.")
        }

        let route = self.resolveRoute(settings: settings)
        let client = LLMClient.shared
        var config = LLMClient.Config(
            messages: LLMTranslationPrompt.polishMessages(
                sourceText: sourceText,
                draft: draft,
                priorSource: priorSource,
                priorCaptions: priorCaptions,
                sourceLanguage: source.displayName,
                targetLanguage: target.displayName
            ).map { $0.mapValues { $0 as Any } },
            model: route.model,
            baseURL: route.baseURL,
            apiKey: route.apiKey,
            streaming: false,
            temperature: LiveTranslationTiming.polishTemperature,
            maxTokens: LiveTranslationTiming.polishMaxTokens
        )
        config.maxRetries = 0
        config.timeoutSeconds = Double(LiveTranslationTiming.polishTimeoutNanoseconds) / 1_000_000_000
        let started = ProcessInfo.processInfo.systemUptime
        let response = try await client.call(config)
        let ms = Int(((ProcessInfo.processInfo.systemUptime - started) * 1000).rounded())
        DebugLogger.shared.info(
            "Caption polish finished in \(ms)ms chars=\(sourceText.count) model=\(route.model)",
            source: "LLMTranslationEngine"
        )
        let polished = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let accepted = Self.acceptedPolished(polished, draft: draft, target: target) {
            MLXRunnerService.shared.markSuccessfulCall()
            return accepted
        }
        return draft
    }

    static func acceptedPolished(
        _ candidate: String,
        draft: String,
        target: TranslationLanguage
    ) -> String? {
        let polished = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if polished.isEmpty { return nil }
        if polished.contains(where: \.isNewline) { return nil }
        let draftCount = max(draft.trimmingCharacters(in: .whitespacesAndNewlines).count, 1)
        let ratio = Double(polished.count) / Double(draftCount)
        if ratio < 0.5 || ratio > 1.6 { return nil }
        if !Self.matchesTargetScript(polished, target: target) { return nil }
        return polished
    }

    static func matchesTargetScript(_ text: String, target: TranslationLanguage) -> Bool {
        let hasHangul = text.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) }
        let hasThai = text.unicodeScalars.contains { (0x0E00...0x0E7F).contains($0.value) }
        let hasLatin = text.contains { $0.isLetter && $0.isASCII }
        switch target.id {
        case "ko":
            return hasHangul
        case "th":
            return hasThai
        case "en":
            return hasLatin && !hasHangul && !hasThai
        default:
            return true
        }
    }

    private func resolveRoute(settings: SettingsStore) -> (model: String, baseURL: String, apiKey: String) {
        if settings.mlxRunnerEnabled {
            let model = MLXRunnerCatalog.model(
                id: settings.mlxRunnerModelID,
                extras: MLXRunnerService.shared.availableModels
            )
            return (
                model: model?.repo ?? settings.mlxRunnerModelID,
                baseURL: MLXRunnerService.shared.baseURL,
                apiKey: "mlx-runner"
            )
        }
        let route = DictationProviderRoute.resolve(settings: settings)
        return (
            model: route.model,
            baseURL: route.baseURL,
            apiKey: route.apiKey.isEmpty ? "lm-studio" : route.apiKey
        )
    }

    private static func isLocalEndpoint(_ baseURL: String) -> Bool {
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local")
    }
}

enum LLMTranslationPrompt {
    static func polishMessages(
        sourceText: String,
        draft: String,
        priorSource: [String],
        priorCaptions: [String] = [],
        sourceLanguage: String,
        targetLanguage: String
    ) -> [[String: String]] {
        let sourceBlock = Self.numberedBlock(priorSource)
        let captionBlock = Self.numberedBlock(priorCaptions)

        return [
            [
                "role": "system",
                "content": """
                You are checking a live language-exchange caption.
                Source language: \(sourceLanguage). Caption language: \(targetLanguage).
                Look at the spoken line and the draft caption together.
                Return the draft unchanged unless there is a clear error.
                If you change anything, change only a few words. Do not rewrite the sentence.
                Use the previous source sentences and captions to resolve pronouns and omitted subjects.
                \(Self.languageGuidance(sourceLanguage: sourceLanguage, targetLanguage: targetLanguage))
                Do not invent facts. Do not add quotes, notes, or romanization.
                Keep names and glossary terms unchanged.
                Keep polite particles (요, ครับ, ค่ะ) when the speaker used them.
                Output only the caption.
                """,
            ],
            [
                "role": "user",
                "content": """
                Previous source sentences:
                \(sourceBlock)

                Previous captions:
                \(captionBlock)

                Current source:
                \(sourceText)

                Draft translation:
                \(draft)
                """,
            ],
        ]
    }

    private static func numberedBlock(_ lines: [String]) -> String {
        if lines.isEmpty { return "None." }
        return lines.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
    }

    private static func languageGuidance(sourceLanguage: String, targetLanguage: String) -> String {
        let source = sourceLanguage.lowercased()
        let target = targetLanguage.lowercased()
        if source.contains("korean") {
            return "Korean is verb-final. Resolve omitted subjects from prior sentences. Do not leave a hanging clause."
        }
        if source.contains("thai") {
            return "Thai has no spaces. Treat this as one finished clause."
        }
        if target.contains("korean") {
            return "Keep the speaker's politeness. Do not upgrade casual speech into lecture 합니다 form."
        }
        if target.contains("thai") {
            return "Keep natural spoken Thai. Keep ครับ/ค่ะ when the source is polite."
        }
        return "Keep the caption one spoken sentence."
    }
}
