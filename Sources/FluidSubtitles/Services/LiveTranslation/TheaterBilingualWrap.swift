import AppKit
import Foundation

/// Splits a bilingual caption into visual lines and stacks them:
/// spoken undertone first (fixed slot), translation title grows below.
///
/// Spoken goes first so its row position never moves as the translation
/// streams in — only rows below it are added or resized. Reordering this
/// (translation before spoken) makes the spoken line's index, and thus its
/// on-screen position, shift every time the translation's line count
/// changes, which reads as a jump rather than smooth growth.
///
/// Wrap fills left to right until the next token does not fit. A narrower
/// board or a larger caption wraps earlier so the line still stays on the
/// board. Do not wrap at a fixed word count while the line still has room.
/// Opening quotes, hyphens, closing marks, and Japanese small kana stay
/// on the same token so a new line starts on a word, not a stray mark.
/// Each caption is the spoken line and then its Show-as title. Empty wrap
/// slots stay off the ink so a short sentence does not look like it
/// already wrapped.
enum TheaterBilingualWrap {
    /// Non-ASCII title scripts (Korean, Japanese, Thai) size by character, not word.
    static func titleUsesCompactScript(_ text: String) -> Bool {
        text.contains { character in
            !character.isASCII && !character.isWhitespace && !character.isNewline
        }
    }

    struct Row: Equatable {
        let text: String
        let isSpoken: Bool
    }

    /// NSTextField cells inset about two points. Do not steal more than that
    /// or a line wraps while the board still has room.
    static let textInset: CGFloat = 2

    /// Below this, Theater has not laid out yet. Do not invent per-glyph wraps.
    static let minimumWrapWidth: CGFloat = 80

    /// Ignore GeometryReader jitter below this so wrap lines stay put when
    /// the board grows a little. A narrower board always rewraps.
    static let wrapWidthHysteresis: CGFloat = 24

    static let rowSpacing: CGFloat = 2

    /// Extra height so NSTextField can draw ascenders and the slide halo.
    static let lineVerticalInset: CGFloat = 10

    /// First-line halo / shadow sits above the ink. Keep it in the board height
    /// so ScrollView does not clip the opening title.
    static let boardTopClearance: CGFloat = 10

    /// About five ems. If the last title line has less room than this, reserve
    /// a second unused slot so wrap does not grow the board.
    static let wrapLookaheadEm: CGFloat = 5

    /// Floor so a first-frame measurement does not claim the line is empty.
    static let latinMinimumWords = 4
    static let compactMinimumCharacters = 8
    /// Average Latin word plus a space, used to see how many words the board holds.
    static let latinSampleWord = "words "

    /// One title line plus halo. Use this for the first paint so SwiftUI does
    /// not size the live row to a single pixel and clip the opening letters.
    static func openingBoardHeight(font: NSFont) -> CGFloat {
        Self.boardTopClearance + Self.lineHeight(for: font)
    }

    /// Finished wrap height, but never shorter than one title line while there
    /// is nothing to measure yet. An empty first paint with a real board width
    /// used to report 1 pt and slice the original sentence through the middle.
    /// Once real rows exist (even just the small spoken line, before
    /// translation starts), use their actual height instead of also
    /// reserving room for a full translated-size line that is not on screen.
    static func displayHeight(
        rows: [Row],
        spokenFont: NSFont,
        translatedFont: NSFont
    ) -> CGFloat {
        guard !rows.isEmpty else {
            return Self.openingBoardHeight(font: translatedFont)
        }
        return Self.boardHeight(
            rows: rows,
            spokenFont: spokenFont,
            translatedFont: translatedFont
        )
    }

    /// Live caption height for the current pair. Spoken-only rows keep one
    /// Show-as slot so the title does not grow the board when it starts.
    /// A nearly-full last title line keeps one unused wrap slot so the next
    /// glyph does not jump existing ink.
    static func reservedDisplayHeight(
        rows: [Row],
        spokenFont: NSFont,
        translatedFont: NSFont,
        width: CGFloat
    ) -> CGFloat {
        let base = self.displayHeight(
            rows: rows,
            spokenFont: spokenFont,
            translatedFont: translatedFont
        )
        if let lastTitle = rows.last(where: { !$0.isSpoken }) {
            guard width >= Self.minimumWrapWidth,
                  self.lastLineIsNearlyFull(lastTitle.text, font: translatedFont, width: width)
            else {
                return base
            }
            return base + Self.rowSpacing + Self.lineHeight(for: translatedFont)
        }
        guard !rows.isEmpty else { return base }
        return base + Self.rowSpacing + Self.lineHeight(for: translatedFont)
    }

    static func lastLineIsNearlyFull(_ text: String, font: NSFont, width: CGFloat) -> Bool {
        let usable = self.usableWidth(width)
        let used = text.isEmpty ? 0 : self.lineWidth(text, font: font)
        return usable - used < ceil(font.pointSize * Self.wrapLookaheadEm)
    }

    /// How many words (or compact characters) actually fit on this width.
    /// Used by tests and reserved-height helpers. Wrap itself fills until
    /// the next token does not fit.
    static func targetLineUnits(for text: String, font: NSFont, width: CGFloat) -> Int {
        let usable = max(width, 1)
        if Self.titleUsesCompactScript(text) {
            let em = max(font.pointSize, 1)
            let fit = Int(floor(usable / em))
            return max(fit, Self.compactMinimumCharacters)
        }
        let wordWidth = max(self.lineWidth(Self.latinSampleWord, font: font), 1)
        let fit = Int(floor(usable / wordWidth))
        return max(fit, Self.latinMinimumWords)
    }

    static func lineUnits(_ text: String) -> Int {
        if Self.titleUsesCompactScript(text) {
            return text.filter { !$0.isWhitespace && !$0.isNewline }.count
        }
        return text.split(whereSeparator: { $0.isWhitespace }).filter { !$0.isEmpty }.count
    }

    /// `nil` until Theater has a real board width. Wrapping against a first-frame
    /// 0–32 pt proposal puts the whole sentence on one line and clips it.
    static func layoutWrapWidth(proposed: CGFloat, locked: CGFloat) -> CGFloat? {
        let width = max(proposed, 1)
        if width >= Self.minimumWrapWidth {
            return self.resolvedWrapWidth(proposed: width, locked: locked)
        }
        if locked >= Self.minimumWrapWidth {
            return locked
        }
        return nil
    }

    static func lineHeight(for font: NSFont) -> CGFloat {
        let typographic = ceil(font.ascender - font.descender + max(0, font.leading))
        let ink = ceil(font.boundingRectForFont.height)
        return max(typographic, ink) + Self.lineVerticalInset
    }

    static func boardHeight(
        rows: [Row],
        spokenFont: NSFont,
        translatedFont: NSFont
    ) -> CGFloat {
        guard !rows.isEmpty else { return 0 }
        var height: CGFloat = Self.boardTopClearance
        for (index, row) in rows.enumerated() {
            if index > 0 {
                height += Self.rowSpacing
            }
            height += Self.lineHeight(for: row.isSpoken ? spokenFont : translatedFont)
        }
        return height
    }

    static func rows(
        spoken: String,
        translated: String,
        font: NSFont,
        width: CGFloat
    ) -> [Row] {
        self.rows(
            spoken: spoken,
            translated: translated,
            spokenFont: font,
            translatedFont: font,
            width: width
        )
    }

    static func rows(
        spoken: String,
        translated: String,
        spokenFont: NSFont,
        translatedFont: NSFont,
        width: CGFloat
    ) -> [Row] {
        let usable = Self.usableWidth(width)
        let spokenLines = self.visualLines(spoken, font: spokenFont, width: usable)
        let translatedLines = self.visualLines(translated, font: translatedFont, width: usable)
        var rows: [Row] = []
        rows.reserveCapacity(spokenLines.count + translatedLines.count)
        for line in spokenLines {
            self.append(line, isSpoken: true, onto: &rows)
        }
        for line in translatedLines {
            self.append(line, isSpoken: false, onto: &rows)
        }
        return rows
    }

    /// Same stacking as `rows`. Wrap lines with no ink yet stay off the
    /// board so a short sentence does not reserve the next line.
    static func revealedRows(
        spoken: String,
        translated: String,
        printedSpoken: String,
        printedTranslated: String,
        font: NSFont,
        width: CGFloat
    ) -> [Row] {
        self.revealedRows(
            spoken: spoken,
            translated: translated,
            printedSpoken: printedSpoken,
            printedTranslated: printedTranslated,
            spokenFont: font,
            translatedFont: font,
            width: width
        )
    }

    static func revealedRows(
        spoken: String,
        translated: String,
        printedSpoken: String,
        printedTranslated: String,
        spokenFont: NSFont,
        translatedFont: NSFont,
        width: CGFloat
    ) -> [Row] {
        let template = self.rows(
            spoken: spoken,
            translated: translated,
            spokenFont: spokenFont,
            translatedFont: translatedFont,
            width: width
        )
        guard !template.isEmpty else { return [] }
        if printedSpoken == spoken, printedTranslated == translated {
            return template
        }

        let usable = Self.usableWidth(width)
        let spokenProgress = self.progress(
            lines: self.visualLines(spoken, font: spokenFont, width: usable),
            printed: printedSpoken
        )
        let translatedProgress = self.progress(
            lines: self.visualLines(translated, font: translatedFont, width: usable),
            printed: printedTranslated
        )

        var spokenIndex = 0
        var translatedIndex = 0
        var revealed: [Row] = []
        revealed.reserveCapacity(template.count)
        for row in template {
            if row.isSpoken {
                let next = self.reveal(row, index: spokenIndex, progress: spokenProgress)
                spokenIndex += 1
                if next.text.isEmpty, !spokenProgress.finished {
                    continue
                }
                revealed.append(next)
            } else {
                let next = self.reveal(row, index: translatedIndex, progress: translatedProgress)
                translatedIndex += 1
                if next.text.isEmpty, !translatedProgress.finished {
                    continue
                }
                revealed.append(next)
            }
        }
        return revealed
    }

    static func visualLines(_ text: String, font: NSFont, width: CGFloat) -> [String] {
        let trimmed = text
        guard !trimmed.isEmpty else { return [] }
        let usableWidth = max(width, 1)
        if usableWidth < Self.minimumWrapWidth {
            return [trimmed]
        }
        let key = WrapCacheKey(
            text: trimmed,
            fontName: font.fontName,
            fontSize: font.pointSize,
            width: Int((usableWidth * 2).rounded())
        )
        if let cached = self.cachedLines(key) {
            return cached
        }
        let lines = self.fillLines(trimmed, font: font, width: usableWidth)
        self.storeLines(lines, for: key)
        return lines
    }

    static func resolvedWrapWidth(proposed: CGFloat, locked: CGFloat) -> CGFloat {
        let width = max(proposed, 1)
        if width >= Self.minimumWrapWidth, locked >= Self.minimumWrapWidth {
            if locked - width >= 1 {
                return width
            }
            if width - locked < Self.wrapWidthHysteresis {
                return locked
            }
            return width
        }
        if width >= Self.minimumWrapWidth {
            return width
        }
        if locked >= Self.minimumWrapWidth {
            return locked
        }
        return width
    }

    private struct LineProgress {
        var completeCount: Int
        var partial: String
        var finished: Bool
    }

    private struct WrapCacheKey: Hashable {
        let text: String
        let fontName: String
        let fontSize: CGFloat
        let width: Int
    }

    private static let cacheLock = NSLock()
    private static var lineCache: [WrapCacheKey: [String]] = [:]
    private static var cacheOrder: [WrapCacheKey] = []
    private static let cacheLimit = 64

    private static func usableWidth(_ width: CGFloat) -> CGFloat {
        max(width - Self.textInset, 1)
    }

    private static func append(_ text: String, isSpoken: Bool, onto rows: inout [Row]) {
        guard !text.isEmpty else { return }
        rows.append(Row(text: text, isSpoken: isSpoken))
    }

    private static func cachedLines(_ key: WrapCacheKey) -> [String]? {
        self.cacheLock.lock()
        defer { self.cacheLock.unlock() }
        return self.lineCache[key]
    }

    private static func storeLines(_ lines: [String], for key: WrapCacheKey) {
        self.cacheLock.lock()
        defer { self.cacheLock.unlock() }
        if self.lineCache[key] == nil {
            self.cacheOrder.append(key)
        }
        self.lineCache[key] = lines
        while self.cacheOrder.count > self.cacheLimit {
            let stale = self.cacheOrder.removeFirst()
            self.lineCache.removeValue(forKey: stale)
        }
    }

    /// Fill left to right. Lock a line only when the next token does not fit.
    /// A fixed word-count wrap hopped the last words to the next line while
    /// the board still had room, and a restitch made that look like a jump.
    private static func fillLines(_ text: String, font: NSFont, width: CGFloat) -> [String] {
        var lines: [String] = []
        var current = ""

        func commitCurrent() {
            guard !current.isEmpty else { return }
            lines.append(current)
            current = ""
        }

        func startLine(_ raw: String) {
            var piece = String(raw.drop(while: { $0.isWhitespace }))
            if piece.isEmpty {
                piece = raw
            }
            while !piece.isEmpty, self.lineWidth(piece, font: font) > width + 1, piece.count > 1 {
                let (head, tail) = self.prefixFitting(piece, font: font, width: width)
                if head.isEmpty {
                    break
                }
                lines.append(head)
                piece = tail
            }
            current = piece
        }

        for token in self.tokens(text) {
            if current.isEmpty {
                startLine(token)
                continue
            }
            let candidate = current + token
            if self.lineWidth(candidate, font: font) > width + 1 {
                commitCurrent()
                startLine(token)
                continue
            }
            current = candidate
        }
        commitCurrent()
        return lines.isEmpty ? [text] : lines
    }

    /// Last-resort split so a long Latin word is not clipped off the board.
    /// Keep opening punctuation and line-start-forbidden marks with their glyph.
    private static func prefixFitting(
        _ text: String,
        font: NSFont,
        width: CGFloat
    ) -> (String, String) {
        var head = ""
        for character in text {
            let next = head + String(character)
            if !head.isEmpty, self.lineWidth(next, font: font) > width + 1 {
                break
            }
            head = next
        }
        if head.isEmpty, let first = text.first {
            head = String(first)
        }
        var tail = String(text.dropFirst(head.count))
        if Self.isOpeningPrefix(head), let first = tail.first {
            head.append(first)
            tail.removeFirst()
        }
        while let first = tail.first, Self.isLineStartForbidden(first) {
            head.append(first)
            tail.removeFirst()
        }
        return (head, tail)
    }

    private static func tokens(_ text: String) -> [String] {
        self.mergeUnbreakable(self.rawAtoms(text))
    }

    /// Whitespace runs, Latin words, and one glyph for everything else.
    /// Glue / kinsoku happens in `mergeUnbreakable` so wrap points stay
    /// on a word, quote, or Japanese cluster instead of a stray mark.
    private static func rawAtoms(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var kind: TokenKind?

        for character in text {
            let next: TokenKind
            if character.isWhitespace {
                next = .space
            } else if character.isASCII, character.isLetter || character.isNumber {
                next = .latin
            } else {
                if !current.isEmpty {
                    result.append(current)
                    current = ""
                    kind = nil
                }
                result.append(String(character))
                continue
            }
            if kind == nil || kind == next {
                current.append(character)
                kind = next
            } else {
                result.append(current)
                current = String(character)
                kind = next
            }
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    private static func mergeUnbreakable(_ atoms: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < atoms.count {
            var token = atoms[index]
            index += 1

            while index < atoms.count, self.cannotStartLine(atoms[index], previous: token) {
                token += atoms[index]
                index += 1
            }

            if Self.isOpeningPrefix(token),
               index < atoms.count,
               !atoms[index].allSatisfy({ $0.isWhitespace })
            {
                token += atoms[index]
                index += 1
                while index < atoms.count, self.cannotStartLine(atoms[index], previous: token) {
                    token += atoms[index]
                    index += 1
                }
            }

            while index < atoms.count,
                  token.last.map(Self.isWordJoiner) == true,
                  self.isLatinAtom(atoms[index])
            {
                token += atoms[index]
                index += 1
            }

            result.append(token)
        }
        return result
    }

    private static func cannotStartLine(_ atom: String, previous: String) -> Bool {
        guard let first = atom.first else { return false }
        if Self.isAmbiguousQuote(first) {
            return !previous.allSatisfy(\.isWhitespace)
        }
        return atom.allSatisfy(Self.isLineStartForbidden)
    }

    private static func isOpeningPrefix(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy {
            Self.lineEndForbidden.contains($0) || Self.isAmbiguousQuote($0)
        }
    }

    private static func isLatinAtom(_ atom: String) -> Bool {
        let trimmed = atom.drop(while: { $0.isWhitespace })
        guard let first = trimmed.first else { return false }
        return first.isASCII && (first.isLetter || first.isNumber)
    }

    private static func isWordJoiner(_ character: Character) -> Bool {
        character == "-" || character == "\u{2010}" || character == "\u{2011}"
            || character == "'" || character == "\u{2019}"
    }

    private static func isAmbiguousQuote(_ character: Character) -> Bool {
        character == "\"" || character == "'"
    }

    /// Marks that must not begin a Theater line (closing punct, small kana).
    private static func isLineStartForbidden(_ character: Character) -> Bool {
        Self.lineStartForbidden.contains(character) || Self.smallKana.contains(character)
    }

    /// Closing punctuation, prolonged sound, iteration marks, units.
    private static let lineStartForbidden: Set<Character> = [
        ".", ",", "!", "?", ";", ":", "…", "‥", "'", "’", "”", "—", "–",
        "、", "。", "！", "？", "｡", "､", "」", "』", "】", "〉", "》",
        ")", "]", "}", "〕", "］", "｝",
        "ー", "ｰ", "ゝ", "ゞ", "々", "ヽ", "ヾ", "・", "･",
        "%", "°", "ๆ", "ฯ",
    ]

    /// Opening punctuation must travel with the next word, not end a line.
    private static let lineEndForbidden: Set<Character> = [
        "\"", "“", "‘", "(", "「", "『", "【", "〈", "《", "[", "{", "〔", "［", "｛",
    ]

    private static let smallKana: Set<Character> = [
        "ぁ", "ぃ", "ぅ", "ぇ", "ぉ", "っ", "ゃ", "ゅ", "ょ", "ゎ", "ゕ", "ゖ",
        "ァ", "ィ", "ゥ", "ェ", "ォ", "ッ", "ャ", "ュ", "ョ", "ヮ", "ヵ", "ヶ",
    ]

    private enum TokenKind {
        case space
        case latin
    }

    private static func lineWidth(_ text: String, font: NSFont) -> CGFloat {
        let size = (text as NSString).size(withAttributes: [.font: font])
        return ceil(size.width)
    }

    private static func progress(lines: [String], printed: String) -> LineProgress {
        if lines.isEmpty {
            return LineProgress(completeCount: 0, partial: "", finished: printed.isEmpty)
        }
        if printed == lines.joined() {
            return LineProgress(completeCount: lines.count, partial: "", finished: true)
        }
        var remaining = printed
        var complete = 0
        for line in lines {
            if remaining.hasPrefix(line) {
                remaining.removeFirst(line.count)
                complete += 1
                continue
            }
            let peeled = String(remaining.drop(while: { $0.isWhitespace }))
            if peeled != remaining, peeled.hasPrefix(line) {
                remaining = String(peeled.dropFirst(line.count))
                complete += 1
                continue
            }
            if line.hasPrefix(remaining) {
                return LineProgress(completeCount: complete, partial: remaining, finished: false)
            }
            if line.hasPrefix(peeled) {
                return LineProgress(completeCount: complete, partial: peeled, finished: false)
            }
            return LineProgress(completeCount: complete, partial: remaining, finished: false)
        }
        return LineProgress(completeCount: complete, partial: "", finished: remaining.drop(while: { $0.isWhitespace }).isEmpty)
    }

    private static func reveal(
        _ row: Row,
        index: Int,
        progress: LineProgress
    ) -> Row {
        if index < progress.completeCount || progress.finished {
            return row
        }
        if index == progress.completeCount, !progress.partial.isEmpty {
            return Row(text: progress.partial, isSpoken: row.isSpoken)
        }
        return Row(text: "", isSpoken: row.isSpoken)
    }
}
