import Foundation

/// Presenter-facing marker: has the audience caption caught the last clause?
/// Visual only. Uses the measured e2e clock. Not a score.
enum TheaterPaceCue {
    enum Kind: String, Equatable {
        case behind
        case caughtUp
    }

    struct Snapshot: Equatable {
        var kind: Kind
        var label: String
        var compactLabel: String
        var accessibilityLabel: String
    }

    /// A finished sentence waiting longer than this without a caption is "behind".
    static let behindThresholdMilliseconds = 1500

    /// `pendingWaitMilliseconds` is how long the oldest finished-but-untranslated
    /// sentence has been waiting. Mid-sentence speech alone is never "behind".
    static func snapshot(
        isTranslating: Bool,
        isListening: Bool,
        isPaused: Bool,
        liveSpoken: String,
        lastTranslation: String,
        pendingWaitMilliseconds: Int?
    ) -> Snapshot? {
        guard isTranslating, isListening, !isPaused else { return nil }

        if let wait = pendingWaitMilliseconds, wait >= self.behindThresholdMilliseconds {
            // Whole seconds: a label that changes width every tick makes the
            // chrome row reflow and nudges the caption board.
            let seconds = String(wait / 1000)
            return Snapshot(
                kind: .behind,
                label: "Behind · \(seconds)s",
                compactLabel: "Behind",
                accessibilityLabel: "Caption is behind. A sentence has waited \(seconds) seconds."
            )
        }

        _ = liveSpoken
        let printedTitle = lastTranslation.trimmingCharacters(in: .whitespacesAndNewlines)
        if printedTitle.isEmpty { return nil }

        return Snapshot(
            kind: .caughtUp,
            label: "Caught up",
            compactLabel: "Caught up",
            accessibilityLabel: "The caption caught the last clause."
        )
    }
}
