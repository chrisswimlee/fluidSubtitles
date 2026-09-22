import Foundation

enum TheaterCaptionFlow {
    /// Same id the clause will keep after it commits, so the NSView is not remounted.
    /// In-flight commits reserve their ids so leftover is the next view.
    static func liveID(
        after committedIDs: [UInt64],
        nextID: UInt64 = 0,
        pendingCount: Int = 0,
        inFlightCount: Int = 0
    ) -> String {
        let fallback = (committedIDs.max() ?? 0) + 1
        let base = nextID > 0 ? nextID : fallback
        return "c-\(base + UInt64(max(pendingCount, 0) + max(inFlightCount, 0)))"
    }

    static func lines(
        committed: [String],
        committedIDs: [UInt64] = [],
        nextCaptionID: UInt64 = 0,
        committedSources: [String] = [],
        draft: String,
        sourceDraft: String = "",
        pendingSources: [String] = [],
        inFlightCount: Int = 0,
        liveRowID: UInt64 = 0,
        spokenDisplay: TheaterCaptionSpokenDisplay = .isTheCaption,
        makesRoomForLive: Bool = true
    ) -> [TheaterFlowLine] {
        _ = draft
        _ = sourceDraft
        _ = pendingSources
        _ = inFlightCount
        _ = liveRowID
        _ = spokenDisplay
        _ = makesRoomForLive
        _ = nextCaptionID
        let history = committed
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .enumerated()
            .filter { !$0.element.isEmpty }

        func committedLine(index: Int, text: String, isCurrent: Bool) -> TheaterFlowLine {
            let id: String
            if index < committedIDs.count {
                id = "c-\(committedIDs[index])"
            } else if committedIDs.isEmpty {
                id = "c-\(index + 1)"
            } else {
                id = "c-h-\(index + 1)"
            }
            let source = index < committedSources.count ? committedSources[index] : ""
            return TheaterFlowLine(id: id, text: text, source: source, isCurrent: isCurrent, isDraft: false)
        }

        return history.map { index, text in
            committedLine(index: index, text: text, isCurrent: index == history.last?.offset)
        }
    }


    static func unreadCaption(
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

    /// Next title only. A restitch of sentence one plus two must not fall back
    /// to the whole blob after peel.
    static func freshCaption(
        _ text: String,
        lastText: String,
        printedSources: [String]
    ) -> String {
        let leftover = Self.unreadCaption(
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

    static func isAlreadyOnBoard(
        _ spoken: String,
        lastText: String,
        printedSources: [String]
    ) -> Bool {
        let cleaned = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }
        if Self.isSameCaption(cleaned, lastText) { return true }
        return TranslationClauseSegmenter.isAlreadyPrintedSource(cleaned, already: printedSources)
    }

    static func isSameCaption(_ left: String, _ right: String) -> Bool {
        let a = left.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = right.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty || b.isEmpty { return false }
        if a == b { return true }
        return TranslationClauseSegmenter.isSameClause(a, b)
    }
}
