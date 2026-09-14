import Foundation

enum LiveTranslationCommitContext {
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

    static func leftoverContainsPriorCaption(_ leftover: String, priors: [String]) -> Bool {
        priors.contains { prior in
            let trimmed = prior.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2 else { return false }
            return leftover.range(
                of: trimmed,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil
        }
    }

    static func shouldPreferConfirmation(
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
