import Foundation

struct LiveTranslationPrefetchKey: Hashable {
    var isolatedSource: String
    var priorJoined: String
    var targetID: String
}

enum LiveTranslationPrefetch {
    static func unitToPrefetch(
        leftover: String,
        languageID: String,
        wordByWord: Bool = false
    ) -> String? {
        let trimmed = leftover.trimmingCharacters(in: .whitespacesAndNewlines)
        if wordByWord {
            let open = TranslationClauseSegmenter.liveOpenText(trimmed, languageID: languageID)
            let unit = open.isEmpty ? trimmed : open
            guard !unit.isEmpty, !CaptionJunkGate.shouldDrop(unit) else { return nil }
            if TranslationClauseSegmenter.isCompactScript(languageID) {
                return unit
            }
            return unit.split(whereSeparator: \.isWhitespace).isEmpty ? nil : unit
        }
        let open = TranslationClauseSegmenter.liveOpenText(trimmed, languageID: languageID)
        if open.count >= 8 { return open }
        if trimmed.count >= 8 { return trimmed }
        if let next = TranslationClauseSegmenter.nextCommitUnit(
            leftover,
            languageID: languageID,
            allowPauseFinalize: false
        ) {
            return next.unit
        }
        return nil
    }

    static func cacheKey(
        unit: String,
        priorSources: [String],
        priorIDs: [UInt64] = [],
        sourceID: String,
        targetID: String
    ) -> LiveTranslationPrefetchKey {
        let isolated = TranslationClauseSegmenter.stripTerminalPunctuation(unit)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let priorKey: String
        if !priorIDs.isEmpty {
            priorKey = priorIDs.map(String.init).joined(separator: ",")
        } else {
            priorKey = priorSources
                .map {
                    TranslationClauseSegmenter.stripTerminalPunctuation($0)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                }
                .joined(separator: "\u{1e}")
        }
        return LiveTranslationPrefetchKey(
            isolatedSource: isolated,
            priorJoined: priorKey.isEmpty
                ? TranslationClauseSegmenter.joinTranslatedLines(priorSources, languageID: sourceID)
                : priorKey,
            targetID: targetID
        )
    }

    /// Same pair and priors, and `later` is still this clause growing.
    static func isPrefixGrowth(
        from earlier: LiveTranslationPrefetchKey,
        to later: LiveTranslationPrefetchKey
    ) -> Bool {
        earlier.targetID == later.targetID
            && earlier.priorJoined == later.priorJoined
            && TranslationClauseSegmenter.isGrowingClause(earlier.isolatedSource, toward: later.isolatedSource)
    }

    /// Do not prefetch a unit that is already a commit.
    static func canPrefetch(unit: String, inFlightSources: [String]) -> Bool {
        let cleaned = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }
        return !inFlightSources.contains { TranslationClauseSegmenter.isSameClause($0, cleaned) }
    }
}

/// One-slot sliding-window cache. A newer prefetch of a different key replaces
/// the stored caption so stale Korean/Thai context cannot print.
final class LiveTranslationPrefetchCache: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (key: LiveTranslationPrefetchKey, caption: String)?
    private var inFlight: LiveTranslationPrefetchKey?
    private var generation: UInt64 = 0

    func invalidate() {
        self.lock.lock()
        self.stored = nil
        self.inFlight = nil
        self.generation += 1
        self.lock.unlock()
    }

    /// Commit reuse. Prefix growth stays on the live row via `caption(for:)`.
    func exactCaption(for key: LiveTranslationPrefetchKey) -> String? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let stored, stored.key == key else { return nil }
        return stored.caption
    }

    func caption(for key: LiveTranslationPrefetchKey) -> String? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let stored else { return nil }
        if stored.key == key { return stored.caption }
        // Fast speech grows the leftover before the next prefetch lands.
        // Keep the prefix title on the live row instead of going blank.
        if LiveTranslationPrefetch.isPrefixGrowth(from: stored.key, to: key) {
            return stored.caption
        }
        return nil
    }

    /// Returns the generation token when a prefetch should start.
    func begin(_ key: LiveTranslationPrefetchKey) -> UInt64? {
        self.lock.lock()
        defer { self.lock.unlock() }
        if let stored, stored.key == key { return nil }
        if self.inFlight == key { return nil }
        // A longer leftover of the same clause must not supersede the
        // prefix already in Apple Translation, or Show-as stays empty
        // until the speaker pauses.
        if let inFlight, LiveTranslationPrefetch.isPrefixGrowth(from: inFlight, to: key) {
            return nil
        }
        self.inFlight = key
        return self.generation
    }

    func finish(
        _ key: LiveTranslationPrefetchKey,
        caption: String?,
        generation: UInt64
    ) {
        self.lock.lock()
        defer { self.lock.unlock() }
        if self.inFlight == key {
            self.inFlight = nil
        }
        guard generation == self.generation, let caption, !caption.isEmpty else { return }
        self.stored = (key, caption)
    }
}
