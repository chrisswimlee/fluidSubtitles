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
        if !a.isEmpty, a == b { return true }
        if self.hasCompactLetters(left) || self.hasCompactLetters(right) {
            let compactA = self.compactKey(left)
            let compactB = self.compactKey(right)
            return !compactA.isEmpty && compactA == compactB
        }
        return false
    }

    /// The last printed sentence grew in place ("We trained the model." →
    /// "We trained the model on Korean data too.") rather than gaining a
    /// new clause after it.
    static func isInPlaceGrowth(previous: String, incoming: String) -> Bool {
        let prev = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prev.isEmpty, !next.isEmpty, !self.isSameClause(prev, next) else { return false }
        guard self.isGrowingClause(prev, toward: next) else { return false }
        let leftover = self.leftoverTail(next, already: [prev])
        if leftover.isEmpty || leftover == next || self.isSameClause(leftover, next) {
            return true
        }
        // leftoverTail peels the printed prefix. A lowercase rest is still
        // this caption, not a new sentence. Growth was already required above.
        if let first = self.tokens(leftover).first {
            return !self.looksLikeClauseBoundaryStart(first)
        }
        return false
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
            guard error > 0, error <= 0.34 else { return false }
            // WER treats "English" → "Korean" the same as "modal" → "model".
            // Only a close spelling is an ASR correction of the printed line.
            return self.hasOnlyCloseSubstitutions(prevTokens, nextTokens)
        }
        let prevCount = max(self.stripped(prev).count, 1)
        let nextCount = max(self.stripped(next).count, 1)
        // Same floor as the word-token path above: a one-character swap in a
        // very short clause is a huge fraction of its length even though it
        // is a different sentence, not an ASR self-correction.
        guard prevCount >= 10, nextCount >= 10 else { return false }
        let lengthRatio = Double(min(prevCount, nextCount)) / Double(max(prevCount, nextCount))
        guard lengthRatio >= 0.7 else { return false }
        // 영어 → 한국어 / 英語 → 韓国語 keeps most of the clause, so overall
        // CER looks like an ASR fix. English already rejects a different
        // first token; compact scripts need the same opening check.
        guard self.sharesRevisionOpening(prev, next) else { return false }
        let error = TheaterQualityScore.characterErrorRate(reference: prev, hypothesis: next)
        return error > 0 && error <= 0.34
    }

    /// A restitch keeps the start of the printed line. A new sentence that
    /// only shares the later words ("영어 데이터로…" then "한국어 데이터로…")
    /// is leftover speech, not a correction.
    fileprivate static func sharesRevisionOpening(_ previous: String, _ incoming: String) -> Bool {
        if previous.contains(where: \.isWhitespace), incoming.contains(where: \.isWhitespace) {
            let previousTokens = self.tokens(previous)
            let incomingTokens = self.tokens(incoming)
            if previousTokens.count >= 2, incomingTokens.count >= 2,
               let firstPrevious = previousTokens.first,
               let firstIncoming = incomingTokens.first
            {
                return self.tokenKey(firstPrevious) == self.tokenKey(firstIncoming)
            }
        }
        let previousKey = self.compactKey(previous)
        let incomingKey = self.compactKey(incoming)
        let head = min(2, previousKey.count, incomingKey.count)
        guard head > 0 else { return false }
        return incomingKey.hasPrefix(String(previousKey.prefix(head)))
    }

    /// True when every substituted token is a close spelling ("modal" /
    /// "model"), not a different content word ("English" / "Korean").
    fileprivate static func hasOnlyCloseSubstitutions(_ previous: [String], _ incoming: [String]) -> Bool {
        let count = min(previous.count, incoming.count)
        var sawMismatch = previous.count != incoming.count
        for index in 0..<count {
            let left = self.tokenKey(previous[index])
            let right = self.tokenKey(incoming[index])
            if left == right { continue }
            sawMismatch = true
            if !self.isCloseTokenSubstitution(left, right) {
                return false
            }
        }
        return sawMismatch
    }

    fileprivate static func isCloseTokenSubstitution(_ left: String, _ right: String) -> Bool {
        if left == right { return true }
        if left.isEmpty || right.isEmpty { return false }
        return TheaterQualityScore.characterErrorRate(reference: left, hypothesis: right) <= 0.34
    }

    /// Word-for-word containment after the same normalization as `isSameClause`.
    /// Scripts without spaces between words (Japanese, Chinese, Thai) match by
    /// substring; spaced scripts match whole words so "cat" is not in "catalog".
    static func contains(_ text: String, clause: String) -> Bool {
        let key = self.normalized(clause)
        guard !key.isEmpty else { return false }
        let haystack = self.normalized(text)
        if self.hasUnspacedScript(key) {
            return haystack.contains(key)
        }
        if (" " + haystack + " ").contains(" " + key + " ") { return true }
        if self.hasCompactLetters(clause) || self.hasCompactLetters(text) {
            let compactClause = self.compactKey(clause)
            let compactText = self.compactKey(text)
            return !compactClause.isEmpty && compactText.contains(compactClause)
        }
        return false
    }

    /// Hangul, kana, Han, or Thai: words are not separated by spaces.
    static func hasUnspacedScript(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value)
                || (0x31F0...0x31FF).contains(scalar.value)
                || (0xFF66...0xFF9D).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value)
                || (0x4E00...0x9FFF).contains(scalar.value)
                || (0x0E00...0x0E7F).contains(scalar.value)
                || (0xAC00...0xD7AF).contains(scalar.value)
                || (0x1100...0x11FF).contains(scalar.value)
                || (0x3130...0x318F).contains(scalar.value)
        }
    }

    /// Hangul, kana, Han, or Thai — spacing is not a word boundary.
    static func hasCompactLetters(_ text: String) -> Bool {
        if self.hasUnspacedScript(text) { return true }
        return text.unicodeScalars.contains { scalar in
            (0xAC00...0xD7AF).contains(scalar.value)
                || (0x1100...0x11FF).contains(scalar.value)
                || (0x3130...0x318F).contains(scalar.value)
        }
    }

    static func clauseUnitCount(_ text: String, languageID: String) -> Int {
        let split = self.split(text, languageID: languageID)
        let tail = split.tail.trimmingCharacters(in: .whitespacesAndNewlines)
        return split.completed.count + (tail.isEmpty ? 0 : 1)
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
    ///
    /// Hot path: match a prefix of `already` left-to-right and return the unread
    /// remainder. Cost is linear in the current leftover (plus one align search
    /// when older speech sits before the peel window), not a per-clause rescan of
    /// the whole talk.
    static func leftoverTail(_ text: String, already: [String], languageID: String = "") -> String {
        var remainder = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty, !already.isEmpty else {
            return self.collapseRepeatedSpeech(
                remainder,
                languageID: languageID.isEmpty ? "en" : languageID
            )
        }

        remainder = self.peelPrintedPrefix(remainder, already: already)
        remainder = self.stripLeadingBoundaries(remainder)
        // Only when a recent printed clause vanished from the full hypothesis
        // (ASR restitch), not merely because prefix peel already removed it.
        for chunk in already.suffix(3).reversed() where !self.contains(text, clause: chunk) {
            if let next = self.consumeDriftedPrefix(remainder, prefix: chunk) {
                remainder = next
                break
            }
        }
        if !languageID.isEmpty {
            // Reuse one normalized haystack so intact checks stay O(|already| + |text|),
            // not O(|already| · |text|) from re-stripping the talk on every clause.
            let intactInText = self.intactPrintedClauses(in: text, already: already)
            remainder = self.peelPrintedLeadingClauses(
                remainder,
                already: already,
                languageID: languageID,
                intactInText: intactInText
            )
        }
        remainder = self.peelLeadingPrintedCopies(remainder, already: already)
        return self.collapseRepeatedSpeech(
            remainder,
            languageID: languageID.isEmpty ? "en" : languageID
        )
    }

    /// Peel already-printed clauses from the front of `text`. When the cumulative
    /// transcript still starts with older offscreen speech, jump once to the peel
    /// window, then continue matching forward on the shrinking remainder.
    fileprivate static func peelPrintedPrefix(_ text: String, already: [String]) -> String {
        var remainder = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty, !already.isEmpty else { return remainder }

        let leading = self.consumeLeadingChunks(remainder, chunks: already)
        remainder = leading.remainder
        var nextIndex = leading.consumed

        if nextIndex == 0, let aligned = self.alignToPeelWindow(remainder, already: already) {
            remainder = aligned.remainder
            nextIndex = aligned.consumed
        }

        for chunk in already.dropFirst(nextIndex) {
            if let next = self.consumePrefix(remainder, prefix: chunk) {
                remainder = next
                continue
            }
            if self.looksLikeRevisedPrefix(text: remainder, prefix: chunk),
               let next = self.consumeApproximatePrefix(remainder, prefix: chunk),
               self.acceptedPrefixLeftover(next, prefix: chunk) != nil
            {
                remainder = next
                continue
            }
            if !self.containsPrintedClause(remainder, chunk: chunk) {
                continue
            }
            // A later printed clause still sits in the remainder, but unread
            // speech is ahead of it. Stop forward peel and keep that unread
            // prefix — do not jump to the last printed clause (that dropped
            // Point 1 when Point 0 and Point 2 were already on the board).
            break
        }
        return remainder
    }

    /// Drop speech before the first still-present peel-window clause. Returns the
    /// text from that clause onward after consuming it, plus how many `already`
    /// entries that accounts for.
    ///
    /// Do not call `consumePrefix` on the full talk first: a miss runs
    /// `dropWhileMatching` across every character and is quadratic in talk length.
    fileprivate static func alignToPeelWindow(
        _ text: String,
        already: [String]
    ) -> (remainder: String, consumed: Int)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for (index, chunk) in already.enumerated() {
            let prefixN = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prefixN.isEmpty else { continue }
            if let after = self.consumeEmbeddedClause(trimmed, prefix: chunk) {
                return (after, index + 1)
            }
            if let range = trimmed.range(of: prefixN)
                ?? trimmed.range(of: prefixN, options: .caseInsensitive)
            {
                if range.lowerBound > trimmed.startIndex {
                    let before = trimmed[trimmed.startIndex..<range.lowerBound]
                    guard let last = before.last else { continue }
                    let boundary = last.isWhitespace
                        || self.isTerminal(last)
                        || self.looksComplete(String(before), languageID: "ko")
                        || self.looksComplete(String(before), languageID: "th")
                        || self.looksComplete(String(before), languageID: "ja")
                    guard boundary else { continue }
                }
                var end = range.upperBound
                while end < trimmed.endIndex,
                      let scalar = trimmed[end].unicodeScalars.first,
                      Self.terminalPunctuation.contains(scalar)
                {
                    end = trimmed.index(after: end)
                }
                let after = self.stripLeadingBoundaries(String(trimmed[end...]))
                return (after, index + 1)
            }
        }
        return nil
    }

    /// Printed clauses still present word-for-word in `text`, using one normalize.
    fileprivate static func intactPrintedClauses(in text: String, already: [String]) -> [String] {
        let haystack = self.normalized(text)
        guard !haystack.isEmpty else { return [] }
        let spacedHaystack = " " + haystack + " "
        let compactText = self.compactKey(text)
        return already.filter { clause in
            let key = self.normalized(clause)
            guard !key.isEmpty else { return false }
            if self.hasUnspacedScript(key) {
                return haystack.contains(key)
            }
            if spacedHaystack.contains(" " + key + " ") { return true }
            if self.hasCompactLetters(clause) || self.hasCompactLetters(text) {
                let compactClause = self.compactKey(clause)
                return !compactClause.isEmpty && compactText.contains(compactClause)
            }
            return false
        }
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
        if let first = split.completed.first,
           !self.isTooThinToCommit(first, languageID: languageID)
        {
            // An unpunctuated run-on past the draft cap was force-cut by `split`.
            // Print that head while talking; otherwise nothing prints until a pause.
            let isForcedCut = trimmed.count >= LiveTranslationTiming.maxDraftCharacters
            if self.looksComplete(first, languageID: languageID) || isForcedCut {
                let rest = self.remainder(after: first, split: split, original: trimmed, languageID: languageID)
                if !rest.isEmpty {
                    return (first, rest)
                }
            }
        }
        return self.unpunctuatedSentenceBreak(trimmed, languageID: languageID)
    }

    /// Trailing-window ASR often stitches the next sentence with no period:
    /// "Today we trained the model Then we applied it".
    static func unpunctuatedSentenceBreak(
        _ text: String,
        languageID: String
    ) -> (unit: String, rest: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch self.languageCode(from: languageID) {
        case "ko":
            return self.compactSentenceBreak(
                trimmed,
                starters: Self.koreanSentenceStarters,
                languageID: languageID
            )
        case "ja":
            return self.compactSentenceBreak(
                trimmed,
                starters: Self.japaneseSentenceStarters,
                languageID: languageID
            )
        case "th":
            return self.compactSentenceBreak(
                trimmed,
                starters: Self.thaiSentenceStarters,
                languageID: languageID
            )
        default:
            return self.englishSentenceBreak(trimmed, languageID: languageID)
        }
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
        if let broken = self.unpunctuatedSentenceBreak(trimmed, languageID: languageID) {
            return broken
        }
        if self.looksComplete(split.tail, languageID: languageID) {
            return self.singleClause(split.tail, languageID: languageID)
        }
        if self.shouldFollowAlong(split.tail, languageID: languageID) {
            let cut = self.followAlongCut(split.tail, languageID: languageID)
            guard !cut.head.isEmpty else { return nil }
            return (unit: cut.head, rest: cut.rest)
        }
        if allowPauseFinalize, self.isPauseFinalizable(split.tail, languageID: languageID) {
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

    /// Current spoken clause only. Uses the same mid-talk gate as
    /// `nextCompletedSentence` so an internal แล้ว / connective does not hide
    /// sentence one while that sentence is still the live caption.
    static func liveOpenClause(_ leftover: String, languageID: String) -> String {
        let trimmed = leftover.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let next = self.nextCompletedSentence(trimmed, languageID: languageID) {
            return next.rest
        }
        return trimmed
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

    /// A new Listen may say "Hello." again. A five-word lecture sentence
    /// already on the board is not a greeting.
    static func isRepeatableGreeting(_ text: String, languageID: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if self.isCompactScript(languageID) || self.hasUnspacedScript(trimmed) {
            return self.stripped(trimmed).filter { !$0.isWhitespace }.count < 10
        }
        return self.tokens(trimmed).count < 4
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

        if character.isNewline {
            return !atEnd
        }
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
    fileprivate static let englishSentenceStarters: Set<String> = [
        "then", "and", "but", "so", "now", "next", "also", "after",
        "later", "still", "however", "therefore", "meanwhile", "finally",
        "first", "second", "plus", "afterward", "afterwards",
    ]

    /// Analyzer often starts the next sentence in lowercase. Only `then` /
    /// `next` — lowercase `and` / `but` / `so` are still this caption.
    fileprivate static let englishSoftSentenceStarters: Set<String> = [
        "then", "next",
    ]

    fileprivate static let englishConnectives: Set<String> = [
        "and", "but", "so", "then", "or",
    ]

    fileprivate static let koreanSentenceStarters: [String] = [
        "그리고", "그다음", "그 다음", "그런데", "그래서", "그러면", "근데", "다음으로",
        "그걸", "그것을", "그게", "그건", "이제", "이번에는",
    ]

    fileprivate static let japaneseSentenceStarters: [String] = [
        "そして", "それから", "次に", "また",
    ]

    fileprivate static let thaiSentenceStarters: [String] = [
        "หลังจากนั้น", "ต่อมา", "จากนั้น",
    ]

    fileprivate static func englishSentenceBreak(
        _ text: String,
        languageID: String
    ) -> (unit: String, rest: String)? {
        let words = self.tokens(text)
        let floor = LiveTranslationTiming.minPauseFinalizeWords
        guard words.count >= floor + 2 else { return nil }
        for index in floor..<words.count {
            let word = words[index]
            let key = self.tokenKey(word)
            let capital = word.first?.isUppercase == true
            let isStarter = capital
                ? Self.englishSentenceStarters.contains(key)
                : Self.englishSoftSentenceStarters.contains(key)
            guard isStarter else { continue }
            if index > 0, Self.englishConnectives.contains(self.tokenKey(words[index - 1])) {
                continue
            }
            if index > 0, let mark = words[index - 1].last, ",;:".contains(mark) {
                continue
            }
            if index + 1 < words.count,
               Self.englishConnectives.contains(self.tokenKey(words[index + 1]))
            {
                continue
            }
            let restWords = words.suffix(from: index)
            guard restWords.count >= 2 else { continue }
            let unit = words.prefix(index).joined(separator: " ")
            let rest = restWords.joined(separator: " ")
            guard !self.isTooThinToCommit(unit, languageID: languageID) else { continue }
            return (unit, rest)
        }
        return nil
    }

    fileprivate static func compactSentenceBreak(
        _ text: String,
        starters: [String],
        languageID: String
    ) -> (unit: String, rest: String)? {
        let folded = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for starter in starters {
            var search = folded.startIndex
            while search < folded.endIndex,
                  let range = folded.range(of: starter, range: search..<folded.endIndex)
            {
                if range.lowerBound == folded.startIndex {
                    search = range.upperBound
                    continue
                }
                let unit = String(folded[..<range.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let rest = String(folded[range.lowerBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let unitLetters = self.stripped(unit).filter { !$0.isWhitespace }
                let isFinished = self.looksComplete(unit, languageID: languageID) || unitLetters.count >= 16
                if isFinished,
                   !self.isTooThinToCommit(unit, languageID: languageID),
                   !rest.isEmpty
                {
                    return (unit, rest)
                }
                search = range.upperBound
            }
        }
        return nil
    }

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
        let leftover = String(trimmed[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
        // Last-word anchors collide on a similar next sentence ("…English
        // data." vs "…Korean data."). Empty leftover of a complete clause
        // that is not an ASR revision is new speech.
        if leftover.isEmpty,
           !self.isSameClause(prefixN, trimmed),
           self.isCompletedPrintedPrefix(trimmed),
           !self.shouldReviseCommitted(previous: prefixN, incoming: trimmed, languageID: "en")
        {
            return nil
        }
        return leftover
    }

    /// A full re-decode of the ring changed a word inside a printed line
    /// ("One day after tea" → "One day after day"). The line is gone from
    /// the hypothesis, so nothing exact can peel it, and it would print
    /// again. Peel the same number of words when most of them still match.
    /// Callers only try this when `prefix` is no longer intact in the text,
    /// so a real next sentence that shares its opening words is kept.
    fileprivate static func consumeDriftedPrefix(_ text: String, prefix: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixN = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !prefixN.isEmpty else { return nil }
        if self.hasUnspacedScript(prefixN) { return nil }
        let textTokens = self.tokens(trimmed)
        let prefixKeys = self.tokens(prefixN).map(self.tokenKey)
        guard prefixKeys.count >= 4, textTokens.count > prefixKeys.count else { return nil }
        let textKeys = textTokens.prefix(prefixKeys.count).map(self.tokenKey)
        let matches = zip(textKeys, prefixKeys).filter { $0 == $1 }.count
        let needed = Int((Double(prefixKeys.count) * 0.75).rounded(.up))
        guard matches >= needed, matches < prefixKeys.count else { return nil }
        return textTokens.dropFirst(prefixKeys.count).joined(separator: " ")
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
        // Do not pass `languageID` here. leftoverTail would call
        // peelPrintedLeadingClauses → remainder → leftoverTail and overflow
        // the stack on a Korean / Japanese / Thai restitch.
        let leftover = self.leftoverTail(trimmed, already: [first], languageID: "")
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
            // leftoverTail is often called on speech already peeled to the
            // next sentence. A similar complete leftover is new speech, not a
            // restitch of the printed line — that restitch still has more
            // after the revised clause. A close ASR correction of that line
            // ("modal." → "model.") still peels empty.
            if next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               self.looksComplete(first, languageID: languageID),
               !already.contains(where: { self.isSameClause($0, first) }),
               !already.contains(where: {
                   self.shouldReviseCommitted(
                       previous: $0,
                       incoming: first,
                       languageID: languageID
                   )
               })
            {
                break
            }
            if next == remainder { break }
            remainder = next
        }
        return self.stripLeadingBoundaries(remainder)
    }

    /// consumeAfterLastPrinted can leave a second copy that lost its period.
    /// Only the peel window can still lead the leftover; older lines are gone.
    fileprivate static func peelLeadingPrintedCopies(_ text: String, already: [String]) -> String {
        var remainder = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let window = already.suffix(LiveTranslationTiming.peelWindowLines)
        var steps = 0
        while steps < 32, !remainder.isEmpty {
            steps += 1
            var peeled = false
            for chunk in window {
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
            let leftover = String(trimmed[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if leftover.isEmpty { return leftover }
            let matched = String(trimmed[..<range.upperBound])
            return self.leftoverAfterExactPrefix(leftover, prefix: matched)
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
                        let leftover = textTokens.dropFirst(start + chunkKeys.count)
                            .joined(separator: " ")
                        if self.leftoverAfterExactPrefix(leftover, prefix: prefixN) != nil {
                            return leftover
                        }
                    }
                    start -= 1
                }
            }
        }

        if self.hasCompactLetters(prefixN) || self.hasCompactLetters(trimmed) {
            let compactNeedle = self.compactKey(prefixN)
            let compactHay = self.compactKey(trimmed)
            if compactNeedle.count >= 8, let range = compactHay.range(of: compactNeedle, options: .backwards) {
                let afterLetters = compactHay.distance(from: range.upperBound, to: compactHay.endIndex)
                let leftover = self.suffixKeepingLetters(trimmed, letterCount: afterLetters)
                if self.leftoverAfterExactPrefix(leftover, prefix: prefixN) != nil { return leftover }
            }
        }

        let needle = self.stripped(prefixN)
        guard needle.count >= 8 else { return nil }
        let haystack = self.stripped(trimmed)
        guard let range = haystack.range(of: needle, options: .backwards) else { return nil }
        let afterLetters = haystack.distance(from: range.upperBound, to: haystack.endIndex)
        let leftover = self.suffixKeepingLetters(trimmed, letterCount: afterLetters)
        if self.leftoverAfterExactPrefix(leftover, prefix: prefixN) != nil { return leftover }
        return nil
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
            let leftover = String(trimmed.dropFirst(prefixN.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return self.leftoverAfterExactPrefix(leftover, prefix: prefixN)
        }

        let compactText = self.compactKey(trimmed)
        let compactPrefix = self.compactKey(prefixN)
        if !compactPrefix.isEmpty, compactText == compactPrefix { return "" }

        let textTokens = self.tokens(trimmed)
        let prefixTokens = self.tokens(prefixN)
        if !prefixTokens.isEmpty,
           textTokens.count >= prefixTokens.count,
           zip(textTokens, prefixTokens).allSatisfy({ self.tokenKey($0) == self.tokenKey($1) })
        {
            let leftover = textTokens.dropFirst(prefixTokens.count).joined(separator: " ")
            if let peeled = self.leftoverAfterExactPrefix(leftover, prefix: prefixN) {
                return peeled
            }
        }

        if self.stripped(trimmed) == self.stripped(prefixN) { return "" }

        // Cheap reject before dropWhileMatching: that scanner walks every
        // prefix of `text` and re-strips, so a miss on a long talk is O(n²).
        // Divergent leading tokens mean this clause is not the prefix.
        if !prefixTokens.isEmpty, !textTokens.isEmpty {
            let check = min(3, prefixTokens.count, textTokens.count)
            let leadingMismatch = (0..<check).contains {
                self.tokenKey(textTokens[$0]) != self.tokenKey(prefixTokens[$0])
            }
            if leadingMismatch {
                return nil
            }
        }

        if let leftover = self.dropWhileMatching(trimmed, prefix: prefixN, using: self.stripped),
           self.leftoverAfterExactPrefix(leftover, prefix: prefixN) != nil
        {
            return leftover
        }
        return nil
    }

    /// Token-key peel must not eat a longer sentence that merely starts with
    /// the printed words ("We trained the model." vs "We trained the model on
    /// Korean data too."). An unpunctuated pause-cut of the same open clause
    /// still peels.
    fileprivate static func tokenMatchEndsAtClauseBoundary(
        textTokens: [String],
        prefixTokens: [String]
    ) -> Bool {
        guard !prefixTokens.isEmpty, textTokens.count >= prefixTokens.count else { return false }
        if textTokens.count == prefixTokens.count { return true }
        let leftover = textTokens[prefixTokens.count...].joined(separator: " ")
        let prefix = prefixTokens.joined(separator: " ")
        return self.leftoverAfterExactPrefix(leftover, prefix: prefix) != nil
    }

    fileprivate static func prefixEndsClause(_ prefix: String) -> Bool {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return false }
        return self.isTerminal(last)
    }

    /// Exact leading match. A finished printed sentence only peels when the
    /// leftover starts the next clause, so "We trained the model." does not
    /// eat "We trained the model on Korean data too." An unpunctuated
    /// pause-cut is still the same open clause. Compact scripts do not
    /// tokenize into English starters; a finished leftover sentence after a
    /// finished printed line is the next caption.
    fileprivate static func leftoverAfterExactPrefix(_ leftover: String, prefix: String) -> String? {
        let rest = leftover.trimmingCharacters(in: .whitespacesAndNewlines)
        if rest.isEmpty { return leftover }
        if self.hasUnspacedScript(prefix) || self.hasUnspacedScript(rest) {
            return leftover
        }
        if self.isCompletedPrintedPrefix(prefix) {
            guard let first = self.tokens(rest).first else { return nil }
            if self.looksLikeClauseBoundaryStart(first) {
                return leftover
            }
            // A lowercase opener ("on Korean data too.") cannot stand as its own
            // sentence even if it ends in punctuation — it is the tail of the
            // printed prefix growing in place, not a fresh clause.
            // An uppercase opener is the next sentence, even while it is still
            // growing ("Point 12 is…") and does not yet lookComplete.
            if first.first?.isUppercase == true {
                return leftover
            }
            return nil
        }
        return leftover
    }

    fileprivate static func isCompletedPrintedPrefix(_ prefix: String) -> Bool {
        if self.prefixEndsClause(prefix) { return true }
        return ["en", "ko", "th", "ja"].contains {
            self.looksComplete(prefix, languageID: $0)
        }
    }

    fileprivate static func acceptedPrefixLeftover(_ leftover: String, prefix _: String) -> String? {
        let rest = leftover.trimmingCharacters(in: .whitespacesAndNewlines)
        if rest.isEmpty { return leftover }
        if let first = rest.first, self.isTerminal(first) { return leftover }
        if let first = self.tokens(rest).first, self.looksLikeClauseBoundaryStart(first) {
            return leftover
        }
        return nil
    }

    fileprivate static func looksLikeClauseBoundaryStart(_ token: String) -> Bool {
        let key = self.tokenKey(token)
        if key.isEmpty { return false }
        if Self.englishSentenceStarters.contains(key) { return true }
        if Self.englishSoftSentenceStarters.contains(key) { return true }
        if Self.koreanSentenceStarters.contains(token) || Self.koreanSentenceStarters.contains(key) {
            return true
        }
        if Self.japaneseSentenceStarters.contains(token) { return true }
        if Self.thaiSentenceStarters.contains(token) { return true }
        return false
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
            let chunkTokens = self.tokens(chunk)
            let remainingTokens = Array(textTokens[index...])
            guard self.tokenMatchEndsAtClauseBoundary(
                textTokens: remainingTokens,
                prefixTokens: chunkTokens
            ) else { break }
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

    fileprivate static func compactKey(_ text: String) -> String {
        String(self.stripped(text).filter { !$0.isWhitespace })
    }

    fileprivate static func collapseWhitespace(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var previousSpace = false
        for character in text {
            if character.isWhitespace {
                if !previousSpace {
                    result.append(" ")
                    previousSpace = true
                }
            } else {
                result.append(character)
                previousSpace = false
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    fileprivate static func stripped(_ text: String) -> String {
        let kept = text.lowercased().compactMap { character -> Character? in
            if character.isLetter || character.isNumber { return character }
            if character.isWhitespace { return " " }
            return nil
        }
        return self.collapseWhitespace(String(kept))
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

        // A racing stale commit and a fresh one can resolve to the same
        // clause, including "Hello" then "Hello." Treat that as one line.
        if let lastSource = self.entries.last?.source,
           lastSource == cleanedSource
            || TranslationClauseSegmenter.isSameClause(lastSource, cleanedSource)
        {
            return nil
        }

        if mayReviseLast, let lastSource = self.entries.last?.source {
            if TranslationClauseSegmenter.shouldIgnoreAsStalePrefix(previous: lastSource, incoming: cleanedSource) {
                return nil
            }
            let peeledSource = TranslationClauseSegmenter.leftoverTail(
                cleanedSource,
                already: [lastSource],
                languageID: SpokenLanguageResolver.listenLanguageID(for: cleanedSource)
            ).trimmingCharacters(in: .whitespacesAndNewlines)
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
            let languageID = SpokenLanguageResolver.listenLanguageID(for: cleanedSource)
            if !peeledSource.isEmpty, peeledSource != cleanedSource {
                let clearlyNew = TranslationClauseSegmenter.looksComplete(peeledSource, languageID: languageID)
                    || TranslationClauseSegmenter.isPauseFinalizable(peeledSource, languageID: languageID)
                    || TranslationClauseSegmenter.shouldFollowAlong(peeledSource, languageID: languageID)
                    || (
                        peeledSource.count >= 12
                            && Double(peeledSource.count) >= Double(cleanedSource.count) * 0.4
                    )
                let replacesLast = TranslationClauseSegmenter.shouldReplaceLast(
                    previous: lastSource,
                    incoming: cleanedSource
                )
                // Prefix growth ("Hello" → "Hello world today") appends the delta.
                // A close spelling that is not that growth ("modal" → "model") does not.
                if !clearlyNew,
                   !replacesLast,
                   TranslationClauseSegmenter.shouldReviseCommitted(
                       previous: lastSource,
                       incoming: cleanedSource,
                       languageID: languageID
                   )
                {
                    return nil
                }
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
                languageID: languageID
            ),
               !TranslationClauseSegmenter.shouldReplaceLast(
                   previous: lastSource,
                   incoming: cleanedSource
               )
            {
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
