import Combine
import Darwin
import Foundation

// swiftlint:disable function_body_length cyclomatic_complexity type_body_length
private struct PendingCaptionGrowth: Equatable {
    var id: UInt64
    var source: String
}

// Session owner. Heard speech becomes a board row only through `advance`.
// A partial uses the two-update rule. Pause, an open tail, and Stop confirm,
// then commit the leftover. `enqueueCommit` is the only new-row publisher.
// LectureCaptionLog.commit peels a leftover after the newest line once.

@MainActor
final class LiveTranslationSubscriber: ObservableObject {
    /// Unread speech. Not published: the board only changes when a line lands.
    private(set) var sourceDraft: String = ""
    private(set) var translatedDraft: String = ""
    @Published private(set) var boardState = TheaterBoardState()
    var committedLines: [String] { self.boardState.translatedLines }
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
    /// Latest full recognition text, used to spot a restitched newest line.
    private var latestHypothesis = ""
    private var tailSettleTask: Task<Void, Never>?
    private var eouHoldTask: Task<Void, Never>?
    private var pauseRevisionTask: Task<Void, Never>?
    /// `commitOrder` indexes whose translation failed after the one automatic
    /// retry. The publish walker steps over these so a later sentence can print.
    private var skippedCommitIndexes: Set<Int> = []
    /// Voice only. Prints the next leftover sentence after a pause flush so
    /// a lagged restitch does not land every finished line in one tick.
    private var voiceCatchUpTask: Task<Void, Never>?
    private var failedRetryTask: Task<Void, Never>?
    /// Retranslation for a painted row after in-place growth.
    /// Cancelled by the next growth tick so a slower, stale translation for
    /// an earlier (shorter) candidate cannot land after a later growth was chosen.
    private var newestGrowthTask: Task<Void, Never>?
    /// Grown source for peel only. The caption log keeps the previous pair
    /// until this source and its translation publish together.
    private var pendingGrowth: PendingCaptionGrowth?
    private var didPauseReviseThisUtterance = false
    /// Last voiced packet. A late ASR tick after this goes quiet must still
    /// flush leftover — skipped silence ticks can miss while a chunk is busy.
    private var lastVoicedUptime: TimeInterval?
    private var didAutoRetryFailure = false
    private var commitTasks: [Task<Void, Never>] = []
    /// Spoken order for this Listen. Publishing walks forward from
    /// `nextCommitToPublish` so a long talk does not re-check every earlier line.
    private var commitOrder: [String] = []
    private var nextCommitToPublish = 0
    private var commitIdentities: Set<String> = []
    private var readyTranslations: [String: String] = [:]
    private var publishedCommits: [String] = []
    /// Insert Stop may admit one fragment the clause cutter refused.
    private var trailingFragmentKeys: Set<String> = []
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
    /// Last leftover held for the next clause. The board does not paint it.
    private var heldLiveSpoken: String = ""
    /// Pause freezes unaccepted speech. Accepted translations already in flight may still land.
    private var liveSpeechHeld = false
    var confirmTranscript: (() async -> String)?
    var canRetryTranslation: Bool { self.lastFailedSource != nil }

    var sessionLineCount: Int { self.captionLog.entries.count }

    var committedSourceLines: [String] { self.captionLog.sourceLines }
    var committedLineIDs: [UInt64] { self.captionLog.lineIDs }
    var nextCaptionID: UInt64 { self.captionLog.nextID }
    /// Whole talk for history and export. The board log keeps the latest
    /// 48 lines, so a long listen would otherwise save only that window.
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

    func flushArchive() {
        self.archive.flush()
    }

    /// Live Show-as for the Insert notch. The Theater board does not draw this.
    var liveCaptionText: String {
        let last = self.committedLines.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let draft = self.resolvedLiveCaptionDraft()
        if draft.isEmpty || draft == last {
            return ""
        }
        return self.freshCaption(
            draft,
            lastText: last,
            printedSources: self.committedLines
        )
    }

    /// Next notch title. A restitch of sentence one plus two must not fall
    /// back to the whole blob after peel. The board does not use this.
    private func freshCaption(
        _ text: String,
        lastText: String,
        printedSources: [String]
    ) -> String {
        let leftover = self.unreadCaption(
            text,
            lastText: lastText,
            printedSources: printedSources
        )
        if !leftover.isEmpty { return leftover }
        if Self.isSameCaption(text, lastText) { return "" }
        if !lastText.isEmpty {
            let peeled = TranslationClauseSegmenter.leftoverTail(text, already: printedSources)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if peeled != text { return "" }
        }
        return text
    }

    private func unreadCaption(
        _ text: String,
        lastText: String,
        printedSources: [String]
    ) -> String {
        let languageID = SpokenLanguageResolver.listenLanguageID(for: text)
        let leftover = TranslationClauseSegmenter.leftoverTail(
            text,
            already: printedSources,
            languageID: languageID
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        if leftover.isEmpty { return "" }
        if Self.isSameCaption(leftover, lastText) { return "" }
        return leftover
    }

    private static func isSameCaption(_ left: String, _ right: String) -> Bool {
        let a = left.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = right.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty || b.isEmpty { return false }
        if a == b { return true }
        return TranslationClauseSegmenter.isSameClause(a, b)
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
        switch self.admissionDecision(open, phase: .propose) {
        case .admit:
            return open
        case .skip(let reason):
            // A thin starter is still the open clause. It is not a board row.
            if reason == .tooThin { return open }
            return nil
        }
    }

    /// Finished sentences waiting on translation. Test diagnostics. The board
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

    /// In-flight commits. The board does not draw them; the pace cue reads the wait.
    var inFlightCaptionCount: Int {
        self.inFlightSources.count
    }

    /// This Listen only. A new Listen can repeat the last greeting.
    private var listenSourceLines: [String] {
        let start = min(max(self.listenBatchStart, 0), self.captionLog.sourceLines.count)
        return Array(self.captionLog.sourceLines.dropFirst(start))
    }

    /// Recent this-Listen clauses. Older than `maxListenHistory` are gone.
    /// Peel only walks the latest lines; the board can still show the rest.
    /// A pending in-place growth replaces that id's source here so the next
    /// sentence peels off, without changing the pair on screen.
    private var peelSources: [String] {
        let lines = self.peelSourceLines()
        return Array(lines.suffix(LiveTranslationTiming.peelWindowLines))
    }

    private func peelSourceLines() -> [String] {
        if !self.listenHistory.isEmpty {
            return self.listenHistory.map { entry in
                self.pendingGrowthSource(for: entry.id) ?? entry.source
            }
        }
        let start = min(max(self.listenBatchStart, 0), self.captionLog.entries.count)
        return self.captionLog.entries.dropFirst(start).map { entry in
            self.pendingGrowthSource(for: entry.id) ?? entry.source
        }
    }

    private func pendingGrowthSource(for id: UInt64) -> String? {
        guard let pending = self.pendingGrowth, pending.id == id else { return nil }
        return pending.source
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
    /// put sentence one back into the open tail while Apple Translation is busy.
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
            guard self.admissionDropsDeliveredUnit(first) else { break }
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

    /// Same checklist as a new row. Drop a unit admission would refuse because
    /// it is already delivered. Junk and a thin starter stay in the leftover.
    private func admissionDropsDeliveredUnit(_ unit: String) -> Bool {
        guard case .skip(let reason) = self.admissionDecision(unit, phase: .propose) else {
            return false
        }
        switch reason {
        case .sameAsPrinted, .revisesEarlier, .revisesNewest, .inFlight:
            return true
        case .empty, .junk, .tooThin, .untracked:
            return false
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
        self.captionLog = LectureCaptionLog()
        self.syncBoardState()
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
        self.heldLiveSpoken = ""
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
        self.heldLiveSpoken = ""
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
        self.heldLiveSpoken = ""
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
        self.heldLiveSpoken = ""
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
        self.heldLiveSpoken = ""
    }

    func releasePauseHold() {
        self.liveSpeechHeld = false
    }

    func awaitAcceptedCommits() async {
        while !self.commitTasks.isEmpty {
            let tasks = self.commitTasks
            self.commitTasks.removeAll()
            for task in tasks {
                await task.value
            }
        }
    }

    func dropUnacceptedSpeech() {
        self.cancelDelayedSpeechTasks()
        self.sourceDraft = ""
        self.translatedDraft = ""
        self.translatedDraftSource = ""
        self.lastHeardText = ""
        self.heldLiveSpoken = ""
    }

    func noteSilenceHold() {
        guard !self.liveSpeechHeld else { return }
        if self.eouHoldTask != nil { return }
        // The caption that closes this utterance still needs speech-start.
        // Resetting here made that line publish with no end-to-end time.
        // `finishPublishedCaption` resets after the sample is written.
        let pendingCaption = !self.sourceDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !self.lastHeardText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !self.inFlightSources.isEmpty
        if self.pauseRevisionTask == nil, !self.didPauseReviseThisUtterance, !pendingCaption {
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
            await self?.advance(.pauseConfirm, generation: token)
            // Voice catch-up owns extra finished sentences. The long
            // open-tail clock is only for a leftover fragment.
            if self?.voiceCatchUpTask == nil {
                self?.scheduleOpenTailSettle(generation: token)
            }
        }
    }

    func waitForIdleForTesting() async {
        // A failed translation schedules its one retry only after the commit
        // task returns, so drain commits, then the retry, then commits again.
        for _ in 0..<8 {
            await self.eouHoldTask?.value
            await self.pauseRevisionTask?.value
            await self.voiceCatchUpTask?.value
            await self.tailSettleTask?.value
            await self.prefetchTask?.value
            let translations = Array(self.inFlightTranslations.values)
            for task in translations {
                _ = await task.value
            }
            await self.awaitAcceptedCommits()
            if let retry = self.failedRetryTask {
                await retry.value
                await self.awaitAcceptedCommits()
            }
            if self.eouHoldTask == nil,
               self.pauseRevisionTask == nil,
               self.voiceCatchUpTask == nil,
               self.tailSettleTask == nil,
               self.inFlightTranslations.isEmpty,
               self.commitTasks.isEmpty
            {
                break
            }
        }
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
        self.failedRetryTask?.cancel()
        self.failedRetryTask = nil
        self.status = .empty
        let stillPending = self.commitOrder.indices.contains {
            $0 >= self.nextCommitToPublish
                && !self.skippedCommitIndexes.contains($0)
                && self.commitOrder[$0] == source
        }
        if stillPending {
            self.restartFailedCommit(source, generation: self.generation)
            return
        }
        self.enqueueCommit(source)
    }

    func snapshot() -> TheaterBoardSnapshot {
        TheaterBoardSnapshot(entries: self.captionLog.entries, nextID: self.captionLog.nextID)
    }

    func restore(_ snapshot: TheaterBoardSnapshot) {
        self.cancelSettles()
        self.cancelCommitsAndPolish()
        self.generation += 1
        self.publish(.restore(snapshot))
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
        guard self.publish(.removeLast) != nil else { return }
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
        self.rememberCommit(source)
        _ = self.publish(.append(source: source, translated: translated))
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
        self.advance(PartialCaption(
            text: leftover,
            confirmed: confirmed,
            heldOpen: display,
            languageID: languageID
        ))
        self.showActivityStatus()
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

    /// A finished sentence on the recognition tick. Pause, open tail, and Stop
    /// use `SettledCaption` so this tick cannot be asked to confirm.
    private struct PartialCaption {
        var text: String
        var confirmed: String
        var heldOpen: String
        var languageID: String
    }

    /// Pause, an aged open tail, and Stop. These confirm the transcript first.
    private enum SettledCaption {
        case pauseConfirm
        case openTail
        case stop(drainRemainder: Bool)
    }

    /// Recognition tick. The draft updates before this returns.
    private func advance(_ partial: PartialCaption) {
        self.commitCompletedSentencesWhileTalking(
            remaining: partial.text,
            confirmed: partial.confirmed,
            heldOpen: partial.heldOpen,
            languageID: partial.languageID
        )
    }

    /// Pause, open tail, and Stop confirm, then commit.
    private func advance(_ reason: SettledCaption, generation: UInt64) async {
        let token = generation
        switch reason {
        case .pauseConfirm:
            await self.commitSettled(
                generation: token,
                isFinal: false,
                allowPauseFinalize: false,
                forceOpenTail: false
            )
        case .openTail:
            await self.commitSettled(
                generation: token,
                isFinal: false,
                allowPauseFinalize: true,
                forceOpenTail: true
            )
        case let .stop(drainRemainder):
            await self.commitSettled(
                generation: token,
                isFinal: true,
                allowPauseFinalize: true,
                forceOpenTail: false
            )
            await self.awaitAcceptedCommits()
            if drainRemainder {
                self.commitTrailingFragment()
                await self.awaitAcceptedCommits()
            }
            self.sourceDraft = ""
            self.translatedDraft = self.captionLog.translatedLines.last ?? ""
            self.translatedDraftSource = self.captionLog.sourceLines.last ?? ""
        }
    }

    /// Mid-talk print peels each finished sentence the confirmed prefix already
    /// contains, ending included. Two recognition updates have to agree on that
    /// sentence. An open tail after it stays invisible and does not hold the
    /// sentence back. Pause, end of utterance, and Stop use `commitNextSettledUnit`.
    private func commitCompletedSentencesWhileTalking(
        remaining initial: String,
        confirmed: String,
        heldOpen: String,
        languageID: String
    ) {
        self.retargetNewestClauseIfGrown(into: initial, languageID: languageID)
        var remaining = TranslationClauseSegmenter.leftoverTail(
            initial,
            already: self.printedSources,
            languageID: languageID
        )
        var horizon = self.leftoverSpeech(confirmed, languageID: languageID)
        let isVoice = SpokenLanguageResolver.isSameLanguagePair()
        var didCommit = false
        var blockedOnUnconfirmed = false
        var steps = 0
        while steps < 32, !remaining.isEmpty {
            steps += 1
            guard let next = TranslationClauseSegmenter.nextCompletedSentence(
                remaining,
                languageID: languageID
            ) else {
                break
            }
            guard Self.confirmedSentenceAgreed(
                unit: next.unit,
                confirmed: horizon,
                languageID: languageID
            ) else {
                blockedOnUnconfirmed = true
                break
            }
            horizon = TranslationClauseSegmenter.leftoverTail(
                horizon,
                already: [next.unit],
                languageID: languageID
            )
            if self.shouldSkipSettledUnit(next.unit) {
                remaining = self.remainderAfterSkippedUnit(
                    next.unit,
                    rest: next.rest,
                    languageID: languageID
                )
                continue
            }
            self.enqueueCommit(next.unit)
            remaining = next.rest
            didCommit = true
        }
        if !blockedOnUnconfirmed,
           isVoice,
           self.midTalkLeftoverReady(
               remaining: remaining,
               confirmed: horizon,
               languageID: languageID
           ),
           let cut = self.voiceFollowAlongCut(remaining, languageID: languageID)
        {
            if self.shouldSkipSettledUnit(cut.unit) {
                remaining = self.remainderAfterSkippedUnit(
                    cut.unit,
                    rest: cut.rest,
                    languageID: languageID
                )
            } else {
                self.enqueueCommit(cut.unit)
                remaining = cut.rest
                didCommit = true
            }
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

    /// The confirmed prefix already includes this sentence, ending included.
    /// The rest of the confirmed text may still be an open tail. A period that
    /// exists only on this tick does not count.
    private static func confirmedSentenceAgreed(
        unit: String,
        confirmed: String,
        languageID: String
    ) -> Bool {
        let unit = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        let confirmed = confirmed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !unit.isEmpty, !confirmed.isEmpty else { return false }
        guard TranslationClauseSegmenter.looksComplete(unit, languageID: languageID) else {
            return false
        }
        if confirmed == unit || confirmed.hasPrefix(unit) || confirmed.hasPrefix(unit + " ") {
            return true
        }
        let stripped = unit.trimmingCharacters(in: CharacterSet(charactersIn: ".?!。！？…"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty, stripped != unit, confirmed.hasPrefix(stripped) else { return false }
        let after = confirmed.dropFirst(stripped.count)
        guard let first = after.first else { return false }
        return ".?!。！？…".contains(first)
    }

    /// The whole unread leftover looks finished in the listen language, and
    /// the confirmed unread text contains that leftover, ending included.
    /// Voice run-on backstop only. Finished sentences use `confirmedSentenceAgreed`.
    private func midTalkLeftoverReady(
        remaining: String,
        confirmed: String,
        languageID: String
    ) -> Bool {
        let remaining = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TranslationClauseSegmenter.looksComplete(remaining, languageID: languageID) else {
            return false
        }
        return StreamingTranscriptStitcher.confirmedClauseContains(
            unit: remaining,
            confirmed: confirmed,
            languageID: languageID
        )
    }

    /// The newest caption grew in place ("the model." → "the model on new
    /// data."). Keep that line id. The board stays on the previous pair until
    /// the replacement translation is ready, then source and Show-as update
    /// once. A following sentence still prints on its own line.
    private func retargetNewestClauseIfGrown(into text: String, languageID: String) {
        guard let candidate = TranslationClauseSegmenter.nextCompletedSentence(text, languageID: languageID)?.unit,
              TranslationClauseSegmenter.looksComplete(candidate, languageID: languageID)
        else { return }
        if let pending = self.pendingGrowth {
            if TranslationClauseSegmenter.isSameClause(pending.source, candidate) {
                return
            }
            if TranslationClauseSegmenter.isInPlaceGrowth(previous: pending.source, incoming: candidate) {
                self.schedulePaintedGrowth(id: pending.id, source: candidate)
                return
            }
        }
        if let last = self.captionLog.entries.last,
           TranslationClauseSegmenter.isInPlaceGrowth(previous: last.source, incoming: candidate) {
            self.schedulePaintedGrowth(id: last.id, source: candidate)
            return
        }
        guard let index = self.commitOrder.indices.last else { return }
        let pending = self.commitOrder[index]
        let pendingPublished = index < self.nextCommitToPublish
        guard !pendingPublished,
              TranslationClauseSegmenter.isInPlaceGrowth(previous: pending, incoming: candidate)
        else { return }
        self.commitOrder[index] = candidate
        let pendingKey = TranslationClauseSegmenter.clauseIdentity(pending)
        let grownKey = TranslationClauseSegmenter.clauseIdentity(candidate)
        if !pendingKey.isEmpty {
            self.commitIdentities.remove(pendingKey)
        }
        if !grownKey.isEmpty {
            self.commitIdentities.insert(grownKey)
        }
        self.readyTranslations.removeValue(forKey: pending)
        self.inFlightTranslations[pending]?.cancel()
        self.inFlightTranslations[pending] = nil
        self.inFlightSources.removeAll {
            TranslationClauseSegmenter.isSameClause($0, pending)
        }
        let generation = self.generation
        self.inFlightSources.append(candidate)
        self.inFlightTranslations[candidate] = self.startCommitTranslation(
            candidate,
            generation: generation,
            allowLocal: true
        )
        let task = Task { [weak self] in
            guard let self else { return }
            await self.commitUnit(candidate, generation: generation)
        }
        self.commitTasks.append(task)
    }

    /// Translate the grown clause without touching the painted pair. A later,
    /// longer growth replaces this target and cancels the shorter task.
    private func schedulePaintedGrowth(id: UInt64, source: String) {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return }
        if let pending = self.pendingGrowth,
           pending.id == id,
           TranslationClauseSegmenter.isSameClause(pending.source, source)
        {
            return
        }
        self.pendingGrowth = PendingCaptionGrowth(id: id, source: source)
        self.newestGrowthTask?.cancel()
        let generation = self.generation
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let translated = try await self.resolvedCommitTranslation(source, generation: generation)
                guard !Task.isCancelled, generation == self.generation else { return }
                self.publishPaintedGrowth(id: id, source: source, translated: translated)
            } catch {
                return
            }
        }
        self.newestGrowthTask = task
        self.commitTasks.append(task)
    }

    /// One write of the grown source and its translation on the same line id.
    /// A following sentence may already own the last row; this id still updates.
    private func publishPaintedGrowth(id: UInt64, source: String, translated: String) {
        guard let pending = self.pendingGrowth,
              pending.id == id,
              TranslationClauseSegmenter.isSameClause(pending.source, source)
        else { return }
        guard let row = self.captionLog.entries.first(where: { $0.id == id }) else { return }
        let old = row.source
        guard self.publish(.grow(id: id, source: source, translated: translated)) != nil else { return }
        self.replaceTrackedSource(old, with: source)
        self.pendingGrowth = nil
    }

    private func replaceTrackedSource(_ old: String, with grown: String) {
        let oldKey = TranslationClauseSegmenter.clauseIdentity(old)
        let grownKey = TranslationClauseSegmenter.clauseIdentity(grown)
        self.commitOrder = self.commitOrder.map {
            TranslationClauseSegmenter.isSameClause($0, old) ? grown : $0
        }
        self.publishedCommits = self.publishedCommits.map {
            TranslationClauseSegmenter.isSameClause($0, old) ? grown : $0
        }
        if !oldKey.isEmpty {
            self.commitIdentities.remove(oldKey)
        }
        if !grownKey.isEmpty {
            self.commitIdentities.insert(grownKey)
        }
        self.readyTranslations.removeValue(forKey: old)
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

    private func commitSettled(
        generation token: UInt64,
        isFinal: Bool,
        allowPauseFinalize: Bool,
        forceOpenTail: Bool
    ) async {
        guard token == self.generation else { return }
        var cleaned = self.lastHeardText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let languageID = SpokenLanguageResolver.listenLanguageID(for: cleaned)

        if LiveTranslationConfirm.shouldReDecode(
            isFinal: isFinal,
            isPause: !isFinal && !allowPauseFinalize && !forceOpenTail,
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
            // A breath-length quiet must not close an unpunctuated fragment.
            // Punctuation, a language ending, and a long run-on still commit
            // here. The short word/character floor waits for the open-tail
            // settle or Stop.
            allowPauseFinalize: allowPauseFinalize,
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
        if case .skip = self.admissionDecision(unit, phase: .propose) { return true }
        return false
    }

    func translateFinal(_ text: String, drainRemainder: Bool = true) async -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty {
            self.latestHypothesis = cleaned
            let incomingLanguage = SpokenLanguageResolver.listenLanguageID(for: cleaned)
            _ = self.rememberUnreadSpeech(cleaned, languageID: incomingLanguage)
        }

        await self.advance(.stop(drainRemainder: drainRemainder), generation: self.generation)
        return self.pendingInsertDocument()
    }

    /// Insert Stop types one trailing fragment the clause cutter refused.
    private func commitTrailingFragment() {
        let heard = self.lastHeardText.trimmingCharacters(in: .whitespacesAndNewlines)
        let languageID = SpokenLanguageResolver.listenLanguageID(for: heard)
        let leftover = self.leftoverSpeech(heard, languageID: languageID)
        guard !leftover.isEmpty else { return }
        let unit: String
        if leftover.count >= LiveTranslationTiming.maxDraftCharacters {
            unit = String(leftover.prefix(LiveTranslationTiming.maxDraftCharacters))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            unit = leftover
        }
        guard !unit.isEmpty else { return }
        self.enqueueCommit(unit, allowTrailingFragment: true)
    }

    private func enqueueCommit(
        _ source: String,
        generation: UInt64? = nil,
        allowTrailingFragment: Bool = false
    ) {
        let cleaned = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if allowTrailingFragment {
            let key = TranslationClauseSegmenter.clauseIdentity(cleaned)
            if !key.isEmpty { self.trailingFragmentKeys.insert(key) }
        }
        switch self.admissionDecision(cleaned, phase: .propose) {
        case .skip:
            self.forgetTrailingFragment(cleaned)
            return
        case .admit:
            break
        }
        let token = generation ?? self.generation
        if SpokenLanguageResolver.isSameLanguagePair() {
            self.commitVoiceCaption(cleaned, generation: token)
            return
        }
        self.commitOrder.append(cleaned)
        self.rememberCommit(cleaned)
        self.inFlightSources.append(cleaned)
        self.inFlightStartedAt[cleaned] = Date()
        self.syncBoardState()
        self.showActivityStatus()
        if self.cachedCommitTranslation(for: cleaned) == nil {
            let allowLocal = self.inFlightSources.count <= 1
            self.inFlightTranslations[cleaned] = self.startCommitTranslation(
                cleaned,
                generation: token,
                allowLocal: allowLocal
            )
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.commitUnit(cleaned, generation: token)
        }
        self.commitTasks.append(task)
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
    private func commitVoiceCaption(_ cleaned: String, generation: UInt64) {
        guard generation == self.generation else { return }
        guard self.publish(.append(source: cleaned, translated: cleaned)) != nil else { return }
        self.finishPublishedCaption(
            source: cleaned,
            translated: cleaned,
            generation: generation
        )
    }

    private func finishPublishedCaption(
        source: String,
        translated: String,
        generation: UInt64
    ) {
        if !self.committedLines.isEmpty, !SettingsStore.shared.theaterListenUsed {
            SettingsStore.shared.theaterListenUsed = true
        }
        self.publishLatencySample(mtMilliseconds: self.lastLatencyMilliseconds ?? 0)
        self.latencyTracker.resetUtterance()

        let heard = self.lastHeardText.isEmpty ? self.sourceDraft : self.lastHeardText
        let leftover = self.leftoverSpeech(
            heard,
            languageID: SpokenLanguageResolver.listenLanguageID(for: heard)
        )
        self.sourceDraft = leftover
        self.lastHeardText = leftover
        // The sentence that just printed is no longer the held leftover. Without this the
        // monotonic guard compares the next clause against the printed one,
        // keeps the printed text, and the next sentence never appears.
        self.heldLiveSpoken = leftover
        if leftover.isEmpty {
            self.translatedDraft = translated
            self.translatedDraftSource = source
        } else if TranslationClauseSegmenter.isSameClause(leftover, source) {
            self.sourceDraft = ""
            self.translatedDraft = translated
            self.translatedDraftSource = source
        } else {
            if TranslationClauseSegmenter.isSameClause(self.translatedDraftSource, source)
                || !TranslationClauseSegmenter.isGrowingClause(self.translatedDraftSource, toward: leftover)
            {
                let current = self.translatedDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                // Prefix growth stays on this leftover. Do not relabel that
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
        self.showActivityStatus()
    }

    /// Failure stays available on Retry. The status line follows the work:
    /// the sentence in flight, then open speech, then a failed sentence only
    /// when nothing else is moving.
    private func showActivityStatus() {
        if let source = self.inFlightSources.first(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            self.status = .info(Self.translatingStatus(for: source))
            return
        }
        let open = self.sourceDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !open.isEmpty {
            self.status = .listening()
            return
        }
        if self.lastFailedSource != nil {
            self.status = .failure("Translation failed — Retry / Download pack")
            return
        }
        self.status = .empty
    }

    private static func translatingStatus(for source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Translating…" }
        let limit = 60
        if trimmed.count <= limit {
            return "Translating… \(trimmed)"
        }
        let head = trimmed.prefix(limit)
        if let space = head.lastIndex(of: " "),
           trimmed.distance(from: head.startIndex, to: space) > 24
        {
            return "Translating… \(head[..<space])…"
        }
        return "Translating… \(head)…"
    }

    private enum BoardChange {
        case append(source: String, translated: String)
        case grow(id: UInt64, source: String, translated: String)
        case restore(TheaterBoardSnapshot)
        case removeLast
    }

    private func admissionContext(
        for source: String,
        requiresTrackedIdentity: Bool
    ) -> TheaterBoardAdmission.Context {
        let key = TranslationClauseSegmenter.clauseIdentity(source)
        return TheaterBoardAdmission.Context(
            peelSources: self.peelSources,
            inFlightSources: self.inFlightSources,
            commitIdentities: self.commitIdentities,
            latestHypothesis: self.latestHypothesis,
            requiresTrackedIdentity: requiresTrackedIdentity,
            allowTrailingFragment: !key.isEmpty && self.trailingFragmentKeys.contains(key)
        )
    }

    private func admissionDecision(
        _ unit: String,
        phase: TheaterBoardAdmission.Phase
    ) -> TheaterBoardAdmission.Decision {
        let tracksTranslation = phase == .publish && !SpokenLanguageResolver.isSameLanguagePair()
        let decision = TheaterBoardAdmission.decide(
            unit,
            languageID: SpokenLanguageResolver.listenLanguageID(for: unit),
            phase: phase,
            context: self.admissionContext(for: unit, requiresTrackedIdentity: tracksTranslation)
        )
        if case .skip(let reason) = decision, reason != .empty {
            DebugLogger.shared.debug(
                LiveTranslationTrace.event(
                    "board skip",
                    token: self.generation,
                    "reason=\(reason.rawValue)"
                ),
                source: LiveTranslationTrace.source
            )
        }
        return decision
    }

    private func syncBoardState() {
        let next = TheaterBoardState(
            rows: self.captionLog.entries.map {
                TheaterBoardRow(id: $0.id, source: $0.source, translated: $0.translated)
            },
            nextID: self.captionLog.nextID,
            inFlightCount: self.inFlightSources.count,
            oldestInFlightWaitMs: self.oldestInFlightWaitMilliseconds
        )
        guard next != self.boardState else { return }
        self.boardState = next
    }

    /// The only writer of the caption log. Callers update drafts and status after.
    @discardableResult
    private func publish(_ change: BoardChange) -> UInt64? {
        switch change {
        case .append(let source, let translated):
            switch self.admissionDecision(source, phase: .publish) {
            case .skip:
                self.forgetTrailingFragment(source)
                return nil
            case .admit:
                break
            }
            guard let committed = self.captionLog.commit(source: source, translated: translated) else {
                self.forgetTrailingFragment(source)
                return nil
            }
            self.forgetTrailingFragment(source)
            self.recordSessionEntries()
            if let entry = self.captionLog.entries.first(where: { $0.id == committed.id }) {
                self.rememberListenEntry(entry)
            }
            self.adjustIndexes(trimmedCount: committed.overflow.count)
            self.syncBoardState()
            return committed.id
        case .grow(let id, let source, let translated):
            guard self.captionLog.applyGrowth(id: id, source: source, translated: translated) else {
                return nil
            }
            if let index = self.listenHistory.lastIndex(where: { $0.id == id }) {
                self.listenHistory[index].source = source
                self.listenHistory[index].translated = translated
            }
            self.recordSessionEntries()
            self.syncBoardState()
            return id
        case .restore(let snapshot):
            self.captionLog.restore(snapshot)
            self.listenHistory = []
            self.suppressedSources = []
            self.listenBatchStart = self.captionLog.sourceLines.count
            self.syncBoardState()
            self.postedLineCount = self.committedLines.count
            return nil
        case .removeLast:
            guard let removed = self.captionLog.popLast() else { return nil }
            self.sessionEntries.removeAll {
                $0.id == removed.id && $0.committedAt == removed.committedAt
            }
            self.forgetListenEntry(removed)
            let source = removed.source.trimmingCharacters(in: .whitespacesAndNewlines)
            if !source.isEmpty {
                self.suppressedSources.append(source)
            }
            let count = self.captionLog.translatedLines.count
            self.listenBatchStart = min(self.listenBatchStart, count)
            self.postedLineCount = min(self.postedLineCount, count)
            self.syncBoardState()
            return removed.id
        }
    }

    private func trackCommit(_ source: String) {
        let cleaned = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let key = TranslationClauseSegmenter.clauseIdentity(cleaned)
        guard !key.isEmpty, !self.commitIdentities.contains(key) else { return }
        self.commitOrder.append(cleaned)
        self.commitIdentities.insert(key)
    }

    private func rememberCommit(_ source: String) {
        let key = TranslationClauseSegmenter.clauseIdentity(source)
        guard !key.isEmpty else { return }
        self.commitIdentities.insert(key)
    }

    private func forgetTrailingFragment(_ source: String) {
        let key = TranslationClauseSegmenter.clauseIdentity(source)
        guard !key.isEmpty else { return }
        self.trailingFragmentKeys.remove(key)
    }

    /// Print sentences in spoken order. A later translation waits until the
    /// sentence before it has landed or been skipped after a failed retry.
    private func publishReadyCommits(generation: UInt64) {
        guard generation == self.generation else { return }
        while self.nextCommitToPublish < self.commitOrder.count {
            if self.skippedCommitIndexes.contains(self.nextCommitToPublish) {
                self.nextCommitToPublish += 1
                continue
            }
            let source = self.commitOrder[self.nextCommitToPublish]
            guard let translated = self.readyTranslations.removeValue(forKey: source) else { break }
            guard self.publish(.append(source: source, translated: translated)) != nil else {
                self.publishedCommits.append(source)
                self.nextCommitToPublish += 1
                continue
            }
            self.publishedCommits.append(source)
            self.nextCommitToPublish += 1
            self.finishPublishedCaption(
                source: source,
                translated: translated,
                generation: generation
            )
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
                self.syncBoardState()
            }
            self.inFlightTranslations[incoming]?.cancel()
            self.inFlightTranslations[cleaned]?.cancel()
            self.inFlightTranslations[incoming] = nil
            self.inFlightTranslations[cleaned] = nil
            if generation == self.generation {
                self.showActivityStatus()
            }
        }
        guard generation == self.generation else { return }
        guard !cleaned.isEmpty else { return }
        if SpokenLanguageResolver.isSameLanguagePair() {
            self.commitVoiceCaption(cleaned, generation: generation)
            return
        }

        do {
            let resolved = try await self.resolvedCommitTranslation(cleaned, generation: generation)
            guard generation == self.generation else { return }
            self.readyTranslations[cleaned] = resolved
            if self.lastFailedSource == cleaned {
                self.lastFailedSource = nil
                if self.status.kind == .failure {
                    self.status = .listening()
                }
            }
            self.publishReadyCommits(generation: generation)
        } catch {
            guard generation == self.generation else { return }
            if error is CancellationError { return }
            self.lastFailedSource = cleaned
            DebugLogger.shared.error(
                "Lecture translation failed: \(error.localizedDescription)",
                source: "LiveTranslation"
            )
            if !self.didAutoRetryFailure {
                self.didAutoRetryFailure = true
                self.scheduleFailedRetry(cleaned, generation: generation)
            } else {
                self.skipFailedCommitSlot(cleaned, generation: generation)
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
        self.showActivityStatus()
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
    /// non-empty forever. Admission refuses a replacement while a call is
    /// in flight, so a stuck call would jam the caption stream.
    private func translateWithTimeout(
        _ text: String,
        source: TranslationLanguage,
        target: TranslationLanguage,
        terms: [String],
        kind: TranslationRequestKind,
        prior: (sources: [String], translations: [String]),
        allowLocal: Bool = true
    ) async throws -> String {
        let timeout = LiveTranslationTiming.mailboxTimeoutNanoseconds(for: kind)
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

    var commitOrderForTesting: [String] { self.commitOrder }

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

    /// Keep only unread speech. A cumulative ASR restitch of dropped lines
    /// is recovered from the last open leftover, not the whole talk.
    private func rememberUnreadSpeech(_ incoming: String, languageID: String) -> String {
        let leftover = self.retainUnreadSpeech(incoming, languageID: languageID)
        self.lastHeardText = leftover
        return leftover
    }

    private func retainUnreadSpeech(_ incoming: String, languageID: String) -> String {
        let incoming = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        // "…data." → "…data too." is not a string prefix: the period is where
        // the new words were inserted. Peel then keeps the shorter leftover,
        // and the longer clause never retargets.
        if self.keepsInPlaceGrowth(incoming, languageID: languageID) {
            return incoming
        }
        let peeled = self.leftoverSpeech(incoming, languageID: languageID)
        let open = self.lastHeardText.trimmingCharacters(in: .whitespacesAndNewlines)
        if peeled != incoming || open.isEmpty {
            return peeled
        }
        if incoming.hasPrefix(open) || open.hasPrefix(incoming) {
            return incoming.hasPrefix(open) ? incoming : peeled
        }
        // Nothing has been committed yet. A restitch that inserts words where
        // a period sat is still this leftover.
        if self.printedSources.isEmpty {
            return incoming
        }
        // The ASR window slid. Peel would have removed a delivered prefix.
        // A decode that does not contain those lines is new speech.
        let repeatsPrinted = self.printedSources.contains { printed in
            TranslationClauseSegmenter.contains(incoming, clause: printed)
        }
        if !repeatsPrinted {
            return incoming
        }
        // Peel did not move, and this tick is not the open leftover growing
        // or shrinking. Keep that leftover so the printed sentence cannot
        // come back onto the board.
        return open
    }

    private func keepsInPlaceGrowth(_ incoming: String, languageID: String) -> Bool {
        guard let candidate = TranslationClauseSegmenter.nextCompletedSentence(
            incoming,
            languageID: languageID
        )?.unit else { return false }
        if let pending = self.pendingGrowth,
           TranslationClauseSegmenter.isSameClause(pending.source, candidate)
            || TranslationClauseSegmenter.isInPlaceGrowth(previous: pending.source, incoming: candidate)
        {
            return true
        }
        if let last = self.captionLog.entries.last?.source,
           TranslationClauseSegmenter.isInPlaceGrowth(previous: last, incoming: candidate)
        {
            return true
        }
        let open = self.lastHeardText.trimmingCharacters(in: .whitespacesAndNewlines)
        return TranslationClauseSegmenter.isInPlaceGrowth(previous: open, incoming: candidate)
    }

    private func cancelSettles() {
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
        await self.advance(.pauseConfirm, generation: generation)
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
            await self.advance(.openTail, generation: token)
        }
    }

    /// Restart translation for the sentence already in `commitOrder`. A second
    /// append would sit behind the failed slot with no caption and wedge the tail.
    private func restartFailedCommit(_ source: String, generation: UInt64) {
        guard generation == self.generation else { return }
        let cleaned = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        guard self.commitOrder.contains(cleaned) else { return }
        self.inFlightSources.append(cleaned)
        self.inFlightStartedAt[cleaned] = Date()
        self.syncBoardState()
        self.showActivityStatus()
        if self.cachedCommitTranslation(for: cleaned) == nil {
            let allowLocal = self.inFlightSources.count <= 1
            self.inFlightTranslations[cleaned] = self.startCommitTranslation(
                cleaned,
                generation: generation,
                allowLocal: allowLocal
            )
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.commitUnit(cleaned, generation: generation)
        }
        self.commitTasks.append(task)
    }

    /// The one automatic retry is spent. Drop this slot and print later sentences.
    private func skipFailedCommitSlot(_ source: String, generation: UInt64) {
        guard generation == self.generation else { return }
        let cleaned = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = self.commitOrder.indices.first(where: {
            $0 >= self.nextCommitToPublish
                && !self.skippedCommitIndexes.contains($0)
                && self.commitOrder[$0] == cleaned
        }) {
            self.skippedCommitIndexes.insert(index)
        }
        self.publishReadyCommits(generation: generation)
    }

    private func scheduleFailedRetry(_ source: String, generation: UInt64) {
        self.failedRetryTask?.cancel()
        self.failedRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self else { return }
            guard generation == self.generation, self.lastFailedSource == source else { return }
            self.restartFailedCommit(source, generation: generation)
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
        for task in self.commitTasks {
            task.cancel()
        }
        self.commitTasks = []
        self.newestGrowthTask?.cancel()
        self.newestGrowthTask = nil
        self.pendingGrowth = nil
        self.commitOrder = []
        self.nextCommitToPublish = 0
        self.skippedCommitIndexes = []
        self.commitIdentities = []
        self.trailingFragmentKeys = []
        self.readyTranslations = [:]
        self.publishedCommits = []
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
