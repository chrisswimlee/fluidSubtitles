import Foundation

/// Joins already-committed live preview text with a trailing-window decode
/// so Stop can return the full lecture without keeping hours of PCM.
enum StreamingTranscriptStitcher {
    static func stitch(committed: String, incoming: String) -> String {
        let left = Self.normalizedSpacing(committed)
        let right = Self.normalizedSpacing(incoming)
        if left.isEmpty { return right }
        if right.isEmpty { return left }
        if left == right { return right }

        if TranslationClauseSegmenter.shouldIgnoreAsStalePrefix(previous: left, incoming: right) {
            return left
        }
        if TranslationClauseSegmenter.shouldReplaceLast(previous: left, incoming: right) {
            return right
        }
        if right.hasPrefix(left) { return right }
        if left.hasPrefix(right) { return left }

        if let overlapped = Self.overlapJoin(left: left, right: right) {
            return overlapped
        }
        return "\(left) \(right)"
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
