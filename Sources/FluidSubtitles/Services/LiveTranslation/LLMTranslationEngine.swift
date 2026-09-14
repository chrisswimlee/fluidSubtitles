import Foundation

/// Counts local-MT echoes for one Listen. After most lines echo, skip local
/// and keep Apple Translation as the fallback.
struct LocalTranslationEchoTally: Equatable {
    var attempts = 0
    var echoes = 0

    var shouldSkipLocal: Bool {
        guard self.attempts >= LiveTranslationTiming.localEchoFailMinimumAttempts else { return false }
        return Double(self.echoes) / Double(self.attempts) >= LiveTranslationTiming.localEchoFailRatio
    }

    mutating func record(echoed: Bool) {
        self.attempts += 1
        if echoed { self.echoes += 1 }
    }
}

/// Local MLX / LM Studio caption translation. Commit uses it only when the
/// runner is already up. It never rewrites a line already on the board.
@MainActor
final class LLMTranslationEngine: TranslationEngine {
    let name = "Local MLX (finished lines)"
    private(set) var echoTally = LocalTranslationEchoTally()
    private var didLogEchoSkip = false

    func isAvailable(settings: SettingsStore = .shared) -> Bool {
        if settings.mlxRunnerEnabled {
            return true
        }
        guard settings.llmTranslationPolishEnabled else { return false }
        let route = DictationProviderRoute.resolve(settings: settings)
        if route.usesPrivateAI { return false }
        return Self.isLocalEndpoint(route.baseURL) && !route.model.isEmpty
    }

    /// Do not start MLX on the first caption. Only use it when it is already up.
    func isReadyForCommitTranslation(settings: SettingsStore = .shared) -> Bool {
        if self.echoTally.shouldSkipLocal {
            if !self.didLogEchoSkip {
                self.didLogEchoSkip = true
                DebugLogger.shared.debug(
                    "Local commit skipped: \(self.echoTally.echoes)/\(self.echoTally.attempts) lines echoed",
                    source: "LLMTranslationEngine"
                )
            }
            return false
        }
        if settings.mlxRunnerEnabled, MLXRunnerService.shared.status.running {
            return true
        }
        guard settings.llmTranslationPolishEnabled else { return false }
        let route = DictationProviderRoute.resolve(settings: settings)
        if route.usesPrivateAI { return false }
        return Self.isLocalEndpoint(route.baseURL) && !route.model.isEmpty
    }

    func resetListenEchoTally() {
        self.echoTally = LocalTranslationEchoTally()
        self.didLogEchoSkip = false
    }

    func noteListenEcho(_ echoed: Bool) {
        self.echoTally.record(echoed: echoed)
    }

    func translate(_ text: String, source: TranslationLanguage, target: TranslationLanguage) async throws -> String {
        try await self.translateCommit(
            text,
            priorSource: [],
            source: source,
            target: target
        )
    }

    /// First-print translation when the local MLX runner is on. Falls back to
    /// Apple Translation if this throws or the line is rejected.
    func translateCommit(
        _ text: String,
        priorSource: [String],
        source: TranslationLanguage,
        target: TranslationLanguage
    ) async throws -> String {
        let settings = SettingsStore.shared
        guard self.isAvailable(settings: settings) else {
            throw TranslationEngineError(message: "Local caption translation is off.")
        }
        if settings.mlxRunnerEnabled {
            let ready = await MLXRunnerService.shared.prepareToPolish()
            guard ready else {
                throw TranslationEngineError(message: "Local MLX runner is not running.")
            }
        }
        let route = self.resolveRoute(settings: settings)
        var config = LLMClient.Config(
            messages: LLMTranslationPrompt.translateMessages(
                sourceText: text,
                priorSource: priorSource,
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
        config.timeoutSeconds = Double(LiveTranslationTiming.commitTranslationTimeoutNanoseconds) / 1_000_000_000
        let response = try await LLMClient.shared.call(config)
        let cleaned = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        switch Self.commitVerdict(cleaned, sourceText: text, target: target) {
        case .accept(let caption):
            self.noteListenEcho(false)
            MLXRunnerService.shared.markSuccessfulCall()
            return caption
        case .echo:
            self.noteListenEcho(true)
            throw TranslationEngineError.localEchoed
        case .malformed:
            throw TranslationEngineError.localRejected
        }
    }

    enum CommitVerdict: Equatable {
        case accept(String)
        case echo
        case malformed
    }

    static func acceptedCommitTranslation(
        _ candidate: String,
        sourceText: String,
        target: TranslationLanguage
    ) -> String? {
        if case .accept(let caption) = Self.commitVerdict(candidate, sourceText: sourceText, target: target) {
            return caption
        }
        return nil
    }

    static func commitVerdict(
        _ candidate: String,
        sourceText: String,
        target: TranslationLanguage
    ) -> CommitVerdict {
        let raw = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty || raw.contains(where: \.isNewline) { return .malformed }
        if Self.looksLikeEngineError(raw) { return .malformed }
        let cleaned = Self.strippingCaptionPrefix(raw)
        if cleaned.isEmpty { return .malformed }
        if Self.looksLikeEngineError(cleaned) { return .malformed }
        if Self.looksLikeEcho(cleaned, sourceText: sourceText) { return .echo }
        if !Self.matchesTargetScript(cleaned, target: target) { return .malformed }
        let sourceCount = max(sourceText.trimmingCharacters(in: .whitespacesAndNewlines).count, 1)
        if cleaned.count > sourceCount * 4 { return .malformed }
        return .accept(cleaned)
    }

    /// Empty, echoed, or provider-error text must never become a Theater line.
    static func captionSafeForBoard(_ candidate: String, sourceText: String) -> String? {
        let cleaned = Self.strippingCaptionPrefix(candidate.trimmingCharacters(in: .whitespacesAndNewlines))
        if cleaned.isEmpty { return nil }
        if Self.looksLikeEngineError(cleaned) { return nil }
        if Self.looksLikeEcho(cleaned, sourceText: sourceText) { return nil }
        return cleaned
    }

    static func looksLikeEcho(_ candidate: String, sourceText: String) -> Bool {
        if TranslationClauseSegmenter.isSameClause(candidate, sourceText) { return true }
        let left = Self.echoKey(candidate)
        let right = Self.echoKey(sourceText)
        return !left.isEmpty && left == right
    }

    static func looksLikeEngineError(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let folded = trimmed.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        if folded.hasPrefix("error:") || folded.hasPrefix("error -") || folded.hasPrefix("error—") {
            return true
        }
        if folded.hasPrefix("exception:") || folded.hasPrefix("failed:") { return true }
        return Self.engineErrorKeys.contains(Self.echoKey(trimmed))
    }

    static func strippingCaptionPrefix(_ text: String) -> String {
        var current = Self.strippingWrappingQuotes(text.trimmingCharacters(in: .whitespacesAndNewlines))
        for _ in 0..<2 {
            let next = Self.stripOneLabelPrefix(current)
            if next == current { break }
            current = Self.strippingWrappingQuotes(next)
        }
        return current
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
        if settings.mlxRunnerEnabled {
            let ready = await MLXRunnerService.shared.prepareToPolish()
            guard ready else {
                throw TranslationEngineError(message: "Local MLX runner is not running.")
            }
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
        target: TranslationLanguage,
        priorSource: [String] = [],
        priorCaptions: [String] = []
    ) -> String? {
        let polished = Self.strippingCaptionPrefix(candidate.trimmingCharacters(in: .whitespacesAndNewlines))
        if polished.isEmpty { return nil }
        if polished.contains(where: \.isNewline) { return nil }
        if Self.looksLikeEngineError(polished) { return nil }
        if CaptionJunkGate.shouldDrop(polished) { return nil }
        let draftCount = max(draft.trimmingCharacters(in: .whitespacesAndNewlines).count, 1)
        let ratio = Double(polished.count) / Double(draftCount)
        if ratio < 0.5 || ratio > 1.6 { return nil }
        if !Self.matchesTargetScript(polished, target: target) { return nil }
        let priors = (priorSource + priorCaptions)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 8 }
        if priors.contains(where: { polished.localizedCaseInsensitiveContains($0) }) {
            return nil
        }
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

    private static let engineErrorKeys: [String] = [
        "quota exceeded",
        "rate limit",
        "rate limit exceeded",
        "invalid api key",
        "invalid api",
        "unauthorized",
        "connection refused",
        "econnrefused",
        "this pair is not supported by apple translation",
        "apple translation is not ready yet",
        "local caption translation was rejected",
        "local caption translation echoed the source",
        "local mlx runner is not running",
    ]

    private static let captionLabels: Set<String> = [
        "original", "translation", "translated", "source", "caption",
        "output", "input", "english", "korean", "thai",
        "原文", "訳文", "翻訳", "译文", "翻译",
        "원문", "번역", "번역문",
        "แปล",
    ]

    private static func echoKey(_ text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        let kept = folded.compactMap { character -> Character? in
            if character.isLetter || character.isNumber { return character }
            if character.isWhitespace { return " " }
            return nil
        }
        return String(kept)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripOneLabelPrefix(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(
            in: CharacterSet(charactersIn: "*#_").union(.whitespacesAndNewlines)
        )
        guard let separator = trimmed.firstIndex(where: { $0 == ":" || $0 == "：" }) else {
            return trimmed
        }
        let label = String(trimmed[..<separator])
            .trimmingCharacters(in: CharacterSet(charactersIn: "*#_ ").union(.whitespacesAndNewlines))
        let foldedLabel = Self.echoKey(label)
        guard Self.captionLabels.contains(where: { Self.echoKey($0) == foldedLabel }),
              !foldedLabel.isEmpty
        else {
            return trimmed
        }
        let after = trimmed[trimmed.index(after: separator)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return after.isEmpty ? trimmed : after
    }

    private static func strippingWrappingQuotes(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return trimmed }
        let pairs: [(Character, Character)] = [
            ("\"", "\""), ("“", "”"), ("'", "'"), ("「", "」"), ("『", "』"),
        ]
        for (open, close) in pairs where trimmed.first == open && trimmed.last == close {
            return String(trimmed.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
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
    static func translateMessages(
        sourceText: String,
        priorSource: [String],
        sourceLanguage: String,
        targetLanguage: String
    ) -> [[String: String]] {
        [
            [
                "role": "system",
                "content": """
                Translate one finished spoken sentence for a live lecture caption.
                Source language: \(sourceLanguage). Caption language: \(targetLanguage).
                Use the previous source sentences only to resolve pronouns and omitted subjects.
                Keep names and glossary tokens unchanged.
                Do not add quotes, notes, or romanization.
                Output only the caption.
                """,
            ],
            [
                "role": "user",
                "content": """
                Previous source sentences:
                \(Self.numberedBlock(priorSource))

                Current source:
                \(sourceText)
                """,
            ],
        ]
    }

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
