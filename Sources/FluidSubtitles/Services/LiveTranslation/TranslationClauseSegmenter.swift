import Foundation

/// Splits a growing lecture transcript into finished clauses and an open tail.
///
/// Mid-talk (`nextCompletedSentence`): commit a finished, non-thin clause only
/// when more speech already follows it. Thin junk (`It.`) stays open.
/// Pause / Stop leftover (`nextCommitUnit`): sentence end, follow-along 12/80,
/// or pause-finalize floors. A twelve-word cut is not a mid-talk title.
/// The live row shows leftover after peel. lineCut is commit-time only.
nonisolated enum TranslationClauseSegmenter {
    struct Split: Equatable {
        var completed: [String]
        var tail: String
    }

    /// Finished unread sentences on their own rows, plus the line still typing.
    struct LivePreview: Equatable {
        var pinned: [String]
        var open: String
    }

    enum CommitDecision: Equatable {
        case ignore
        case commitNow
        case waitForStability
    }

    static func languageCode(from languageID: String) -> String {
        languageID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .first
            .map(String.init) ?? languageID.lowercased()
    }

    static func isVerbFinalLanguage(_ languageID: String) -> Bool {
        switch self.languageCode(from: languageID) {
        case "ko", "ja":
            return true
        default:
            return false
        }
    }

    static func split(_ text: String, languageID: String) -> Split {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Split(completed: [], tail: "") }

        var completed: [String] = []
        var start = trimmed.startIndex
        var index = trimmed.startIndex

        while index < trimmed.endIndex {
            let next = trimmed.index(after: index)
            if self.isBoundary(in: trimmed, at: index, languageID: languageID) {
                let piece = String(trimmed[start..<next]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty {
                    completed.append(piece)
                }
                start = next
                while start < trimmed.endIndex, trimmed[start].isWhitespace {
                    start = trimmed.index(after: start)
                }
                index = start
                continue
            }
            index = next
        }

        var tail = start < trimmed.endIndex
            ? String(trimmed[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""

        let peeled = self.peelCompletedInternalClauses(tail, languageID: languageID)
        if !peeled.completed.isEmpty {
            completed.append(contentsOf: peeled.completed)
            tail = peeled.tail
        }

        while tail.count >= LiveTranslationTiming.maxDraftCharacters {
            let forced = self.forceCut(tail)
            if forced.head.isEmpty { break }
            completed.append(forced.head)
            tail = forced.rest
        }

        return Split(completed: completed, tail: tail)
    }

    static func looksComplete(_ text: String, languageID: String) -> Bool {
        self.isCommitComplete(text, languageID: languageID)
    }

    static func isCommitComplete(_ text: String, languageID: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let complete: Bool
        if let last = trimmed.unicodeScalars.last, Self.terminalPunctuation.contains(last) {
            complete = true
        } else {
            switch self.languageCode(from: languageID) {
            case "ko":
                complete = self.hasEnding(trimmed, endings: Self.koreanCommitEndings)
                    || self.isCaptionReadyConnective(trimmed, languageID: languageID)
            case "ja":
                complete = self.hasJapanesePredicateEnding(trimmed)
                    || self.isCaptionReadyConnective(trimmed, languageID: languageID)
            case "th":
                complete = self.hasEnding(trimmed, endings: Self.thaiCommitEndings)
            default:
                complete = false
            }
        }
        return complete && !self.isTooThinToCommit(trimmed, languageID: languageID)
    }

    /// ASR often emits "It." / "The." / "So." as a sentence. That is not a clause.
    static func isTooThinToCommit(_ text: String, languageID: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if CaptionJunkGate.isAcknowledgement(trimmed) { return false }
        let words = self.tokens(trimmed).map(self.tokenKey).filter { !$0.isEmpty }
        if words.contains(where: { $0.contains(where: \.isASCII) }) {
            if words.count >= 3 { return false }
            if words.count == 1 { return self.isThinEnglishStarter(words[0]) }
            return self.isThinEnglishStarter(words[0])
                && (self.isThinEnglishStarter(words[1]) || self.isThinEnglishAuxiliary(words[1]))
        }
        switch self.languageCode(from: languageID) {
        case "ko", "ja", "th":
            return self.stripped(trimmed).filter { !$0.isWhitespace }.count < 2
        default:
            return words.isEmpty
        }
    }

    static func isThinEnglishStarter(_ word: String) -> Bool {
        Self.thinEnglishStarters.contains(self.tokenKey(word))
    }

    /// Run-on backstop only, used at EOU / silence / Stop leftover flush.
    /// Mid-talk does not fire a title at a word count.
    static func shouldFollowAlong(_ text: String, languageID: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if self.isTooThinToCommit(trimmed, languageID: languageID) { return false }
        if self.isCompactScript(languageID) {
            return trimmed.count >= LiveTranslationTiming.maxLineCharacters
        }
        return self.tokens(trimmed).count >= LiveTranslationTiming.maxLineWords
    }

    /// A long Korean/Japanese connective can print before the final verb.
    /// Short tags like “그건 그렇거든요” stay open.
    static func isCaptionReadyConnective(_ text: String, languageID: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !self.isTooThinToCommit(trimmed, languageID: languageID) else {
            return false
        }
        let letters = self.stripped(trimmed).filter { !$0.isWhitespace }
        guard letters.count >= 16 else { return false }
        switch self.languageCode(from: languageID) {
        case "ko":
            return self.hasEnding(trimmed, endings: Self.koreanInternalEndings)
        case "ja":
            return self.hasEnding(trimmed, endings: Self.japaneseConnectiveEndings)
        default:
            return false
        }
    }

    static func isInternalBoundary(_ text: String, languageID: String) -> Bool {
        if self.isCommitComplete(text, languageID: languageID) { return true }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        switch self.languageCode(from: languageID) {
        case "ko":
            return self.hasEnding(trimmed, endings: Self.koreanInternalEndings)
        case "th":
            return self.hasEnding(trimmed, endings: Self.thaiInternalEndings)
        case "ja":
            return self.hasJapanesePredicateEnding(trimmed)
                || self.hasEnding(trimmed, endings: Self.japaneseConnectiveEndings)
        default:
            return false
        }
    }

    static func decision(forTail tail: String, languageID: String) -> CommitDecision {
        let trimmed = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .ignore }
        if trimmed.count >= LiveTranslationTiming.maxDraftCharacters { return .commitNow }
        if self.shouldFollowAlong(trimmed, languageID: languageID) { return .commitNow }
        return .waitForStability
    }

    /// Preview helper. Mid-talk commit uses `nextCompletedSentence`, not this
    /// 8-word short-stop absorb.
    static func hasUnreadSpeechAfterCompleted(_ leftover: String, languageID: String) -> Bool {
        let split = self.absorbShortCompleted(
            self.absorbThinCompleted(self.split(leftover, languageID: languageID), languageID: languageID),
            languageID: languageID
        )
        guard let first = split.completed.first, !self.isTooThinToCommit(first, languageID: languageID) else {
            return false
        }
        if self.isShortSpokenStop(first, languageID: languageID) {
            return false
        }
        return split.completed.count > 1 || !split.tail.isEmpty
    }

    /// Unused by the live session. Do not treat 1.0 s / 6.0 s as commit clocks.
    static func settleNanoseconds(unreadCount: Int, tail: String, languageID: String) -> UInt64 {
        if unreadCount > 0 {
            return LiveTranslationTiming.completeSettleNanoseconds(languageID: languageID)
        }
        if self.looksComplete(tail, languageID: languageID) {
            return LiveTranslationTiming.completeSettleNanoseconds(languageID: languageID)
        }
        if tail.count >= LiveTranslationTiming.maxDraftCharacters
            || self.shouldFollowAlong(tail, languageID: languageID)
        {
            return 0
        }
        return LiveTranslationTiming.openSettleNanoseconds(languageID: languageID)
    }

    static func isReadyToCommit(
        _ text: String,
        languageID: String,
        allowPauseFinalize: Bool = false
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if trimmed.count >= LiveTranslationTiming.maxDraftCharacters { return true }
        if self.looksComplete(trimmed, languageID: languageID) { return true }
        return allowPauseFinalize && self.isPauseFinalizable(trimmed, languageID: languageID)
    }

    static func isPauseFinalizable(_ text: String, languageID: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if self.looksComplete(trimmed, languageID: languageID) { return true }
        if self.isVerbFinalLanguage(languageID) {
            return trimmed.count >= LiveTranslationTiming.minPauseFinalizeCharactersVerbFinal
        }
        if self.languageCode(from: languageID) == "th" {
            return trimmed.count >= LiveTranslationTiming.minPauseFinalizeCharactersThai
        }
        let words = trimmed.split { $0.isWhitespace }.filter { !$0.isEmpty }
        return words.count >= LiveTranslationTiming.minPauseFinalizeWords
            || trimmed.count >= LiveTranslationTiming.minPauseFinalizeCharacters
    }

    static func shouldRestartSettle(previous: String, incoming: String) -> Bool {
        let next = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        if next.isEmpty { return false }
        if last.isEmpty { return true }
        if self.isSameClause(last, next) { return false }
        if self.shouldIgnoreAsStalePrefix(previous: last, incoming: next) { return false }
        return true
    }

    static func isCompactScript(_ languageID: String) -> Bool {
        switch self.languageCode(from: languageID) {
        case "ko", "ja", "zh", "th":
            return true
        default:
            return false
        }
    }

    static func isSameClause(_ left: String, _ right: String) -> Bool {
        let a = self.normalized(left)
        let b = self.normalized(right)
        return !a.isEmpty && a == b
    }

    /// ASR often grows a clause by inserting words before the period.
    /// "Hey, how are you doing?" → "Hey, how are you doing today?"
    static func isGrowingClause(_ earlier: String, toward later: String) -> Bool {
        let a = earlier.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = later.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty || b.isEmpty { return false }
        if b.hasPrefix(a) || a.hasPrefix(b) || self.isSameClause(a, b) { return true }
        let coreA = self.stripTerminalPunctuation(a)
        let coreB = self.stripTerminalPunctuation(b)
        return !coreA.isEmpty && (b.hasPrefix(coreA) || coreB.hasPrefix(coreA))
    }

    /// Live prefetch may paint only while `unit` is this leftover, not an
    /// earlier finished sentence still sitting at the front of it.
    static func isLivePrefetchMatch(unit: String, leftover: String, languageID: String) -> Bool {
        if self.isSameClause(unit, leftover) || leftover == unit { return true }
        guard self.isGrowingClause(unit, toward: leftover) else { return false }
        if let first = self.nextCommitUnit(
            leftover,
            languageID: languageID,
            allowPauseFinalize: false
        )?.unit,
           self.isSameClause(first, unit),
           !self.isSameClause(leftover, unit)
        {
            return false
        }
        return true
    }

    static func stripTerminalPunctuation(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"[.!?,…。？！、]+$"#,
            with: "",
            options: .regularExpression
        )
    }

    /// A fuller ASR pass revised the last committed sentence. Used on pause and Stop.
    static func revisedLastCommitted(
        confirmed: String,
        lastCommitted: String,
        languageID: String
    ) -> String? {
        let confirmed = confirmed.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = lastCommitted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !confirmed.isEmpty, !last.isEmpty else { return nil }
        if self.isSameClause(confirmed, last) { return nil }

        let split = self.split(confirmed, languageID: languageID)
        let head = split.completed.first
            ?? (self.looksComplete(split.tail, languageID: languageID) ? split.tail : nil)
        guard let head, !self.isSameClause(head, last) else { return nil }
        if self.shouldReplaceLast(previous: last, incoming: head) { return head }
        if self.shouldReviseCommitted(previous: last, incoming: head, languageID: languageID) {
            return head
        }
        return nil
    }

    static func shouldReviseCommitted(
        previous: String,
        incoming: String,
        languageID: String
    ) -> Bool {
        if self.shouldReplaceLast(previous: previous, incoming: incoming) { return true }
        let prev = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prev.isEmpty, !next.isEmpty, !self.isSameClause(prev, next) else { return false }
        if self.shouldIgnoreAsStalePrefix(previous: prev, incoming: next) { return false }
        let prevKey = self.normalized(prev)
        let nextKey = self.normalized(next)
        if nextKey.hasPrefix(prevKey) || nextKey.hasPrefix(prevKey + " ") { return false }
        if !self.isCompactScript(languageID) {
            let prevTokens = self.tokens(prev)
            let nextTokens = self.tokens(next)
            // A single substitution in a very short clause ("line 1." → "line
            // 2.") is a huge fraction of the word count even though it is a
            // different sentence, not an ASR self-correction. Below this
            // floor the WER ratio is too noisy to trust.
            guard prevTokens.count >= 4, nextTokens.count >= 4 else { return false }
            guard abs(prevTokens.count - nextTokens.count) <= 1 else { return false }
            if let firstPrev = prevTokens.first, let firstNext = nextTokens.first,
               self.tokenKey(firstPrev) != self.tokenKey(firstNext)
            {
                return false
            }
            let error = TheaterQualityScore.wordErrorRate(reference: prev, hypothesis: next)
            return error > 0 && error <= 0.34
        }
        let prevCount = max(self.stripped(prev).count, 1)
        let nextCount = max(self.stripped(next).count, 1)
        // Same floor as the word-token path above: a one-character swap in a
        // very short clause is a huge fraction of its length even though it
        // is a different sentence, not an ASR self-correction.
        guard prevCount >= 10, nextCount >= 10 else { return false }
        let lengthRatio = Double(min(prevCount, nextCount)) / Double(max(prevCount, nextCount))
        guard lengthRatio >= 0.7 else { return false }
        let error = TheaterQualityScore.characterErrorRate(reference: prev, hypothesis: next)
        return error > 0 && error <= 0.34
    }

    /// Word-for-word containment after the same normalization as `isSameClause`.
    static func contains(_ text: String, clause: String) -> Bool {
        let key = self.normalized(clause)
        guard !key.isEmpty else { return false }
        return (" " + self.normalized(text) + " ").contains(" " + key + " ")
    }

    static func shouldReplaceLast(previous: String, incoming: String) -> Bool {
        let left = self.normalized(previous)
        let right = self.normalized(incoming)
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left == right {
            return previous.trimmingCharacters(in: .whitespacesAndNewlines)
                != incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard right.hasPrefix(left) || right.hasPrefix(left + " ") else { return false }
        if ["en", "ko", "th", "ja"].contains(where: { self.isTooThinToCommit(previous, languageID: $0) }) {
            return true
        }
        if ["en", "ko", "th", "ja"].contains(where: { self.isCommitComplete(previous, languageID: $0) }) {
            return false
        }
        let leftover = self.leftoverTail(incoming, already: [previous])
        if leftover.isEmpty { return true }
        if leftover.count < 3, leftover.allSatisfy({ $0.isNumber || $0.isPunctuation }) {
            return false
        }
        if ["en", "ko", "th", "ja"].contains(where: {
            self.looksComplete(leftover, languageID: $0)
                || self.shouldFollowAlong(leftover, languageID: $0)
                || self.isPauseFinalizable(leftover, languageID: $0)
        }) {
            return false
        }
        return self.split(leftover, languageID: "en").completed.isEmpty
    }

    static func shouldIgnoreAsStalePrefix(previous: String, incoming: String) -> Bool {
        let left = self.normalized(previous)
        let right = self.normalized(incoming)
        guard !left.isEmpty, !right.isEmpty, left != right else { return false }
        return left.hasPrefix(right) || left.hasPrefix(right + " ")
    }

    static func unreadCompleted(completed: [String], already: [String]) -> [String] {
        if already.isEmpty { return completed }

        var additions: [String] = []
        var alreadyIndex = 0

        for seen in completed {
            if alreadyIndex < already.count, self.isSameClause(already[alreadyIndex], seen) {
                if alreadyIndex == already.count - 1,
                   self.shouldReplaceLast(previous: already[alreadyIndex], incoming: seen)
                {
                    additions.append(seen)
                }
                alreadyIndex += 1
                continue
            }
            if let last = already.last, self.shouldReplaceLast(previous: last, incoming: seen) {
                additions.append(seen)
                alreadyIndex = already.count
                continue
            }
            if already.contains(where: { self.isSameClause($0, seen) }) {
                continue
            }
            if already.contains(where: { self.shouldIgnoreAsStalePrefix(previous: $0, incoming: seen) }) {
                continue
            }
            additions.append(seen)
        }
        return additions
    }

    /// ASR partials are cumulative. After a clause is committed, only the leftover
    /// suffix should stay open. Otherwise Theater re-translates the whole talk.
    static func leftoverTail(_ text: String, already: [String], languageID: String = "") -> String {
        var remainder = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let afterLast = self.consumeAfterLastPrinted(remainder, already: already) {
            remainder = afterLast
        } else {
            let fast = self.consumeLeadingChunks(remainder, chunks: already)
            remainder = fast.remainder
            for chunk in already.dropFirst(fast.consumed) {
                if let next = self.consumePrefix(remainder, prefix: chunk) {
                    remainder = next
                    continue
                }
                if self.looksLikeRevisedPrefix(text: remainder, prefix: chunk),
                   let next = self.consumeApproximatePrefix(remainder, prefix: chunk)
                {
                    remainder = next
                    continue
                }
                if !self.containsPrintedClause(remainder, chunk: chunk) {
                    continue
                }
                break
            }
        }
        remainder = self.stripLeadingBoundaries(remainder)
        if !languageID.isEmpty {
            remainder = self.peelPrintedLeadingClauses(
                remainder,
                already: already,
                languageID: languageID,
                intactInText: already.filter { self.contains(text, clause: $0) }
            )
        }
        remainder = self.peelLeadingPrintedCopies(remainder, already: already)
        return self.collapseRepeatedSpeech(
            remainder,
            languageID: languageID.isEmpty ? "en" : languageID
        )
    }

    /// Whisper often restates the last clause. Keep one copy on the live row.
    static func collapseRepeatedSpeech(_ text: String, languageID: String) -> String {
        var remainder = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var steps = 0
        while steps < 16, !remainder.isEmpty {
            steps += 1
            if let next = self.dropLeadingRepeatedClause(remainder, languageID: languageID),
               next != remainder
            {
                remainder = next
                continue
            }
            if let next = self.dropLeadingRepeatedPhrase(remainder), next != remainder {
                remainder = next
                continue
            }
            break
        }
        return remainder
    }

    /// Mid-talk unit: finished and not thin, with unread speech after it.
    /// Skips `It.` via `looksComplete`. Does not use `isShortSpokenStop`.
    static func nextCompletedSentence(
        _ text: String,
        languageID: String
    ) -> (unit: String, rest: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let split = self.absorbThinCompleted(self.split(trimmed, languageID: languageID), languageID: languageID)
        guard let first = split.completed.first,
              !self.isTooThinToCommit(first, languageID: languageID)
        else {
            return nil
        }
        // An unpunctuated run-on past the draft cap was force-cut by `split`.
        // Print that head while talking; otherwise nothing prints until a pause.
        let isForcedCut = trimmed.count >= LiveTranslationTiming.maxDraftCharacters
        guard self.looksComplete(first, languageID: languageID) || isForcedCut else {
            return nil
        }
        let rest = self.remainder(after: first, split: split, original: trimmed, languageID: languageID)
        guard !rest.isEmpty else { return nil }
        return (first, rest)
    }

    /// Pause / Stop leftover unit. Follow-along and pause-finalize live here.
    /// Never returns the whole remaining talk when more than one clause is sitting.
    static func nextCommitUnit(
        _ text: String,
        languageID: String,
        allowPauseFinalize: Bool
    ) -> (unit: String, rest: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let split = self.absorbThinCompleted(self.split(trimmed, languageID: languageID), languageID: languageID)
        if let first = split.completed.first, !self.isTooThinToCommit(first, languageID: languageID) {
            return (first, self.remainder(after: first, split: split, original: trimmed, languageID: languageID))
        }
        if self.looksComplete(split.tail, languageID: languageID) {
            return self.singleClause(split.tail, languageID: languageID)
        }
        if self.shouldFollowAlong(split.tail, languageID: languageID) {
            let cut = self.followAlongCut(split.tail, languageID: languageID)
            guard !cut.head.isEmpty else { return nil }
            return (unit: cut.head, rest: cut.rest)
        }
        if allowPauseFinalize,
           self.isReadyToCommit(split.tail, languageID: languageID, allowPauseFinalize: true)
        {
            let cut = self.followAlongCut(split.tail, languageID: languageID)
            guard !cut.head.isEmpty else { return nil }
            return (unit: cut.head, rest: cut.rest)
        }
        return nil
    }

    /// Commit-time lineCut of leftover. Live display uses the full leftover.
    static func liveOpenText(_ leftover: String, languageID: String) -> String {
        let trimmed = leftover.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return self.currentSpokenLine(trimmed, languageID: languageID)
    }

    /// Finished sentences stay on their own rows. The open line is the one still being said.
    static func livePreview(_ leftover: String, languageID: String) -> LivePreview {
        let trimmed = leftover.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return LivePreview(pinned: [], open: "") }
        let split = self.absorbShortCompleted(
            self.absorbThinCompleted(self.split(trimmed, languageID: languageID), languageID: languageID),
            languageID: languageID
        )
        let completed = split.completed.filter { !self.isTooThinToCommit($0, languageID: languageID) }
        if completed.isEmpty {
            let open = split.tail.isEmpty ? trimmed : split.tail
            return LivePreview(pinned: [], open: self.currentSpokenLine(open, languageID: languageID))
        }
        if split.tail.isEmpty {
            if completed.count == 1 {
                return LivePreview(
                    pinned: [],
                    open: self.currentSpokenLine(completed[0], languageID: languageID)
                )
            }
            return LivePreview(
                pinned: Array(completed.dropLast()),
                open: self.currentSpokenLine(completed.last ?? "", languageID: languageID)
            )
        }
        return LivePreview(
            pinned: completed,
            open: self.currentSpokenLine(split.tail, languageID: languageID)
        )
    }

    /// Next clause that is not already on Theater. Cumulative ASR still starts
    /// with printed sentences; never commit that blob as one line.
    static func printableCommitUnit(
        _ text: String,
        already: [String],
        languageID: String,
        allowPauseFinalize: Bool
    ) -> String? {
        var remaining = self.leftoverTail(text, already: already, languageID: languageID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if remaining.isEmpty { return nil }

        var steps = 0
        while steps < 32, !remaining.isEmpty {
            steps += 1
            guard let next = self.nextCommitUnit(
                remaining,
                languageID: languageID,
                allowPauseFinalize: allowPauseFinalize
            ) else {
                return nil
            }
            let unit = next.unit.trimmingCharacters(in: .whitespacesAndNewlines)
            let peeled = self.leftoverTail(unit, already: already, languageID: languageID)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if peeled.isEmpty
                || self.isAlreadyPrintedSource(unit, already: already, languageID: languageID)
            {
                if next.rest == remaining { return nil }
                remaining = next.rest
                continue
            }
            if peeled != unit {
                remaining = peeled
                continue
            }
            return unit
        }
        return nil
    }

    static func isAlreadyPrintedSource(
        _ source: String,
        already: [String],
        languageID: String = ""
    ) -> Bool {
        let cleaned = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return true }
        if already.contains(where: { self.isSameClause($0, cleaned) }) { return true }
        if already.contains(where: { self.shouldIgnoreAsStalePrefix(previous: $0, incoming: cleaned) }) {
            return true
        }
        if already.dropLast().contains(where: {
            self.shouldReviseCommitted(previous: $0, incoming: cleaned, languageID: languageID)
        }) {
            return true
        }
        return self.leftoverTail(cleaned, already: already, languageID: languageID).isEmpty
    }

    /// Join committed translations for typing or history.
    static func joinTranslatedLines(_ lines: [String], languageID: String) -> String {
        let cleaned = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        switch self.languageCode(from: languageID) {
        case "ko", "th", "ja", "zh":
            return cleaned.joined()
        default:
            return cleaned.joined(separator: " ")
        }
    }
}

extension TranslationClauseSegmenter {
    fileprivate static let terminalPunctuation = CharacterSet(charactersIn: ".!?。！？…")

    fileprivate static let koreanCommitEndings: [String] = [
        "습니까", "습니다", "ㅂ니까", "ㅂ니다", "입니다",
        "이에요", "예요", "어요", "아요", "해요",
        "십시오", "세요", "죠",
    ]

    fileprivate static let koreanInternalEndings: [String] = [
        "거든요", "잖아요", "는데요", "네요", "군요",
        "할게요", "을게요", "게요", "니까", "을까", "할까", "일까",
        "했다", "였다", "았다", "었다", "인다", "는다", "된다",
    ]

    fileprivate static let shortKoreanEndings: Set<String> = ["죠"]

    fileprivate static let japaneseEndings: [String] = [
        "ました", "ましたか", "です", "でした", "ません", "ます", "でしょうか",
    ]

    fileprivate static let japaneseConnectiveEndings: [String] = [
        "ので", "けれど", "けど", "から",
    ]

    fileprivate static let thaiCommitEndings: [String] = [
        "ครับผม", "ครับ", "ค่ะ", "คะ",
    ]

    fileprivate static let thaiInternalEndings: [String] = [
        "จ้ะ", "นะ", "เลย", "ไหม", "มั้ย", "ด้วย", "แล้ว", "ล่ะ", "สิ",
    ]

    fileprivate static let thaiEndings: [String] = Self.thaiCommitEndings + Self.thaiInternalEndings

    fileprivate static let shortThaiEndings: Set<String> = ["นะ", "สิ"]

    fileprivate static func isBoundary(in text: String, at index: String.Index, languageID _: String) -> Bool {
        let character = text[index]
        let next = text.index(after: index)
        let atEnd = next == text.endIndex
        let followedBySpace = !atEnd && text[next].isWhitespace

        if let scalar = character.unicodeScalars.first, Self.terminalPunctuation.contains(scalar) {
            if character == ".", self.isDecimalPoint(in: text, at: index) {
                return false
            }
            if atEnd || followedBySpace || self.isTerminal(text[next]) {
                return true
            }
            return !atEnd && self.looksLikeSentenceBreak(in: text, at: index)
        }

        return false
    }

    /// ASR often restitches "Hello.Then we" with no space after the period.
    /// Treat that as a sentence break so leftover cannot dump as one line.
    fileprivate static func looksLikeSentenceBreak(in text: String, at index: String.Index) -> Bool {
        let next = text.index(after: index)
        guard next < text.endIndex else { return false }
        let following = text[next]
        guard following.isLetter || following.isNumber else { return false }

        var start = index
        while start > text.startIndex {
            let previous = text.index(before: start)
            if text[previous].isWhitespace { break }
            if let scalar = text[previous].unicodeScalars.first,
               Self.terminalPunctuation.contains(scalar)
            {
                break
            }
            start = previous
        }
        let token = text[start..<index]
        if following.isUppercase {
            return token.count > 1
        }
        return token.count >= 4
    }

    fileprivate static func isTerminal(_ character: Character) -> Bool {
        character.unicodeScalars.contains { Self.terminalPunctuation.contains($0) }
    }

    fileprivate static func isDecimalPoint(in text: String, at index: String.Index) -> Bool {
        guard text[index] == ".", index > text.startIndex else { return false }
        let previous = text.index(before: index)
        let next = text.index(after: index)
        guard next < text.endIndex else { return false }
        return text[previous].isNumber && text[next].isNumber
    }

    fileprivate static func hasJapanesePredicateEnding(_ text: String) -> Bool {
        if let last = text.last, last == "か" || last == "だ" || last == "よ" {
            return true
        }
        return self.hasEnding(text, endings: Self.japaneseEndings)
    }

    fileprivate static func hasEnding(_ text: String, endings: [String]) -> Bool {
        let folded = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return endings.contains { ending in
            self.matchesEnding(folded, ending: ending)
                || self.matchesEnding(folded, ending: ending + ".")
                || self.matchesEnding(folded, ending: ending + "?")
        }
    }

    fileprivate static func matchesEnding(_ text: String, ending: String) -> Bool {
        if text.hasSuffix(ending) {
            let bare = ending.trimmingCharacters(in: CharacterSet(charactersIn: ".?"))
            if Self.shortKoreanEndings.contains(bare) || Self.shortThaiEndings.contains(bare) || bare.count <= 1 {
                return self.hasScriptBoundary(beforeSuffix: ending, in: text)
            }
            return true
        }
        return self.matchesHangulBatchimEnding(text, ending: ending)
    }

    /// `갑니까` ends with the ㅂ니까 ending even though 갑 is one composed syllable.
    fileprivate static func matchesHangulBatchimEnding(_ text: String, ending: String) -> Bool {
        guard let first = ending.first, let jongseong = Self.hangulCompatibilityJongseong[first] else {
            return false
        }
        let rest = String(ending.dropFirst())
        guard !rest.isEmpty, text.hasSuffix(rest) else { return false }
        let stemEnd = text.index(text.endIndex, offsetBy: -rest.count)
        guard stemEnd > text.startIndex else { return false }
        let syllable = text[text.index(before: stemEnd)]
        guard let scalar = syllable.unicodeScalars.first else { return false }
        let value = scalar.value
        guard (0xAC00...0xD7A3).contains(value) else { return false }
        return (value - 0xAC00) % 28 == jongseong
    }

    /// Compatibility jamo → Hangul syllable jongseong index (`ㅂ` = 17).
    fileprivate static let hangulCompatibilityJongseong: [Character: UInt32] = [
        "ㄱ": 1, "ㄲ": 2, "ㄳ": 3, "ㄴ": 4, "ㄵ": 5, "ㄶ": 6, "ㄷ": 7,
        "ㄹ": 8, "ㄺ": 9, "ㄻ": 10, "ㄼ": 11, "ㄽ": 12, "ㄾ": 13, "ㄿ": 14,
        "ㅀ": 15, "ㅁ": 16, "ㅂ": 17, "ㅄ": 18, "ㅅ": 19, "ㅆ": 20, "ㅇ": 21,
        "ㅈ": 22, "ㅊ": 23, "ㅋ": 24, "ㅌ": 25, "ㅍ": 26, "ㅎ": 27,
    ]

    fileprivate static func hasScriptBoundary(beforeSuffix suffix: String, in text: String) -> Bool {
        guard text.count > suffix.count else { return false }
        let previous = text[text.index(text.endIndex, offsetBy: -suffix.count - 1)]
        if Self.shortKoreanEndings.contains(suffix.trimmingCharacters(in: CharacterSet(charactersIn: ".?"))) {
            return previous.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) }
        }
        if Self.shortThaiEndings.contains(suffix.trimmingCharacters(in: CharacterSet(charactersIn: ".?"))) {
            return previous.unicodeScalars.contains { (0x0E00...0x0E7F).contains($0.value) }
        }
        return previous.isLetter || previous.isNumber
    }

    /// Peel finished Korean/Japanese/Thai clauses when more speech already follows.
    /// The last open piece stays in the tail so ASR can still revise it.
    fileprivate static func peelCompletedInternalClauses(_ text: String, languageID: String) -> Split {
        switch self.languageCode(from: languageID) {
        case "ko", "ja", "th":
            break
        default:
            return Split(completed: [], tail: text)
        }

        var completed: [String] = []
        var start = text.startIndex
        var index = text.startIndex

        while index < text.endIndex {
            let next = text.index(after: index)
            let piece = String(text[start..<next])
            if self.isInternalBoundary(piece, languageID: languageID), next < text.endIndex {
                var restStart = next
                while restStart < text.endIndex, text[restStart].isWhitespace {
                    restStart = text.index(after: restStart)
                }
                if restStart < text.endIndex,
                   self.shouldPeelBeforeRemainder(String(text[restStart...]), languageID: languageID)
                {
                    let head = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !head.isEmpty {
                        completed.append(head)
                        start = restStart
                        index = restStart
                        continue
                    }
                }
            }
            index = next
        }

        let tail = start < text.endIndex
            ? String(text[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        return Split(completed: completed, tail: tail)
    }

    fileprivate static func shouldPeelBeforeRemainder(_ remainder: String, languageID: String) -> Bool {
        let rest = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rest.count >= 2 else { return false }
        switch self.languageCode(from: languageID) {
        case "ko":
            let first = String(rest.prefix(1))
            return !Self.koreanConnectiveStarts.contains(first)
        case "th":
            return !Self.thaiEndings.contains(where: { rest.hasPrefix($0) })
        case "ja":
            let first = String(rest.prefix(1))
            return !["か", "よ", "ね", "が"].contains(first)
        default:
            return true
        }
    }

    fileprivate static let koreanConnectiveStarts: Set<String> = [
        "고", "만", "면", "서", "니", "며", "요", "도", "나", "든",
    ]

    fileprivate static func consumeApproximatePrefix(_ text: String, prefix: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixN = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !prefixN.isEmpty else { return trimmed }
        guard self.looksLikeRevisedPrefix(text: trimmed, prefix: prefixN) else { return nil }
        guard let anchor = self.clauseAnchor(prefixN) else { return nil }

        let range = trimmed.range(of: anchor)
            ?? trimmed.range(of: anchor, options: [.caseInsensitive])
        guard let range else { return nil }

        var end = range.upperBound
        while end < trimmed.endIndex,
              let scalar = trimmed[end].unicodeScalars.first,
              Self.terminalPunctuation.contains(scalar)
        {
            end = trimmed.index(after: end)
        }

        let matched = String(trimmed[..<end])
        let matchedCount = self.stripped(matched).count
        let prefixCount = max(self.stripped(prefixN).count, 1)
        let ratio = Double(matchedCount) / Double(prefixCount)
        guard (0.7...1.6).contains(ratio) else { return nil }
        return String(trimmed[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Approximate peel is only for a revised *prefix*. A later sentence that
    /// happens to share a last word ("model") must not eat the new clause.
    fileprivate static func looksLikeRevisedPrefix(text: String, prefix: String) -> Bool {
        let textTokens = self.tokens(text)
        let prefixTokens = self.tokens(prefix)
        if let firstText = textTokens.first, let firstPrefix = prefixTokens.first,
           self.tokenKey(firstText) == self.tokenKey(firstPrefix)
        {
            return true
        }
        let textKey = self.stripped(text)
        let prefixKey = self.stripped(prefix)
        let head = String(prefixKey.prefix(min(8, prefixKey.count)))
        return !head.isEmpty && textKey.hasPrefix(head)
    }

    fileprivate static func stripLeadingBoundaries(_ text: String) -> String {
        var remainder = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = remainder.unicodeScalars.first, Self.terminalPunctuation.contains(first) {
            remainder.removeFirst()
            remainder = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return remainder
    }

    /// Peel a committed clause that still sits later in a cumulative ASR transcript
    /// (previous-listen prefix, or a restitch that no longer starts at the clause).
    fileprivate static func consumeEmbeddedClause(_ text: String, prefix: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixN = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, prefixN.count >= 8 else { return nil }
        let prefixWords = self.tokens(prefixN)
        if prefixN.contains(where: { $0.isWhitespace }), prefixWords.count < 3 {
            return nil
        }
        guard let range = trimmed.range(of: prefixN)
            ?? trimmed.range(of: prefixN, options: .caseInsensitive)
        else { return nil }
        if range.lowerBound > trimmed.startIndex {
            let before = trimmed[trimmed.startIndex..<range.lowerBound]
            guard let last = before.last else { return nil }
            let boundary = last.isWhitespace
                || self.isTerminal(last)
                || self.looksComplete(String(before), languageID: "ko")
                || self.looksComplete(String(before), languageID: "th")
                || self.looksComplete(String(before), languageID: "ja")
            guard boundary else { return nil }
        }
        var end = range.upperBound
        while end < trimmed.endIndex,
              let scalar = trimmed[end].unicodeScalars.first,
              Self.terminalPunctuation.contains(scalar)
        {
            end = trimmed.index(after: end)
        }
        return self.stripLeadingBoundaries(String(trimmed[end...]))
    }

    fileprivate static func clauseAnchor(_ text: String) -> String? {
        let tokens = self.tokens(text)
        if let last = tokens.last {
            let key = self.tokenKey(last)
            if key.count >= 4 {
                return last.trimmingCharacters(in: CharacterSet.punctuationCharacters)
            }
            if tokens.count >= 2 {
                let pair = tokens.suffix(2).joined(separator: " ")
                if pair.count >= 6 {
                    return pair
                }
            }
        }
        if text.count >= 6 {
            return String(text.suffix(6)).trimmingCharacters(in: CharacterSet.punctuationCharacters)
        }
        return text.count >= 4 ? text : nil
    }

    fileprivate static func remainder(
        after first: String,
        split: Split,
        original: String,
        languageID: String
    ) -> String {
        let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let leftover = self.leftoverTail(trimmed, already: [first], languageID: languageID)
        if leftover != trimmed {
            return leftover
        }
        if trimmed.hasPrefix(first) {
            return String(trimmed.dropFirst(first.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var parts = Array(split.completed.dropFirst())
        if !split.tail.isEmpty {
            parts.append(split.tail)
        }
        if trimmed.contains(where: { $0.isWhitespace }) {
            return parts.joined(separator: " ")
        }
        return parts.joined()
    }

    /// Drop leading clauses Theater already printed so a restitch cannot
    /// reopen the last few sentences as one live line.
    /// `intactInText`: printed lines still word-for-word in the full text. A
    /// clause merely similar to one of those is new speech, not a correction.
    fileprivate static func peelPrintedLeadingClauses(
        _ text: String,
        already: [String],
        languageID: String,
        intactInText: [String] = []
    ) -> String {
        var remainder = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var steps = 0
        while steps < 32, !remainder.isEmpty {
            steps += 1
            let split = self.split(remainder, languageID: languageID)
            guard let first = split.completed.first else { break }
            let printed = already.contains {
                self.isSameClause($0, first)
                    || self.shouldIgnoreAsStalePrefix(previous: $0, incoming: first)
                    || (
                        !intactInText.contains($0)
                            && self.shouldReviseCommitted(
                                previous: $0,
                                incoming: first,
                                languageID: languageID
                            )
                            && !self.shouldReplaceLast(previous: $0, incoming: first)
                    )
            }
            guard printed else { break }
            if let last = already.last,
               self.shouldReplaceLast(previous: last, incoming: first),
               !already.dropLast().contains(where: { self.isSameClause($0, first) })
            {
                break
            }
            let next = self.remainder(after: first, split: split, original: remainder, languageID: languageID)
            if next == remainder { break }
            remainder = next
        }
        return self.stripLeadingBoundaries(remainder)
    }

    /// consumeAfterLastPrinted can leave a second copy that lost its period.
    fileprivate static func peelLeadingPrintedCopies(_ text: String, already: [String]) -> String {
        var remainder = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var steps = 0
        while steps < 32, !remainder.isEmpty {
            steps += 1
            var peeled = false
            for chunk in already {
                guard let next = self.consumePrefix(remainder, prefix: chunk) else { continue }
                let stripped = self.stripLeadingBoundaries(next)
                if stripped != remainder {
                    remainder = stripped
                    peeled = true
                    break
                }
            }
            if !peeled { break }
        }
        return remainder
    }

    fileprivate static func dropLeadingRepeatedClause(_ text: String, languageID: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let split = self.absorbThinCompleted(self.split(trimmed, languageID: languageID), languageID: languageID)
        guard let first = split.completed.first else { return nil }
        guard let after = self.consumePrefix(trimmed, prefix: first) else { return nil }
        let rest = self.stripLeadingBoundaries(after)
        guard !rest.isEmpty else { return nil }
        if rest.hasPrefix(first) { return rest }
        if self.consumePrefix(rest, prefix: first) != nil { return rest }
        if split.completed.count >= 2, self.isSameClause(first, split.completed[1]) { return rest }
        let restSplit = self.absorbThinCompleted(self.split(rest, languageID: languageID), languageID: languageID)
        if let again = restSplit.completed.first, self.isSameClause(first, again) { return rest }
        return nil
    }

    fileprivate static func dropLeadingRepeatedPhrase(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = trimmed
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map(String.init)
        if tokens.count >= 2, let dropped = self.dropRepeatedTokenPrefix(tokens) {
            return dropped
        }
        guard !trimmed.contains(where: { $0.isWhitespace }), trimmed.count >= 6 else { return nil }
        let characters = Array(trimmed)
        let maxN = characters.count / 2
        guard maxN >= 3 else { return nil }
        for length in stride(from: min(maxN, 24), through: 3, by: -1) {
            let first = String(characters[0..<length])
            let second = String(characters[length..<(length * 2)])
            if first == second, Set(first).count > 1 {
                return String(characters[length...])
            }
        }
        return nil
    }

    fileprivate static func dropRepeatedTokenPrefix(_ tokens: [String]) -> String? {
        let maxN = tokens.count / 2
        guard maxN >= 1 else { return nil }
        let keys = tokens.map(self.tokenKey)
        for count in stride(from: maxN, through: 1, by: -1) {
            if count == 1 {
                guard tokens[0].count >= 4 else { continue }
            }
            if keys[0..<count].elementsEqual(keys[count..<(count * 2)]) {
                return tokens[count...].joined(separator: " ")
            }
        }
        return nil
    }

    /// Bound the live caption to one spoken line so an unpunctuated restitch
    /// cannot type out the last few sentences at once. Keep the prefix so the
    /// line grows in place instead of sliding the last N words.
    fileprivate static func currentSpokenLine(_ text: String, languageID: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return self.lineCut(trimmed, languageID: languageID).head
    }

    /// A finished tail can still be several clauses if ASR omitted spaces.
    /// Never return that whole leftover as one Theater line.
    fileprivate static func singleClause(
        _ text: String,
        languageID _: String
    ) -> (unit: String, rest: String) {
        if text.count >= LiveTranslationTiming.maxDraftCharacters {
            let cut = self.forceCut(text)
            return (cut.head, cut.rest)
        }
        return (text, "")
    }

    /// Whisper restitch still starts at sentence one. The unread leftover is
    /// everything after the last printed clause, including when earlier
    /// sentences have already left the board.
    fileprivate static func consumeAfterLastPrinted(_ text: String, already: [String]) -> String? {
        for chunk in already.reversed() {
            if let after = self.consumeLastOccurrence(text, chunk: chunk) {
                return after
            }
        }
        return nil
    }

    fileprivate static func consumeLastOccurrence(_ text: String, chunk: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixN = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !prefixN.isEmpty else { return nil }

        if let range = trimmed.range(
            of: prefixN,
            options: [.caseInsensitive, .diacriticInsensitive, .backwards]
        ) {
            return String(trimmed[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let textTokens = self.tokens(trimmed)
        let chunkTokens = self.tokens(prefixN)
        if !chunkTokens.isEmpty, textTokens.count >= chunkTokens.count {
            let textKeys = textTokens.map(self.tokenKey)
            let chunkKeys = chunkTokens.map(self.tokenKey)
            if chunkKeys.allSatisfy({ !$0.isEmpty }) {
                var start = textKeys.count - chunkKeys.count
                while start >= 0 {
                    let slice = textKeys[start..<(start + chunkKeys.count)]
                    if zip(slice, chunkKeys).allSatisfy({ $0 == $1 }) {
                        return textTokens.dropFirst(start + chunkKeys.count).joined(separator: " ")
                    }
                    start -= 1
                }
            }
        }

        let needle = self.stripped(prefixN)
        guard needle.count >= 8 else { return nil }
        let haystack = self.stripped(trimmed)
        guard let range = haystack.range(of: needle, options: .backwards) else { return nil }
        let afterLetters = haystack.distance(from: range.upperBound, to: haystack.endIndex)
        return self.suffixKeepingLetters(trimmed, letterCount: afterLetters)
    }

    fileprivate static func suffixKeepingLetters(_ text: String, letterCount: Int) -> String {
        guard letterCount > 0 else { return "" }
        var kept = 0
        var index = text.endIndex
        while index > text.startIndex, kept < letterCount {
            index = text.index(before: index)
            let character = text[index]
            if character.isLetter || character.isNumber {
                kept += 1
            }
        }
        return String(text[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    fileprivate static func containsPrintedClause(_ text: String, chunk: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixN = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !prefixN.isEmpty else { return false }
        if trimmed.range(of: prefixN, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
            return true
        }
        let needle = self.stripped(prefixN)
        let haystack = self.stripped(trimmed)
        return needle.count >= 6 && haystack.contains(needle)
    }

    /// Prefer a comma or connective so a follow-along line does not end on "the".
    fileprivate static func followAlongCut(_ text: String, languageID: String) -> (head: String, rest: String) {
        let hard = self.lineCut(text, languageID: languageID)
        guard !hard.head.isEmpty else { return hard }
        if let breath = self.breathHead(in: hard.head, languageID: languageID) {
            let leftoverHead = String(hard.head.dropFirst(breath.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let rest = [leftoverHead, hard.rest].filter { !$0.isEmpty }.joined(separator: " ")
            return (breath, rest)
        }
        return self.retractTrailingThin(head: hard.head, rest: hard.rest, languageID: languageID)
    }

    fileprivate static func breathHead(in head: String, languageID: String) -> String? {
        if self.isCompactScript(languageID) {
            let peeled = self.peelCompletedInternalClauses(head, languageID: languageID)
            if let first = peeled.completed.first, !peeled.tail.isEmpty, !self.isTooThinToCommit(first, languageID: languageID) {
                return first
            }
            return nil
        }
        if let comma = self.lastPunctuationBreath(in: head) {
            return comma
        }
        return self.lastConjunctionBreath(in: head)
    }

    fileprivate static func lastPunctuationBreath(in head: String) -> String? {
        let marks = CharacterSet(charactersIn: ",;:")
        guard let index = head.lastIndex(where: { character in
            character.unicodeScalars.contains { marks.contains($0) }
        }) else {
            return nil
        }
        let left = String(head[...index]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard self.tokens(left).count >= LiveTranslationTiming.minPauseFinalizeWords else {
            return nil
        }
        return left
    }

    fileprivate static func lastConjunctionBreath(in head: String) -> String? {
        let words = self.tokens(head)
        guard words.count >= LiveTranslationTiming.minPauseFinalizeWords + 1 else { return nil }
        let connectives: Set<String> = ["and", "but", "so", "then", "or"]
        for index in stride(from: words.count - 1, through: 1, by: -1) {
            guard connectives.contains(self.tokenKey(words[index])) else { continue }
            var cut = index
            while cut > 1, connectives.contains(self.tokenKey(words[cut - 1])) {
                cut -= 1
            }
            guard cut >= LiveTranslationTiming.minPauseFinalizeWords else { continue }
            let left = words.prefix(cut).joined(separator: " ")
            guard !self.isTooThinToCommit(left, languageID: "en") else { continue }
            return left
        }
        return nil
    }

    fileprivate static func retractTrailingThin(
        head: String,
        rest: String,
        languageID: String
    ) -> (head: String, rest: String) {
        if self.isCompactScript(languageID) { return (head, rest) }
        var words = self.tokens(head)
        var pulled: [String] = []
        let floor = max(LiveTranslationTiming.minPauseFinalizeWords, LiveTranslationTiming.followAlongWords / 2)
        while words.count > floor, let last = words.last {
            guard self.isThinEnglishStarter(last) || self.isThinEnglishAuxiliary(last) else { break }
            pulled.insert(last, at: 0)
            words.removeLast()
        }
        guard !pulled.isEmpty else { return (head, rest) }
        let nextHead = words.joined(separator: " ")
        let nextRest = (pulled + self.tokens(rest)).joined(separator: " ")
        return (nextHead, nextRest)
    }

    fileprivate static func lineCut(_ text: String, languageID: String) -> (head: String, rest: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if self.isCompactScript(languageID) {
            if trimmed.count <= LiveTranslationTiming.maxLineCharacters {
                return (trimmed, "")
            }
            return self.cut(trimmed, limit: LiveTranslationTiming.maxLineCharacters)
        }
        let words = self.tokens(trimmed)
        if words.count <= LiveTranslationTiming.maxLineWords {
            return (trimmed, "")
        }
        let head = words.prefix(LiveTranslationTiming.maxLineWords).joined(separator: " ")
        let rest = words.dropFirst(LiveTranslationTiming.maxLineWords).joined(separator: " ")
        return (head, rest)
    }

    fileprivate static func forceCut(_ text: String) -> (head: String, rest: String) {
        self.cut(text, limit: LiveTranslationTiming.maxDraftCharacters)
    }

    fileprivate static func cut(_ text: String, limit: Int) -> (head: String, rest: String) {
        guard text.count > limit else { return (text, "") }

        let headLimit = text.index(text.startIndex, offsetBy: limit)
        var cut = headLimit
        if let space = text[..<headLimit].lastIndex(where: { $0.isWhitespace }) {
            cut = space
        }
        let head = String(text[text.startIndex..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
        let rest = String(text[cut...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if head.isEmpty {
            return (String(text[text.startIndex..<headLimit]), String(text[headLimit...]))
        }
        return (head, rest)
    }

    fileprivate static func normalized(_ text: String) -> String {
        self.stripped(text)
    }

    fileprivate static func consumePrefix(_ text: String, prefix: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixN = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !prefixN.isEmpty else { return trimmed }

        // A live ASR transcript is cumulative, so it usually still literally starts
        // with the clause just printed. Everything below rescans the whole
        // transcript, which a 200 ms tick cannot afford once the board is long.
        if trimmed.hasPrefix(prefixN) {
            return String(trimmed.dropFirst(prefixN.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let textTokens = self.tokens(trimmed)
        let prefixTokens = self.tokens(prefixN)
        if !prefixTokens.isEmpty,
           textTokens.count >= prefixTokens.count,
           zip(textTokens, prefixTokens).allSatisfy({ self.tokenKey($0) == self.tokenKey($1) })
        {
            return textTokens.dropFirst(prefixTokens.count).joined(separator: " ")
        }

        if self.stripped(trimmed) == self.stripped(prefixN) { return "" }

        if let leftover = self.dropWhileMatching(trimmed, prefix: prefixN, using: self.normalized) {
            return leftover
        }
        return self.dropWhileMatching(trimmed, prefix: prefixN, using: self.stripped)
    }

    /// Peel as many leading printed clauses as possible from one tokenization.
    /// The per-chunk scanners below rescan the whole transcript, so doing this
    /// first keeps a long board off the critical path of every ASR tick.
    fileprivate static func consumeLeadingChunks(
        _ text: String,
        chunks: [String]
    ) -> (remainder: String, consumed: Int) {
        guard !chunks.isEmpty else { return (text, 0) }
        let textTokens = self.tokens(text)
        guard !textTokens.isEmpty else { return (text, 0) }
        let keys = textTokens.map(self.tokenKey)

        var index = 0
        var consumed = 0
        for chunk in chunks {
            let chunkKeys = self.tokens(chunk).map(self.tokenKey)
            guard !chunkKeys.isEmpty, index + chunkKeys.count <= keys.count else { break }
            var matches = true
            for offset in 0..<chunkKeys.count where keys[index + offset] != chunkKeys[offset] {
                matches = false
                break
            }
            guard matches else { break }
            index += chunkKeys.count
            consumed += 1
        }

        guard consumed > 0 else { return (text, 0) }
        return (textTokens[index...].joined(separator: " "), consumed)
    }

    fileprivate static func dropWhileMatching(
        _ text: String,
        prefix: String,
        using fold: (String) -> String
    ) -> String? {
        let target = fold(prefix)
        guard !target.isEmpty else { return text }

        var built = ""
        var index = text.startIndex
        while index < text.endIndex {
            built.append(text[index])
            index = text.index(after: index)
            if fold(built) == target {
                return String(text[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    fileprivate static let thinEnglishStarters: Set<String> = [
        "a", "an", "and", "as", "at", "because", "but", "for", "from", "he",
        "here", "i", "if", "in", "it", "its", "just", "like", "my", "now",
        "of", "on", "or", "our", "she", "so", "the", "then", "there", "they",
        "this", "that", "to", "uh", "um", "we", "well", "when", "with", "your",
    ]

    fileprivate static let thinEnglishAuxiliaries: Set<String> = [
        "am", "are", "be", "been", "being", "can", "could", "did", "do", "does",
        "had", "has", "have", "is", "shall", "should", "was", "were", "will", "would",
    ]

    fileprivate static func isThinEnglishAuxiliary(_ word: String) -> Bool {
        Self.thinEnglishAuxiliaries.contains(self.tokenKey(word))
    }

    /// Whisper often plants a period after five or six words. Fold that last
    /// stub back into the open tail while more speech is already arriving.
    fileprivate static func absorbShortCompleted(_ split: Split, languageID: String) -> Split {
        guard split.completed.count > 1,
              let last = split.completed.last,
              !split.tail.isEmpty,
              self.isShortSpokenStop(last, languageID: languageID)
        else {
            return split
        }
        var completed = split.completed
        let held = completed.removeLast()
        return Split(
            completed: completed,
            tail: self.joinTranslatedLines([held, split.tail], languageID: languageID)
        )
    }

    static func isShortSpokenStop(_ text: String, languageID: String) -> Bool {
        if self.isTooThinToCommit(text, languageID: languageID) { return true }
        if self.isCompactScript(languageID) {
            let marks = text.filter { character in
                character.unicodeScalars.contains { Self.terminalPunctuation.contains($0) }
            }
            return !marks.isEmpty
                && text.filter { !$0.isWhitespace }.count < 16
        }
        return self.tokens(text).count < LiveTranslationTiming.followAlongWords
    }

    fileprivate static func absorbThinCompleted(_ split: Split, languageID: String) -> Split {
        var completed = split.completed
        var prefix: [String] = []
        while let first = completed.first, self.isTooThinToCommit(first, languageID: languageID) {
            prefix.append(completed.removeFirst())
        }
        guard !prefix.isEmpty else { return split }
        let glued = self.joinTranslatedLines(prefix, languageID: languageID)
        if let next = completed.first {
            completed[0] = self.joinTranslatedLines([glued, next], languageID: languageID)
            return Split(completed: completed, tail: split.tail)
        }
        if split.tail.isEmpty {
            return Split(completed: [], tail: glued)
        }
        return Split(
            completed: [],
            tail: self.joinTranslatedLines([glued, split.tail], languageID: languageID)
        )
    }

    fileprivate static let tokenTrimSet = CharacterSet.punctuationCharacters
        .union(.whitespacesAndNewlines)

    fileprivate static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    fileprivate static func tokenKey(_ token: String) -> String {
        token.lowercased().trimmingCharacters(in: Self.tokenTrimSet)
    }

    fileprivate static func stripped(_ text: String) -> String {
        let kept = text.lowercased().compactMap { character -> Character? in
            if character.isLetter || character.isNumber { return character }
            if character.isWhitespace { return " " }
            return nil
        }
        return String(kept)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct LectureCaptionEntry: Codable, Equatable, Identifiable {
    let id: UInt64
    var source: String
    var translated: String
    var wasPolished: Bool = false
    var committedAt: Date = Date()

    private enum CodingKeys: String, CodingKey {
        case id
        case source
        case translated
        case wasPolished
        case committedAt
    }

    init(
        id: UInt64,
        source: String,
        translated: String,
        wasPolished: Bool = false,
        committedAt: Date = Date()
    ) {
        self.id = id
        self.source = source
        self.translated = translated
        self.wasPolished = wasPolished
        self.committedAt = committedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UInt64.self, forKey: .id)
        self.source = try container.decode(String.self, forKey: .source)
        self.translated = try container.decode(String.self, forKey: .translated)
        self.wasPolished = try container.decodeIfPresent(Bool.self, forKey: .wasPolished) ?? false
        self.committedAt = try container.decodeIfPresent(Date.self, forKey: .committedAt) ?? .distantPast
    }
}

struct TheaterBoardSnapshot: Codable, Equatable {
    var entries: [LectureCaptionEntry]
    var nextID: UInt64
}

/// Lecture caption history: one translated line per source clause, with prefix rewrite.
struct LectureCaptionLog: Equatable {
    var entries: [LectureCaptionEntry] = []
    var nextID: UInt64 = 1

    var sourceLines: [String] { self.entries.map(\.source) }
    var translatedLines: [String] { self.entries.map(\.translated) }
    var lineIDs: [UInt64] { self.entries.map(\.id) }

    var contextSourceLines: [String] {
        Array(self.sourceLines.suffix(LiveTranslationTiming.contextSentenceCount))
    }

    var captionPairs: [CaptionHistoryPair] {
        TheaterCaptionExport.pairs(from: self.entries)
    }

    var didPolishAnyLine: Bool {
        self.entries.contains(where: \.wasPolished)
    }

    /// Append a pair. Once a pair is on the board it is never rewritten in
    /// place — a printed line must never repeat, correct itself, or
    /// disappear. `mayReviseLast` still gates the peel/dedup pass below (a
    /// recursive call already carries an exactly-peeled source and passes
    /// false so it is not re-peeled), but no path in this function ever
    /// mutates an existing entry — every branch either appends a new one or
    /// rejects a duplicate/stale incoming clause.
    @discardableResult
    mutating func commit(
        source: String,
        translated: String,
        mayReviseLast: Bool = true
    ) -> (id: UInt64, overflow: [LectureCaptionEntry])? {
        let cleanedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedTranslation = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedSource.isEmpty, !cleanedTranslation.isEmpty else { return nil }

        // A racing stale commit and a fresh one can resolve to the exact same
        // clause. This is a duplicate, not a revise, so it applies even when
        // `mayReviseLast` is false (an in-flight commit forbids replacing —
        // it does not mean "append this again").
        if self.entries.last?.source == cleanedSource { return nil }

        if mayReviseLast, let lastSource = self.entries.last?.source {
            if TranslationClauseSegmenter.shouldIgnoreAsStalePrefix(previous: lastSource, incoming: cleanedSource) {
                return nil
            }
            let peeledSource = TranslationClauseSegmenter.leftoverTail(
                cleanedSource,
                already: [lastSource],
                languageID: SpokenLanguageResolver.listenLanguageID(for: cleanedSource)
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let languageID = SpokenLanguageResolver.listenLanguageID(for: cleanedSource)
            // `cleanedTranslation` is MT's output for the whole incoming
            // `cleanedSource`, which can still carry the previous entry's
            // translation as a leading chunk. A peeled *source* paired with
            // the unpeeled translation would attach the last sentence's
            // Korean onto this new entry — peel the translation the same way.
            let peeledTranslation = LiveTranslationCommitContext.peeledNewTranslation(
                cleanedTranslation,
                priorTranslations: [self.entries.last?.translated ?? ""],
                targetID: SpokenLanguageResolver.targetLanguage().id
            ) ?? cleanedTranslation
            let leftoverIsNewClause = !peeledSource.isEmpty && peeledSource != cleanedSource
                && (
                    TranslationClauseSegmenter.looksComplete(peeledSource, languageID: languageID)
                        || TranslationClauseSegmenter.isPauseFinalizable(peeledSource, languageID: languageID)
                        || TranslationClauseSegmenter.shouldFollowAlong(peeledSource, languageID: languageID)
                )
            if leftoverIsNewClause {
                return self.commit(
                    source: peeledSource,
                    translated: peeledTranslation,
                    mayReviseLast: false
                )
            }
            // Safety net: even when the completeness heuristics above miss it,
            // a peeled leftover that is a large, independent chunk of the
            // incoming text is almost never "the same sentence, corrected" —
            // it is a new sentence. Overwriting the previous entry below would
            // silently delete its already-finished translation, which is how
            // a whole prior sentence's Korean can vanish from the board.
            let peeledIsSubstantial = !peeledSource.isEmpty && peeledSource != cleanedSource
                && peeledSource.count >= 12
                && Double(peeledSource.count) >= Double(cleanedSource.count) * 0.4
            if peeledIsSubstantial {
                DebugLogger.shared.debug(
                    "Theater commit treated substantial peeled leftover as a new "
                        + "sentence instead of replacing last: previous=\"\(lastSource)\" "
                        + "incoming=\"\(cleanedSource)\" peeledSource=\"\(peeledSource)\"",
                    source: "LiveTranslation"
                )
                return self.commit(
                    source: peeledSource,
                    translated: peeledTranslation,
                    mayReviseLast: false
                )
            }
            // A previous build replaced the last entry in place here when
            // `incoming` was judged a growing correction of the same
            // utterance. That mutated a line already on screen, which is
            // exactly what must never happen — the peeled-leftover append
            // below (or the duplicate/stale rejections that follow it)
            // now cover this case without touching `lastSource`.
            if !peeledSource.isEmpty, peeledSource != cleanedSource {
                return self.commit(
                    source: peeledSource,
                    translated: peeledTranslation,
                    mayReviseLast: false
                )
            }
            if TranslationClauseSegmenter.isAlreadyPrintedSource(
                cleanedSource,
                already: [lastSource]
            ) {
                return nil
            }
            if TranslationClauseSegmenter.shouldReviseCommitted(
                previous: lastSource,
                incoming: cleanedSource,
                languageID: SpokenLanguageResolver.listenLanguageID(for: cleanedSource)
            ), peeledSource != cleanedSource {
                return nil
            }
        }

        let id = self.nextID
        self.entries.append(
            LectureCaptionEntry(id: id, source: cleanedSource, translated: cleanedTranslation)
        )
        self.nextID += 1
        return (id, self.trimIfNeeded())
    }

    @discardableResult
    mutating func updateTranslated(id: UInt64, translated: String, wasPolished: Bool) -> Bool {
        let cleaned = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, let index = self.entries.firstIndex(where: { $0.id == id }) else {
            return false
        }
        self.entries[index].translated = cleaned
        self.entries[index].wasPolished = wasPolished
        return true
    }

    mutating func restore(_ snapshot: TheaterBoardSnapshot) {
        self.entries = snapshot.entries
        self.nextID = max(snapshot.nextID, (snapshot.entries.map(\.id).max() ?? 0) + 1)
    }

    @discardableResult
    mutating func replaceTranslatedLines(_ lines: [String]) -> [LectureCaptionEntry] {
        let cleaned = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var next = self.nextID
        var rebuilt: [LectureCaptionEntry] = []
        for (index, line) in cleaned.enumerated() {
            if index < self.entries.count {
                var entry = self.entries[index]
                entry.translated = line
                rebuilt.append(entry)
            } else {
                rebuilt.append(LectureCaptionEntry(id: next, source: line, translated: line))
                next += 1
            }
        }
        self.entries = rebuilt
        self.nextID = next
        return self.trimIfNeeded()
    }

    @discardableResult
    /// The one exception to "never rewrite a printed pair": recognition
    /// dropped the newest line's period and kept going ("the model." →
    /// "the model on new data."). The newest row keeps its id and is fixed in
    /// place, instead of the extra words printing as a fragment line.
    mutating func reviseNewest(source: String, translated: String) -> Bool {
        let cleanedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedTranslation = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedSource.isEmpty, !cleanedTranslation.isEmpty, !self.entries.isEmpty else { return false }
        self.entries[self.entries.count - 1].source = cleanedSource
        self.entries[self.entries.count - 1].translated = cleanedTranslation
        self.entries[self.entries.count - 1].wasPolished = false
        return true
    }

    mutating func popLast() -> LectureCaptionEntry? {
        guard !self.entries.isEmpty else { return nil }
        return self.entries.removeLast()
    }

    @discardableResult
    mutating func trimIfNeeded() -> [LectureCaptionEntry] {
        guard self.entries.count > LiveTranslationTiming.maxCommittedLines else { return [] }
        let overflowCount = self.entries.count - LiveTranslationTiming.maxCommittedLines
        let overflow = Array(self.entries.prefix(overflowCount))
        self.entries.removeFirst(overflowCount)
        return overflow
    }
}

enum LiveTranslationConfirm {
    /// Korean, Japanese, and Thai preview ticks are weak. Pause and Stop still take the
    /// fuller 30-second decode for leftover speech. Mid-talk prints from the live stitch.
    static func requiresConfirmBeforePrint(languageID: String) -> Bool {
        switch TranslationClauseSegmenter.languageCode(from: languageID) {
        case "ko", "ja", "th":
            return true
        default:
            return false
        }
    }

    static func shouldReDecode(
        isFinal: Bool,
        isPause: Bool = false,
        languageID _: String = ""
    ) -> Bool {
        isFinal || isPause
    }

    /// First print: keep a short greeting ("OK", "네", "ขอบคุณ") when confirm heard it.
    static func prefersFirstConfirmation(confirmed: String, heard: String) -> Bool {
        let next = confirmed.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        if next.isEmpty { return false }
        if current.isEmpty { return true }
        if next.count >= max(8, (current.count * 2) / 3) { return true }
        guard next.count <= max(current.count + 4, 8) else { return false }
        return next.compare(current, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            || next.hasPrefix(current)
            || current.hasPrefix(next)
    }
}
