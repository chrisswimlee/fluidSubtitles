import Combine
import Foundation

@MainActor
final class LiveTranslationSubscriber: ObservableObject {
    @Published private(set) var sourceDraft: String = ""
    @Published private(set) var translatedDraft: String = ""
    @Published private(set) var committedLines: [String] = []
    @Published private(set) var lastLatencyMilliseconds: Int?
    @Published private(set) var statusText: String = ""

    private var captionLog = LectureCaptionLog()
    private var listenBatchStart = 0
    private var postedLineCount = 0
    private var inFlightSources: [String] = []
    private var lastHeardText: String = ""
    private var lastSettleTail: String = ""
    private var lastSettleUnread: [String] = []
    private var completedSettleTask: Task<Void, Never>?
    private var tailSettleTask: Task<Void, Never>?
    private var commitChain: Task<Void, Never>?
    private var polishTasks: [UInt64: Task<Void, Never>] = [:]
    private var generation: UInt64 = 0
    private let appleEngine: AppleTranslationEngine
    private let llmEngine: LLMTranslationEngine
    var confirmTranscript: (() async -> String)?

    var committedSourceLines: [String] { self.captionLog.sourceLines }
    var committedLineIDs: [UInt64] { self.captionLog.lineIDs }
    var captionPairs: [CaptionHistoryPair] { self.captionLog.captionPairs }
    var didPolishAnyLine: Bool { self.captionLog.didPolishAnyLine }

    init(
        appleEngine: AppleTranslationEngine? = nil,
        llmEngine: LLMTranslationEngine? = nil
    ) {
        self.appleEngine = appleEngine ?? .shared
        self.llmEngine = llmEngine ?? LLMTranslationEngine()
    }

    func reset() {
        self.cancelSettles()
        self.cancelCommitsAndPolish()
        self.generation += 1
        self.sourceDraft = ""
        self.translatedDraft = ""
        self.committedLines = []
        self.captionLog = LectureCaptionLog()
        self.listenBatchStart = 0
        self.postedLineCount = 0
        self.lastHeardText = ""
        self.lastSettleTail = ""
        self.lastSettleUnread = []
        self.statusText = ""
    }

    /// Stop settling new speech. Keep captions already committed this session.
    func endListening() {
        self.cancelSettles()
        self.cancelCommitsAndPolish()
        self.generation += 1
        self.lastSettleTail = ""
        self.lastSettleUnread = []
        self.lastHeardText = ""
        self.sourceDraft = ""
        self.translatedDraft = self.captionLog.translatedLines.last ?? ""
    }

    /// Start another listen without wiping captions already on Theater.
    func beginListening() {
        self.cancelSettles()
        self.lastSettleTail = ""
        self.lastSettleUnread = []
        self.lastHeardText = ""
        self.sourceDraft = ""
        self.translatedDraft = self.captionLog.translatedLines.last ?? ""
        self.statusText = ""
        self.listenBatchStart = self.captionLog.translatedLines.count
        self.objectWillChange.send()
    }

    func pendingInsertDocument() -> String {
        let start = min(self.committedLines.count, max(self.postedLineCount, self.listenBatchStart))
        return PresenterCaptionController.captionDocument(
            committed: Array(self.committedLines.dropFirst(start)),
            draft: ""
        )
    }

    func consumePendingInsertDocument() -> String {
        let text = self.pendingInsertDocument()
        self.markAllPosted()
        return text
    }

    func markAllPosted() {
        self.postedLineCount = self.committedLines.count
        self.objectWillChange.send()
    }

    func applyEditedLines(_ lines: [String]) {
        self.captionLog.replaceTranslatedLines(lines)
        self.committedLines = self.captionLog.translatedLines
        self.listenBatchStart = min(self.listenBatchStart, self.committedLines.count)
        self.postedLineCount = min(self.postedLineCount, self.committedLines.count)
        self.sourceDraft = ""
        self.translatedDraft = self.captionLog.translatedLines.last ?? ""
    }

    func deliveryDocument() -> String {
        PresenterCaptionController.captionDocument(
            committed: self.committedLines,
            draft: ""
        )
    }

    func seedCommittedForTesting(source: String, translated: String) {
        self.captionLog.commit(source: source, translated: translated)
        self.committedLines = self.captionLog.translatedLines
        self.sourceDraft = source
        self.translatedDraft = translated
    }

    func handlePartial(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.lastHeardText = cleaned
        let languageID = SpokenLanguageResolver.sourceLanguage().id
        let split = TranslationClauseSegmenter.split(cleaned, languageID: languageID)

        guard !cleaned.isEmpty else {
            self.sourceDraft = ""
            self.translatedDraft = ""
            return
        }

        let absorbed = self.captionLog.sourceLines + self.inFlightSources
        let unread = TranslationClauseSegmenter.unreadCompleted(
            completed: split.completed,
            already: absorbed
        )
        let tail = TranslationClauseSegmenter.leftoverTail(cleaned, already: absorbed)
        if !self.sourceDraft.isEmpty,
           !TranslationClauseSegmenter.isSameClause(self.sourceDraft, tail),
           !TranslationClauseSegmenter.shouldReplaceLast(previous: self.sourceDraft, incoming: tail),
           !TranslationClauseSegmenter.shouldIgnoreAsStalePrefix(previous: self.sourceDraft, incoming: tail)
        {
            self.translatedDraft = ""
        }
        self.sourceDraft = tail

        if unread.isEmpty, tail.isEmpty {
            self.completedSettleTask?.cancel()
            self.tailSettleTask?.cancel()
            self.lastSettleTail = ""
            self.lastSettleUnread = []
            return
        }

        let token = self.generation
        switch TranslationClauseSegmenter.decision(forTail: tail, languageID: languageID) {
        case .commitNow:
            Task { [weak self] in
                await self?.flushSettled(generation: token, isFinal: false)
            }
        case .ignore, .waitForStability:
            self.scheduleSettles(
                unread: unread,
                tail: tail,
                languageID: languageID,
                generation: token
            )
        }
    }

    private func scheduleSettles(
        unread: [String],
        tail: String,
        languageID: String,
        generation token: UInt64
    ) {
        if unread != self.lastSettleUnread {
            self.lastSettleUnread = unread
            self.completedSettleTask?.cancel()
            if !unread.isEmpty {
                self.completedSettleTask = Task { [weak self] in
                    try? await Task.sleep(
                        nanoseconds: LiveTranslationTiming.completeSettleNanoseconds(languageID: languageID)
                    )
                    guard !Task.isCancelled else { return }
                    await self?.flushSettled(generation: token, isFinal: false)
                }
            }
        }

        if TranslationClauseSegmenter.shouldRestartSettle(previous: self.lastSettleTail, incoming: tail) {
            self.lastSettleTail = tail
            self.tailSettleTask?.cancel()
            guard !tail.isEmpty else { return }
            let delay = TranslationClauseSegmenter.settleNanoseconds(
                unreadCount: 0,
                tail: tail,
                languageID: languageID
            )
            if delay == 0 {
                Task { [weak self] in
                    await self?.flushSettled(generation: token, isFinal: false)
                }
                return
            }
            self.tailSettleTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                await self?.flushSettled(generation: token, isFinal: false)
            }
        } else if !tail.isEmpty {
            self.lastSettleTail = tail
        }
    }

    private func flushSettled(generation token: UInt64, isFinal: Bool) async {
        guard token == self.generation else { return }
        let languageID = SpokenLanguageResolver.sourceLanguage().id
        var cleaned = self.lastHeardText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        var split = TranslationClauseSegmenter.split(cleaned, languageID: languageID)
        var absorbed = self.captionLog.sourceLines + self.inFlightSources
        var unread = TranslationClauseSegmenter.unreadCompleted(
            completed: split.completed,
            already: absorbed
        )
        var tail = TranslationClauseSegmenter.leftoverTail(cleaned, already: absorbed)

        if LiveTranslationConfirm.shouldReDecode(
            unread: unread,
            tail: tail,
            languageID: languageID,
            isFinal: isFinal
        ), let confirmed = await self.confirmTranscript?() {
            let cleanedConfirm = confirmed.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.shouldPreferConfirmation(cleanedConfirm, over: self.lastHeardText) {
                self.lastHeardText = cleanedConfirm
                cleaned = cleanedConfirm
                split = TranslationClauseSegmenter.split(cleaned, languageID: languageID)
                absorbed = self.captionLog.sourceLines + self.inFlightSources
                unread = TranslationClauseSegmenter.unreadCompleted(
                    completed: split.completed,
                    already: absorbed
                )
                tail = TranslationClauseSegmenter.leftoverTail(cleaned, already: absorbed)
            }
        }

        for sentence in unread {
            self.enqueueCommit(sentence, reason: .completedSentence)
        }

        let absorbedAfterEnqueue = self.captionLog.sourceLines + self.inFlightSources
        tail = TranslationClauseSegmenter.leftoverTail(cleaned, already: absorbedAfterEnqueue)
        self.sourceDraft = tail
        self.lastSettleUnread = []
        self.lastSettleTail = tail
        switch TranslationClauseSegmenter.decision(forTail: tail, languageID: languageID) {
        case .ignore:
            return
        case .commitNow:
            self.enqueueCommit(tail, reason: .completedSentence)
        case .waitForStability:
            guard TranslationClauseSegmenter.isReadyToCommit(
                tail,
                languageID: languageID,
                allowPauseFinalize: true
            ) else { return }
            self.enqueueCommit(tail, reason: .stableTail)
        }
    }

    private static func shouldPreferConfirmation(_ confirmed: String, over heard: String) -> Bool {
        let next = confirmed.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        if next.isEmpty { return false }
        if current.isEmpty { return true }
        return next.count >= max(8, (current.count * 2) / 3)
    }

    func translateFinal(_ text: String) async -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return text }

        if let confirmed = await self.confirmTranscript?() {
            let cleanedConfirm = confirmed.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.shouldPreferConfirmation(cleanedConfirm, over: cleaned) {
                self.lastHeardText = cleanedConfirm
            } else {
                self.lastHeardText = cleaned
            }
        } else {
            self.lastHeardText = cleaned
        }

        await self.flushSettled(generation: self.generation, isFinal: true)
        if let chain = self.commitChain {
            await chain.value
        }
        await self.waitForPolish()

        let languageID = SpokenLanguageResolver.sourceLanguage().id
        let heard = self.lastHeardText.trimmingCharacters(in: .whitespacesAndNewlines)
        let absorbed = self.captionLog.sourceLines + self.inFlightSources
        let leftover = TranslationClauseSegmenter.leftoverTail(heard, already: absorbed)
        let split = TranslationClauseSegmenter.split(leftover, languageID: languageID)
        var units = split.completed
        if !split.tail.isEmpty {
            units.append(split.tail)
        }

        let unread = TranslationClauseSegmenter.unreadCompleted(completed: units, already: absorbed)
        let token = self.generation
        for sentence in unread {
            await self.commitUnit(sentence, generation: token, reason: .final)
        }
        await self.waitForPolish()

        self.sourceDraft = ""
        self.translatedDraft = self.captionLog.translatedLines.last ?? ""
        return self.pendingInsertDocument()
    }

    private enum CommitReason {
        case completedSentence
        case stableTail
        case final
    }

    private func enqueueCommit(_ source: String, reason: CommitReason, generation: UInt64? = nil) {
        let cleaned = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if self.inFlightSources.contains(where: { TranslationClauseSegmenter.isSameClause($0, cleaned) }) {
            return
        }
        if let last = self.captionLog.sourceLines.last,
           TranslationClauseSegmenter.isSameClause(last, cleaned),
           !TranslationClauseSegmenter.shouldReplaceLast(previous: last, incoming: cleaned)
        {
            return
        }
        let token = generation ?? self.generation
        let previous = self.commitChain
        self.inFlightSources.append(cleaned)
        self.commitChain = Task { [weak self] in
            await previous?.value
            await self?.commitUnit(cleaned, generation: token, reason: reason)
        }
    }

    private func commitUnit(_ source: String, generation: UInt64, reason: CommitReason) async {
        let cleaned = source.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { self.inFlightSources.removeAll { $0 == cleaned } }
        guard generation == self.generation else { return }
        guard !cleaned.isEmpty else { return }

        let replaceLast = self.captionLog.sourceLines.last.map {
            TranslationClauseSegmenter.shouldReplaceLast(previous: $0, incoming: cleaned)
        } ?? false
        if !replaceLast, self.captionLog.sourceLines.last == cleaned {
            return
        }
        if let lastSource = self.captionLog.sourceLines.last,
           TranslationClauseSegmenter.shouldIgnoreAsStalePrefix(previous: lastSource, incoming: cleaned)
        {
            return
        }

        let languageID = SpokenLanguageResolver.sourceLanguage().id
        let priorSource: [String]
        let priorCaptions: [String]
        if replaceLast {
            priorSource = Array(
                self.captionLog.sourceLines.dropLast().suffix(
                    LiveTranslationTiming.contextCount(languageID: languageID)
                )
            )
            priorCaptions = Array(self.captionLog.translatedLines.dropLast().suffix(
                LiveTranslationTiming.polishPriorCaptionCount
            ))
        } else {
            priorSource = self.captionLog.contextSourceLines(languageID: languageID)
            priorCaptions = self.captionLog.contextTranslatedLines()
        }

        do {
            self.statusText = "Translating…"
            let translated = try await self.performTranslation(cleaned)
            guard generation == self.generation else { return }
            let resolved = translated.isEmpty ? cleaned : translated

            guard let committed = self.captionLog.commit(source: cleaned, translated: resolved) else { return }
            self.adjustIndexes(trimmedCount: committed.trimmedCount)
            self.committedLines = self.captionLog.translatedLines
            self.statusText = ""

            if self.sourceDraft == cleaned || reason == .final {
                self.translatedDraft = resolved
            }

            self.schedulePolish(
                lineID: committed.id,
                sourceText: cleaned,
                draft: resolved,
                priorSource: priorSource,
                priorCaptions: priorCaptions,
                generation: generation
            )
        } catch {
            guard generation == self.generation else { return }
            if let committed = self.captionLog.commit(source: cleaned, translated: cleaned) {
                self.adjustIndexes(trimmedCount: committed.trimmedCount)
            }
            self.committedLines = self.captionLog.translatedLines
            self.statusText = "Showing spoken line — translation failed"
            DebugLogger.shared.error(
                "Lecture translation failed: \(error.localizedDescription)",
                source: "LiveTranslation"
            )
        }
    }

    private func performTranslation(_ text: String) async throws -> String {
        let settings = SettingsStore.shared
        let source = SpokenLanguageResolver.sourceLanguage(settings: settings)
        let target = SpokenLanguageResolver.targetLanguage(settings: settings)
        self.appleEngine.prepare(source: source, target: target)

        let terms = TranslationGlossary.protectedTerms(from: settings)
        let protected = TranslationGlossary.protect(text, terms: terms)
        let started = ProcessInfo.processInfo.systemUptime

        var translated = try await self.translateWithRetry(
            protected.text,
            source: source,
            target: target
        )
        translated = TranslationGlossary.restore(translated, tokens: protected.tokens)

        let ms = Int(((ProcessInfo.processInfo.systemUptime - started) * 1000).rounded())
        self.lastLatencyMilliseconds = ms
        DebugLogger.shared.debug(
            "Live translation \(source.id)->\(target.id) \(ms)ms chars=\(text.count)",
            source: "LiveTranslation"
        )
        return translated
    }

    private func schedulePolish(
        lineID: UInt64,
        sourceText: String,
        draft: String,
        priorSource: [String],
        priorCaptions: [String],
        generation: UInt64
    ) {
        let settings = SettingsStore.shared
        let source = SpokenLanguageResolver.sourceLanguage(settings: settings)
        let target = SpokenLanguageResolver.targetLanguage(settings: settings)
        guard source.id != target.id else { return }
        guard self.llmEngine.isAvailable(settings: settings) else { return }

        let terms = TranslationGlossary.protectedTerms(from: settings)
        self.polishTasks[lineID]?.cancel()
        self.polishTasks[lineID] = Task { [weak self] in
            guard let self, generation == self.generation else { return }
            do {
                let polished = try await self.polishWithTimeout(
                    sourceText: sourceText,
                    draft: draft,
                    priorSource: priorSource,
                    priorCaptions: priorCaptions,
                    source: source,
                    target: target
                )
                guard generation == self.generation else { return }
                guard let accepted = LLMTranslationEngine.acceptedPolished(
                    polished,
                    draft: draft,
                    target: target
                ), accepted != draft else { return }
                if !TranslationGlossary.lostProtectedTerms(
                    source: sourceText,
                    polished: accepted,
                    terms: terms
                ).isEmpty {
                    return
                }
                if self.captionLog.updateTranslated(id: lineID, translated: accepted, wasPolished: true) {
                    self.committedLines = self.captionLog.translatedLines
                    if self.translatedDraft == draft {
                        self.translatedDraft = accepted
                    }
                }
            } catch {
                DebugLogger.shared.debug(
                    "Caption polish skipped: \(error.localizedDescription)",
                    source: "LiveTranslation"
                )
            }
            self.polishTasks[lineID] = nil
        }
    }

    private func translateWithRetry(
        _ text: String,
        source: TranslationLanguage,
        target: TranslationLanguage
    ) async throws -> String {
        do {
            return try await self.appleEngine.translate(text, source: source, target: target)
        } catch {
            DebugLogger.shared.debug(
                "Apple Translation retry after \(error.localizedDescription)",
                source: "LiveTranslation"
            )
            return try await self.appleEngine.translate(text, source: source, target: target)
        }
    }

    private func polishWithTimeout(
        sourceText: String,
        draft: String,
        priorSource: [String],
        priorCaptions: [String],
        source: TranslationLanguage,
        target: TranslationLanguage
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { @MainActor in
                try await self.llmEngine.polish(
                    sourceText: sourceText,
                    draft: draft,
                    priorSource: priorSource,
                    priorCaptions: priorCaptions,
                    source: source,
                    target: target
                )
            }
            group.addTask {
                try await Task.sleep(nanoseconds: LiveTranslationTiming.polishTimeoutNanoseconds)
                throw TranslationEngineError(message: "Caption polish timed out.")
            }
            guard let first = try await group.next() else {
                throw TranslationEngineError(message: "Caption polish timed out.")
            }
            group.cancelAll()
            return first
        }
    }

    private func waitForPolish() async {
        let tasks = Array(self.polishTasks.values)
        await withTaskGroup(of: Void.self) { group in
            for task in tasks {
                group.addTask { await task.value }
            }
        }
    }

    private func cancelSettles() {
        self.completedSettleTask?.cancel()
        self.tailSettleTask?.cancel()
        self.completedSettleTask = nil
        self.tailSettleTask = nil
    }

    private func cancelCommitsAndPolish() {
        self.commitChain?.cancel()
        self.commitChain = nil
        self.polishTasks.values.forEach { $0.cancel() }
        self.polishTasks.removeAll()
        self.inFlightSources = []
    }

    private func adjustIndexes(trimmedCount: Int) {
        guard trimmedCount > 0 else { return }
        self.listenBatchStart = max(0, self.listenBatchStart - trimmedCount)
        self.postedLineCount = max(0, self.postedLineCount - trimmedCount)
    }
}
