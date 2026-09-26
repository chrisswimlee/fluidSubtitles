import Foundation

enum LiveTranslationMTError: Error {
    case timedOut
    case sharpenBudget
}

@MainActor
enum LiveTranslationMT {
    /// Apple Translation is `session.translate(text)` with no prompt. Isolated
    /// Korean/Thai clauses lose zero-subject context, so commit sends the last
    /// 2–4 source clauses with the new one marked, then takes that span.
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
        // Do not pause the speech tick for this call. A commit used to skip
        // every recognition update until Apple returned, so a slow or repeated
        // translation left a hole and the next tick had to catch up. The
        // Apple mailbox still runs one session call at a time.
        if !prior.sources.isEmpty {
            let payload = LiveTranslationCommitContext.markedContextPayload(
                priors: prior.sources,
                current: text,
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
            if let marked = LiveTranslationCommitContext.markedNewTranslation(contextual),
               LiveTranslationCommitContext.isSanePeeledCaption(
                   marked,
                   isolatedSource: text,
                   targetID: target.id
               )
            {
                return marked
            }
            DebugLogger.shared.debug(
                "Contextual caption marks did not yield the new clause.",
                source: "LiveTranslation"
            )
            // A blob that still contains a mark has a broken boundary. Prefix
            // peel would keep that mark in the caption. Peel only when the
            // model dropped the marks and kept the prior caption in front.
            if LiveTranslationCommitContext.containsContextClauseMark(contextual) == false,
               let lined = LiveTranslationCommitContext.lineBoundNewTranslation(
                   contextual,
                   priorTranslations: prior.translations,
                   isolatedSource: text,
                   targetID: target.id
               )
            {
                return lined
            }
            if LiveTranslationCommitContext.containsContextClauseMark(contextual) == false,
               let peeled = LiveTranslationCommitContext.peeledNewTranslation(
                   contextual,
                   priorTranslations: prior.translations,
                   targetID: target.id
               ), LiveTranslationCommitContext.isSanePeeledCaption(
                   peeled,
                   isolatedSource: text,
                   targetID: target.id
               )
            {
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

    /// True when an ASR tick is still running after one preview interval.
    /// A zero wait reports the current tick without sleeping. Skipping polish
    /// is not a listen failure, and a polish that already started is not cancelled.
    static func polishYieldsToASRChunk(maxWait: TimeInterval? = nil) async -> Bool {
        let asr = AppServices.shared.asr
        guard asr.isProcessingChunk else { return false }
        let limit = maxWait ?? asr.streamingChunkDurationSeconds
        guard limit > 0 else { return true }
        let deadline = ProcessInfo.processInfo.systemUptime + limit
        while asr.isProcessingChunk, ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return asr.isProcessingChunk
    }

    /// Apple prints if local sharpen is still running when the budget ends.
    /// A non-throwing group so the budget miss cannot discard a polish that already finished.
    private static func withinFirstPrintBudget(
        _ work: @escaping @MainActor () async throws -> String
    ) async throws -> String {
        let outcome: Result<String, Error> = await withTaskGroup(of: Result<String, Error>.self) { group in
            group.addTask { @MainActor in
                do {
                    return .success(try await work())
                } catch {
                    return .failure(error)
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: LiveTranslationTiming.firstPrintSharpenNanoseconds)
                } catch {
                    return .failure(CancellationError())
                }
                return .failure(LiveTranslationMTError.sharpenBudget)
            }
            let first = await group.next() ?? .failure(LiveTranslationMTError.sharpenBudget)
            group.cancelAll()
            return first
        }
        return try outcome.get()
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
        guard TheaterAcceleratorGate.shared.allowsSharpen else { return nil }
        guard llmEngine.isReadyForCommitTranslation() else { return nil }
        if await Self.polishYieldsToASRChunk() { return nil }
        do {
            let polished = try await Self.withinFirstPrintBudget {
                try await llmEngine.polish(
                    sourceText: text,
                    draft: draft,
                    priorSource: prior.sources,
                    priorCaptions: prior.translations,
                    source: source,
                    target: target
                )
            }
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
        } catch LiveTranslationMTError.sharpenBudget {
            return nil
        } catch {
            if TheaterSharpenAdmission.isWithdrawal(error) { return nil }
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
        guard TheaterAcceleratorGate.shared.allowsSharpen else { return nil }
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
            if TheaterSharpenAdmission.isWithdrawal(error) { return nil }
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
        // The Apple mailbox already runs one session call at a time and lets a
        // commit supersede a live prefetch. A second queue in front of it held
        // a grown sentence behind a call that had already been replaced.
        do {
            return try await engine.translate(text, source: source, target: target, kind: kind)
        } catch {
            if error is CancellationError { throw error }
            if let engineError = error as? TranslationEngineError,
               engineError.isSuperseded || engineError.isTimeout
            {
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
