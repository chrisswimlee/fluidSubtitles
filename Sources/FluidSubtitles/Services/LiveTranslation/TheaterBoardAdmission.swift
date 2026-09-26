import Foundation

/// Whether a finished sentence may become a Theater board row.
/// Propose runs before a sentence is queued. Publish runs after translation,
/// while this sentence is still the in-flight entry. Both phases use the same
/// checklist. Publish ignores this sentence's own in-flight entry, and a
/// translated sentence must still be tracked.
enum TheaterBoardAdmission {
    enum Phase: Equatable {
        case propose
        case publish
    }

    enum Decision: Equatable {
        case admit
        case skip(Reason)
    }

    enum Reason: String, Equatable {
        case empty
        case junk
        case tooThin
        case inFlight
        case sameAsPrinted
        case revisesEarlier
        case revisesNewest
        case untracked
    }

    struct Context: Equatable {
        var peelSources: [String] = []
        var inFlightSources: [String] = []
        var commitIdentities: Set<String> = []
        var latestHypothesis: String = ""
        var requiresTrackedIdentity: Bool = false
        /// Insert Stop may type one trailing fragment the clause cutter refused.
        var allowTrailingFragment: Bool = false
    }

    static func decide(
        _ source: String,
        languageID: String,
        phase: Phase,
        context: Context
    ) -> Decision {
        let cleaned = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return .skip(.empty) }
        if CaptionJunkGate.shouldDrop(cleaned) { return .skip(.junk) }
        if !context.allowTrailingFragment,
           TranslationClauseSegmenter.isTooThinToCommit(cleaned, languageID: languageID)
        {
            return .skip(.tooThin)
        }

        var inFlight = context.inFlightSources
        if phase == .publish {
            inFlight.removeAll { TranslationClauseSegmenter.isSameClause($0, cleaned) }
        }
        if inFlight.contains(where: { TranslationClauseSegmenter.isSameClause($0, cleaned) }) {
            return .skip(.inFlight)
        }

        if context.peelSources.dropLast().contains(where: {
            TranslationClauseSegmenter.isSameClause($0, cleaned)
        }) {
            return .skip(.revisesEarlier)
        }

        if let last = context.peelSources.last {
            if TranslationClauseSegmenter.isSameClause(last, cleaned) {
                return .skip(.sameAsPrinted)
            }
            if TranslationClauseSegmenter.isInPlaceGrowth(previous: last, incoming: cleaned) {
                return .skip(.revisesNewest)
            }
            if Self.revisesNewest(
                previous: last,
                incoming: cleaned,
                languageID: languageID,
                hypothesis: context.latestHypothesis
            ) {
                return .skip(.revisesNewest)
            }
        }
        if context.peelSources.contains(where: { TranslationClauseSegmenter.isSameClause($0, cleaned) }) {
            return .skip(.sameAsPrinted)
        }

        if phase == .publish, context.requiresTrackedIdentity {
            let key = TranslationClauseSegmenter.clauseIdentity(cleaned)
            if key.isEmpty || !context.commitIdentities.contains(key) {
                return .skip(.untracked)
            }
        }
        return .admit
    }

    private static func revisesNewest(
        previous: String,
        incoming: String,
        languageID: String,
        hypothesis: String
    ) -> Bool {
        guard TranslationClauseSegmenter.shouldReviseCommitted(
            previous: previous,
            incoming: incoming,
            languageID: languageID
        ) else { return false }
        if TranslationClauseSegmenter.shouldReplaceLast(previous: previous, incoming: incoming) {
            return true
        }
        guard !hypothesis.isEmpty else { return true }
        return !TranslationClauseSegmenter.contains(hypothesis, clause: previous)
    }
}
