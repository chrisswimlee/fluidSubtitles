import Foundation

enum LiveTranslationMTError: Error {
    case timedOut
}

@MainActor
enum LiveTranslationMT {
    /// Apple Translation is `session.translate(text)` with no prompt. Isolated
    /// Korean/Thai clauses lose zero-subject context, so commit sends the last
    /// 2–4 source clauses plus the new one, then peels the new caption out.
    static func translateClause(
        _ text: String,
        source: TranslationLanguage,
        target: TranslationLanguage,
        terms: [String],
        kind: TranslationRequestKind,
        prior: (sources: [String], translations: [String]),
        translator: TranslationEngine,
        llmEngine: LLMTranslationEngine,
        allowLocal: Bool = true
    ) async throws -> String {
        do {
            let apple = try await self.appleClause(
                text,
                source: source,
                target: target,
                terms: terms,
                kind: kind,
                prior: prior,
                translator: translator
            )
            if allowLocal, let sharpened = await self.localFirstPrint(
                text,
                draft: apple,
                prior: prior,
                source: source,
                target: target,
                terms: terms,
                llmEngine: llmEngine
            ) {
                return sharpened
            }
            return apple
        } catch {
            if allowLocal, let local = await self.localCommitTranslation(
                text,
                priorSource: prior.sources,
                source: source,
                target: target,
                terms: terms,
                llmEngine: llmEngine
            ) {
                return local
            }
            throw error
        }
    }

    static func appleClause(
        _ text: String,
        source: TranslationLanguage,
        target: TranslationLanguage,
        terms: [String],
        kind: TranslationRequestKind,
        prior: (sources: [String], translations: [String]),
        translator: TranslationEngine
    ) async throws -> String {
        if !prior.sources.isEmpty {
            let payload = TranslationClauseSegmenter.joinTranslatedLines(
                prior.sources + [text],
                languageID: source.id
            )
            let contextual = try await self.translateProtected(
                payload,
                terms: terms,
                source: source,
                target: target,
                kind: kind,
                translator: translator
            )
            if let peeled = LiveTranslationCommitContext.peeledNewTranslation(
                contextual,
                priorTranslations: prior.translations,
                targetID: target.id
            ) {
                return peeled
            }
        }
        return try await self.translateProtected(
            text,
            terms: terms,
            source: source,
            target: target,
            kind: kind,
            translator: translator
        )
    }

    /// Sharpen an Apple draft before it prints. Does not start the runner.
    static func localFirstPrint(
        _ text: String,
        draft: String,
        prior: (sources: [String], translations: [String]),
        source: TranslationLanguage,
        target: TranslationLanguage,
        terms: [String],
        llmEngine: LLMTranslationEngine
    ) async -> String? {
        guard llmEngine.isReadyForCommitTranslation() else { return nil }
        do {
            let polished = try await llmEngine.polish(
                sourceText: text,
                draft: draft,
                priorSource: prior.sources,
                priorCaptions: prior.translations,
                source: source,
                target: target
            )
            let cleaned = polished.trimmingCharacters(in: .whitespacesAndNewlines)
            let draftTrimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard cleaned != draftTrimmed else { return nil }
            guard let accepted = LLMTranslationEngine.acceptedPolished(
                cleaned,
                draft: draft,
                target: target,
                priorSource: prior.sources,
                priorCaptions: prior.translations
            ) else {
                llmEngine.noteListenFailure()
                return nil
            }
            if !TranslationGlossary.lostProtectedTerms(
                source: text,
                polished: accepted,
                terms: terms
            ).isEmpty {
                llmEngine.noteListenFailure()
                return nil
            }
            llmEngine.noteListenEcho(false)
            return accepted
        } catch {
            llmEngine.noteListenFailure()
            DebugLogger.shared.debug(
                "Local first-print polish skipped: \(error.localizedDescription)",
                source: "LiveTranslation"
            )
            return nil
        }
    }

    static func localCommitTranslation(
        _ text: String,
        priorSource: [String],
        source: TranslationLanguage,
        target: TranslationLanguage,
        terms: [String],
        llmEngine: LLMTranslationEngine
    ) async -> String? {
        guard llmEngine.isReadyForCommitTranslation() else { return nil }
        let protected = TranslationGlossary.protect(text, terms: terms)
        do {
            let translated = try await llmEngine.translateCommit(
                protected.text,
                priorSource: priorSource,
                source: source,
                target: target
            )
            let restored = TranslationGlossary.restore(translated, tokens: protected.tokens)
            if !TranslationGlossary.lostProtectedTerms(
                source: text,
                polished: restored,
                terms: terms
            ).isEmpty {
                return nil
            }
            return restored
        } catch {
            DebugLogger.shared.debug(
                "Local commit translation skipped: \(error.localizedDescription)",
                source: "LiveTranslation"
            )
            return nil
        }
    }

    static func translateProtected(
        _ text: String,
        terms: [String],
        source: TranslationLanguage,
        target: TranslationLanguage,
        kind: TranslationRequestKind,
        translator: TranslationEngine
    ) async throws -> String {
        let protected = TranslationGlossary.protect(text, terms: terms)
        let translated = try await self.translateWithRetry(
            protected.text,
            source: source,
            target: target,
            engine: translator,
            kind: kind
        )
        return TranslationGlossary.restore(translated, tokens: protected.tokens)
    }

    static func translateWithRetry(
        _ text: String,
        source: TranslationLanguage,
        target: TranslationLanguage,
        engine: TranslationEngine,
        kind: TranslationRequestKind
    ) async throws -> String {
        do {
            return try await engine.translate(text, source: source, target: target, kind: kind)
        } catch {
            if let engineError = error as? TranslationEngineError, engineError.isSuperseded {
                throw error
            }
            DebugLogger.shared.debug(
                "Apple Translation retry after \(error.localizedDescription)",
                source: "LiveTranslation"
            )
            return try await engine.translate(text, source: source, target: target, kind: kind)
        }
    }
}
