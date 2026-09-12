import Combine
import Darwin
import Foundation

// swiftlint:disable function_body_length cyclomatic_complexity type_body_length
// Tracked grandfather: existing FluidVoice-era file. New work belongs in a smaller file.

@MainActor
final class LiveTranslationSubscriber: ObservableObject {
    @Published private(set) var sourceDraft: String = ""
    @Published private(set) var translatedDraft: String = ""
    @Published private(set) var committedLines: [String] = []
    @Published private(set) var lastLatencyMilliseconds: Int?
    @Published private(set) var lastLatencySample = LiveTranslationLatencySample()
    @Published private(set) var statusText: String = ""

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
    var captionPairs: [CaptionHistoryPair] { self.captionLog.captionPairs }
    var exportCaptionPairs: [CaptionHistoryPair] {
        TheaterCaptionExport.pairs(from: self.archive.loadAll()) + self.captionLog.captionPairs
    }

    /// Translated draft after a clause commits. Incomplete speech stays off Theater.
    var liveCaptionText: String {
        let draft = self.translatedDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = self.committedLines.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !draft.isEmpty, draft != last {
            return draft
        }
        return ""
    }

    /// Incomplete speech stays off Theater until the clause commits.
    var liveSpokenText: String { "" }

    /// Unpublished clauses stay in the private buffer, not on the board.
    var pendingSpokenLines: [String] { [] }

    /// Peel against the whole board. A trailing ASR window can still contain
    /// sentences committed before this Listen.
    private var printedSources: [String] {
        self.captionLog.sourceLines + self.inFlightSources
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
        self.statusText = ""
        self.lastFailedSource = nil
        self.didPauseReviseThisUtterance = false
        self.didAutoRetryFailure = false
        self.llmEngine.resetListenEchoTally()
    }

    /// Stop settling new speech. Keep captions already committed this session.
    func endListening() {
        self.cancelSettles()
        self.cancelCommitsAndPolish()
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
        self.generation += 1
        self.translatedDraftSource = ""
        self.lastSettleTail = ""
        self.lastSettleUnread = []
        self.lastHeardText = ""
        self.sourceDraft = ""
        self.translatedDraft = self.captionLog.translatedLines.last ?? ""
        self.statusText = "Listening…"
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
        self.generation += 1
        self.translatedDraftSource = ""
        self.lastSettleTail = ""
        self.lastSettleUnread = []
        self.lastHeardText = ""
        self.sourceDraft = ""
        self.translatedDraft = self.captionLog.translatedLines.last ?? ""
        self.statusText = ""
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
        LastListenLatencyStore.write(self.lastLatencySample)
    }

    func refreshThermal(_ thermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState) {
        self.lastLatencySample = self.latencyTracker.refreshThermal(thermal)
    }

    func handleEndOfUtterance() {
        // Parakeet EOU is a pause, not a sentence. Hold briefly so the last ASR
        // tick can land, then restart settle. Do not commit the open tail.
        let token = self.generation
        let languageID = SpokenLanguageResolver.sourceLanguage().id
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
            await self?.restartSettlesAfterHold(generation: token, languageID: languageID)
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
        self.statusText = message
        self.objectWillChange.send()
    }

    func retryFailedTranslation() {
        guard let source = self.lastFailedSource else { return }
        self.lastFailedSource = nil
        self.statusText = ""
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
        self.statusText = ""
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

        let leftover = TranslationClauseSegmenter.leftoverTail(
            cleaned,
            already: self.printedSources,
            languageID: languageID
        )
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
        }
        self.sourceDraft = leftover
        if !self.statusText.contains("failed") {
            self.statusText = "Listening…"
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
            if Self.shouldPreferConfirmation(
                cleanedConfirm,
                over: self.lastHeardText,
                already: self.printedSources
            ) {
                self.lastHeardText = cleanedConfirm
                cleaned = cleanedConfirm
            }
        }

        let remaining = TranslationClauseSegmenter.leftoverTail(
            cleaned,
            already: self.printedSources,
            languageID: languageID
        )
        self.commitNextSettledUnit(
            remaining: remaining,
            languageID: languageID,
            allowPauseFinalize: reason == .openTailAged,
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
            let next = TranslationClauseSegmenter.nextCommitUnit(
                remaining,
                languageID: languageID,
                allowPauseFinalize: allowPauseFinalize
            )
            let unit: String
            let rest: String
            if let next {
                unit = next.unit
                rest = next.rest
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
        if let last = self.captionLog.sourceLines.last {
            if TranslationClauseSegmenter.isSameClause(last, unit),
               !TranslationClauseSegmenter.shouldReplaceLast(previous: last, incoming: unit)
            {
                return true
            }
            if TranslationClauseSegmenter.shouldReviseCommitted(
                previous: last,
                incoming: unit,
                languageID: SpokenLanguageResolver.sourceLanguage().id
            ), !TranslationClauseSegmenter.shouldReplaceLast(previous: last, incoming: unit) {
                return true
            }
        }
        if self.captionLog.sourceLines.contains(where: {
            TranslationClauseSegmenter.isSameClause($0, unit)
        }) {
            return !TranslationClauseSegmenter.shouldReplaceLast(
                previous: self.captionLog.sourceLines.last ?? "",
                incoming: unit
            )
        }
        return false
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

    private static func shouldPreferConfirmation(
        _ confirmed: String,
        over heard: String,
        already: [String] = []
    ) -> Bool {
        let next = confirmed.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        if next.isEmpty { return false }
        if current.isEmpty { return true }
        if already.isEmpty {
            return LiveTranslationConfirm.prefersFirstConfirmation(confirmed: next, heard: current)
        }

        let languageID = SpokenLanguageResolver.sourceLanguage().id
        let nextLeftover = TranslationClauseSegmenter.leftoverTail(
            next,
            already: already,
            languageID: languageID
        )
        let currentLeftover = TranslationClauseSegmenter.leftoverTail(
            current,
            already: already,
            languageID: languageID
        )
        if nextLeftover.isEmpty { return false }
        if currentLeftover.isEmpty { return true }
        guard Self.isLeftoverRevision(nextLeftover, of: currentLeftover) else { return false }
        return nextLeftover.count >= max(8, (currentLeftover.count * 2) / 3)
    }

    private static func isLeftoverRevision(_ incoming: String, of previous: String) -> Bool {
        if TranslationClauseSegmenter.isSameClause(previous, incoming) { return true }
        let left = Self.foldedClause(previous)
        let right = Self.foldedClause(incoming)
        guard !left.isEmpty, !right.isEmpty else { return false }
        return right.hasPrefix(left) || left.hasPrefix(right)
    }

    private static func foldedClause(_ text: String) -> String {
        let kept = text.lowercased().compactMap { character -> Character? in
            if character.isLetter || character.isNumber { return character }
            if character.isWhitespace { return " " }
            return nil
        }
        return String(kept)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func restartSettlesAfterHold(generation token: UInt64, languageID: String) {
        guard token == self.generation else { return }
        let leftover = TranslationClauseSegmenter.leftoverTail(
            self.lastHeardText,
            already: self.printedSources,
            languageID: languageID
        )
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
        let leftover = TranslationClauseSegmenter.leftoverTail(
            heard,
            already: self.printedSources,
            languageID: languageID
        )
        let token = self.generation
        var remaining = leftover
        while let next = TranslationClauseSegmenter.nextCommitUnit(
            remaining,
            languageID: languageID,
            allowPauseFinalize: false
        ) {
            await self.commitUnit(next.unit, generation: token, reason: .final)
            remaining = next.rest
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

    private func commitUnit(_ source: String, generation: UInt64, reason _: CommitReason) async {
        let cleaned = source.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { self.inFlightSources.removeAll { $0 == cleaned } }
        guard generation == self.generation else { return }
        guard !cleaned.isEmpty else { return }

        if let lastSource = self.captionLog.sourceLines.last {
            if TranslationClauseSegmenter.shouldIgnoreAsStalePrefix(previous: lastSource, incoming: cleaned) {
                return
            }
            if TranslationClauseSegmenter.shouldReviseCommitted(
                previous: lastSource,
                incoming: cleaned,
                languageID: SpokenLanguageResolver.sourceLanguage().id
            ), !TranslationClauseSegmenter.shouldReplaceLast(previous: lastSource, incoming: cleaned) {
                return
            }
        }
        let replaceLast = self.captionLog.sourceLines.last.map {
            TranslationClauseSegmenter.shouldReplaceLast(previous: $0, incoming: cleaned)
        } ?? false
        if !replaceLast, self.captionLog.sourceLines.last == cleaned {
            return
        }

        do {
            let resolved: String
            if SpokenLanguageResolver.isSameLanguagePair() {
                resolved = cleaned
            } else if let cached = self.cachedLiveTranslation(for: cleaned) {
                resolved = cached
            } else {
                self.statusText = "Translating…"
                let translated = try await self.performTranslation(cleaned, kind: .commit)
                guard generation == self.generation else { return }
                guard let safe = LLMTranslationEngine.captionSafeForBoard(translated, sourceText: cleaned)
                else {
                    throw TranslationEngineError.localRejected
                }
                resolved = safe
            }

            guard let committed = self.captionLog.commit(source: cleaned, translated: resolved) else { return }
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
            let leftover = TranslationClauseSegmenter.leftoverTail(
                heard,
                already: self.printedSources,
                languageID: SpokenLanguageResolver.sourceLanguage().id
            )
            self.sourceDraft = leftover
            self.statusText = leftover.isEmpty ? "" : "Listening…"
            if leftover.isEmpty {
                self.translatedDraft = resolved
                self.translatedDraftSource = cleaned
            } else if TranslationClauseSegmenter.isSameClause(leftover, cleaned) {
                self.sourceDraft = ""
                self.translatedDraft = resolved
                self.translatedDraftSource = cleaned
                self.statusText = ""
            } else {
                self.translatedDraft = ""
                self.translatedDraftSource = ""
            }
        } catch {
            guard generation == self.generation else { return }
            self.lastFailedSource = cleaned
            self.statusText = "Translation failed — Retry / Download pack"
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
        guard !cleaned.isEmpty, !cached.isEmpty else { return nil }
        guard TranslationClauseSegmenter.isSameClause(self.translatedDraftSource, cleaned) else { return nil }
        return cached
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
        let translated = try await self.translateClause(
            text,
            source: source,
            target: target,
            terms: terms,
            kind: kind
        )
        let ms = Int(((ProcessInfo.processInfo.systemUptime - started) * 1000).rounded())
        self.lastLatencyMilliseconds = ms
        DebugLogger.shared.debug(
            "Live translation \(source.id)->\(target.id) \(ms)ms chars=\(text.count)",
            source: "LiveTranslation"
        )
        return translated
    }

    /// Apple Translation is `session.translate(text)` with no prompt. Isolated
    /// Korean/Thai clauses lose zero-subject context, so commit sends the last
    /// 2–4 source clauses plus the new one, then peels the new caption out.
    private func translateClause(
        _ text: String,
        source: TranslationLanguage,
        target: TranslationLanguage,
        terms: [String],
        kind: TranslationRequestKind
    ) async throws -> String {
        let prior = self.priorClausesForContextualTranslation(incoming: text)
        if let local = await self.localCommitTranslation(
            text,
            priorSource: prior.sources,
            source: source,
            target: target,
            terms: terms
        ) {
            return local
        }
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
                kind: kind
            )
            if let peeled = Self.peeledNewTranslation(
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
            kind: kind
        )
    }

    private func priorClausesForContextualTranslation(
        incoming: String
    ) -> (sources: [String], translations: [String]) {
        var sources = self.captionLog.contextSourceLines
        var translations = Array(self.captionLog.translatedLines.suffix(sources.count))
        guard !sources.isEmpty, sources.count == translations.count else {
            return ([], [])
        }
        if let last = sources.last,
           TranslationClauseSegmenter.shouldReplaceLast(previous: last, incoming: incoming)
        {
            sources.removeLast()
            translations.removeLast()
        }
        let count = min(LiveTranslationTiming.contextSentenceCount, sources.count)
        guard count > 0 else { return ([], []) }
        return (Array(sources.suffix(count)), Array(translations.suffix(count)))
    }

    private static func peeledNewTranslation(
        _ translated: String,
        priorTranslations: [String],
        targetID: String
    ) -> String? {
        let cleaned = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !priorTranslations.isEmpty else { return nil }
        let leftover = TranslationClauseSegmenter.leftoverTail(
            cleaned,
            already: priorTranslations,
            languageID: targetID
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        if leftover.isEmpty { return nil }
        if leftover == cleaned || TranslationClauseSegmenter.isSameClause(leftover, cleaned) {
            return nil
        }
        if priorTranslations.contains(where: { TranslationClauseSegmenter.isSameClause($0, leftover) }) {
            return nil
        }
        if Self.leftoverContainsPriorCaption(leftover, priors: priorTranslations) {
            return nil
        }
        return leftover
    }

    private static func leftoverContainsPriorCaption(_ leftover: String, priors: [String]) -> Bool {
        priors.contains { prior in
            let trimmed = prior.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2 else { return false }
            return leftover.range(
                of: trimmed,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil
        }
    }

    private func localCommitTranslation(
        _ text: String,
        priorSource: [String],
        source: TranslationLanguage,
        target: TranslationLanguage,
        terms: [String]
    ) async -> String? {
        guard self.llmEngine.isReadyForCommitTranslation() else { return nil }
        let protected = TranslationGlossary.protect(text, terms: terms)
        do {
            let translated = try await self.llmEngine.translateCommit(
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

    private func translateProtected(
        _ text: String,
        terms: [String],
        source: TranslationLanguage,
        target: TranslationLanguage,
        kind: TranslationRequestKind
    ) async throws -> String {
        let protected = TranslationGlossary.protect(text, terms: terms)
        let translated = try await self.translateWithRetry(
            protected.text,
            source: source,
            target: target,
            engine: self.translator,
            kind: kind
        )
        return TranslationGlossary.restore(translated, tokens: protected.tokens)
    }

    private func translateWithRetry(
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

    private func publishLatencySample(mtMilliseconds: Int) {
        self.lastLatencySample = self.latencyTracker.markTranslated(
            at: ProcessInfo.processInfo.systemUptime,
            mtMilliseconds: mtMilliseconds,
            thermal: ProcessInfo.processInfo.thermalState
        )
    }

    private func archiveOverflow(_ overflow: [LectureCaptionEntry]) {
        guard !overflow.isEmpty else { return }
        self.archive.append(overflow)
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
    }

    private func adjustIndexes(trimmedCount: Int) {
        guard trimmedCount > 0 else { return }
        self.listenBatchStart = max(0, self.listenBatchStart - trimmedCount)
        self.postedLineCount = max(0, self.postedLineCount - trimmedCount)
    }
}
