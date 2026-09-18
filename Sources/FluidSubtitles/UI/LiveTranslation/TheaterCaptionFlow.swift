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
        spokenDisplay: TheaterCaptionSpokenDisplay = .isTheCaption,
        makesRoomForLive: Bool = true
    ) -> [TheaterFlowLine] {
        let history = committed
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .enumerated()
            .filter { !$0.element.isEmpty }
        let draftText = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let spoken = sourceDraft.trimmingCharacters(in: .whitespacesAndNewlines)

        var liveText = ""
        var liveSource = ""
        let printedSources = committedSources
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let pending = pendingSources
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { !Self.isAlreadyOnBoard($0, lastText: history.last?.element ?? "", printedSources: printedSources) }
        let lastText = history.last?.element ?? ""
        let alreadyOnBoard = printedSources + pending
        let peeledSpoken = Self.unreadCaption(
            spoken,
            lastText: lastText,
            printedSources: alreadyOnBoard
        )
        let unreadSpoken = !peeledSpoken.isEmpty
            && !Self.isAlreadyOnBoard(
                peeledSpoken,
                lastText: lastText,
                printedSources: alreadyOnBoard
            )
        let printedTitles = history.map(\.element)
        switch spokenDisplay {
        case .hidden:
            if !draftText.isEmpty, !Self.isSameCaption(draftText, lastText) {
                liveText = Self.freshCaption(
                    draftText,
                    lastText: lastText,
                    printedSources: printedTitles
                )
            }
        case .paired:
            if !draftText.isEmpty, !Self.isSameCaption(draftText, lastText) {
                liveText = Self.freshCaption(
                    draftText,
                    lastText: lastText,
                    printedSources: history.map(\.element)
                )
                if unreadSpoken, !Self.isSameCaption(peeledSpoken, liveText) {
                    liveSource = peeledSpoken
                }
            } else if unreadSpoken {
                liveSource = peeledSpoken
            }
        case .isTheCaption:
            if !draftText.isEmpty, !Self.isSameCaption(draftText, lastText) {
                liveText = Self.freshCaption(
                    draftText,
                    lastText: lastText,
                    printedSources: alreadyOnBoard
                )
                if liveText.isEmpty, unreadSpoken {
                    liveText = peeledSpoken
                }
            } else if unreadSpoken {
                liveText = peeledSpoken
            }
        }

        let freshLive = !liveText.isEmpty || !liveSource.isEmpty
        let visiblePending = spokenDisplay == .hidden ? [] : pending
        let liveSlots = (freshLive ? 1 : 0) + visiblePending.count
        // The board keeps every row and scrolls old ones up out of view, so
        // it passes false. Dropping the top row as a new one appears made the
        // rows below jump up.
        let historyLimit = makesRoomForLive
            ? max(0, LiveTranslationTiming.visibleTheaterLines - liveSlots)
            : LiveTranslationTiming.visibleTheaterLines
        let visibleHistory = Array(history.suffix(historyLimit))

        func committedLine(index: Int, text: String, isCurrent: Bool) -> TheaterFlowLine {
            let id = index < committedIDs.count ? "c-\(committedIDs[index])" : "c-\(index + 1)"
            let source = index < committedSources.count ? committedSources[index] : ""
            return TheaterFlowLine(id: id, text: text, source: source, isCurrent: isCurrent, isDraft: false)
        }

        let hasRowsBelow = freshLive || !visiblePending.isEmpty
        var result: [TheaterFlowLine] = visibleHistory.map { index, text in
            committedLine(index: index, text: text, isCurrent: !hasRowsBelow && index == visibleHistory.last?.offset)
        }
        let fallback = (committedIDs.max() ?? 0) + 1
        let pendingBase = nextCaptionID > 0 ? nextCaptionID : fallback
        for (offset, spokenLine) in visiblePending.enumerated() {
            let id = "c-\(pendingBase + UInt64(offset))"
            switch spokenDisplay {
            case .hidden:
                break
            case .paired:
                result.append(TheaterFlowLine(
                    id: id,
                    text: "",
                    source: spokenLine,
                    isCurrent: false,
                    isDraft: true
                ))
            case .isTheCaption:
                result.append(TheaterFlowLine(
                    id: id,
                    text: spokenLine,
                    source: "",
                    isCurrent: false,
                    isDraft: true
                ))
            }
        }
        if freshLive {
            result.append(TheaterFlowLine(
                id: Self.liveID(
                    after: committedIDs,
                    nextID: nextCaptionID,
                    // `visiblePending` already reflects every in-flight
                    // source (pendingSpokenLines includes inFlightSources),
                    // so adding `inFlightCount` here would double-count them
                    // and forecast an id the row never actually gets.
                    pendingCount: visiblePending.count
                ),
                text: liveText,
                source: liveSource,
                isCurrent: true,
                isDraft: true
            ))
        }
        return result
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
