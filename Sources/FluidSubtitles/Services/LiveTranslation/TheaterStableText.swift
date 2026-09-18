import Foundation

/// Speech recognition rewrites its guess as it hears more. Typing every guess
/// makes Theater retype and jump. This keeps only the words two guesses in a
/// row agree on, and only ever grows while the speaker keeps talking.
struct TheaterStableText: Equatable {
    private(set) var shown = ""
    private(set) var hypothesis = ""

    /// Words not yet confirmed by a second guess.
    var hasHiddenTail: Bool { self.shown != self.hypothesis }

    mutating func ingest(_ next: String) -> String {
        let incoming = next.trimmingCharacters(in: .whitespacesAndNewlines)
        // Theater refreshes several times per recognition update. The same
        // guess seen again is not a second guess agreeing with it.
        if incoming == self.hypothesis, !incoming.isEmpty { return self.shown }
        defer { self.hypothesis = incoming }
        guard !incoming.isEmpty else {
            self.shown = ""
            return ""
        }
        let agreed = Self.agreedPrefix(self.hypothesis, incoming)
        if Self.isPrefix(self.shown, of: incoming) {
            if agreed.count > self.shown.count {
                self.shown = agreed
            }
        } else {
            // A confirmed word was revised, or the old clause committed and
            // left the leftover. Fall back to what both guesses still share.
            self.shown = agreed
        }
        return self.shown
    }

    /// The speaker paused: nothing newer is coming, so show the full guess.
    mutating func revealAll() -> String {
        self.shown = self.hypothesis
        return self.shown
    }

    mutating func reset() {
        self.shown = ""
        self.hypothesis = ""
    }

    /// Shared prefix cut back to a whole word. Scripts that do not put spaces
    /// between words (Japanese, Chinese, and Thai, which spaces only phrases)
    /// share by character; `Character` keeps Thai marks on their consonant.
    static func agreedPrefix(_ lhs: String, _ rhs: String) -> String {
        let common = String(zip(lhs, rhs).prefix { $0 == $1 }.map(\.0))
        guard !common.isEmpty else { return "" }
        if common.count == lhs.count, common.count == rhs.count { return common }
        guard rhs.contains(" "), !Self.containsThai(rhs) else { return common }
        let nextIndex = rhs.index(rhs.startIndex, offsetBy: common.count)
        if nextIndex < rhs.endIndex, rhs[nextIndex] == " " {
            return common.trimmingCharacters(in: .whitespaces)
        }
        guard let lastSpace = common.lastIndex(of: " ") else { return "" }
        return String(common[..<lastSpace]).trimmingCharacters(in: .whitespaces)
    }

    private static func containsThai(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0E00...0x0E7F).contains($0.value) }
    }

    private static func isPrefix(_ shown: String, of text: String) -> Bool {
        shown.isEmpty || text.hasPrefix(shown)
    }
}
