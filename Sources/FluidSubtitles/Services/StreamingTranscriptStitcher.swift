import Foundation

/// Joins already-committed live preview text with a trailing-window decode
/// so Stop can return the full lecture without keeping hours of PCM.
enum StreamingTranscriptStitcher {
    struct StitchResult: Equatable {
        var text: String
        /// Prefix of `text` that survived this decode unchanged (the
        /// alignment run and everything before it). Empty when the left
        /// side was empty — nothing has been confirmed by a second tick.
        var confirmedPrefix: String
    }

    static func stitch(committed: String, incoming: String) -> String {
        self.stitchResult(committed: committed, incoming: incoming).text
    }

    static func stitchResult(committed: String, incoming: String) -> StitchResult {
        let left = Self.normalizedSpacing(committed)
        let right = Self.normalizedSpacing(incoming)
        if left.isEmpty { return StitchResult(text: right, confirmedPrefix: "") }
        if right.isEmpty { return StitchResult(text: left, confirmedPrefix: left) }
        if left == right { return StitchResult(text: right, confirmedPrefix: right) }

        if TranslationClauseSegmenter.shouldIgnoreAsStalePrefix(previous: left, incoming: right) {
            return StitchResult(text: left, confirmedPrefix: left)
        }
        if TranslationClauseSegmenter.shouldReplaceLast(previous: left, incoming: right) {
            return StitchResult(text: right, confirmedPrefix: Self.tokenSharedPrefix(left, right))
        }
        if right.hasPrefix(left) { return StitchResult(text: right, confirmedPrefix: left) }
        if left.hasPrefix(right) { return StitchResult(text: left, confirmedPrefix: right) }

        if let aligned = Self.alignedJoinResult(left: left, right: right) {
            return aligned
        }
        if let overlapped = Self.overlapJoin(left: left, right: right) {
            return StitchResult(text: overlapped, confirmedPrefix: left)
        }
        return StitchResult(text: "\(left) \(right)", confirmedPrefix: left)
    }

    /// Prefix of `incoming` confirmed against the previous stitched hypothesis.
    static func confirmedPrefix(previous: String, incoming: String) -> String {
        self.stitchResult(committed: previous, incoming: incoming).confirmedPrefix
    }

    /// Once a word is on the live row, only grow it. A restitch that rewrites
    /// printed words holds the old target until a later decode settles.
    static func monotonicTarget(printed: String, incoming: String) -> String {
        let printed = printed.trimmingCharacters(in: .whitespacesAndNewlines)
        let incoming = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        if printed.isEmpty { return incoming }
        if incoming.isEmpty { return printed }
        if incoming.hasPrefix(printed) || incoming.hasPrefix(printed + " ") { return incoming }
        if printed.hasPrefix(incoming) || printed.hasPrefix(incoming + " ") { return printed }
        // Apple Speech ends an unfinished partial with "." / "…". The next
        // tick takes that mark back and adds words; that is growth, not a rewrite.
        let printedOpen = TheaterLiveRow.openText(printed)
        let incomingOpen = TheaterLiveRow.openText(incoming)
        if incomingOpen.hasPrefix(printedOpen) || incomingOpen.hasPrefix(printedOpen + " ") {
            return incoming
        }
        if printedOpen.hasPrefix(incomingOpen) || printedOpen.hasPrefix(incomingOpen + " ") {
            return printed
        }
        return printed
    }

    /// A mid-talk commit may only fire for a clause the confirmed prefix
    /// already contained as a finished unit. A late period on a printed
    /// run-on is not enough to peel the next sentence off.
    static func confirmedClauseContains(unit: String, confirmed: String) -> Bool {
        let unit = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        let confirmed = confirmed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !unit.isEmpty, !confirmed.isEmpty else { return false }
        if confirmed.hasPrefix(unit) || confirmed.hasPrefix(unit + " ") { return true }
        if TranslationClauseSegmenter.isSameClause(confirmed, unit) { return true }
        let stripped = unit.trimmingCharacters(in: CharacterSet(charactersIn: ".?!。！？…"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty, confirmed.hasPrefix(stripped) else { return false }
        let after = confirmed.dropFirst(stripped.count)
        guard let first = after.first else {
            return TranslationClauseSegmenter.looksComplete(confirmed, languageID: "en")
                || TranslationClauseSegmenter.looksComplete(confirmed, languageID: "ko")
                || TranslationClauseSegmenter.looksComplete(confirmed, languageID: "ja")
                || TranslationClauseSegmenter.looksComplete(confirmed, languageID: "th")
        }
        return ".?!。！？…".contains(first)
    }

    private static func tokenSharedPrefix(_ left: String, _ right: String) -> String {
        if TranslationClauseSegmenter.hasUnspacedScript(left)
            || TranslationClauseSegmenter.hasUnspacedScript(right)
        {
            return left.commonPrefix(with: right)
        }
        let leftTokens = left.split(separator: " ").map(String.init)
        let rightTokens = right.split(separator: " ").map(String.init)
        var count = 0
        while count < leftTokens.count, count < rightTokens.count {
            let a = leftTokens[count].lowercased().trimmingCharacters(in: .punctuationCharacters)
            let b = rightTokens[count].lowercased().trimmingCharacters(in: .punctuationCharacters)
            if a.isEmpty || a != b { break }
            count += 1
        }
        guard count > 0 else { return "" }
        return leftTokens.prefix(count).joined(separator: " ")
    }

    /// Once the PCM ring is full, every tick re-decodes the same half minute.
    /// That decode rarely repeats the earlier words exactly ("what it on me"
    /// → "what it all means"), so an exact suffix/prefix overlap fails and
    /// the whole window would be appended again. Align on the longest shared
    /// run of words instead: keep the committed text up to that run, then
    /// take the fresh decode from there.
    static func alignedJoin(left: String, right: String) -> String? {
        self.alignedJoinResult(left: left, right: right)?.text
    }

    private static func alignedJoinResult(left: String, right: String) -> StitchResult? {
        if TranslationClauseSegmenter.hasUnspacedScript(right) {
            return Self.alignedJoin(
                leftTokens: Array(left).map(String.init),
                rightTokens: Array(right).map(String.init),
                joiner: "",
                minimumRun: 6,
                key: { $0.lowercased() }
            )
        }
        let leftTokens = left.split(separator: " ").map(String.init)
        // The first seconds of a talk are one short clause that the next
        // decode rewrites ("I feel fine." → "I feel the fine about it.").
        // Two shared words are enough there; a long text needs three so a
        // stray "and the" cannot anchor.
        let minimumRun = leftTokens.count <= Self.shortCommittedTokens ? 2 : 3
        return Self.alignedJoin(
            leftTokens: leftTokens,
            rightTokens: right.split(separator: " ").map(String.init),
            joiner: " ",
            minimumRun: minimumRun,
            key: { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        )
    }

    private static let shortCommittedTokens = 8

    private static let maximumAlignmentTokens = 400

    private static func alignedJoin(
        leftTokens: [String],
        rightTokens: [String],
        joiner: String,
        minimumRun: Int,
        key: (String) -> String
    ) -> StitchResult? {
        guard !leftTokens.isEmpty, !rightTokens.isEmpty else { return nil }
        let offset = max(0, leftTokens.count - Self.maximumAlignmentTokens)
        let tail = Array(leftTokens[offset...])
        let window = Array(rightTokens.prefix(Self.maximumAlignmentTokens))
        let tailKeys = tail.map(key)
        let windowKeys = window.map(key)

        // Common runs over token keys. Pick the run that ends latest in
        // both texts: late in the committed text keeps what Theater already
        // printed, late in the window appends the least. Longer wins a tie.
        var previous = [Int](repeating: 0, count: windowKeys.count + 1)
        var current = [Int](repeating: 0, count: windowKeys.count + 1)
        var bestScore = -1
        var bestLength = 0
        var bestTailEnd = 0
        var bestWindowEnd = 0
        for i in 1...tailKeys.count {
            for j in 1...windowKeys.count {
                if !tailKeys[i - 1].isEmpty, tailKeys[i - 1] == windowKeys[j - 1] {
                    let length = previous[j - 1] + 1
                    current[j] = length
                    if length >= minimumRun {
                        let score = i + j
                        if score > bestScore || (score == bestScore && length > bestLength) {
                            bestScore = score
                            bestLength = length
                            bestTailEnd = i
                            bestWindowEnd = j
                        }
                    }
                } else {
                    current[j] = 0
                }
            }
            swap(&previous, &current)
            for j in current.indices { current[j] = 0 }
        }
        guard bestLength >= minimumRun else { return nil }
        // The shared run is the same words in both texts; only punctuation
        // and case can differ. Take the fresh decode's spelling of it, so
        // "meaningful, but" becomes "meaningful. But" once the decoder hears
        // the sentence end, and a mid-sentence "bit." loses its period.
        let kept = leftTokens.prefix(offset + bestTailEnd - bestLength)
        let fresh = rightTokens.dropFirst(bestWindowEnd - bestLength)
        let text = (Array(kept) + Array(fresh)).joined(separator: joiner)
        let confirmed = (Array(kept) + Array(fresh.prefix(bestLength))).joined(separator: joiner)
        return StitchResult(text: text, confirmedPrefix: confirmed)
    }

    static func previewChunk(
        logicalSampleCount: Int,
        logicalStart: Int,
        incrementalDeltaStart: Int?,
        retained: [Float]
    ) -> (samples: [Float], kind: Kind) {
        if let incrementalDeltaStart {
            let start = max(incrementalDeltaStart, logicalStart)
            let available = logicalSampleCount - start
            guard available > 0, retained.count >= available else {
                return (retained, .retainedWindow)
            }
            return (Array(retained.suffix(available)), .incrementalDelta)
        }
        return (retained, .retainedWindow)
    }

    /// Live Theater only needs the last half-minute of speech, matching the PCM
    /// ring. Dictation Stop still stitches the full listen.
    static let maximumLiveCharacters = 2_400

    static func boundLiveTranscript(_ text: String) -> String {
        let trimmed = Self.normalizedSpacing(text)
        guard trimmed.count > Self.maximumLiveCharacters else { return trimmed }

        let tailStart = trimmed.index(trimmed.endIndex, offsetBy: -Self.maximumLiveCharacters)
        var cut = tailStart
        let previous: Character = tailStart > trimmed.startIndex
            ? trimmed[trimmed.index(before: tailStart)]
            : " "
        let startsMidSentence = !previous.isWhitespace && !".!?。！？…".contains(previous)
        if startsMidSentence {
            if let boundary = trimmed[tailStart...].firstIndex(where: { ".!?。！？…".contains($0) }) {
                cut = trimmed.index(after: boundary)
            } else if let space = trimmed[tailStart...].firstIndex(where: { $0.isWhitespace }) {
                cut = trimmed.index(after: space)
            }
        }
        while cut < trimmed.endIndex, trimmed[cut].isWhitespace {
            cut = trimmed.index(after: cut)
        }
        let bounded = String(trimmed[cut...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if bounded.isEmpty || bounded.count > Self.maximumLiveCharacters {
            return String(trimmed.suffix(Self.maximumLiveCharacters))
        }
        return bounded
    }

    enum Kind: Equatable {
        case incrementalDelta
        case retainedWindow
    }

    private static func normalizedSpacing(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private static func overlapJoin(left: String, right: String) -> String? {
        let leftWords = left.split(separator: " ").map(String.init)
        let rightWords = right.split(separator: " ").map(String.init)
        guard !leftWords.isEmpty, !rightWords.isEmpty else { return nil }

        let maxOverlap = min(leftWords.count, rightWords.count)
        guard maxOverlap > 0 else { return nil }
        for overlap in stride(from: maxOverlap, through: 1, by: -1) {
            let suffix = leftWords.suffix(overlap)
            let prefix = rightWords.prefix(overlap)
            if Self.wordsMatch(suffix, prefix) {
                let kept = leftWords.dropLast(overlap)
                return (kept + rightWords).joined(separator: " ")
            }
        }
        return nil
    }

    private static func wordsMatch<S: Sequence>(_ left: S, _ right: S) -> Bool where S.Element == String {
        var rightIterator = right.makeIterator()
        for word in left {
            guard let other = rightIterator.next() else { return false }
            if word.lowercased().trimmingCharacters(in: .punctuationCharacters)
                != other.lowercased().trimmingCharacters(in: .punctuationCharacters)
            {
                return false
            }
        }
        return rightIterator.next() == nil
    }
}
