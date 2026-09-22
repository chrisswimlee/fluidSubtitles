import Combine
import Darwin
import Foundation

// swiftlint:disable function_body_length cyclomatic_complexity type_body_length
// Session owner. One classifier per moment:
// mid-talk is nextCompletedSentence; pause and Stop units are printableCommitUnit;
// a fragment that printable refuses is force-flushed once.
// LectureCaptionLog.commit peels a leftover after the newest line once.

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
    /// Apple Translation started when the clause was known, not when the
    /// previous caption finished landing.
    private var inFlightTranslations: [String: Task<Result<String, Error>, Never>] = [:]
    private var lastHeardText: String = ""
    /// A finished sentence seen in the previous recognition update, still
    /// with nothing after it. Two updates agreeing means the ending is real.
    private var loneCompleteCandidate = ""
    /// Latest full recognition text, used to spot a restitched newest line.
    private var latestHypothesis = ""
    private var tailSettleTask: Task<Void, Never>?
    private var eouHoldTask: Task<Void, Never>?
    private var pauseRevisionTask: Task<Void, Never>?
    /// Voice only. Prints the next leftover sentence after a pause flush so
    /// a lagged restitch does not land every finished line in one tick.
    private var voiceCatchUpTask: Task<Void, Never>?
    private var failedRetryTask: Task<Void, Never>?
    private var didPauseReviseThisUtterance = false
    /// Last voiced packet. A late ASR tick after this goes quiet must still
    /// flush leftover — skipped silence ticks can miss while a chunk is busy.
    private var lastVoicedUptime: TimeInterval?
    private var didAutoRetryFailure = false
    private var commitChain: Task<Void, Never>?
    /// Clause-boundary Show-as. Separate from the commit chain so a pause
    /// can still translate the whole leftover.
    private var prefetchTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var translatedDraftSource: String = ""
    private let appleEngine: AppleTranslationEngine
    private let translator: TranslationEngine
    private let llmEngine: LLMTranslationEngine
    private let prefetchCache = LiveTranslationPrefetchCache()
    private var lastFailedSource: String?
    /// Last leftover published to the live row. Restitches may only grow it.
    private var heldLiveSpoken: String = ""
    /// Stable `c-N` for the open clause. Not `nextID + pendingCount`.
    private var liveRowIdentity: UInt64 = 0
    private var liveRowClause: String = ""
    /// Pause freezes unaccepted speech. Accepted translations already in flight may still land.
    private var liveSpeechHeld = false
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
    /// Sliding window for leftover peel and last-4 MT priors. Oldest drop.
    private var listenHistory: [LectureCaptionEntry] = []
    /// Lines the presenter removed this Listen. ASR's cumulative partial
    /// still contains them, so leftover peel must treat them as already read.
    private var suppressedSources: [String] = []

    func startSessionRecord() {
        self.sessionEntries = []
        self.listenHistory = []
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

    private func rememberListenEntry(_ entry: LectureCaptionEntry) {
        if let index = self.listenHistory.lastIndex(where: { $0.id == entry.id }) {
            self.listenHistory[index] = entry
        } else {
            self.listenHistory.append(entry)
        }
        let overflow = self.listenHistory.count - LiveTranslationTiming.maxListenHistory
        if overflow > 0 {
            self.listenHistory.removeFirst(overflow)
        }
    }

    private func forgetListenEntry(_ entry: LectureCaptionEntry) {
        self.listenHistory.removeAll { $0.id == entry.id }
    }

    /// Board edits only touch clauses this Listen already holds. Lines from an
    /// earlier Listen and hand-typed lines never join the peel window; a line
    /// the presenter deleted leaves it.
    private func applyEditsToListenHistory(removedFrom boardBefore: Set<UInt64>, edited: [LectureCaptionEntry]) {
        let byID = Dictionary(edited.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        self.listenHistory = self.listenHistory.compactMap { entry in
            if let updated = byID[entry.id] { return updated }
            return boardBefore.contains(entry.id) ? nil : entry
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
        if let unit = LiveTranslationPrefetch.unitToPrefetch(
            leftover: leftover,
            languageID: languageID,
            wordByWord: false
        ),
           let cached = self.cachedLiveTranslation(for: unit)
        {
            return cached
        }
        return ""
    }

    /// Current open clause after peel. Finished sentences sit on their own rows.
    /// Voice shows only the next unread clause. A lagged restitch of three
    /// finished sentences must not dump the whole leftover on this row.
    /// Extra finished sentences stay in leftover until they commit one at a
    /// time. Do not skip ahead to the tail — that hid sentence one and jumped.
    var liveSpokenText: String {
        let languageID = SpokenLanguageResolver.listenLanguageID(for: self.sourceDraft)
        let leftover = self.leftoverSpeech(self.sourceDraft, languageID: languageID)
        let open = SpokenLanguageResolver.isSameLanguagePair()
            ? self.nextVoiceSpokenClause(leftover, languageID: languageID)
            : TranslationClauseSegmenter.liveOpenClause(leftover, languageID: languageID)
        return self.visibleSpokenClause(open) ?? ""
    }

    /// First Voice clause still to type. Later finished sentences stay off
    /// this row until they commit.
    private func nextVoiceSpokenClause(_ leftover: String, languageID: String) -> String {
        let preview = TranslationClauseSegmenter.livePreview(leftover, languageID: languageID)
        let next = preview.pinned.first ?? preview.open
        return next.trimmingCharacters(in: .whitespacesAndNewlines)
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
            already: self.printedSources,
            languageID: languageID
        ) {
            return nil
        }
        // Newest line only. Earlier lines are already inside isAlreadyPrintedSource.
        // A replace-last growth of this line is still the live caption.
        if let last = self.printedSources.last,
           self.revisesPrinted(
               previous: last,
               incoming: open,
               languageID: languageID
           ),
           !TranslationClauseSegmenter.shouldReplaceLast(previous: last, incoming: open)
        {
            return nil
        }
        return open
    }

    /// Finished sentences waiting on translation. Diagnostics only; the board
    /// does not draw them.
    var pendingSpokenLines: [String] {
        let languageID = SpokenLanguageResolver.listenLanguageID(for: self.sourceDraft)
        let leftover = TranslationClauseSegmenter.leftoverTail(
            self.sourceDraft,
            already: self.printedSources,
            languageID: languageID
        )
        // Voice has no in-flight title. Pinning leftover sentences here
        // queued the first clause and hid the live row, so the next line jumped.
        let pinned = SpokenLanguageResolver.isSameLanguagePair()
            ? []
            : TranslationClauseSegmenter.livePreview(leftover, languageID: languageID).pinned
        var lines: [String] = []
        for line in self.inFlightSources + pinned {
            let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            if lines.contains(where: { TranslationClauseSegmenter.isSameClause($0, cleaned) }) {
                continue
            }
            if self.peelSources.contains(where: { TranslationClauseSegmenter.isSameClause($0, cleaned) }) {
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

    /// Live row id minted when the open clause starts. Failure / retry must
    /// not remount the row the audience is reading.
    var liveCaptionID: UInt64 {
        self.resolveLiveRowIdentity()
    }

    private func clearLiveRowIdentity() {
        self.heldLiveSpoken = ""
        self.liveRowIdentity = 0
        self.liveRowClause = ""
    }

    /// The board no longer has a live row. Callers that still ask get the next commit id.
    private func resolveLiveRowIdentity() -> UInt64 {
        self.nextCaptionID
    }

    /// This Listen only. A new Listen can repeat the last greeting.
    private var listenSourceLines: [String] {
        let start = min(max(self.listenBatchStart, 0), self.captionLog.sourceLines.count)
        return Array(self.captionLog.sourceLines.dropFirst(start))
    }

    /// Recent this-Listen clauses. Older than `maxListenHistory` are gone.
    /// Peel only walks the latest lines; the board can still show the rest.
    private var peelSources: [String] {
        let lines = self.listenHistory.isEmpty ? self.listenSourceLines : self.listenHistory.map(\.source)
        return Array(lines.suffix(LiveTranslationTiming.peelWindowLines))
    }

    /// Last-four MT priors from the sliding window, not only the three board rows.
    private var listenContextEntries: [LectureCaptionEntry] {
        if !self.listenHistory.isEmpty { return self.listenHistory }
        let start = min(max(self.listenBatchStart, 0), self.captionLog.entries.count)
        return Array(self.captionLog.entries.dropFirst(start))
    }

    private var printedSources: [String] {
        self.peelSources + self.inFlightSources + self.suppressedSources
    }

    /// Peel this Listen first, including in-flight commits so a restitch cannot
    /// put sentence one back on the live row while Apple Translation is busy.
    /// An empty board leftover means the talk is already on Theater — except a
    /// new Listen repeating a short greeting. A printed lecture line, or a
    /// pause-confirm spelling of that line, stays put.
    private func leftoverSpeech(_ text: String, languageID: String) -> String {
        let listenAlready = self.printedSources
        let boardWindow = Array(self.captionLog.sourceLines.suffix(LiveTranslationTiming.peelWindowLines))
        let listenLeftover = TranslationClauseSegmenter.leftoverTail(
            text,
            already: listenAlready,
            languageID: languageID
        )
        // Same peel-window lines and no in-flight / suppressed extras: one peel
        // already matches what the board pass would return.
        if boardWindow.count == listenAlready.count,
           zip(boardWindow, listenAlready).allSatisfy({ TranslationClauseSegmenter.isSameClause($0, $1) })
        {
            if listenLeftover.isEmpty {
                return self.repeatableGreetingLeftover(listenLeftover, languageID: languageID)
            }
            return self.peelPrintedOrRevisedBoardLines(listenLeftover, languageID: languageID)
        }
        let boardLeftover = TranslationClauseSegmenter.leftoverTail(
            text,
            already: boardWindow,
            languageID: languageID
        )
        let result: String
        if boardLeftover.isEmpty {
            result = self.repeatableGreetingLeftover(listenLeftover, languageID: languageID)
        } else {
            let unread = listenLeftover.count <= boardLeftover.count ? listenLeftover : boardLeftover
            result = self.peelPrintedOrRevisedBoardLines(unread, languageID: languageID)
        }
        return result
    }

    private func repeatableGreetingLeftover(_ listenLeftover: String, languageID: String) -> String {
        guard !listenLeftover.isEmpty, self.listenSourceLines.isEmpty else { return "" }
        guard let last = self.captionLog.sourceLines.last else { return listenLeftover }
        guard TranslationClauseSegmenter.isSameClause(last, listenLeftover) else { return "" }
        guard TranslationClauseSegmenter.isRepeatableGreeting(listenLeftover, languageID: languageID) else {
            return ""
        }
        return listenLeftover
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
            let printed = (self.printedSources + self.captionLog.sourceLines).contains { line in
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
        self.peelSources.dropLast().contains { printed in
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
        let heard = self.latestHypothesis
        self.cancelSettles()
        self.cancelCommitsAndPolish()
        self.prefetchCache.invalidate()
        self.generation += 1
        self.liveSpeechHeld = false
        self.translatedDraftSource = ""
        self.sourceDraft = ""
        self.translatedDraft = ""
        self.committedLines = []
        self.captionLog = LectureCaptionLog()
        self.sessionEntries = []
        self.listenHistory = []
        self.suppressedSources = Self.suppressionUnits(from: heard)
        if clearArchive {
            self.archive.reset()
        }
        self.latencyTracker = LiveTranslationLatencyTracker()
        self.lastLatencySample = LiveTranslationLatencySample()
        self.lastLatencyMilliseconds = nil
        self.listenBatchStart = 0
        self.postedLineCount = 0
        self.lastHeardText = ""
        self.status = .empty
        self.lastFailedSource = nil
        self.didPauseReviseThisUtterance = false
        self.didAutoRetryFailure = false
        self.lastVoicedUptime = nil
        self.clearLiveRowIdentity()
        self.llmEngine.resetListenEchoTally()
    }

    /// Stop settling new speech. Keep captions already committed this session.
    func endListening() {
        self.cancelSettles()
        self.cancelCommitsAndPolish()
        self.prefetchCache.invalidate()
        self.archive.flush()
        self.generation += 1
        self.liveSpeechHeld = false
        self.translatedDraftSource = ""
        self.lastHeardText = ""
        self.sourceDraft = ""
        self.translatedDraft = self.captionLog.translatedLines.last ?? ""
        self.clearLiveRowIdentity()
    }

    /// Start another listen without wiping captions already on Theater.
    func beginListening(preserveSuppressed: Bool = false) {
        self.cancelSettles()
        self.cancelCommitsAndPolish()
        self.prefetchCache.invalidate()
        if !preserveSuppressed {
            self.suppressedSources = []
        }
        self.generation += 1
        self.liveSpeechHeld = false
        self.translatedDraftSource = ""
        self.lastHeardText = ""
        self.sourceDraft = ""
        self.translatedDraft = self.captionLog.translatedLines.last ?? ""
        self.status = .listening()
        self.lastFailedSource = nil
        self.didPauseReviseThisUtterance = false
        self.didAutoRetryFailure = false
        self.lastVoicedUptime = nil
        self.clearLiveRowIdentity()
        self.llmEngine.resetListenEchoTally()
        self.listenBatchStart = self.captionLog.sourceLines.count
        self.listenHistory = []
        self.latencyTracker.resetUtterance()
        self.latencyTracker.markListenStart(ProcessInfo.processInfo.systemUptime)
        self.objectWillChange.send()
    }

    func noteLanguagePairChanged() {
        self.cancelSettles()
        self.cancelCommitsAndPolish()
        self.prefetchCache.invalidate()
        self.generation += 1
        self.liveSpeechHeld = false
        self.translatedDraftSource = ""
        self.lastHeardText = ""
        self.sourceDraft = ""
        self.translatedDraft = self.captionLog.translatedLines.last ?? ""
        self.status = .empty
        self.lastFailedSource = nil
        self.clearLiveRowIdentity()
        self.llmEngine.resetListenEchoTally()
        self.listenBatchStart = self.captionLog.sourceLines.count
        self.listenHistory = []
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
        self.voiceCatchUpTask?.cancel()
        self.voiceCatchUpTask = nil
        self.didPauseReviseThisUtterance = false
        self.lastVoicedUptime = uptime
        self.latencyTracker.markSpeechStart(uptime)
    }

    /// Pause: drop speech that has not been accepted, and keep an already-started
    /// translation running. Resume must not reprint the dropped fragment.
    func holdUnacceptedForPause() {
        self.liveSpeechHeld = true
        self.cancelDelayedSpeechTasks()
        let dropped = self.sourceDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !dropped.isEmpty {
            self.suppressedSources.append(dropped)
        }
        self.sourceDraft = ""
        self.translatedDraft = ""
        self.translatedDraftSource = ""
        self.lastHeardText = ""
        self.loneCompleteCandidate = ""
        self.heldLiveSpoken = ""
    }

    func releasePauseHold() {
        self.liveSpeechHeld = false
    }

    func awaitAcceptedCommits() async {
        if let chain = self.commitChain {
            await chain.value
        }
    }

    func dropUnacceptedSpeech() {
        self.cancelDelayedSpeechTasks()
        self.sourceDraft = ""
        self.translatedDraft = ""
        self.translatedDraftSource = ""
        self.lastHeardText = ""
        self.loneCompleteCandidate = ""
        self.heldLiveSpoken = ""
    }

    func noteSilenceHold() {
        guard !self.liveSpeechHeld else { return }
        if self.eouHoldTask != nil { return }
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
        guard !self.liveSpeechHeld else { return }
        // A natural pause. Hold so the last ASR tick can land, then commit a
        // real leftover clause. Thin leftovers stay open.
        let token = self.generation
        self.pauseRevisionTask?.cancel()
        self.pauseRevisionTask = nil
        self.didPauseReviseThisUtterance = true
        self.tailSettleTask?.cancel()
        self.eouHoldTask?.cancel()
        self.voiceCatchUpTask?.cancel()
        self.tailSettleTask = nil
        self.voiceCatchUpTask = nil
        self.eouHoldTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: LiveTranslationTiming.eouHoldNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.flushSettled(generation: token, isFinal: false, reason: .pauseConfirm)
            // Voice catch-up owns extra finished sentences. The long
            // open-tail clock is only for a leftover fragment.
            if self?.voiceCatchUpTask == nil {
                self?.scheduleOpenTailSettle(generation: token)
            }
        }
    }

    func waitForIdleForTesting() async {
        // Voice catch-up can chain another flush after this one lands.
        for _ in 0..<16 {
            await self.eouHoldTask?.value
            await self.pauseRevisionTask?.value
            await self.voiceCatchUpTask?.value
            await self.tailSettleTask?.value
            await self.prefetchTask?.value
            if self.eouHoldTask == nil,
               self.pauseRevisionTask == nil,
               self.voiceCatchUpTask == nil,
               self.tailSettleTask == nil
            {
                break
            }
        }
        await self.prefetchTask?.value
        let translations = Array(self.inFlightTranslations.values)
        for task in translations {
            _ = await task.value
        }
        await self.commitChain?.value
    }

    func reportFailure(_ message: String) {
        self.reportStatus(message, kind: .failure)
    }

    func reportStatus(_ message: String, kind: TheaterStatusKind) {
        let next = TheaterStatus(text: message, kind: kind)
        guard next != self.status else { return }
        self.status = next
        self.objectWillChange.send()
    }

    func retryFailedTranslation() {
        guard let source = self.lastFailedSource else { return }
        self.lastFailedSource = nil
        self.status = .empty
        self.enqueueCommit(source)
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
        self.listenHistory = []
        self.suppressedSources = []
        self.postedLineCount = self.committedLines.count
        self.translatedDraftSource = ""
        self.sourceDraft = ""
        self.translatedDraft = self.captionLog.translatedLines.last ?? ""
        self.status = .empty
        self.lastFailedSource = nil
        self.lastHeardText = ""
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
        self.forgetListenEntry(removed)
        let source = removed.source.trimmingCharacters(in: .whitespacesAndNewlines)
        if !source.isEmpty {
            self.suppressedSources.append(source)
        }
        self.committedLines = self.captionLog.translatedLines
        self.listenBatchStart = min(self.listenBatchStart, self.committedLines.count)
        self.postedLineCount = min(self.postedLineCount, self.committedLines.count)
        self.translatedDraftSource = ""
        self.sourceDraft = ""
        self.translatedDraft = self.captionLog.translatedLines.last ?? ""
        self.objectWillChange.send()
    }

    func applyEditedLines(_ lines: [String]) {
        let boardBefore = Set(self.captionLog.entries.map(\.id))
        let overflow = self.captionLog.replaceTranslatedLines(lines)
        self.recordSessionEntries()
        self.applyEditsToListenHistory(removedFrom: boardBefore, edited: self.captionLog.entries + overflow)
        let kept = Set(self.captionLog.entries.map(\.id))
        self.sessionEntries.removeAll { boardBefore.contains($0.id) && !kept.contains($0.id) }
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
            self.recordSessionEntries()
            if let entry = self.captionLog.entries.first(where: { $0.id == committed.id }) {
                self.rememberListenEntry(entry)
            }
            self.archiveOverflow(committed.overflow)
            self.adjustIndexes(trimmedCount: committed.overflow.count)
        }
        self.committedLines = self.captionLog.translatedLines
        self.sourceDraft = source
        self.translatedDraft = translated
        self.translatedDraftSource = source
        // A printed line is not on the live row. Seeding it here would make the
        // monotonic guard hold this clause and swallow the next one.
        self.heldLiveSpoken = ""
    }

    func handlePartial(_ text: String) {
        guard !self.liveSpeechHeld else { return }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let previous = self.latestHypothesis
        let confirmed = StreamingTranscriptStitcher.confirmedPrefix(
            previous: previous,
            incoming: cleaned
        )
        self.latestHypothesis = cleaned
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
            self.eouHoldTask?.cancel()
            self.eouHoldTask = nil
            self.voiceCatchUpTask?.cancel()
            self.voiceCatchUpTask = nil
        }
        let display = StreamingTranscriptStitcher.monotonicTarget(
            printed: self.heldLiveSpoken,
            incoming: leftover
        )
        self.sourceDraft = display
        if self.status.kind != .failure, self.status != .listening() {
            self.status = .listening()
        }
        self.commitCompletedSentencesWhileTalking(
            remaining: leftover,
            confirmed: confirmed,
            heldOpen: display,
            languageID: languageID
        )
        self.schedulePrefetchIfNeeded(
            leftover: self.sourceDraft,
            languageID: languageID,
            generation: self.generation
        )
        // Apple Speech can take longer than a silence tick. If the room is
        // already quiet when this leftover lands, start the pause flush here
        // so the caption does not wait for the next utterance.
        if self.isPastVoicedSilenceHold() {
            self.noteSilenceHold()
        }
    }

    /// Pair each finished sentence as soon as more speech follows it.
    /// A lone finished sentence prints once two recognition updates agree on
    /// it, so a late restitch of its last words cannot print a wrong line.
    /// After a pause peels finished sentences here too: a finished sentence is
    /// already a whole sentence, so holding it only adds latency. That mode
    /// holds the open fragment instead, and the pause commits it as one unit.
    /// Mid-talk, a finished sentence is accepted only when confirmed speech
    /// already follows it. A lone period is not enough: Apple Speech ends
    /// partials with "." and then rewrites them. Pause and Stop accept the
    /// open clause. Voice and Translate both enqueue every accepted sentence
    /// in this tick.
    private func commitCompletedSentencesWhileTalking(
        remaining initial: String,
        confirmed: String,
        heldOpen: String,
        languageID: String
    ) {
        var remaining = TranslationClauseSegmenter.leftoverTail(
            initial,
            already: self.printedSources,
            languageID: languageID
        )
        var commitHorizon = self.leftoverSpeech(confirmed, languageID: languageID)
        let isVoice = SpokenLanguageResolver.isSameLanguagePair()
        var steps = 0
        var didCommit = false
        while steps < 32, !remaining.isEmpty {
            steps += 1
            if let next = TranslationClauseSegmenter.nextCompletedSentence(
                remaining,
                languageID: languageID
            ) {
                if self.shouldSkipSettledUnit(next.unit) {
                    remaining = self.remainderAfterSkippedUnit(
                        next.unit,
                        rest: next.rest,
                        languageID: languageID
                    )
                    continue
                }
                guard StreamingTranscriptStitcher.confirmedClauseContains(
                    unit: next.unit,
                    confirmed: commitHorizon
                ) else { break }
                self.enqueueCommit(next.unit)
                remaining = next.rest
                // Peel only the unit just accepted. Re-running leftoverSpeech on
                // the full confirmed talk once per commit was the long-talk cost.
                commitHorizon = TranslationClauseSegmenter.leftoverTail(
                    commitHorizon,
                    already: [next.unit],
                    languageID: languageID
                )
                didCommit = true
                continue
            }
            guard isVoice, let cut = self.voiceFollowAlongCut(remaining, languageID: languageID) else {
                break
            }
            if self.shouldSkipSettledUnit(cut.unit) {
                remaining = self.remainderAfterSkippedUnit(cut.unit, rest: cut.rest, languageID: languageID)
                continue
            }
            self.enqueueCommit(cut.unit)
            remaining = cut.rest
            didCommit = true
            break
        }
        if didCommit {
            self.sourceDraft = remaining
        } else {
            self.sourceDraft = StreamingTranscriptStitcher.monotonicTarget(
                printed: heldOpen,
                incoming: remaining
            )
        }
        self.heldLiveSpoken = self.sourceDraft
        self.lastHeardText = self.sourceDraft
    }

    /// Voice mid-talk backstop for a run-on that never finds a period.
    /// Comma / and / but cuts were jumping to the next line mid-thought.
    /// A finished sentence plus more speech still peels via
    /// `nextCompletedSentence`. Pause / Stop flush leftover.
    private func voiceFollowAlongCut(_ text: String, languageID: String) -> (unit: String, rest: String)? {
        // Apple Speech marks an unfinished partial with "…". That is not a
        // sentence end, and it would make the whole run-on one finished unit.
        var remaining = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while remaining.hasSuffix("...") || remaining.hasSuffix("…") {
            remaining = remaining.hasSuffix("...") ? String(remaining.dropLast(3)) : String(remaining.dropLast())
            remaining = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard TranslationClauseSegmenter.shouldFollowAlong(remaining, languageID: languageID) else { return nil }
        guard let cut = TranslationClauseSegmenter.nextCommitUnit(
            remaining,
            languageID: languageID,
            allowPauseFinalize: false
        ) else { return nil }
        let unit = cut.unit.trimmingCharacters(in: .whitespacesAndNewlines)
        let rest = cut.rest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !unit.isEmpty, !rest.isEmpty else { return nil }
        // A 24-word comma cut still jumped mid-thought ("a day," / "and").
        // Hold until the leftover is a true run-on dump, or a period peels it.
        guard remaining.count >= LiveTranslationTiming.maxDraftCharacters else { return nil }
        if TranslationClauseSegmenter.isCompactScript(languageID) {
            guard rest.count >= 8 else { return nil }
            return (unit, rest)
        }
        func words(_ text: String) -> [String] {
            text.split(whereSeparator: \.isWhitespace).map(String.init)
        }
        guard words(rest).count >= Self.voiceFollowAlongSettleWords else { return nil }
        return (unit, rest)
    }

    private static let voiceFollowAlongSettleWords = 4

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
            guard token == self.generation else { return }
            let cleanedConfirm = confirmed.trimmingCharacters(in: .whitespacesAndNewlines)
            if LiveTranslationCommitContext.shouldPreferConfirmation(
                cleanedConfirm,
                over: self.lastHeardText,
                already: self.printedSources
            ) {
                cleaned = cleanedConfirm
                self.latestHypothesis = cleanedConfirm
            }
        }
        guard token == self.generation else { return }

        let remaining = self.rememberUnreadSpeech(cleaned, languageID: languageID)
        self.commitNextSettledUnit(
            remaining: remaining,
            languageID: languageID,
            allowPauseFinalize: reason == .openTailAged || reason == .pauseConfirm || reason == .stop,
            forceOpenTail: forceOpenTail,
            generation: token
        )
    }

    /// Drop the committed unit from leftover by range. Do not wipe the rest
    /// of the draft when peel cannot find a prefix.
    static func remainingAfterCommittedUnit(_ unit: String, in remaining: String) -> String {
        let unit = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        let remaining = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !unit.isEmpty, !remaining.isEmpty else { return remaining }
        if remaining.hasPrefix(unit) {
            return remaining.dropFirst(unit.count).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return remaining
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
            }
            let unit: String
            var rest: String
            if let next {
                unit = next.unit
                rest = next.rest
                if rest == remaining {
                    rest = Self.remainingAfterCommittedUnit(unit, in: remaining)
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
                return
            }

            if rest == remaining { break }
            if self.shouldSkipSettledUnit(unit) {
                remaining = self.remainderAfterSkippedUnit(unit, rest: rest, languageID: languageID)
                continue
            }

            self.enqueueCommit(unit)
            remaining = rest
        }

        if !remaining.isEmpty, self.inFlightSources.isEmpty {
            self.sourceDraft = remaining
            self.lastHeardText = remaining
        }
    }

    /// A skipped unit may still contain speech after the clause already on the board.
    private func remainderAfterSkippedUnit(_ unit: String, rest: String, languageID: String) -> String {
        let suffix = TranslationClauseSegmenter.leftoverTail(
            unit,
            already: self.printedSources,
            languageID: languageID
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let rest = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if suffix.isEmpty || suffix == unit {
            return rest
        }
        if rest.isEmpty || rest.hasPrefix(suffix) { return rest.isEmpty ? suffix : rest }
        return (suffix + " " + rest).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func shouldSkipSettledUnit(_ unit: String) -> Bool {
        if self.inFlightSources.contains(where: { TranslationClauseSegmenter.isSameClause($0, unit) }) {
            return true
        }
        let languageID = SpokenLanguageResolver.listenLanguageID(for: unit)
        if self.revisesEarlierPrintedLine(unit, languageID: languageID) {
            return true
        }
        if let last = self.peelSources.last {
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
        if self.peelSources.contains(where: {
            TranslationClauseSegmenter.isSameClause($0, unit)
        }) {
            return !self.mayReplaceLastCommitted(with: unit)
        }
        return false
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

    func translateFinal(_ text: String, drainRemainder: Bool = true) async -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty {
            self.latestHypothesis = cleaned
            let incomingLanguage = SpokenLanguageResolver.listenLanguageID(for: cleaned)
            _ = self.rememberUnreadSpeech(cleaned, languageID: incomingLanguage)
        }

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
        ) {
            await self.commitUnit(unit, generation: token)
            let next = self.leftoverSpeech(remaining, languageID: languageID)
            if next == remaining { break }
            remaining = next
        }
        if drainRemainder, !remaining.isEmpty {
            let unit: String
            if remaining.count >= LiveTranslationTiming.maxDraftCharacters {
                unit = String(remaining.prefix(LiveTranslationTiming.maxDraftCharacters))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                unit = remaining
            }
            if !unit.isEmpty {
                await self.commitUnit(unit, generation: token)
            }
        }

        self.sourceDraft = ""
        self.translatedDraft = self.captionLog.translatedLines.last ?? ""
        self.translatedDraftSource = self.captionLog.sourceLines.last ?? ""
        return self.pendingInsertDocument()
    }

    private func enqueueCommit(_ source: String, generation: UInt64? = nil) {
        let cleaned = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let languageID = SpokenLanguageResolver.listenLanguageID(for: cleaned)
        if CaptionJunkGate.shouldDrop(cleaned) { return }
        let replaceLast = self.mayReplaceLastCommitted(with: cleaned)
        if TranslationClauseSegmenter.isTooThinToCommit(
            cleaned,
            languageID: languageID
        ) {
            return
        }
        if self.inFlightSources.contains(where: { TranslationClauseSegmenter.isSameClause($0, cleaned) }) {
            return
        }
        if let last = self.peelSources.last,
           TranslationClauseSegmenter.isSameClause(last, cleaned),
           !TranslationClauseSegmenter.shouldReplaceLast(previous: last, incoming: cleaned)
        {
            return
        }
        let token = generation ?? self.generation
        if SpokenLanguageResolver.isSameLanguagePair() {
            self.commitVoiceCaption(cleaned, replaceLast: replaceLast, generation: token)
            return
        }
        let previous = self.commitChain
        self.inFlightSources.append(cleaned)
        self.inFlightStartedAt[cleaned] = Date()
        self.status = .info("Translating…")
        if self.cachedCommitTranslation(for: cleaned) == nil {
            let allowLocal = self.inFlightSources.count <= 1
            self.inFlightTranslations[cleaned] = self.startCommitTranslation(
                cleaned,
                generation: token,
                allowLocal: allowLocal
            )
        }
        self.commitChain = Task { [weak self] in
            await previous?.value
            await self?.commitUnit(cleaned, generation: token)
        }
    }

    /// Start Apple Translation now. The board still prints in order.
    private func startCommitTranslation(
        _ cleaned: String,
        generation: UInt64,
        allowLocal: Bool
    ) -> Task<Result<String, Error>, Never> {
        Task { [weak self] in
            guard let self else { return .failure(CancellationError()) }
            guard self.generation == generation else { return .failure(CancellationError()) }
            do {
                let translated = try await self.performTranslation(
                    cleaned,
                    kind: .commit,
                    allowLocal: allowLocal
                )
                return .success(translated)
            } catch {
                return .failure(error)
            }
        }
    }

    /// Voice has no translation wait. Append the accepted sentence. A later
    /// restitch does not rewrite a line already on the board.
    private func commitVoiceCaption(_ cleaned: String, replaceLast _: Bool, generation: UInt64) {
        guard generation == self.generation else { return }
        if self.shouldSkipSettledUnit(cleaned) { return }
        guard let committed = self.captionLog.commit(
            source: cleaned,
            translated: cleaned,
            mayReviseLast: false
        ) else { return }
        self.finishPublishedCaption(
            source: cleaned,
            translated: cleaned,
            committed: committed,
            generation: generation
        )
    }

    private func finishPublishedCaption(
        source: String,
        translated: String,
        committed: (id: UInt64, overflow: [LectureCaptionEntry]),
        generation: UInt64
    ) {
        self.recordSessionEntries()
        if let entry = self.captionLog.entries.first(where: { $0.id == committed.id }) {
            self.rememberListenEntry(entry)
        }
        self.archiveOverflow(committed.overflow)
        self.adjustIndexes(trimmedCount: committed.overflow.count)
        self.committedLines = self.captionLog.translatedLines
        if !self.committedLines.isEmpty, !SettingsStore.shared.theaterListenUsed {
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
        // The row that just printed is no longer the live row. Without this the
        // monotonic guard compares the next clause against the printed one,
        // keeps the printed text, and the next sentence never appears.
        self.heldLiveSpoken = leftover
        self.status = leftover.isEmpty ? .empty : .listening()
        if leftover.isEmpty {
            self.translatedDraft = translated
            self.translatedDraftSource = source
        } else if TranslationClauseSegmenter.isSameClause(leftover, source) {
            self.sourceDraft = ""
            self.translatedDraft = translated
            self.translatedDraftSource = source
            self.status = .empty
        } else {
            if TranslationClauseSegmenter.isSameClause(self.translatedDraftSource, source)
                || !TranslationClauseSegmenter.isGrowingClause(self.translatedDraftSource, toward: leftover)
            {
                let current = self.translatedDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                // Prefix growth stays on the live row. Do not relabel that
                // caption as the translation of a longer leftover.
                if let cached = self.cachedCommitTranslation(for: leftover),
                   current.isEmpty || Self.prefixCompatible(current, next: cached)
                {
                    self.translatedDraft = cached
                    self.translatedDraftSource = leftover
                } else if current.isEmpty {
                    self.translatedDraft = ""
                    self.translatedDraftSource = ""
                }
            }
            if !SpokenLanguageResolver.isSameLanguagePair() {
                self.schedulePrefetchIfNeeded(
                    leftover: leftover,
                    languageID: SpokenLanguageResolver.listenLanguageID(for: leftover),
                    generation: generation
                )
            }
        }
    }

    private func commitUnit(_ source: String, generation: UInt64) async {
        let incoming = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = incoming
        defer {
            if generation == self.generation {
                self.inFlightSources.removeAll { $0 == incoming || $0 == cleaned }
                self.inFlightStartedAt[incoming] = nil
                self.inFlightStartedAt[cleaned] = nil
            }
            self.inFlightTranslations[incoming]?.cancel()
            self.inFlightTranslations[cleaned]?.cancel()
            self.inFlightTranslations[incoming] = nil
            self.inFlightTranslations[cleaned] = nil
        }
        guard generation == self.generation else { return }
        guard !cleaned.isEmpty else { return }
        if SpokenLanguageResolver.isSameLanguagePair() {
            self.commitVoiceCaption(cleaned, replaceLast: false, generation: generation)
            return
        }
        let languageID = SpokenLanguageResolver.listenLanguageID(for: cleaned)
        if TranslationClauseSegmenter.isTooThinToCommit(
            cleaned,
            languageID: languageID
        ) {
            return
        }
        if self.revisesEarlierPrintedLine(cleaned, languageID: languageID) { return }

        do {
            let resolved = try await self.resolvedCommitTranslation(cleaned, generation: generation)
            guard generation == self.generation else { return }

            guard let committed = self.captionLog.commit(
                source: cleaned,
                translated: resolved,
                mayReviseLast: false
            ) else { return }
            self.finishPublishedCaption(
                source: cleaned,
                translated: resolved,
                committed: committed,
                generation: generation
            )
        } catch {
            guard generation == self.generation else { return }
            if error is CancellationError { return }
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

    private func resolvedCommitTranslation(_ cleaned: String, generation: UInt64) async throws -> String {
        if SpokenLanguageResolver.isSameLanguagePair() {
            return cleaned
        }
        if let cached = self.cachedCommitTranslation(for: cleaned) {
            self.inFlightTranslations.removeValue(forKey: cleaned)?.cancel()
            let sharpened = await self.sharpenCachedCaption(cleaned, draft: cached)
            guard generation == self.generation else { throw CancellationError() }
            return sharpened
        }
        if let task = self.inFlightTranslations.removeValue(forKey: cleaned) {
            let translated = try await task.value.get()
            guard generation == self.generation else { throw CancellationError() }
            guard let safe = LLMTranslationEngine.captionSafeForBoard(translated, sourceText: cleaned)
            else {
                throw TranslationEngineError.localRejected
            }
            return safe
        }
        self.status = .info("Translating…")
        let translated = try await self.performTranslation(cleaned, kind: .commit)
        guard generation == self.generation else { throw CancellationError() }
        guard let safe = LLMTranslationEngine.captionSafeForBoard(translated, sourceText: cleaned)
        else {
            throw TranslationEngineError.localRejected
        }
        return safe
    }

    /// A word-by-word live caption is translated with no prior clauses. A
    /// printed line still earns the 4-prior window, so a commit does not
    /// reuse that cache. A clause-boundary prefetch is reused only when it
    /// is this same clause. A longer leftover, and the next sentence, go
    /// back to Apple Translation.
    private func cachedCommitTranslation(for source: String) -> String? {
        let cleaned = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        if let draft = self.sameClauseDraft(cleaned) {
            return draft
        }
        return self.exactPrefetchCaption(for: cleaned)
    }

    private func sameClauseDraft(_ source: String) -> String? {
        let cached = self.translatedDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cached.isEmpty,
              TranslationClauseSegmenter.isSameClause(self.translatedDraftSource, source)
        else { return nil }
        return cached
    }

    private func exactPrefetchCaption(for source: String) -> String? {
        let settings = SettingsStore.shared
        let pair = SpokenLanguageResolver.pairForSpokenText(source, settings: settings)
        let context = self.livePrefetchContext(incoming: source)
        let key = LiveTranslationPrefetch.cacheKey(
            unit: source,
            priorSources: context.prior.sources,
            priorIDs: context.priorIDs,
            sourceID: pair.source.id,
            targetID: pair.target.id
        )
        return self.prefetchCache.exactCaption(for: key)
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
        let context = self.livePrefetchContext(incoming: cleaned)
        let key = LiveTranslationPrefetch.cacheKey(
            unit: cleaned,
            priorSources: context.prior.sources,
            priorIDs: context.priorIDs,
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
        let current = self.translatedDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard current.isEmpty || Self.prefixCompatible(current, next: caption) else {
            return
        }
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
        self.dropStaleLiveDraftIfNewClause(leftover)
        let unit = LiveTranslationPrefetch.unitToPrefetch(
            leftover: leftover,
            languageID: languageID,
            wordByWord: false
        )
        guard !SpokenLanguageResolver.isSameLanguagePair() else { return }
        if self.translator === self.appleEngine {
            guard self.appleEngine.isMailboxReady else { return }
        }
        guard let unit else { return }
        guard LiveTranslationPrefetch.canPrefetch(
            unit: unit,
            inFlightSources: self.inFlightSources
        ) else { return }
        // One in-flight commit is fine: live waits behind it. A pile of
        // finished sentences would make this leftover stale.
        guard self.inFlightSources.count <= 1 else { return }
        let settings = SettingsStore.shared
        let pair = SpokenLanguageResolver.pairForSpokenText(unit, settings: settings)
        let source = pair.source
        let target = pair.target
        let context = self.livePrefetchContext(incoming: unit)
        let prior = context.prior
        let key = LiveTranslationPrefetch.cacheKey(
            unit: unit,
            priorSources: prior.sources,
            priorIDs: context.priorIDs,
            sourceID: source.id,
            targetID: target.id
        )
        guard let token = self.prefetchCache.begin(key) else { return }
        self.prefetchTask = Task { [weak self] in
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
                translator: self.translator,
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
        excludingNewestLine: Bool = false,
        allowLocal: Bool = true
    ) async throws -> String {
        let kind = kind == .commit && self.listenHistory.isEmpty ? .firstCommit : kind
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
            prior: prior,
            allowLocal: allowLocal
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
        prior: (sources: [String], translations: [String]),
        allowLocal: Bool = true
    ) async throws -> String {
        let timeout = self.listenHistory.isEmpty
            ? LiveTranslationTiming.translateClauseTimeoutNanoseconds
            : LiveTranslationTiming.commitMailboxTimeoutNanoseconds
        let apple = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await LiveTranslationMT.appleClause(
                    text,
                    source: source,
                    target: target,
                    terms: terms,
                    kind: kind,
                    prior: prior,
                    translator: self.translator
                )
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeout)
                throw LiveTranslationMTError.timedOut
            }
            defer { group.cancelAll() }
            let result = try await group.next()!
            return result
        }
        if allowLocal, let sharpened = await LiveTranslationMT.localFirstPrint(
            text,
            draft: apple,
            prior: prior,
            source: source,
            target: target,
            terms: terms,
            llmEngine: self.llmEngine
        ) {
            return sharpened
        }
        return apple
    }

    /// First clause of a Listen uses the 25 s cold floor. Later clauses use 7 s.
    var translateTimeoutNsForTesting: UInt64 {
        self.listenHistory.isEmpty
            ? LiveTranslationTiming.translateClauseTimeoutNanoseconds
            : LiveTranslationTiming.commitMailboxTimeoutNanoseconds
    }

    func priorClausesForTesting(incoming: String) -> (sources: [String], translations: [String]) {
        self.priorClausesForContextualTranslation(incoming: incoming)
    }

    var listenHistoryCountForTesting: Int { self.listenHistory.count }

    /// Every line this session printed, including lines the 3-line board
    /// already archived.
    var sessionSourceLinesForTesting: [String] { self.sessionEntries.map(\.source) }

    private func priorClausesForContextualTranslation(
        incoming: String,
        excludingNewestLine: Bool = false
    ) -> (sources: [String], translations: [String]) {
        // Fixing the newest line in place: its old text is not context.
        let context = excludingNewestLine
            ? Array(self.listenContextEntries.dropLast())
            : self.listenContextEntries
        let prior = Self.priorClauses(
            entries: context,
            listenBatchStart: 0,
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
        self.tailSettleTask?.cancel()
        self.eouHoldTask?.cancel()
        self.pauseRevisionTask?.cancel()
        self.voiceCatchUpTask?.cancel()
        self.failedRetryTask?.cancel()
        self.tailSettleTask = nil
        self.eouHoldTask = nil
        self.pauseRevisionTask = nil
        self.voiceCatchUpTask = nil
        self.failedRetryTask = nil
    }

    private func shouldCancelPauseRevision(leftover: String) -> Bool {
        let leftover = leftover.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !leftover.isEmpty else { return false }
        let previous = self.sourceDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if TranslationClauseSegmenter.isSameClause(previous, leftover) { return false }
        if TranslationClauseSegmenter.shouldIgnoreAsStalePrefix(
            previous: previous,
            incoming: leftover
        ) {
            return false
        }
        // EOU / silence holds so this last tick can land. Growing the same
        // leftover must not drop the flush, or the line waits until the
        // next utterance.
        if TranslationClauseSegmenter.isGrowingClause(previous, toward: leftover)
            || TranslationClauseSegmenter.isGrowingClause(leftover, toward: previous)
        {
            return false
        }
        return true
    }

    private func isPastVoicedSilenceHold() -> Bool {
        guard let lastVoicedUptime else { return false }
        return LiveTranslationSilenceGate.isPastHold(
            lastVoicedUptime: lastVoicedUptime,
            now: ProcessInfo.processInfo.systemUptime
        )
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
        if self.voiceCatchUpTask == nil {
            self.scheduleOpenTailSettle(generation: generation)
        }
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

    private func cancelDelayedSpeechTasks() {
        self.eouHoldTask?.cancel()
        self.eouHoldTask = nil
        self.pauseRevisionTask?.cancel()
        self.pauseRevisionTask = nil
        self.voiceCatchUpTask?.cancel()
        self.voiceCatchUpTask = nil
        self.tailSettleTask?.cancel()
        self.tailSettleTask = nil
    }

    private func cancelCommitsAndPolish() {
        self.commitChain?.cancel()
        self.commitChain = nil
        for task in self.inFlightTranslations.values {
            task.cancel()
        }
        self.inFlightTranslations = [:]
        self.inFlightSources = []
        self.inFlightStartedAt = [:]
        self.prefetchTask?.cancel()
        self.prefetchTask = nil
        self.prefetchCache.invalidate()
        self.appleEngine.cancelQueuedTranslations()
    }

    private static func prefixCompatible(_ shown: String, next: String) -> Bool {
        if next.isEmpty { return shown.isEmpty }
        return next.hasPrefix(shown) || shown.hasPrefix(next)
    }

    private func livePrefetchContext(incoming: String) -> (
        prior: (sources: [String], translations: [String]),
        priorIDs: [UInt64]
    ) {
        (
            self.priorClausesForContextualTranslation(incoming: incoming),
            self.priorIDsForPrefetch(incoming: incoming)
        )
    }

    /// The leftover moved to another sentence. Drop the previous Show-as
    /// instead of pairing the new source with that caption: a commit reads
    /// the pair as a cache hit and prints the previous line twice.
    private func dropStaleLiveDraftIfNewClause(_ leftover: String) {
        let source = self.translatedDraftSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return }
        let incoming = leftover.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !incoming.isEmpty else { return }
        if self.liveDraftStillMatches(source, leftover: incoming) { return }
        self.suppressLiveTranslationDraft()
    }

    private func liveDraftStillMatches(_ source: String, leftover: String) -> Bool {
        if TranslationClauseSegmenter.isSameClause(source, leftover) { return true }
        if TranslationClauseSegmenter.isGrowingClause(source, toward: leftover) { return true }
        if TranslationClauseSegmenter.isGrowingClause(leftover, toward: source) { return true }
        let languageID = SpokenLanguageResolver.listenLanguageID(for: leftover)
        return TranslationClauseSegmenter.isLivePrefetchMatch(
            unit: source,
            leftover: leftover,
            languageID: languageID
        )
    }

    private func suppressLiveTranslationDraft() {
        guard !self.translatedDraft.isEmpty || !self.translatedDraftSource.isEmpty else { return }
        self.translatedDraft = ""
        self.translatedDraftSource = ""
        self.prefetchCache.invalidate()
    }

    private func priorIDsForPrefetch(incoming: String) -> [UInt64] {
        let prior = self.priorClausesForContextualTranslation(incoming: incoming)
        let sources = Set(prior.sources.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        return self.listenContextEntries.compactMap { entry in
            sources.contains(entry.source.trimmingCharacters(in: .whitespacesAndNewlines))
                ? entry.id
                : nil
        }
    }

    private static func suppressionUnits(from text: String) -> [String] {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }
        let languageID = SpokenLanguageResolver.listenLanguageID(for: cleaned)
        let split = TranslationClauseSegmenter.split(cleaned, languageID: languageID)
        var units = split.completed
        let tail = split.tail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { units.append(tail) }
        units.append(cleaned)
        return units
    }

    private func adjustIndexes(trimmedCount: Int) {
        guard trimmedCount > 0 else { return }
        self.listenBatchStart = max(0, self.listenBatchStart - trimmedCount)
        self.postedLineCount = max(0, self.postedLineCount - trimmedCount)
    }
}
