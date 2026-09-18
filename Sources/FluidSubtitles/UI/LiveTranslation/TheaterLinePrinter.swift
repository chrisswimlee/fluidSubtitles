import Foundation

enum TheaterLinePrinter {
    enum EmptyTarget {
        /// Keep what is already on screen. Used when ASR flickers blank.
        case hold
        /// Take back one chunk. Used when a translation is withdrawn.
        case retract
    }

    static func extend(
        _ shown: String,
        toward target: String,
        style: TheaterCaptionPrintStyle = .word
    ) -> String {
        if target.isEmpty { return shown }
        if shown.isEmpty {
            return Self.openingChunk(in: target, style: style)
        }
        if shown == target { return target }
        if target.hasPrefix(shown) {
            let rest = String(target.dropFirst(shown.count))
            return shown + Self.nextChunk(in: rest, style: style)
        }
        return shown
    }

    /// Once a caption is on screen, only grow it. A later ASR or polish
    /// ending must not retract the line the audience is already reading.
    static func shouldAdoptPrintedCaption(
        currentSpoken: String,
        currentTranslated: String,
        nextSpoken: String,
        nextTranslated: String
    ) -> Bool {
        if nextSpoken.isEmpty, nextTranslated.isEmpty {
            return currentSpoken.isEmpty && currentTranslated.isEmpty
        }
        if currentSpoken.isEmpty, currentTranslated.isEmpty { return true }
        if nextSpoken == currentSpoken, nextTranslated == currentTranslated { return true }
        if Self.isGrowthOfHeldFirstClause(
            currentSpoken: currentSpoken,
            currentTranslated: currentTranslated,
            nextSpoken: nextSpoken,
            nextTranslated: nextTranslated
        ) {
            return true
        }
        if Self.reprintsLeadingPrintedClause(currentSpoken: currentSpoken, nextSpoken: nextSpoken) {
            return false
        }
        if currentSpoken.isEmpty, nextSpoken.isEmpty,
           Self.reprintsLeadingPrintedClause(
            currentSpoken: currentTranslated,
            nextSpoken: nextTranslated
           )
        {
            return false
        }
        if Self.isAlreadyPeeledTail(current: currentSpoken, incoming: nextSpoken)
            || (
                currentSpoken.isEmpty && nextSpoken.isEmpty
                    && Self.isAlreadyPeeledTail(current: currentTranslated, incoming: nextTranslated)
            )
        {
            return true
        }
        // Before the title starts, English may still correct (shop → store)
        // and the first Korean target may land.
        if currentTranslated.isEmpty {
            if nextSpoken.isEmpty { return false }
            if nextSpoken == currentSpoken { return true }
            if nextSpoken.hasPrefix(currentSpoken) || currentSpoken.hasPrefix(nextSpoken) {
                return true
            }
            return self.isContinuation(currentSpoken, of: nextSpoken)
        }
        let spokenGrows = nextSpoken.hasPrefix(currentSpoken) || currentSpoken.hasPrefix(nextSpoken)
        let translatedGrows = nextTranslated.hasPrefix(currentTranslated)
            || currentTranslated.hasPrefix(nextTranslated)
        return spokenGrows && translatedGrows
    }

    /// Flow `line.id` starts a new pair. This row only grows or holds.
    static func shouldStartNewCaption(
        currentSpoken _: String,
        currentTranslated _: String,
        nextSpoken _: String,
        nextTranslated _: String
    ) -> Bool {
        false
    }

    /// Grow or correct one chunk. Never replace the line with a different clause.
    static func follow(
        _ shown: String,
        toward target: String,
        emptyTarget: EmptyTarget = .hold,
        style: TheaterCaptionPrintStyle = .word
    ) -> String {
        if !style.typesIn {
            if target.isEmpty {
                switch emptyTarget {
                case .hold:
                    return shown
                case .retract:
                    return ""
                }
            }
            return target
        }
        if target.isEmpty {
            switch emptyTarget {
            case .hold:
                return shown
            case .retract:
                return shown.isEmpty ? "" : Self.dropLastChunk(shown)
            }
        }
        if shown.isEmpty {
            return Self.openingChunk(in: target, style: style)
        }
        if shown == target { return target }
        if target.hasPrefix(shown) {
            return Self.extend(shown, toward: target, style: style)
        }
        if shown.hasPrefix(target) {
            return shown
        }
        if Self.stableSharedPrefix(shown, target) != nil, target.count >= shown.count {
            return target
        }
        return shown
    }

    static func advance(
        _ shown: String,
        toward target: String,
        emptyTarget: EmptyTarget = .hold,
        style: TheaterCaptionPrintStyle = .word
    ) -> String {
        Self.follow(shown, toward: target, emptyTarget: emptyTarget, style: style)
    }

    /// One language per tick, top row first. Spoken sits above the Show-as
    /// title (see TheaterBilingualWrap), so it finishes before the title
    /// below starts typing and the line above never changes under it.
    static func nextPrintStep(
        printedSpoken: String,
        targetSpoken: String,
        printedTranslated: String,
        targetTranslated: String,
        style: TheaterCaptionPrintStyle
    ) -> (spoken: String, translated: String) {
        if printedSpoken != targetSpoken {
            return (
                Self.advance(
                    printedSpoken,
                    toward: targetSpoken,
                    emptyTarget: .hold,
                    style: style
                ),
                printedTranslated
            )
        }
        if printedTranslated != targetTranslated {
            return (
                printedSpoken,
                Self.advance(
                    printedTranslated,
                    toward: targetTranslated,
                    emptyTarget: .hold,
                    style: style
                )
            )
        }
        return (printedSpoken, printedTranslated)
    }

    /// A pending (spoken-only) row and its eventual committed row are the
    /// same clause under two different ids — the pending id is a forecast,
    /// the committed id is final. Wiping printed progress on that handoff
    /// retypes English that already finished printing, then the Korean,
    /// which reads as the whole line reprinting. Only hard-reset when the
    /// incoming text is not a continuation of what is already on screen —
    /// a genuinely different clause.
    static func shouldResetPrintProgressOnLineChange(
        printedSpoken: String,
        printedTranslated: String,
        nextSpoken: String,
        nextTranslated: String
    ) -> Bool {
        let continuesSpoken = printedSpoken.isEmpty || nextSpoken.hasPrefix(printedSpoken)
        let continuesTranslated = printedTranslated.isEmpty
            || nextTranslated.isEmpty
            || nextTranslated.hasPrefix(printedTranslated)
        return !(continuesSpoken && continuesTranslated)
    }

    static func isGrowthOfHeldFirstClause(
        currentSpoken: String,
        currentTranslated: String,
        nextSpoken: String,
        nextTranslated: String
    ) -> Bool {
        let current = nextSpoken.isEmpty && currentSpoken.isEmpty ? currentTranslated : currentSpoken
        let next = nextSpoken.isEmpty ? nextTranslated : nextSpoken
        guard let held = self.heldFirstClause(current: current, incoming: next) else { return false }
        return TranslationClauseSegmenter.isSameClause(held, next) || held == next
    }

    /// A restitch of sentence one plus two still starts with this row. Keep
    /// sentence one instead of blanking the pair and typing both.
    static func heldFirstClause(current: String, incoming: String) -> String? {
        let current = current.trimmingCharacters(in: .whitespacesAndNewlines)
        let incoming = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty, incoming.count > current.count else { return nil }
        let languageID = SpokenLanguageResolver.listenLanguageID(for: incoming)
        let first = TranslationClauseSegmenter.liveOpenText(incoming, languageID: languageID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !first.isEmpty else { return nil }
        if TranslationClauseSegmenter.isSameClause(current, first) { return first }
        if first.hasPrefix(current) || current.hasPrefix(first) { return first }
        if incoming.hasPrefix(current) || incoming.hasPrefix(current + " ") { return first }
        return nil
    }

    /// Cumulative ASR still starts with the clause already on this row.
    /// Extending into sentence two reprints sentence one.
    static func reprintsLeadingPrintedClause(currentSpoken: String, nextSpoken: String) -> Bool {
        let current = currentSpoken.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = nextSpoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty, !next.isEmpty, current != next else { return false }
        if TranslationClauseSegmenter.isSameClause(current, next) { return false }
        let leftover = TranslationClauseSegmenter.leftoverTail(
            next,
            already: [current],
            languageID: SpokenLanguageResolver.listenLanguageID(for: next)
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        let peeledAway = !leftover.isEmpty && leftover != next && leftover.count < next.count
        if peeledAway, self.leftoverIsANewClause(leftover, after: current) {
            return true
        }
        if TranslationClauseSegmenter.shouldReplaceLast(previous: current, incoming: next) {
            return false
        }
        return peeledAway
    }

    /// "the model" after "Today we trained" is the same phrase. "Then we applied
    /// it" after a finished clause is sentence two.
    static func leftoverIsANewClause(_ leftover: String, after current: String) -> Bool {
        let leftover = leftover.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !leftover.isEmpty, !current.isEmpty else { return false }
        let languages = ["en", "ko", "th", "ja"]
        if languages.contains(where: { TranslationClauseSegmenter.looksComplete(current, languageID: $0) }) {
            return true
        }
        if languages.contains(where: { TranslationClauseSegmenter.looksComplete(leftover, languageID: $0) }) {
            return true
        }
        if languages.contains(where: {
            TranslationClauseSegmenter.isPauseFinalizable(leftover, languageID: $0)
                || TranslationClauseSegmenter.shouldFollowAlong(leftover, languageID: $0)
        }) {
            return true
        }
        let leftoverWords = leftover.split { $0.isWhitespace }.filter { !$0.isEmpty }.count
        let currentWords = current.split { $0.isWhitespace }.filter { !$0.isEmpty }.count
        return leftoverWords >= 4 && currentWords >= 4
    }

    static func unreadSpokenTarget(currentSpoken _: String, nextSpoken: String) -> String {
        nextSpoken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Voice / same-language Theater hides the spoken undertone. The title is
    /// the clause identity, so leftover peel has to run on that field.
    struct IncomingResolution: Equatable {
        var spoken: String
        var translated: String
        var reset: Bool
    }

    static func resolveIncoming(
        currentSpoken: String,
        currentTranslated: String,
        nextSpoken: String,
        nextTranslated: String,
        translationStarted _: Bool
    ) -> IncomingResolution {
        let identityCurrent = nextSpoken.isEmpty && currentSpoken.isEmpty
            ? currentTranslated
            : currentSpoken
        let identityNext = nextSpoken.isEmpty ? nextTranslated : nextSpoken

        if self.isAlreadyPeeledTail(current: identityCurrent, incoming: identityNext) {
            return IncomingResolution(
                spoken: currentSpoken,
                translated: currentTranslated,
                reset: false
            )
        }

        if identityNext.count < identityCurrent.count,
           identityCurrent.hasPrefix(identityNext)
            || identityCurrent.hasPrefix(identityNext + " ")
            || identityCurrent.hasPrefix(identityNext + ".")
        {
            return IncomingResolution(
                spoken: currentSpoken,
                translated: currentTranslated,
                reset: false
            )
        }

        if identityCurrent.isEmpty {
            return IncomingResolution(
                spoken: nextSpoken,
                translated: nextTranslated,
                reset: false
            )
        }

        if identityNext.hasPrefix(identityCurrent)
            || identityCurrent.hasPrefix(identityNext)
            || self.isContinuation(identityCurrent, of: identityNext)
        {
            return IncomingResolution(
                spoken: nextSpoken,
                translated: nextTranslated,
                reset: false
            )
        }

        return IncomingResolution(
            spoken: currentSpoken,
            translated: currentTranslated,
            reset: false
        )
    }

    /// The live row already shows sentence two. A later restitch of sentence
    /// one plus two must not replace that tail with the whole blob.
    static func isAlreadyPeeledTail(current: String, incoming: String) -> Bool {
        let current = current.trimmingCharacters(in: .whitespacesAndNewlines)
        let incoming = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty, incoming.count > current.count else { return false }
        if incoming.hasPrefix(current) || incoming.hasPrefix(current + " ") { return false }
        if TranslationClauseSegmenter.isSameClause(current, incoming) { return false }
        guard incoming.hasSuffix(current) else { return false }
        let prefix = String(incoming.dropLast(current.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { return false }
        let languageID = SpokenLanguageResolver.listenLanguageID(for: prefix)
        let languages = [languageID, "en", "ko", "th", "ja"]
        if languages.contains(where: {
            TranslationClauseSegmenter.looksComplete(prefix, languageID: $0)
        }) {
            return true
        }
        if languages.contains(where: {
            TranslationClauseSegmenter.isPauseFinalizable(prefix, languageID: $0)
                && (
                    TranslationClauseSegmenter.isCompactScript($0)
                        || TranslationClauseSegmenter.looksComplete(current, languageID: $0)
                )
        }) {
            return true
        }
        return false
    }

    static func extendedCaption(current: String, incoming: String) -> String {
        let current = current.trimmingCharacters(in: .whitespacesAndNewlines)
        let incoming = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        if incoming.isEmpty { return current }
        if current.isEmpty { return incoming }
        if incoming.hasPrefix(current) || current.hasPrefix(incoming) { return incoming }
        if let held = self.heldFirstClause(current: current, incoming: incoming) {
            return held
        }
        return current
    }

    static func isContinuation(_ shown: String, of target: String) -> Bool {
        if shown.isEmpty || target.isEmpty { return true }
        if target.hasPrefix(shown) || shown.hasPrefix(target) { return true }
        return Self.stableSharedPrefix(shown, target) != nil
    }

    static func stableSharedPrefix(_ shown: String, _ target: String) -> String? {
        let shared = shown.commonPrefix(with: target)
        if shared.count >= 4 { return shared }
        let shownWord = shown.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        let targetWord = target.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        if shownWord.count >= 2, shownWord == targetWord {
            return shownWord
        }
        return nil
    }

    static func retract(_ shown: String, downTo prefix: String) -> String {
        if shown == prefix { return prefix }
        if prefix.isEmpty { return Self.dropLastChunk(shown) }
        if !shown.hasPrefix(prefix) { return shown }
        let next = Self.dropLastChunk(shown)
        if next.count < prefix.count || !next.hasPrefix(prefix) {
            return prefix
        }
        return next
    }

    static func dropLastChunk(_ shown: String) -> String {
        guard let last = shown.last else { return "" }
        if last.isWhitespace {
            return Self.dropLast(shown) { $0.isWhitespace }
        }
        if last.isASCII, last.isLetter || last.isNumber {
            let withoutWord = Self.dropLast(shown) { $0.isASCII && ($0.isLetter || $0.isNumber) }
            return Self.dropLast(withoutWord) { $0.isWhitespace }
        }
        return String(shown.dropLast())
    }

    private static func dropLast(_ shown: String, while shouldDrop: (Character) -> Bool) -> String {
        var end = shown.endIndex
        while end > shown.startIndex {
            let previous = shown.index(before: end)
            guard shouldDrop(shown[previous]) else { break }
            end = previous
        }
        return String(shown[..<end])
    }

    /// First paint is one chunk. A thin starter stays one word so the title
    /// does not pop in as "It was a long".
    static func openingChunk(
        in target: String,
        style: TheaterCaptionPrintStyle
    ) -> String {
        self.nextChunk(in: target, style: style)
    }

    private static func nextChunk(in rest: String, style: TheaterCaptionPrintStyle) -> String {
        guard let first = rest.first else { return "" }
        if first.isWhitespace {
            let spaces = rest.prefix(while: { $0.isWhitespace })
            let after = rest.drop(while: { $0.isWhitespace })
            return String(spaces) + self.nextChunk(in: String(after), style: style)
        }
        if first.isASCII, first.isLetter || first.isNumber {
            let latin = rest.prefix(while: { $0.isASCII && ($0.isLetter || $0.isNumber) })
            if style == .flow {
                return String(latin.prefix(1))
            }
            return String(latin)
        }
        let compact = style == .flow ? 1 : 3
        return String(rest.prefix(compact))
    }
}
