import Foundation

/// Drops Whisper YouTube boilerplate and clause-level loops before a line prints.
/// Single-grapheme emphasis (ㅋㅋㅋㅋ, ㅎㅎ) and short acknowledgements stay.
enum CaptionJunkGate {
    private static let boilerplate: [String] = [
        "thanks for watching",
        "thank you for watching",
        "thanks for watching.",
        "subtitles by",
        "amara.org",
        "please subscribe",
        "like and subscribe",
        "don't forget to subscribe",
        "do not forget to subscribe",
    ]

    private static let acknowledgements: Set<String> = [
        "네", "예", "맞아요", "응",
        "ครับ", "ค่ะ", "ใช่", "จ้า",
        "yes", "yeah", "yep", "ok", "okay",
    ]

    static func shouldDrop(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if self.isAcknowledgement(trimmed) { return false }
        if self.matchesBoilerplate(trimmed) { return true }
        return self.hasPhraseRepeat(trimmed)
    }

    static func isAcknowledgement(_ text: String) -> Bool {
        let folded = self.foldedToken(text)
        return Self.acknowledgements.contains(folded)
    }

    private static func matchesBoilerplate(_ text: String) -> Bool {
        let folded = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.boilerplate.contains { folded.contains($0) }
    }

    static func hasPhraseRepeat(_ text: String) -> Bool {
        let tokens = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map(String.init)
            .filter { !$0.isEmpty }
        if tokens.count >= 3 {
            for index in 0..<(tokens.count - 2) {
                let token = tokens[index]
                if token.count >= 2,
                   token == tokens[index + 1],
                   token == tokens[index + 2]
                {
                    return true
                }
            }
        }

        let compact = tokens.joined()
        let characters = Array(compact)
        guard characters.count >= 6 else { return false }
        let maxBlock = min(8, characters.count / 3)
        guard maxBlock >= 2 else { return false }
        for blockLength in 2...maxBlock {
            let block = String(characters[0..<blockLength])
            if Set(block).count == 1 { continue }
            var cursor = 0
            var repeats = 0
            while cursor + blockLength <= characters.count,
                  String(characters[cursor..<(cursor + blockLength)]) == block
            {
                repeats += 1
                cursor += blockLength
            }
            if repeats >= 3, cursor * 10 >= characters.count * 8 {
                return true
            }
        }
        return false
    }

    private static func foldedToken(_ text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        return folded.filter { $0.isLetter || $0.isNumber }
    }
}
