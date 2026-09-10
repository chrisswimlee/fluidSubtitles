import Foundation

/// Optional polish on a **finished** lecture line via the local MLX runner or LM Studio.
/// Never used while a clause is still open. Never on the live caption path.
@MainActor
final class LLMTranslationEngine: TranslationEngine {
    let name = "Local MLX (finished lines)"

    func isAvailable(settings: SettingsStore = .shared) -> Bool {
        if settings.mlxRunnerEnabled {
            return true
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
            source: source,
            target: target
        )
    }

    func polish(
        sourceText: String,
        draft: String,
        priorSource: [String],
        source: TranslationLanguage,
        target: TranslationLanguage
    ) async throws -> String {
        let settings = SettingsStore.shared
        guard self.isAvailable(settings: settings) else {
            throw TranslationEngineError(message: "Local caption polish is off or no local chat provider is configured.")
        }

        let route = self.resolveRoute(settings: settings)
        let client = LLMClient.shared
        let config = LLMClient.Config(
            messages: LLMTranslationPrompt.polishMessages(
                sourceText: sourceText,
                draft: draft,
                priorSource: priorSource,
                sourceLanguage: source.displayName,
                targetLanguage: target.displayName
            ).map { $0.mapValues { $0 as Any } },
            model: route.model,
            baseURL: route.baseURL,
            apiKey: route.apiKey,
            streaming: false
        )
        let started = ProcessInfo.processInfo.systemUptime
        let response = try await client.call(config)
        let ms = Int(((ProcessInfo.processInfo.systemUptime - started) * 1000).rounded())
        DebugLogger.shared.info(
            "Caption polish finished in \(ms)ms chars=\(sourceText.count) model=\(route.model)",
            source: "LLMTranslationEngine"
        )
        let polished = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return polished.isEmpty ? draft : polished
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
        sourceLanguage: String,
        targetLanguage: String
    ) -> [[String: String]] {
        let contextBlock: String
        if priorSource.isEmpty {
            contextBlock = "None."
        } else {
            contextBlock = priorSource.enumerated()
                .map { "\($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
        }

        return [
            [
                "role": "system",
                "content": """
                You are polishing a live lecture caption.
                Source language: \(sourceLanguage). Caption language: \(targetLanguage).
                Improve the draft translation of the CURRENT sentence only.
                Use the previous source sentences to resolve pronouns, omitted subjects, and words like "that" or "그것".
                \(Self.languageGuidance(sourceLanguage: sourceLanguage, targetLanguage: targetLanguage))
                Do not invent facts. Do not add quotes, notes, or romanization.
                Keep names and glossary terms unchanged.
                Output only the polished caption.
                """,
            ],
            [
                "role": "user",
                "content": """
                Previous source sentences:
                \(contextBlock)

                Current source:
                \(sourceText)

                Draft translation:
                \(draft)
                """,
            ],
        ]
    }

    private static func languageGuidance(sourceLanguage: String, targetLanguage: String) -> String {
        let source = sourceLanguage.lowercased()
        let target = targetLanguage.lowercased()
        if source.contains("korean") {
            return "Korean is verb-final. The last predicate carries tense and politeness. Resolve omitted subjects from prior sentences. Do not leave a hanging clause."
        }
        if source.contains("thai") {
            return "Thai has no spaces. Treat this as one finished clause. Drop polite particles (ครับ/ค่ะ) in English unless they change meaning."
        }
        if target.contains("korean") {
            return "Use a complete lecture register in Korean (합니다/요) consistent with the prior captions."
        }
        if target.contains("thai") {
            return "Use natural spoken Thai for a lecture, with a polite ending if the source is formal."
        }
        return "Keep the caption one spoken sentence an audience can read aloud."
    }
}
