import Combine
import Darwin
import Foundation

// swiftlint:disable function_body_length cyclomatic_complexity type_body_length
// Session owner. Mid-talk commit is nextCompletedSentence; leftover flush is
// nextCommitUnit. LiveTranslationCommitContext is prior-4 MT context + peel.

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
    private var inFlightStartedAt: [String: Date] = [:]
    private var lastHeardText: String = ""
    /// A finished sentence seen in the previous recognition update, still
    /// with nothing after it. Two updates agreeing means the ending is real.
    private var loneCompleteCandidate = ""
    /// Latest full recognition text, used to spot a restitched newest line.
    private var latestHypothesis = ""
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
    private var lastFailedSource: String?
    var confirmTranscript: (() async -> String)?
    var canRetryTranslation: Bool { self.lastFailedSource != nil }
    var isApproachingLineLimit: Bool { false }

    var archivedLineCount: Int { 0 }
    var sessionLineCount: Int { self.captionLog.entries.count }

    var lineWindowStatus: String? { nil }

    var committedSourceLines: [String] { self.captionLog.sourceLines }
    var committedLineIDs: [UInt64] { self.captionLog.lineIDs }
    var nextCaptionID: UInt64 { self.captionLog.nextID }
    /// Whole talk for history and export. The board log keeps only the lines
    /// on screen, so an hour-long talk would otherwise save three lines.
    var captionPairs: [CaptionHistoryPair] {
        self.sessionEntries.isEmpty
            ? self.captionLog.captionPairs
            : TheaterCaptionExport.pairs(from: self.sessionEntries)
    }
    var exportCaptionPairs: [CaptionHistoryPair] { self.captionPairs }

    /// Every pair printed this session, in memory only (an hour is ~100 KB).
    private var sessionEntries: [LectureCaptionEntry] = []

    func startSessionRecord() {
        self.sessionEntries = []
    }

    /// Mirror the board log into the session record: new pairs append, a
    /// fixed or edited on-screen pair updates its copy.
    private func recordSessionEntries() {
        for entry in self.captionLog.entries {
            let recentStart = max(0, self.sessionEntries.count - 8)
            if let index = self.sessionEntries[recentStart...].lastIndex(where: {
                $0.id == entry.id && $0.committedAt == entry.committedAt
            }) {
                self.sessionEntries[index] = entry
            } else if !self.sessionEntries.contains(where: {
                $0.id == entry.id && $0.committedAt == entry.committedAt
            }) {
                self.sessionEntries.append(entry)
            }
        }
    }

    func flushArchive() {
        self.archive.flush()
    }

    /// Live Show-as title. Prefetch paints here while you talk; commit keeps it.
    var liveCaptionText: String {
        let last = self.committedLines.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let draft = self.resolvedLiveCaptionDraft()
        if draft.isEmpty || draft == last {
            return ""
        }
        return TheaterCaptionFlow.freshCaption(
            draft,
            lastText: last,
            printedSources: self.committedLines
        )
    }

    private func resolvedLiveCaptionDraft() -> String {
        let fromDraft = self.translatedDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = self.committedLines.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !fromDraft.isEmpty, fromDraft != last {
            return fromDraft
        }
        let leftover = self.liveSpokenText
        guard !leftover.isEmpty else { return "" }
        if let cached = self.cachedLiveTranslation(for: leftover) {
            return cached
        }
        let languageID = SpokenLanguageResolver.listenLanguageID(for: leftover)
        if let unit = LiveTranslationPrefetch.unitToPrefetch(leftover: leftover, languageID: languageID),
           let cached = self.cachedLiveTranslation(for: unit)
        {
            return cached
        }
        return ""
    }

    /// Full leftover after committed history. lineCut is commit-time only.
    var liveSpokenText: String {
        let languageID = SpokenLanguageResolver.listenLanguageID(for: self.sourceDraft)
        let leftover = self.leftoverSpeech(self.sourceDraft, languageID: languageID)
        return self.visibleSpokenClause(leftover) ?? ""
    }

    private func visibleSpokenClause(_ text: String) -> String? {
        let open = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if open.isEmpty { return nil }
        let languageID = SpokenLanguageResolver.listenLanguageID(for: open)
        if CaptionJunkGate.shouldDrop(open) {
            return nil
        }
        if TranslationClauseSegmenter.isAlreadyPrintedSource(
            open,
            already: self.listenSourceLines,
            languageID: languageID
        ) {
            return nil
        }
        if self.captionLog.sourceLines.dropLast().contains(where: {
            TranslationClauseSegmenter.isSameClause($0, open)
                || self.revisesPrinted(
                    previous: $0,
                    incoming: open,
                    languageID: languageID
                )
        }) {
            return nil
        }
        if let last = self.captionLog.sourceLines.last {
            if TranslationClauseSegmenter.isSameClause(last, open) { return nil }
            if self.revisesPrinted(
                previous: last,
                incoming: open,
                languageID: languageID
            ), !TranslationClauseSegmenter.shouldReplaceLast(previous: last, incoming: open) {
                return nil
            }
        }
        return open
    }

    /// Finished sentences already spoken but still waiting on their
    /// translation. Must stay on screen (English only) while in flight —
    /// nothing already printed may disappear, even briefly.
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

    /// How long the oldest finished sentence has waited for its caption.
    var oldestInFlightWaitMilliseconds: Int? {
        guard let oldest = self.inFlightStartedAt.values.min() else { return nil }
        return max(0, Int(Date().timeIntervalSince(oldest) * 1000))
    }

    /// In-flight commits offset the live `c-id` so leftover is not the same view.
    var inFlightCaptionCount: Int {
        self.inFlightSources.count
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
            already: self.listenSourceLines,
            languageID: languageID
        )
        let boardLeftover = TranslationClauseSegmenter.leftoverTail(
            text,
            already: self.captionLog.sourceLines,
            languageID: languageID
        )
        let result: String
        if boardLeftover.isEmpty {
            result = self.repeatableGreetingLeftover(listenLeftover, languageID: languageID)
        } else {
            let unread = boardLeftover != listenLeftover ? boardLeftover : listenLeftover
            result = self.peelPrintedOrRevisedBoardLines(unread, languageID: languageID)
        }
        return result
    }

    private func repeatableGreetingLeftover(_ listenLeftover: String, languageID: String) -> String {
        guard !listenLeftover.isEmpty, self.listenSourceLines.isEmpty else { return "" }
        guard let last = self.captionLog.sourceLines.last else { return listenLeftover }
        if TranslationClauseSegmenter.isSameClause(last, listenLeftover)
            || self.revisesPrinted(
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
                        self.revisesPrinted(
                            previous: line,
                            incoming: first,
                            languageID: languageID
                        )
                        && !TranslationClauseSegmenter.shouldReplaceLast(previous: line, incoming: first)
                    )
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
                || self.revisesPrinted(
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
        self.tailSettleTask?.cancel()
        self.tailSettleTask = nil
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
            self?.scheduleOpenTailSettle(generation: token)
        }
    }

    func waitForIdleForTesting() async {
        await self.completedSettleTask?.value
        await self.eouHoldTask?.value
        await self.tailSettleTask?.value
        await self.pauseRevisionTask?.value
        // A pause confirm or EOU flush schedules the silent-tail print last.
        await self.tailSettleTask?.value
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
        guard let removed = self.captionLog.popLast() else { return }
        self.sessionEntries.removeAll { $0.id == removed.id && $0.committedAt == removed.committedAt }
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
        self.recordSessionEntries()
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
        self.latestHypothesis = cleaned
        self.eouHoldTask?.cancel()
        self.eouHoldTask = nil
        let languageID = SpokenLanguageResolver.listenLanguageID(for: cleaned)
        let now = ProcessInfo.processInfo.systemUptime
        if self.latencyTracker.speechStart == nil {
            self.latencyTracker.markSpeechStart(now)
        }
        self.latencyTracker.markASRReady(now)

        let leftover = self.rememberUnreadSpeech(cleaned, languageID: languageID)
        if self.shouldCancelPauseRevision(leftover: leftover) {
            self.pauseRevisionTask?.cancel()
            self.pauseRevisionTask = nil
            self.didPauseReviseThisUtterance = false
        }
        self.sourceDraft = leftover
        if self.status.kind != .failure {
            self.status = .listening()
        }
        self.commitCompletedSentencesWhileTalking(
            remaining: leftover,
            languageID: languageID
        )
        self.schedulePrefetchIfNeeded(
            leftover: self.sourceDraft,
            languageID: languageID,
            generation: self.generation
        )
    }

    /// Pair each finished sentence as soon as more speech follows it.
    /// A lone finished sentence prints once two recognition updates agree on
    /// it, so a late restitch of its last words cannot print a wrong line.
    /// Follow-along word cuts stay pause-only.
    private func commitCompletedSentencesWhileTalking(remaining initial: String, languageID: String) {
        var remaining = initial
        var steps = 0
        while steps < 32, !remaining.isEmpty {
            steps += 1
            guard let next = TranslationClauseSegmenter.nextCompletedSentence(
                remaining,
                languageID: languageID
            ) else { break }
            if self.shouldSkipSettledUnit(next.unit) {
                remaining = next.rest
                continue
            }
            self.enqueueCommit(next.unit, reason: .completedSentence)
            remaining = next.rest
        }
        remaining = self.commitConfirmedLoneSentence(remaining, languageID: languageID)
        self.sourceDraft = remaining
        self.lastHeardText = remaining
        self.lastSettleUnread = []
        self.lastSettleTail = remaining
    }

    private func commitConfirmedLoneSentence(_ remaining: String, languageID: String) -> String {
        let lone = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lone.isEmpty,
              TranslationClauseSegmenter.isCommitComplete(lone, languageID: languageID)
        else {
            self.loneCompleteCandidate = ""
            return remaining
        }
        guard lone == self.loneCompleteCandidate else {
            self.loneCompleteCandidate = lone
            return remaining
        }
        self.loneCompleteCandidate = ""
        if self.shouldSkipSettledUnit(lone) { return remaining }
        self.enqueueCommit(lone, reason: .completedSentence)
        return ""
    }

    private enum FlushReason {
        case completedClause
        /// Sustained silence after a pause confirm: print a short unfinished tail.
        case openTailAged
        case pauseConfirm
        case stop
    }

    private func flushSettled(
        generation token: UInt64,
        isFinal: Bool,
        reason: FlushReason,
        forceOpenTail: Bool = false
    ) async {
        guard token == self.generation else { return }
        var cleaned = self.lastHeardText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let languageID = SpokenLanguageResolver.listenLanguageID(for: cleaned)

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
                cleaned = cleanedConfirm
            }
        }

        let remaining = self.rememberUnreadSpeech(cleaned, languageID: languageID)
        self.commitNextSettledUnit(
            remaining: remaining,
            languageID: languageID,
            allowPauseFinalize: reason == .openTailAged || reason == .pauseConfirm,
            forceOpenTail: forceOpenTail,
            generation: token
        )
    }

    private func commitNextSettledUnit(
        remaining initial: String,
        languageID: String,
        allowPauseFinalize: Bool,
        forceOpenTail: Bool,
        generation _: UInt64
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
            remaining = rest
            self.lastSettleUnread = []
            self.lastSettleTail = rest
        }

        if !remaining.isEmpty, self.inFlightSources.isEmpty {
            self.sourceDraft = remaining
            self.lastHeardText = remaining
        }
        self.lastSettleUnread = []
        self.lastSettleTail = remaining
    }

    private func shouldSkipSettledUnit(_ unit: String) -> Bool {
        if self.inFlightSources.contains(where: { TranslationClauseSegmenter.isSameClause($0, unit) }) {
            return true
        }
        let languageID = SpokenLanguageResolver.listenLanguageID(for: unit)
        if self.revisesEarlierPrintedLine(unit, languageID: languageID) {
            return true
        }
        if let last = self.listenSourceLines.last {
            if TranslationClauseSegmenter.isSameClause(last, unit),
               !self.mayReplaceLastCommitted(with: unit)
            {
                return true
            }
            if self.revisesPrinted(
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
    /// the board, leftover speech is the next row. An in-flight commit already
    /// owns that slot, so a second unit cannot replace it.
    /// Recognition dropped the newest line's ending and ran on: the latest
    /// text has the printed sentence, without its period, straight into this
    /// unit. A real next sentence keeps the period between them.
    /// Commits run one at a time in order, so the log's newest entry is the
    /// line spoken right before `unit` even if later units are queued.
    private func restitchedNewestLine(continuedBy unit: String) -> String? {
        guard !self.listenSourceLines.isEmpty,
              let last = self.captionLog.sourceLines.last?.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        let stem = Self.droppingTerminalPunctuation(last)
        guard !stem.isEmpty, stem != last else { return nil }
        let unitStart = Self.droppingTerminalPunctuation(unit)
        guard !unitStart.isEmpty else { return nil }
        let hypothesis = Self.collapsedSpacing(self.latestHypothesis)
        let joined = Self.collapsedSpacing(stem + " " + unitStart)
        guard hypothesis.range(of: joined, options: [.caseInsensitive]) != nil else { return nil }
        return Self.collapsedSpacing(stem + " " + unit.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func reviseNewestLine(to revised: String, generation: UInt64) async {
        do {
            let resolved: String
            if SpokenLanguageResolver.isSameLanguagePair() {
                resolved = revised
            } else {
                let translated = try await self.performTranslation(
                    revised,
                    kind: .commit,
                    excludingNewestLine: true
                )
                guard generation == self.generation else { return }
                guard let safe = LLMTranslationEngine.captionSafeForBoard(translated, sourceText: revised) else {
                    return
                }
                resolved = safe
            }
            guard self.captionLog.reviseNewest(source: revised, translated: resolved) else { return }
            self.recordSessionEntries()
            self.committedLines = self.captionLog.translatedLines
            self.translatedDraft = resolved
            self.translatedDraftSource = revised
            DebugLogger.shared.debug(
                "Theater fixed newest line in place after restitch: \"\(revised)\"",
                source: "LiveTranslation"
            )
        } catch {
            // Keep the printed line; the extra words were already heard.
            DebugLogger.shared.debug("Theater restitch revise failed: \(error)", source: "LiveTranslation")
        }
    }

    private static func droppingTerminalPunctuation(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = trimmed.last, ".!?。！？…".contains(last) {
            trimmed.removeLast()
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func collapsedSpacing(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// A similar clause is an ASR correction of a printed line only if that
    /// line no longer appears intact in the latest recognition text. When it
    /// still does, the similar clause is new speech ("…on English data." then
    /// "…on Korean data.") and must print, not vanish as a "revision".
    private func revisesPrinted(previous: String, incoming: String, languageID: String) -> Bool {
        guard TranslationClauseSegmenter.shouldReviseCommitted(
            previous: previous,
            incoming: incoming,
            languageID: languageID
        ) else { return false }
        if TranslationClauseSegmenter.shouldReplaceLast(previous: previous, incoming: incoming) { return true }
        let hypothesis = self.latestHypothesis
        guard !hypothesis.isEmpty else { return true }
        return !TranslationClauseSegmenter.contains(hypothesis, clause: previous)
    }

    private func mayReplaceLastCommitted(with incoming: String) -> Bool {
        guard self.inFlightSources.isEmpty else { return false }
        guard let last = self.listenSourceLines.last else { return false }
        guard TranslationClauseSegmenter.shouldReplaceLast(previous: last, incoming: incoming) else {
            return false
        }
        let lastTranslation = self.captionLog.translatedLines.last?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return lastTranslation.isEmpty
    }

    func translateFinal(_ text: String) async -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return text }
        self.latestHypothesis = cleaned
        let incomingLanguage = SpokenLanguageResolver.listenLanguageID(for: cleaned)
        _ = self.rememberUnreadSpeech(cleaned, languageID: incomingLanguage)

        await self.flushSettled(generation: self.generation, isFinal: true, reason: .stop)
        if let chain = self.commitChain {
            await chain.value
        }

        let heard = self.lastHeardText.trimmingCharacters(in: .whitespacesAndNewlines)
        let languageID = SpokenLanguageResolver.listenLanguageID(for: heard)
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
        /// Unused. Open-tail settle tasks are not started.
        case stableTail
        case final
    }

    private func enqueueCommit(_ source: String, reason: CommitReason, generation: UInt64? = nil) {
        var cleaned = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let languageID = SpokenLanguageResolver.listenLanguageID(for: cleaned)
        if CaptionJunkGate.shouldDrop(cleaned) { return }
        let replaceLast = self.mayReplaceLastCommitted(with: cleaned)
        if reason != .completedSentence,
           !replaceLast,
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
        self.inFlightStartedAt[cleaned] = Date()
        self.commitChain = Task { [weak self] in
            await previous?.value
            await self?.commitUnit(cleaned, generation: token, reason: reason)
        }
    }

    private func commitUnit(_ source: String, generation: UInt64, reason _: CommitReason) async {
        let incoming = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = incoming
        defer {
            self.inFlightSources.removeAll { $0 == incoming || $0 == cleaned }
            self.inFlightStartedAt[incoming] = nil
            self.inFlightStartedAt[cleaned] = nil
        }
        guard generation == self.generation else { return }
        guard !cleaned.isEmpty else { return }
        let languageID = SpokenLanguageResolver.listenLanguageID(for: cleaned)
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
            if self.revisesPrinted(
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
        if let revised = self.restitchedNewestLine(continuedBy: cleaned) {
            await self.reviseNewestLine(to: revised, generation: generation)
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
                let sharpened = await self.sharpenCachedCaption(cleaned, draft: cached)
                resolved = sharpened
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
            self.recordSessionEntries()
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
                languageID: SpokenLanguageResolver.listenLanguageID(for: heard)
            )
            self.sourceDraft = leftover
            self.lastHeardText = leftover
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
                if TranslationClauseSegmenter.isSameClause(self.translatedDraftSource, cleaned)
                    || !TranslationClauseSegmenter.isGrowingClause(self.translatedDraftSource, toward: leftover)
                {
                    // The held draft no longer applies to the leftover speech,
                    // but a prefetch may already have finished translating it —
                    // reuse that instead of blanking already-done work.
                    if let cached = self.cachedLiveTranslation(for: leftover) {
                        self.translatedDraft = cached
                        self.translatedDraftSource = leftover
                    } else {
                        self.translatedDraft = ""
                        self.translatedDraftSource = ""
                    }
                }
                self.schedulePrefetchIfNeeded(
                    leftover: leftover,
                    languageID: SpokenLanguageResolver.listenLanguageID(for: leftover),
                    generation: generation
                )
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
        let pair = SpokenLanguageResolver.pairForSpokenText(cleaned, settings: settings)
        let sourceLanguage = pair.source
        let target = pair.target
        let prior = self.priorClausesForContextualTranslation(incoming: cleaned)
        let key = LiveTranslationPrefetch.cacheKey(
            unit: cleaned,
            priorSources: prior.sources,
            sourceID: sourceLanguage.id,
            targetID: target.id
        )
        return self.prefetchCache.caption(for: key)
    }

    private func publishLivePrefetch(unit: String, caption: String) {
        let leftover = self.liveSpokenText
        let languageID = SpokenLanguageResolver.listenLanguageID(for: leftover)
        let matches = TranslationClauseSegmenter.isLivePrefetchMatch(
            unit: unit,
            leftover: leftover,
            languageID: languageID
        )
        guard matches else { return }
        let last = self.committedLines.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard caption != last else { return }
        self.translatedDraft = caption
        self.translatedDraftSource = unit
    }

    private func sharpenCachedCaption(_ source: String, draft: String) async -> String {
        let settings = SettingsStore.shared
        let pair = SpokenLanguageResolver.pairForSpokenText(source, settings: settings)
        let terms = TranslationGlossary.protectedTerms(from: settings)
        let prior = self.priorClausesForContextualTranslation(incoming: source)
        let started = ProcessInfo.processInfo.systemUptime
        if let sharpened = await LiveTranslationMT.localFirstPrint(
            source,
            draft: draft,
            prior: prior,
            source: pair.source,
            target: pair.target,
            terms: terms,
            llmEngine: self.llmEngine
        ) {
            self.lastLatencyMilliseconds = Int(
                ((ProcessInfo.processInfo.systemUptime - started) * 1000).rounded()
            )
            return sharpened
        }
        self.lastLatencyMilliseconds = 0
        return draft
    }

    private func schedulePrefetchIfNeeded(leftover: String, languageID: String, generation: UInt64) {
        let unit = LiveTranslationPrefetch.unitToPrefetch(leftover: leftover, languageID: languageID)
        guard !SpokenLanguageResolver.isSameLanguagePair() else { return }
        guard self.translator === self.appleEngine else { return }
        guard self.appleEngine.isMailboxReady else { return }
        guard !self.appleEngine.hasQueuedOrInFlightCommit else { return }
        guard self.inFlightSources.isEmpty else { return }
        guard let unit else { return }
        let settings = SettingsStore.shared
        let pair = SpokenLanguageResolver.pairForSpokenText(unit, settings: settings)
        let source = pair.source
        let target = pair.target
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
        let pair = SpokenLanguageResolver.pairForSpokenText(unit, settings: settings)
        let source = pair.source
        let target = pair.target
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
            self.publishLivePrefetch(unit: unit, caption: safe)
        } catch {
            DebugLogger.shared.debug(
                "Live prefetch skipped: \(error.localizedDescription)",
                source: "LiveTranslation"
            )
        }
    }

    private func performTranslation(
        _ text: String,
        kind: TranslationRequestKind = .commit,
        excludingNewestLine: Bool = false
    ) async throws -> String {
        let settings = SettingsStore.shared
        let pair = SpokenLanguageResolver.pairForSpokenText(text, settings: settings)
        let source = pair.source
        let target = pair.target
        if source.id == target.id {
            self.lastLatencyMilliseconds = 0
            return text
        }
        self.appleEngine.prepare(source: source, target: target)

        let terms = TranslationGlossary.protectedTerms(from: settings)
        let started = ProcessInfo.processInfo.systemUptime
        let prior = self.priorClausesForContextualTranslation(
            incoming: text,
            excludingNewestLine: excludingNewestLine
        )
        let translated = try await self.translateWithTimeout(
            text,
            source: source,
            target: target,
            terms: terms,
            kind: kind,
            prior: prior
        )
        let ms = Int(((ProcessInfo.processInfo.systemUptime - started) * 1000).rounded())
        self.lastLatencyMilliseconds = ms
        DebugLogger.shared.debug(
            "Live translation \(source.id)->\(target.id) \(ms)ms chars=\(text.count)",
            source: "LiveTranslation"
        )
        return translated
    }

    /// A hung Apple Translation call must not hold `inFlightSources`
    /// non-empty forever: `mayReplaceLastCommitted` hard-gates on it being
    /// empty, so a stuck call would permanently jam the caption stream.
    private func translateWithTimeout(
        _ text: String,
        source: TranslationLanguage,
        target: TranslationLanguage,
        terms: [String],
        kind: TranslationRequestKind,
        prior: (sources: [String], translations: [String])
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await LiveTranslationMT.translateClause(
                    text,
                    source: source,
                    target: target,
                    terms: terms,
                    kind: kind,
                    prior: prior,
                    translator: self.translator,
                    llmEngine: self.llmEngine
                )
            }
            group.addTask {
                try await Task.sleep(nanoseconds: LiveTranslationTiming.translateClauseTimeoutNanoseconds)
                throw LiveTranslationMTError.timedOut
            }
            defer { group.cancelAll() }
            let result = try await group.next()!
            return result
        }
    }

    func priorClausesForTesting(incoming: String) -> (sources: [String], translations: [String]) {
        self.priorClausesForContextualTranslation(incoming: incoming)
    }

    private func priorClausesForContextualTranslation(
        incoming: String,
        excludingNewestLine: Bool = false
    ) -> (sources: [String], translations: [String]) {
        // Fixing the newest line in place: its old text is not context.
        let entries = excludingNewestLine
            ? Array(self.captionLog.entries.dropLast())
            : self.captionLog.entries
        let prior = Self.priorClauses(
            entries: entries,
            listenBatchStart: self.listenBatchStart,
            incoming: incoming
        )
        guard SpokenLanguageResolver.isDynamicPairingEnabled() else { return prior }
        let incomingID = SpokenLanguageResolver.listenLanguageID(for: incoming)
        var sources: [String] = []
        var translations: [String] = []
        for (source, translation) in zip(prior.sources, prior.translations) {
            guard SpokenLanguageResolver.listenLanguageID(for: source) == incomingID else { continue }
            sources.append(source)
            translations.append(translation)
        }
        return (sources, translations)
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

    /// Off-screen captions are dropped. Theater is a live subtitle board.
    private func archiveOverflow(_ overflow: [LectureCaptionEntry]) {
        _ = overflow
    }

    /// Keep only unread speech. A cumulative ASR restitch of dropped lines
    /// is recovered from the last open leftover, not the whole talk.
    private func rememberUnreadSpeech(_ incoming: String, languageID: String) -> String {
        let leftover = self.retainUnreadSpeech(incoming, languageID: languageID)
        self.lastHeardText = leftover
        return leftover
    }

    private func retainUnreadSpeech(_ incoming: String, languageID: String) -> String {
        let peeled = self.leftoverSpeech(incoming, languageID: languageID)
        let open = self.lastHeardText.trimmingCharacters(in: .whitespacesAndNewlines)
        if peeled != incoming || open.isEmpty {
            return peeled
        }
        if incoming.hasPrefix(open) || open.hasPrefix(incoming) {
            return incoming.hasPrefix(open) ? incoming : peeled
        }
        if let range = incoming.range(of: open, options: [.caseInsensitive, .backwards]) {
            return self.leftoverSpeech(String(incoming[range.lowerBound...]), languageID: languageID)
        }
        return peeled
    }

    private func cancelSettles() {
        self.loneCompleteCandidate = ""
        self.latestHypothesis = ""
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
        self.scheduleOpenTailSettle(generation: generation)
    }

    /// A pause confirm keeps a short unfinished tail open ("and that's it")
    /// in case the thought continues. If the room stays silent, print it
    /// instead of holding it until the next sentence or Stop.
    private func scheduleOpenTailSettle(generation token: UInt64) {
        self.tailSettleTask?.cancel()
        self.tailSettleTask = nil
        guard token == self.generation else { return }
        let tail = self.sourceDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tail.isEmpty else { return }
        let languageID = SpokenLanguageResolver.listenLanguageID(for: tail)
        let delay = LiveTranslationTiming.openSettleNanoseconds(languageID: languageID)
        self.tailSettleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self else { return }
            self.tailSettleTask = nil
            // New speech since the pause means the thought went on.
            guard token == self.generation,
                  self.sourceDraft.trimmingCharacters(in: .whitespacesAndNewlines) == tail
            else { return }
            await self.flushSettled(
                generation: token,
                isFinal: false,
                reason: .openTailAged,
                forceOpenTail: true
            )
        }
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

    private func cancelCommitsAndPolish() {
        self.commitChain?.cancel()
        self.commitChain = nil
        self.inFlightSources = []
        self.inFlightStartedAt = [:]
        self.prefetchCache.invalidate()
    }

    private func adjustIndexes(trimmedCount: Int) {
        guard trimmedCount > 0 else { return }
        self.listenBatchStart = max(0, self.listenBatchStart - trimmedCount)
        self.postedLineCount = max(0, self.postedLineCount - trimmedCount)
    }
}
