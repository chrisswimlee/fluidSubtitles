import Foundation

/// Prior-4 MT context and confirmation peel. When-to-commit lives on
/// TranslationClauseSegmenter (`nextCompletedSentence` / `nextCommitUnit`).
enum LiveTranslationCommitContext {
    /// Interlinear annotation anchors, same family as glossary lock tokens.
    /// Lock tokens are `\u{FFF9}` plus digits plus `\u{FFFA}`. These use
    /// triangles so a term lock cannot collide with a clause boundary.
    static let contextClauseStart = "\u{FFF9}\u{25B9}\u{FFFA}"
    static let contextClauseEnd = "\u{FFF9}\u{25C3}\u{FFFA}"

    /// Priors stay unmarked context. Only the new clause sits between the marks.
    static func markedContextPayload(
        priors: [String],
        current: String,
        languageID: String
    ) -> String {
        let marked = Self.contextClauseStart + current + Self.contextClauseEnd
        let head = priors
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !head.isEmpty else { return marked }
        let context = TranslationClauseSegmenter.joinTranslatedLines(
            head,
            languageID: languageID
        )
        return context + "\n" + marked
    }

    /// Last line after a preserved break, when the model dropped the marks
    /// but did not fuse the new caption into the priors.
    static func lineBoundNewTranslation(
        _ translated: String,
        priorTranslations: [String],
        isolatedSource: String,
        targetID: String
    ) -> String? {
        guard translated.contains("\n") else { return nil }
        guard let line = translated
            .split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .last(where: { !$0.isEmpty })
        else { return nil }
        if priorTranslations.contains(where: { TranslationClauseSegmenter.isSameClause($0, line) }) {
            return nil
        }
        if Self.leftoverContainsPriorCaption(line, priors: priorTranslations) {
            return nil
        }
        guard Self.isSanePeeledCaption(line, isolatedSource: isolatedSource, targetID: targetID) else {
            return nil
        }
        return line
    }

    /// The span between one start mark and one end mark. A missing, doubled,
    /// or empty span is not a caption.
    static func markedNewTranslation(_ translated: String) -> String? {
        let startToken = Self.contextClauseStart
        let endToken = Self.contextClauseEnd
        guard translated.components(separatedBy: startToken).count == 2,
              translated.components(separatedBy: endToken).count == 2,
              let start = translated.range(of: startToken),
              let end = translated.range(of: endToken),
              start.upperBound <= end.lowerBound
        else {
            return nil
        }
        let caption = translated[start.upperBound..<end.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !caption.isEmpty else { return nil }
        return caption
    }

    static func containsContextClauseMark(_ translated: String) -> Bool {
        translated.contains(Self.contextClauseStart) || translated.contains(Self.contextClauseEnd)
    }

    /// Only this Listen. A restored board or yesterday's talk must not prime MT.
    static func priorClauses(
        entries: [LectureCaptionEntry],
        listenBatchStart: Int,
        incoming: String,
        limit: Int = LiveTranslationTiming.contextSentenceCount
    ) -> (sources: [String], translations: [String]) {
        let start = min(max(listenBatchStart, 0), entries.count)
        var sources = Array(entries.dropFirst(start).map(\.source))
        var translations = Array(entries.dropFirst(start).map(\.translated))
        guard !sources.isEmpty, sources.count == translations.count else {
            return ([], [])
        }
        if let last = sources.last,
           TranslationClauseSegmenter.shouldReplaceLast(previous: last, incoming: incoming)
        {
            sources.removeLast()
            translations.removeLast()
        }
        let count = min(limit, sources.count)
        guard count > 0 else { return ([], []) }
        return (Array(sources.suffix(count)), Array(translations.suffix(count)))
    }

    static func peeledNewTranslation(
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

    static func isSanePeeledCaption(
        _ peeled: String,
        isolatedSource: String,
        targetID: String
    ) -> Bool {
        let cleaned = peeled.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }
        let sourceID = SpokenLanguageResolver.listenLanguageID(for: isolatedSource)
        let peeledCount = TranslationClauseSegmenter.clauseUnitCount(cleaned, languageID: targetID)
        let sourceCount = max(
            1,
            TranslationClauseSegmenter.clauseUnitCount(isolatedSource, languageID: sourceID)
        )
        return peeledCount <= sourceCount
    }

    static func leftoverContainsPriorCaption(_ leftover: String, priors: [String]) -> Bool {
        let haystack = leftover.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        return priors.contains { prior in
            let trimmed = prior.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2 else { return false }
            let needle = trimmed.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            return Self.containsPriorTokens(haystack, prior: needle)
        }
    }

    /// Spaced scripts match whole words ("OK" is not inside "Okay").
    /// Japanese, Chinese, and Thai have no word spaces, so they match a
    /// substring of at least `unspacedPriorMinimumLength` characters.
    static func containsPriorTokens(_ leftover: String, prior: String) -> Bool {
        if TranslationClauseSegmenter.hasUnspacedScript(prior) {
            let needle = Self.captionToken(prior)
            guard needle.count >= Self.unspacedPriorMinimumLength else { return false }
            return leftover.contains(needle)
        }
        let hay = leftover
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map { Self.captionToken(String($0)) }
        let needle = prior
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map { Self.captionToken(String($0)) }
        guard !needle.isEmpty, needle.allSatisfy({ !$0.isEmpty }) else { return false }
        if hay.count >= needle.count {
            let limit = hay.count - needle.count
            if (0...limit).contains(where: { start in
                hay[start..<(start + needle.count)].elementsEqual(needle)
            }) {
                return true
            }
        }
        return false
    }

    static let unspacedPriorMinimumLength = 4

    private static func captionToken(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
    }

    static func shouldPreferConfirmation(
        _ confirmed: String,
        over heard: String,
        already: [String] = []
    ) -> Bool {
        let next = confirmed.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        if next.isEmpty { return false }
        if already.isEmpty {
            if current.isEmpty { return true }
            return LiveTranslationConfirm.prefersFirstConfirmation(confirmed: next, heard: current)
        }

        let languageID = SpokenLanguageResolver.listenLanguageID(for: next)
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
        if currentLeftover.isEmpty {
            if already.contains(where: {
                TranslationClauseSegmenter.isSameClause($0, nextLeftover)
                    || TranslationClauseSegmenter.isInPlaceGrowth(previous: $0, incoming: nextLeftover)
                    || TranslationClauseSegmenter.shouldReviseCommitted(
                        previous: $0,
                        incoming: nextLeftover,
                        languageID: languageID
                    )
                    || Self.isNearReprint($0, incoming: nextLeftover)
            }) {
                return false
            }
            return true
        }
        guard Self.isLeftoverRevision(nextLeftover, of: currentLeftover) else { return false }
        return nextLeftover.count >= max(8, (currentLeftover.count * 2) / 3)
    }

    static func isNearReprint(_ previous: String, incoming: String) -> Bool {
        let prev = previous
            .split(whereSeparator: \.isWhitespace)
            .map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        let next = incoming
            .split(whereSeparator: \.isWhitespace)
            .map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        guard prev.count >= 4, next.count >= 4, abs(prev.count - next.count) <= 2 else { return false }
        let shared = prev.filter { next.contains($0) }.count
        return shared * 3 >= prev.count * 2
    }

    static func isLeftoverRevision(_ incoming: String, of previous: String) -> Bool {
        if TranslationClauseSegmenter.isSameClause(previous, incoming) { return true }
        let left = Self.foldedClause(previous)
        let right = Self.foldedClause(incoming)
        guard !left.isEmpty, !right.isEmpty else { return false }
        return right.hasPrefix(left) || left.hasPrefix(right)
    }

    static func foldedClause(_ text: String) -> String {
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
