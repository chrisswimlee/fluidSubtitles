import Foundation

struct LiveTranslationPrefetchKey: Hashable {
    var isolatedSource: String
    var priorJoined: String
    var targetID: String
}

enum LiveTranslationPrefetch {
    static func unitToPrefetch(leftover: String, languageID: String) -> String? {
        if let next = TranslationClauseSegmenter.nextCommitUnit(
            leftover,
            languageID: languageID,
            allowPauseFinalize: false
        ) {
            return next.unit
        }
        let split = TranslationClauseSegmenter.split(leftover, languageID: languageID)
        if let first = split.completed.first {
            return first
        }
        if TranslationClauseSegmenter.decision(forTail: split.tail, languageID: languageID) == .commitNow {
            return nil
        }
        if TranslationClauseSegmenter.isReadyToCommit(split.tail, languageID: languageID) {
            return split.tail
        }
        return nil
    }

    static func cacheKey(
        unit: String,
        priorSources: [String],
        sourceID: String,
        targetID: String
    ) -> LiveTranslationPrefetchKey {
        LiveTranslationPrefetchKey(
            isolatedSource: unit.trimmingCharacters(in: .whitespacesAndNewlines),
            priorJoined: TranslationClauseSegmenter.joinTranslatedLines(priorSources, languageID: sourceID),
            targetID: targetID
        )
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

    func caption(for key: LiveTranslationPrefetchKey) -> String? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let stored, stored.key == key else { return nil }
        return stored.caption
    }

    /// Returns the generation token when a prefetch should start.
    func begin(_ key: LiveTranslationPrefetchKey) -> UInt64? {
        self.lock.lock()
        defer { self.lock.unlock() }
        if let stored, stored.key == key { return nil }
        if self.inFlight == key { return nil }
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
