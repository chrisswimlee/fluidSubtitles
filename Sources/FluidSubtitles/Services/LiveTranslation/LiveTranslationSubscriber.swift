import Combine
import Darwin
import Foundation

// swiftlint:disable function_body_length cyclomatic_complexity type_body_length
// Session owner. Commit policy is LiveTranslationCommitContext; MT is LiveTranslationMT.

@MainActor
final class LiveTranslationSubscriber: ObservableObject {
    @Published private(set) var sourceDraft: String = ""
    @Published private(set) var translatedDraft: String = ""
    @Published private(set) var committedLines: [String] = []
    @Published private(set) var lastLatencyMilliseconds: Int?
    @Published private(set) var lastLatencySample = LiveTranslationLatencySample()
    @Published private(set) var status = TheaterStatus.empty

    var statusText: String { self.status.text }
    var statusKind: TheaterStatusKind { self.status.kind }

    private var captionLog = LectureCaptionLog()
    private let archive: LectureCaptionArchive
    private var latencyTracker = LiveTranslationLatencyTracker()
    private var listenBatchStart = 0
    private var postedLineCount = 0
    private var inFlightSources: [String] = []
    private var lastHeardText: String = ""
    private var lastSettleTail: String = ""
    private var lastSettleUnread: [String] = []
    private var completedSettleTask: Task<Void, Never>?
    private var tailSettleTask: Task<Void, Never>?
    private var eouHoldTask: Task<Void, Never>?
    private var pauseRevisionTask: Task<Void, Never>?
    private var failedRetryTask: Task<Void, Never>?
    private var didPauseReviseThisUtterance = false
    private var didAutoRetryFailure = false
    private var commitChain: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var translatedDraftSource: String = ""
    private let appleEngine: AppleTranslationEngine
    private let translator: TranslationEngine
    private let llmEngine: LLMTranslationEngine
    private let prefetchCache = LiveTranslationPrefetchCache()
    private var polishTasks: [UInt64: Task<Void, Never>] = [:]
    private var lastFailedSource: String?
    var confirmTranscript: (() async -> String)?
    var canRetryTranslation: Bool { self.lastFailedSource != nil }
    var isApproachingLineLimit: Bool {
        self.captionLog.entries.count >= LiveTranslationTiming.maxCommittedLines - 10
    }

    var archivedLineCount: Int { self.archive.overflowCount }
    var sessionLineCount: Int { self.archivedLineCount + self.captionLog.entries.count }

    var lineWindowStatus: String? {
        if self.archivedLineCount > 0 {
            return "Showing last \(self.captionLog.entries.count) of \(self.sessionLineCount)"
        }
        if self.isApproachingLineLimit {
            return "Approaching the \(LiveTranslationTiming.maxCommittedLines)-line window. Older lines stay in the session archive."
        }
        return nil
    }

    var committedSourceLines: [String] { self.captionLog.sourceLines }
    var committedLineIDs: [UInt64] { self.captionLog.lineIDs }
    var nextCaptionID: UInt64 { self.captionLog.nextID }
    var captionPairs: [CaptionHistoryPair] { self.captionLog.captionPairs }
    var exportCaptionPairs: [CaptionHistoryPair] {
        TheaterCaptionExport.pairs(from: self.archive.loadAll()) + self.captionLog.captionPairs
    }

    func flushArchive() {
        self.archive.flush()
    }

    /// Translated draft after a clause commits. The open spoken clause uses `liveSpokenText`.
    var liveCaptionText: String {
        let draft = self.translatedDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = self.committedLines.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !draft.isEmpty, draft != last {
            return draft
        }
        return ""
    }

    /// Current unread clause so Theater can follow along before the line commits.
    var liveSpokenText: String {
        let languageID = SpokenLanguageResolver.sourceLanguage().id
        let leftover = TranslationClauseSegmenter.leftoverTail(
            self.sourceDraft,
            already: self.printedSources,
            languageID: languageID
        )
        let open = TranslationClauseSegmenter.livePreview(leftover, languageID: languageID).open
        if open.isEmpty { return "" }
        if CaptionJunkGate.shouldDrop(open) {
            return ""
        }
        if TranslationClauseSegmenter.isAlreadyPrintedSource(
            open,
            already: self.printedSources,
            languageID: languageID
        ) {
            return ""
        }
        if self.captionLog.sourceLines.dropLast().contains(where: {
            TranslationClauseSegmenter.isSameClause($0, open)
                || TranslationClauseSegmenter.shouldReviseCommitted(
                    previous: $0,
                    incoming: open,
                    languageID: languageID
                )
        }) {
            return ""
        }
        if let last = self.captionLog.sourceLines.last {
            if TranslationClauseSegmenter.isSameClause(last, open) { return "" }
            if TranslationClauseSegmenter.shouldReviseCommitted(
                previous: last,
                incoming: open,
                languageID: languageID
            ), !TranslationClauseSegmenter.shouldReplaceLast(previous: last, incoming: open) {
                return ""
            }
        }
        return open
    }

    /// Finished unread sentences already on their own row while the next line types.
    var pendingSpokenLines: [String] {
        let languageID = SpokenLanguageResolver.sourceLanguage().id
        let leftover = TranslationClauseSegmenter.leftoverTail(
            self.sourceDraft,
            already: self.printedSources,
            languageID: languageID
        )
        let pinned = TranslationClauseSegmenter.livePreview(leftover, languageID: languageID).pinned
        var lines: [String] = []
        for line in self.inFlightSources + pinned {
            let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            if lines.contains(where: { TranslationClauseSegmenter.isSameClause($0, cleaned) }) {
                continue
            }
            if self.listenSourceLines.contains(where: { TranslationClauseSegmenter.isSameClause($0, cleaned) }) {
                continue
            }
            lines.append(cleaned)
        }
        return lines
    }

    /// This Listen only. A new Listen can repeat the last greeting.
    private var listenSourceLines: [String] {
        let start = min(max(self.listenBatchStart, 0), self.captionLog.sourceLines.count)
        return Array(self.captionLog.sourceLines.dropFirst(start))
    }

    private var printedSources: [String] {
        self.listenSourceLines + self.inFlightSources
    }

    /// Peel this Listen first. A restitch that still starts with a printed
    /// board line peels that too. An empty board leftover means the talk is
    /// already on Theater — except a new Listen repeating the last greeting.
    private func leftoverSpeech(_ text: String, languageID: String) -> String {
        let listenLeftover = TranslationClauseSegmenter.leftoverTail(
            text,
            already: self.printedSources,
            languageID: languageID
        )
        let boardLeftover = TranslationClauseSegmenter.leftoverTail(
            text,
            already: self.captionLog.sourceLines + self.inFlightSources,
            languageID: languageID
        )
        if boardLeftover.isEmpty {
            return self.repeatableGreetingLeftover(listenLeftover, languageID: languageID)
        }
        let unread = boardLeftover != listenLeftover ? boardLeftover : listenLeftover
        return self.peelPrintedOrRevisedBoardLines(unread, languageID: languageID)
    }

    private func repeatableGreetingLeftover(_ listenLeftover: String, languageID: String) -> String {
        guard !listenLeftover.isEmpty, self.listenSourceLines.isEmpty else { return "" }
        guard let last = self.captionLog.sourceLines.last else { return listenLeftover }
        if TranslationClauseSegmenter.isSameClause(last, listenLeftover)
            || TranslationClauseSegmenter.shouldReviseCommitted(
                previous: last,
                incoming: listenLeftover,
                languageID: languageID
            )
            || TranslationClauseSegmenter.shouldReplaceLast(previous: last, incoming: listenLeftover)
        {
            return listenLeftover
        }
        return ""
    }

    private func peelPrintedOrRevisedBoardLines(_ leftover: String, languageID: String) -> String {
        var remaining = leftover
        var steps = 0
        while steps < 32, !remaining.isEmpty {
            steps += 1
            guard let first = TranslationClauseSegmenter.nextCommitUnit(
                remaining,
                languageID: languageID,
                allowPauseFinalize: false
            )?.unit else { break }
            let printed = self.captionLog.sourceLines.contains { line in
                TranslationClauseSegmenter.isSameClause(line, first)
                    || (
                        TranslationClauseSegmenter.shouldReviseCommitted(
                            previous: line,
                            incoming: first,
                            languageID: languageID
                        )
                        && !TranslationClauseSegmenter.shouldReplaceLast(previous: line, incoming: first)
                    )
            } || self.inFlightSources.contains {
                TranslationClauseSegmenter.isSameClause($0, first)
            }
            guard printed else { break }
            let rest = TranslationClauseSegmenter.leftoverTail(
                remaining,
                already: [first],
                languageID: languageID
            )
            if rest.isEmpty || rest == remaining { break }
            remaining = rest
        }
        return remaining
    }

    private func revisesEarlierPrintedLine(_ unit: String, languageID: String) -> Bool {
        self.captionLog.sourceLines.dropLast().contains { printed in
            TranslationClauseSegmenter.isSameClause(printed, unit)
                || TranslationClauseSegmenter.shouldReviseCommitted(
                    previous: printed,
                    incoming: unit,
                    languageID: languageID
                )
        }
    }

    init(
        appleEngine: AppleTranslationEngine? = nil,
        translator: TranslationEngine? = nil,
        archive: LectureCaptionArchive? = nil,
        llmEngine: LLMTranslationEngine? = nil
    ) {
        let engine = appleEngine ?? .shared
        self.appleEngine = engine
        self.translator = translator ?? engine
        self.archive = archive ?? LectureCaptionArchive()
        self.llmEngine = llmEngine ?? LLMTranslationEngine()
        self.archive.recount()
    }

    func reset(clearArchive: Bool = false) {
        self.cancelSettles()
        self.cancelCommitsAndPolish()
        self.prefetchCache.invalidate()
        self.generation += 1
        self.translatedDraftSource = ""
        self.sourceDraft = ""
        self.translatedDraft = ""
        self.committedLines = []
        self.captionLog = LectureCaptionLog()
        if clearArchive {
            self.archive.reset()
        }
        self.latencyTracker = LiveTranslationLatencyTracker()
        self.lastLatencySample = LiveTranslationLatencySample()
        self.lastLatencyMilliseconds = nil
        self.listenBatchStart = 0
        self.postedLineCount = 0
        self.lastHeardText = ""
        self.lastSettleTail = ""
        self.lastSettleUnread = []
        self.status = .empty
        self.lastFailedSource = nil
        self.didPauseReviseThisUtterance = false
        self.didAutoRetryFailure = false
        self.llmEngine.resetListenEchoTally()
    }

    /// Stop settling new speech. Keep captions already committed this session.
    func endListening() {
        self.cancelSettles()
        self.cancelCommitsAndPolish()
        self.prefetchCache.invalidate()
        self.archive.flush()
        self.generation += 1
        self.translatedDraftSource = ""
        self.lastSettleTail = ""
        self.lastSettleUnread = []
        self.lastHeardText = ""
        self.sourceDraft = ""
        self.translatedDraft = self.captionLog.translatedLines.last ?? ""
    }

    /// Start another listen without wiping captions already on Theater.
    func beginListening() {
        self.cancelSettles()
        self.cancelCommitsAndPolish()
        self.prefetchCache.invalidate()
        self.generation += 1
        self.translatedDraftSource = ""
        self.lastSettleTail = ""
        self.lastSettleUnread = []
        self.lastHeardText = ""
        self.sourceDraft = ""
        self.translatedDraft = self.captionLog.translatedLines.last ?? ""
        self.status = .listening()
        self.lastFailedSource = nil
        self.didPauseReviseThisUtterance = false
        self.didAutoRetryFailure = false
        self.llmEngine.resetListenEchoTally()
        self.listenBatchStart = self.captionLog.sourceLines.count
        self.latencyTracker.resetUtterance()
        self.latencyTracker.markListenStart(ProcessInfo.processInfo.systemUptime)
        self.objectWillChange.send()
    }

    func noteLanguagePairChanged() {
        self.cancelSettles()
        self.cancelCommitsAndPolish()
        self.prefetchCache.invalidate()
        self.generation += 1
        self.translatedDraftSource = ""
        self.lastSettleTail = ""
        self.lastSettleUnread = []
        self.lastHeardText = ""
        self.sourceDraft = ""
        self.translatedDraft = self.captionLog.translatedLines.last ?? ""
        self.status = .empty
        self.lastFailedSource = nil
        self.llmEngine.resetListenEchoTally()
        self.listenBatchStart = self.captionLog.sourceLines.count
        self.objectWillChange.send()
    }

    func noteFirstBuffer() {
        self.latencyTracker.markFirstBuffer(ProcessInfo.processInfo.systemUptime)
    }

    func noteSpeechStart(hostTime: UInt64) {
        let now = ProcessInfo.processInfo.systemUptime
        let start = LiveTranslationHostClock.uptime(
            fromHostTime: hostTime,
            nowUptime: now,
            nowHostTime: mach_absolute_time()
        )
        self.noteSpeechStart(uptime: start)
    }

    func noteSpeechStart(uptime: TimeInterval) {
        self.pauseRevisionTask?.cancel()
        self.pauseRevisionTask = nil
        self.didPauseReviseThisUtterance = false
        self.latencyTracker.markSpeechStart(uptime)
    }

    func noteSilenceHold() {
        if self.pauseRevisionTask == nil, !self.didPauseReviseThisUtterance {
            self.latencyTracker.resetUtterance()
        }
        self.schedulePauseRevision()
    }

    func recountArchive() {
        self.archive.recount()
        self.objectWillChange.send()
    }

    func persistLastLatency() {
        self.archive.flush()
        LastListenLatencyStore.write(self.lastLatencySample)
    }

    func refreshThermal(_ thermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState) {
        self.lastLatencySample = self.latencyTracker.refreshThermal(thermal)
    }

    func handleEndOfUtterance() {
        // A natural pause. Hold so the last ASR tick can land, then commit a
        // real leftover clause. Thin leftovers stay open.
        let token = self.generation
        self.completedSettleTask?.cancel()
        self.tailSettleTask?.cancel()
        self.eouHoldTask?.cancel()
        self.completedSettleTask = nil
        self.tailSettleTask = nil
        self.lastSettleUnread = []
        self.lastSettleTail = ""
        self.eouHoldTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: LiveTranslationTiming.eouHoldNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.flushSettled(generation: token, isFinal: false, reason: .pauseConfirm)
        }
    }

    func waitForIdleForTesting() async {
        await self.completedSettleTask?.value
        await self.eouHoldTask?.value
        await self.tailSettleTask?.value
        await self.pauseRevisionTask?.value
        await self.commitChain?.value
    }

    func reportFailure(_ message: String) {
        self.reportStatus(message, kind: .failure)
    }

    func reportStatus(_ message: String, kind: TheaterStatusKind) {
        self.status = TheaterStatus(text: message, kind: kind)
        self.objectWillChange.send()
    }

    func retryFailedTranslation() {
        guard let source = self.lastFailedSource else { return }
        self.lastFailedSource = nil
        self.status = .empty
        self.enqueueCommit(source, reason: .completedSentence)
    }

    func snapshot() -> TheaterBoardSnapshot {
        TheaterBoardSnapshot(entries: self.captionLog.entries, nextID: self.captionLog.nextID)
    }

    func restore(_ snapshot: TheaterBoardSnapshot) {
        self.cancelSettles()
        self.cancelCommitsAndPolish()
        self.generation += 1
        self.captionLog.restore(snapshot)
        self.committedLines = self.captionLog.translatedLines
        self.listenBatchStart = self.captionLog.sourceLines.count
        self.postedLineCount = self.committedLines.count
        self.translatedDraftSource = ""
        self.sourceDraft = ""
        self.translatedDraft = self.captionLog.translatedLines.last ?? ""
        self.status = .empty
        self.lastFailedSource = nil
        self.lastHeardText = ""
        self.lastSettleTail = ""
        self.lastSettleUnread = []
    }

    func pendingInsertDocument() -> String {
        let start = min(self.committedLines.count, max(self.postedLineCount, self.listenBatchStart))
        return PresenterCaptionController.captionDocument(
            committed: Array(self.committedLines.dropFirst(start)),
            draft: ""
        )
    }

    /// Same answer as `pendingInsertDocument().isEmpty` without joining the board.
    var hasPendingInsertText: Bool {
        let start = min(self.committedLines.count, max(self.postedLineCount, self.listenBatchStart))
        return self.committedLines.dropFirst(start).contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
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

    func removeLastCommittedLine() {
        guard self.captionLog.popLast() != nil else { return }
        self.committedLines = self.captionLog.translatedLines
        self.listenBatchStart = min(self.listenBatchStart, self.committedLines.count)
        self.postedLineCount = min(self.postedLineCount, self.committedLines.count)
        self.translatedDraftSource = ""
        self.sourceDraft = ""
        self.translatedDraft = self.captionLog.translatedLines.last ?? ""
        self.objectWillChange.send()
    }

    func applyEditedLines(_ lines: [String]) {
        let overflow = self.captionLog.replaceTranslatedLines(lines)
        self.archiveOverflow(overflow)
        self.committedLines = self.captionLog.translatedLines
        self.listenBatchStart = min(self.listenBatchStart, self.committedLines.count)
        self.postedLineCount = min(self.postedLineCount, self.committedLines.count)
        self.translatedDraftSource = ""
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
        if let committed = self.captionLog.commit(source: source, translated: translated) {
            self.archiveOverflow(committed.overflow)
            self.adjustIndexes(trimmedCount: committed.overflow.count)
        }
        self.committedLines = self.captionLog.translatedLines
        self.sourceDraft = source
        self.translatedDraft = translated
        self.translatedDraftSource = source
    }

    func handlePartial(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        self.eouHoldTask?.cancel()
        self.eouHoldTask = nil
        self.lastHeardText = cleaned
        let languageID = SpokenLanguageResolver.sourceLanguage().id
        let now = ProcessInfo.processInfo.systemUptime
        if self.latencyTracker.speechStart == nil {
            self.latencyTracker.markSpeechStart(now)
        }
        self.latencyTracker.markASRReady(now)

        let leftover = self.leftoverSpeech(cleaned, languageID: languageID)
        if self.shouldCancelPauseRevision(leftover: leftover) {
            self.pauseRevisionTask?.cancel()
            self.pauseRevisionTask = nil
            self.didPauseReviseThisUtterance = false
        }
        if !self.sourceDraft.isEmpty,
           !TranslationClauseSegmenter.isSameClause(self.sourceDraft, leftover),
           !TranslationClauseSegmenter.shouldReplaceLast(previous: self.sourceDraft, incoming: leftover),
           !TranslationClauseSegmenter.shouldIgnoreAsStalePrefix(previous: self.sourceDraft, incoming: leftover)
        {
            self.translatedDraft = ""
            self.translatedDraftSource = ""
            self.prefetchCache.invalidate()
        }
        self.sourceDraft = leftover
        if self.status.kind != .failure {
            self.status = .listening()
        }

        let split = TranslationClauseSegmenter.split(leftover, languageID: languageID)
        if split.completed.isEmpty, split.tail.isEmpty {
            self.completedSettleTask?.cancel()
            self.tailSettleTask?.cancel()
            self.lastSettleTail = ""
            self.lastSettleUnread = []
            return
        }

        let token = self.generation
        if TranslationClauseSegmenter.hasUnreadSpeechAfterCompleted(leftover, languageID: languageID) {
            self.commitNextSettledUnit(
                remaining: leftover,
                languageID: languageID,
                allowPauseFinalize: false,
                forceOpenTail: false,
                generation: token
            )
            self.schedulePrefetchIfNeeded(
                leftover: self.sourceDraft,
                languageID: languageID,
                generation: token
            )
            return
        }
        switch TranslationClauseSegmenter.decision(forTail: split.tail, languageID: languageID) {
        case .commitNow:
            Task { [weak self] in
                await self?.flushSettled(generation: token, isFinal: false, reason: .openTailAged)
            }
        case .ignore, .waitForStability:
            self.scheduleSettles(
                unread: split.completed,
                tail: split.tail,
                languageID: languageID,
                generation: token
            )
            self.schedulePrefetchIfNeeded(leftover: leftover, languageID: languageID, generation: token)
        }
    }

    private enum FlushReason {
        case completedClause
        case openTailAged
        case pauseConfirm
        case stop
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
                    await self?.flushSettled(generation: token, isFinal: false, reason: .completedClause)
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
            let reason: FlushReason = TranslationClauseSegmenter.looksComplete(tail, languageID: languageID)
                ? .completedClause
                : .openTailAged
            if delay == 0 {
                Task { [weak self] in
                    await self?.flushSettled(generation: token, isFinal: false, reason: .openTailAged)
                }
                return
            }
            self.tailSettleTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                await self?.flushSettled(generation: token, isFinal: false, reason: reason)
            }
        } else if !tail.isEmpty {
            self.lastSettleTail = tail
        }
    }

    private func flushSettled(generation token: UInt64, isFinal: Bool, reason: FlushReason) async {
        guard token == self.generation else { return }
        let languageID = SpokenLanguageResolver.sourceLanguage().id
        var cleaned = self.lastHeardText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        if LiveTranslationConfirm.shouldReDecode(
            isFinal: isFinal,
            isPause: reason == .pauseConfirm,
            languageID: languageID
        ),
           let confirmed = await self.confirmTranscript?() {
            let cleanedConfirm = confirmed.trimmingCharacters(in: .whitespacesAndNewlines)
            if LiveTranslationCommitContext.shouldPreferConfirmation(
                cleanedConfirm,
                over: self.lastHeardText,
                already: self.printedSources
            ) {
                self.lastHeardText = cleanedConfirm
                cleaned = cleanedConfirm
            }
        }

        let remaining = self.leftoverSpeech(cleaned, languageID: languageID)
        self.commitNextSettledUnit(
            remaining: remaining,
            languageID: languageID,
            allowPauseFinalize: reason == .openTailAged || reason == .pauseConfirm,
            forceOpenTail: false,
            generation: token
        )
    }

    private func commitNextSettledUnit(
        remaining initial: String,
        languageID: String,
        allowPauseFinalize: Bool,
        forceOpenTail: Bool,
        generation token: UInt64
    ) {
        var remaining = initial
        var steps = 0
        while steps < 32, !remaining.isEmpty {
            steps += 1
            let next = TranslationClauseSegmenter.printableCommitUnit(
                remaining,
                already: self.printedSources,
                languageID: languageID,
                allowPauseFinalize: allowPauseFinalize
            ).map { unit in
                (
                    unit: unit,
                    rest: TranslationClauseSegmenter.leftoverTail(
                        remaining,
                        already: self.printedSources + [unit],
                        languageID: languageID
                    )
                )
            } ?? TranslationClauseSegmenter.nextCommitUnit(
                remaining,
                languageID: languageID,
                allowPauseFinalize: allowPauseFinalize
            )
            let unit: String
            var rest: String
            if let next {
                unit = next.unit
                rest = next.rest
                if rest == remaining {
                    rest = TranslationClauseSegmenter.nextCommitUnit(
                        remaining,
                        languageID: languageID,
                        allowPauseFinalize: allowPauseFinalize
                    )?.rest ?? ""
                    if rest == remaining { rest = "" }
                }
            } else if forceOpenTail {
                let split = TranslationClauseSegmenter.split(remaining, languageID: languageID)
                if let first = split.completed.first {
                    unit = first
                    rest = TranslationClauseSegmenter.leftoverTail(
                        remaining,
                        already: [first],
                        languageID: languageID
                    )
                } else {
                    unit = split.tail.isEmpty ? remaining : split.tail
                    rest = ""
                }
            } else {
                self.sourceDraft = remaining
                self.lastSettleUnread = []
                self.lastSettleTail = remaining
                return
            }

            if rest == remaining { break }
            if self.shouldSkipSettledUnit(unit) {
                remaining = rest
                continue
            }

            self.enqueueCommit(unit, reason: .completedSentence)
            self.sourceDraft = rest
            self.lastSettleUnread = []
            self.lastSettleTail = rest
            guard !rest.isEmpty else { return }
            self.scheduleBacklogSettle(languageID: languageID, generation: token)
            return
        }

        self.sourceDraft = remaining
        self.lastSettleUnread = []
        self.lastSettleTail = remaining
    }

    private func shouldSkipSettledUnit(_ unit: String) -> Bool {
        if self.inFlightSources.contains(where: { TranslationClauseSegmenter.isSameClause($0, unit) }) {
            return true
        }
        let languageID = SpokenLanguageResolver.sourceLanguage().id
        if self.revisesEarlierPrintedLine(unit, languageID: languageID) {
            return true
        }
        if let last = self.listenSourceLines.last {
            if TranslationClauseSegmenter.isSameClause(last, unit),
               !self.mayReplaceLastCommitted(with: unit)
            {
                return true
            }
            if TranslationClauseSegmenter.shouldReviseCommitted(
                previous: last,
                incoming: unit,
                languageID: languageID
            ), !self.mayReplaceLastCommitted(with: unit) {
                return true
            }
        }
        if self.listenSourceLines.contains(where: {
            TranslationClauseSegmenter.isSameClause($0, unit)
        }) {
            return !self.mayReplaceLastCommitted(with: unit)
        }
        return false
    }

    /// English may correct before the title starts. After a translation is on
    /// the board, leftover speech is the next row.
    private func mayReplaceLastCommitted(with incoming: String) -> Bool {
        guard let last = self.listenSourceLines.last else { return false }
        guard TranslationClauseSegmenter.shouldReplaceLast(previous: last, incoming: incoming) else {
            return false
        }
        let lastTranslation = self.captionLog.translatedLines.last?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return lastTranslation.isEmpty
    }

    /// Commit leftover clauses one pause at a time. Never drain the rest of the
    /// talk in the same turn, even when ASR restitched several sentences at once.
    private func scheduleBacklogSettle(languageID: String, generation token: UInt64) {
        self.completedSettleTask?.cancel()
        self.tailSettleTask?.cancel()
        self.tailSettleTask = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: LiveTranslationTiming.completeSettleNanoseconds(languageID: languageID)
            )
            guard !Task.isCancelled else { return }
            await self?.flushSettled(generation: token, isFinal: false, reason: .completedClause)
        }
    }

    private func restartSettlesAfterHold(generation token: UInt64, languageID: String) {
        guard token == self.generation else { return }
        let leftover = self.leftoverSpeech(self.lastHeardText, languageID: languageID)
        let split = TranslationClauseSegmenter.split(leftover, languageID: languageID)
        if split.completed.isEmpty, split.tail.isEmpty { return }
        self.lastSettleUnread = []
        self.lastSettleTail = ""
        self.scheduleSettles(
            unread: split.completed,
            tail: split.tail,
            languageID: languageID,
            generation: token
        )
    }

    func translateFinal(_ text: String) async -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return text }

        self.lastHeardText = cleaned

        await self.flushSettled(generation: self.generation, isFinal: true, reason: .stop)
        if let chain = self.commitChain {
            await chain.value
        }

        let languageID = SpokenLanguageResolver.sourceLanguage().id
        let heard = self.lastHeardText.trimmingCharacters(in: .whitespacesAndNewlines)
        let leftover = self.leftoverSpeech(heard, languageID: languageID)
        let token = self.generation
        var remaining = leftover
        while let unit = TranslationClauseSegmenter.printableCommitUnit(
            remaining,
            already: self.printedSources,
            languageID: languageID,
            allowPauseFinalize: false
        ) ?? TranslationClauseSegmenter.nextCommitUnit(
            remaining,
            languageID: languageID,
            allowPauseFinalize: false
        )?.unit {
            await self.commitUnit(unit, generation: token, reason: .final)
            let next = self.leftoverSpeech(remaining, languageID: languageID)
            if next == remaining { break }
            remaining = next
        }
        if !remaining.isEmpty {
            let unit: String
            if remaining.count >= LiveTranslationTiming.maxDraftCharacters {
                unit = String(remaining.prefix(LiveTranslationTiming.maxDraftCharacters))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                unit = remaining
            }
            if !unit.isEmpty {
                await self.commitUnit(unit, generation: token, reason: .final)
            }
        }

        self.sourceDraft = ""
        self.translatedDraft = self.captionLog.translatedLines.last ?? ""
        self.translatedDraftSource = self.captionLog.sourceLines.last ?? ""
        return self.pendingInsertDocument()
    }

    private enum CommitReason {
        case completedSentence
        case stableTail
        case final
    }

    private func enqueueCommit(_ source: String, reason: CommitReason, generation: UInt64? = nil) {
        let languageID = SpokenLanguageResolver.sourceLanguage().id
        var cleaned = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if CaptionJunkGate.shouldDrop(cleaned) { return }
        let replaceLast = self.mayReplaceLastCommitted(with: cleaned)
        if !replaceLast,
           let unit = TranslationClauseSegmenter.printableCommitUnit(
               cleaned,
               already: self.printedSources,
               languageID: languageID,
               allowPauseFinalize: true
           )
        {
            cleaned = unit
        }
        if CaptionJunkGate.shouldDrop(cleaned) { return }
        if TranslationClauseSegmenter.isTooThinToCommit(
            cleaned,
            languageID: languageID
        ) {
            return
        }
        if self.inFlightSources.contains(where: { TranslationClauseSegmenter.isSameClause($0, cleaned) }) {
            return
        }
        if let last = self.listenSourceLines.last,
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

    private func commitUnit(_ source: String, generation: UInt64, reason _: CommitReason) async {
        let incoming = source.trimmingCharacters(in: .whitespacesAndNewlines)
        var cleaned = incoming
        defer { self.inFlightSources.removeAll { $0 == incoming || $0 == cleaned } }
        guard generation == self.generation else { return }
        guard !cleaned.isEmpty else { return }
        let languageID = SpokenLanguageResolver.sourceLanguage().id
        if TranslationClauseSegmenter.isTooThinToCommit(
            cleaned,
            languageID: languageID
        ) {
            return
        }

        if let lastSource = self.captionLog.sourceLines.last {
            if TranslationClauseSegmenter.shouldIgnoreAsStalePrefix(previous: lastSource, incoming: cleaned) {
                return
            }
            if TranslationClauseSegmenter.shouldReviseCommitted(
                previous: lastSource,
                incoming: cleaned,
                languageID: languageID
            ), !TranslationClauseSegmenter.shouldReplaceLast(previous: lastSource, incoming: cleaned) {
                return
            }
        }
        if self.revisesEarlierPrintedLine(cleaned, languageID: languageID) {
            return
        }
        let replaceLast = self.mayReplaceLastCommitted(with: cleaned)
        if !replaceLast, self.listenSourceLines.last == cleaned {
            return
        }

        do {
            let resolved: String
            if SpokenLanguageResolver.isSameLanguagePair() {
                resolved = cleaned
            } else if let cached = self.cachedLiveTranslation(for: cleaned) {
                resolved = cached
                self.lastLatencyMilliseconds = 0
            } else {
                self.status = .info("Translating…")
                let translated = try await self.performTranslation(cleaned, kind: .commit)
                guard generation == self.generation else { return }
                guard let safe = LLMTranslationEngine.captionSafeForBoard(translated, sourceText: cleaned)
                else {
                    throw TranslationEngineError.localRejected
                }
                resolved = safe
            }

            guard let committed = self.captionLog.commit(
                source: cleaned,
                translated: resolved,
                mayReviseLast: replaceLast
            ) else { return }
            self.archiveOverflow(committed.overflow)
            self.adjustIndexes(trimmedCount: committed.overflow.count)
            self.committedLines = self.captionLog.translatedLines
            if !self.committedLines.isEmpty {
                SettingsStore.shared.theaterListenUsed = true
            }
            self.didAutoRetryFailure = false
            self.publishLatencySample(mtMilliseconds: self.lastLatencyMilliseconds ?? 0)
            self.latencyTracker.resetUtterance()

            let heard = self.lastHeardText.isEmpty ? self.sourceDraft : self.lastHeardText
            let leftover = self.leftoverSpeech(
                heard,
                languageID: SpokenLanguageResolver.sourceLanguage().id
            )
            self.sourceDraft = leftover
            self.status = leftover.isEmpty ? .empty : .listening()
            if leftover.isEmpty {
                self.translatedDraft = resolved
                self.translatedDraftSource = cleaned
            } else if TranslationClauseSegmenter.isSameClause(leftover, cleaned) {
                self.sourceDraft = ""
                self.translatedDraft = resolved
                self.translatedDraftSource = cleaned
                self.status = .empty
            } else {
                self.translatedDraft = ""
                self.translatedDraftSource = ""
            }
        } catch {
            guard generation == self.generation else { return }
            self.lastFailedSource = cleaned
            self.status = .failure("Translation failed — Retry / Download pack")
            DebugLogger.shared.error(
                "Lecture translation failed: \(error.localizedDescription)",
                source: "LiveTranslation"
            )
            if !self.didAutoRetryFailure {
                self.didAutoRetryFailure = true
                self.scheduleFailedRetry(cleaned, generation: generation)
            }
        }
    }

    private func cachedLiveTranslation(for source: String) -> String? {
        let cleaned = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let cached = self.translatedDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty, !cached.isEmpty,
           TranslationClauseSegmenter.isSameClause(self.translatedDraftSource, cleaned)
        {
            return cached
        }
        let settings = SettingsStore.shared
        let sourceLanguage = SpokenLanguageResolver.sourceLanguage(settings: settings)
        let target = SpokenLanguageResolver.targetLanguage(settings: settings)
        let prior = self.priorClausesForContextualTranslation(incoming: cleaned)
        let key = LiveTranslationPrefetch.cacheKey(
            unit: cleaned,
            priorSources: prior.sources,
            sourceID: sourceLanguage.id,
            targetID: target.id
        )
        return self.prefetchCache.caption(for: key)
    }

    private func schedulePrefetchIfNeeded(leftover: String, languageID: String, generation: UInt64) {
        guard !SpokenLanguageResolver.isSameLanguagePair() else { return }
        guard self.translator === self.appleEngine else { return }
        guard self.appleEngine.isMailboxReady else { return }
        guard !self.appleEngine.hasQueuedOrInFlightCommit else { return }
        guard self.inFlightSources.isEmpty else { return }
        guard let unit = LiveTranslationPrefetch.unitToPrefetch(leftover: leftover, languageID: languageID)
        else { return }
        let settings = SettingsStore.shared
        let source = SpokenLanguageResolver.sourceLanguage(settings: settings)
        let target = SpokenLanguageResolver.targetLanguage(settings: settings)
        let prior = self.priorClausesForContextualTranslation(incoming: unit)
        let key = LiveTranslationPrefetch.cacheKey(
            unit: unit,
            priorSources: prior.sources,
            sourceID: source.id,
            targetID: target.id
        )
        guard let token = self.prefetchCache.begin(key) else { return }
        Task { [weak self] in
            await self?.prefetchUnit(unit, key: key, prior: prior, generation: generation, cacheGeneration: token)
        }
    }

    private func prefetchUnit(
        _ unit: String,
        key: LiveTranslationPrefetchKey,
        prior: (sources: [String], translations: [String]),
        generation: UInt64,
        cacheGeneration: UInt64
    ) async {
        defer { self.prefetchCache.finish(key, caption: nil, generation: cacheGeneration) }
        guard generation == self.generation else { return }
        guard !self.appleEngine.hasQueuedOrInFlightCommit else { return }
        let settings = SettingsStore.shared
        let source = SpokenLanguageResolver.sourceLanguage(settings: settings)
        let target = SpokenLanguageResolver.targetLanguage(settings: settings)
        let terms = TranslationGlossary.protectedTerms(from: settings)
        do {
            let translated = try await LiveTranslationMT.translateClause(
                unit,
                source: source,
                target: target,
                terms: terms,
                kind: .live,
                prior: prior,
                translator: self.appleEngine,
                llmEngine: self.llmEngine,
                allowLocal: false
            )
            guard generation == self.generation else { return }
            guard let safe = LLMTranslationEngine.captionSafeForBoard(translated, sourceText: unit)
            else { return }
            self.prefetchCache.finish(key, caption: safe, generation: cacheGeneration)
        } catch {
            DebugLogger.shared.debug(
                "Live prefetch skipped: \(error.localizedDescription)",
                source: "LiveTranslation"
            )
        }
    }

    private func performTranslation(_ text: String, kind: TranslationRequestKind = .commit) async throws -> String {
        let settings = SettingsStore.shared
        let source = SpokenLanguageResolver.sourceLanguage(settings: settings)
        let target = SpokenLanguageResolver.targetLanguage(settings: settings)
        if source.id == target.id {
            self.lastLatencyMilliseconds = 0
            return text
        }
        self.appleEngine.prepare(source: source, target: target)

        let terms = TranslationGlossary.protectedTerms(from: settings)
        let started = ProcessInfo.processInfo.systemUptime
        let prior = self.priorClausesForContextualTranslation(incoming: text)
        let translated = try await LiveTranslationMT.translateClause(
            text,
            source: source,
            target: target,
            terms: terms,
            kind: kind,
            prior: prior,
            translator: self.translator,
            llmEngine: self.llmEngine
        )
        let ms = Int(((ProcessInfo.processInfo.systemUptime - started) * 1000).rounded())
        self.lastLatencyMilliseconds = ms
        DebugLogger.shared.debug(
            "Live translation \(source.id)->\(target.id) \(ms)ms chars=\(text.count)",
            source: "LiveTranslation"
        )
        return translated
    }

    func priorClausesForTesting(incoming: String) -> (sources: [String], translations: [String]) {
        self.priorClausesForContextualTranslation(incoming: incoming)
    }

    private func priorClausesForContextualTranslation(
        incoming: String
    ) -> (sources: [String], translations: [String]) {
        Self.priorClauses(
            entries: self.captionLog.entries,
            listenBatchStart: self.listenBatchStart,
            incoming: incoming
        )
    }

    static func priorClauses(
        entries: [LectureCaptionEntry],
        listenBatchStart: Int,
        incoming: String,
        limit: Int = LiveTranslationTiming.contextSentenceCount
    ) -> (sources: [String], translations: [String]) {
        LiveTranslationCommitContext.priorClauses(
            entries: entries,
            listenBatchStart: listenBatchStart,
            incoming: incoming,
            limit: limit
        )
    }

    private func publishLatencySample(mtMilliseconds: Int) {
        self.lastLatencySample = self.latencyTracker.markTranslated(
            at: ProcessInfo.processInfo.systemUptime,
            mtMilliseconds: mtMilliseconds,
            thermal: ProcessInfo.processInfo.thermalState
        )
    }

    private func archiveOverflow(_ overflow: [LectureCaptionEntry]) {
        guard !overflow.isEmpty else { return }
        self.archive.enqueue(overflow)
    }

    private func cancelSettles() {
        self.completedSettleTask?.cancel()
        self.tailSettleTask?.cancel()
        self.eouHoldTask?.cancel()
        self.pauseRevisionTask?.cancel()
        self.failedRetryTask?.cancel()
        self.completedSettleTask = nil
        self.tailSettleTask = nil
        self.eouHoldTask = nil
        self.pauseRevisionTask = nil
        self.failedRetryTask = nil
    }

    private func shouldCancelPauseRevision(leftover: String) -> Bool {
        let leftover = leftover.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !leftover.isEmpty else { return false }
        if TranslationClauseSegmenter.isSameClause(self.sourceDraft, leftover) { return false }
        if TranslationClauseSegmenter.shouldIgnoreAsStalePrefix(
            previous: self.sourceDraft,
            incoming: leftover
        ) {
            return false
        }
        return true
    }

    private func schedulePauseRevision() {
        guard !self.didPauseReviseThisUtterance else { return }
        guard self.pauseRevisionTask == nil else { return }
        let token = self.generation
        self.pauseRevisionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: LiveTranslationTiming.eouHoldNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.reviseOnPause(generation: token)
        }
    }

    private func reviseOnPause(generation: UInt64) async {
        guard generation == self.generation else { return }
        guard !self.didPauseReviseThisUtterance else { return }
        self.didPauseReviseThisUtterance = true
        await self.flushSettled(generation: generation, isFinal: false, reason: .pauseConfirm)
    }

    private func scheduleFailedRetry(_ source: String, generation: UInt64) {
        self.failedRetryTask?.cancel()
        self.failedRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self else { return }
            guard generation == self.generation, self.lastFailedSource == source else { return }
            self.retryFailedTranslation()
        }
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
                    target: target,
                    priorSource: priorSource,
                    priorCaptions: priorCaptions
                ), accepted != draft else { return }
                if !TranslationGlossary.lostProtectedTerms(
                    source: sourceText,
                    polished: accepted,
                    terms: terms
                ).isEmpty {
                    return
                }
                // Printed captions stay. Polish must not rewrite a line that
                // is already on the board.
            } catch {
                DebugLogger.shared.debug(
                    "Caption polish skipped: \(error.localizedDescription)",
                    source: "LiveTranslation"
                )
            }
            self.polishTasks[lineID] = nil
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

    private func cancelCommitsAndPolish() {
        self.commitChain?.cancel()
        self.commitChain = nil
        self.polishTasks.values.forEach { $0.cancel() }
        self.polishTasks.removeAll()
        self.inFlightSources = []
        self.prefetchCache.invalidate()
    }

    private func adjustIndexes(trimmedCount: Int) {
        guard trimmedCount > 0 else { return }
        self.listenBatchStart = max(0, self.listenBatchStart - trimmedCount)
        self.postedLineCount = max(0, self.postedLineCount - trimmedCount)
    }
}
