import AppKit
import CoreText
import Foundation

/// Splits a bilingual caption into visual lines and stacks them:
/// Show-as title first, spoken undertone underneath.
///
/// The title is the line the audience reads. It stays the top of the pair,
/// matching the empty-board preview. The spoken line sits under that title
/// with a fixed gap, so a wrap does not move the title to a new slot.
///
/// Wrap fills left to right until the next token does not fit. A narrower
/// board or a larger caption wraps earlier so the line still stays on the
/// board. Do not wrap at a fixed word count while the line still has room.
/// Opening quotes, hyphens, closing marks, and Japanese small kana stay
/// on the same token so a new line starts on a word, not a stray mark.
/// Each caption is the Show-as title and then the spoken line. Empty wrap
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

    /// Gap between wrap lines of the same role. Kept outside the text field
    /// so the glyph cannot float inside a taller box and land on the next line.
    static let rowSpacing: CGFloat = 8

    /// Extra gap between the Show-as block and the spoken line under it.
    static let spokenPairGap: CGFloat = 6

    /// Room inside the line box so a descender is not clipped by the field edge.
    static let linePad: CGFloat = 2

    /// Empty space above the glyph box. The caption cell clips to its title
    /// rect, and Thai marks sit on that edge when the rect starts at the top.
    static let lineTopSlack: CGFloat = 6

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

    /// Live caption height for the current pair. A missing Show-as line keeps
    /// its slot above the spoken line, and a nearly-full title line keeps the
    /// next wrap slot there too, so later ink does not push words already shown.
    static func reservedDisplayHeight(
        rows: [Row],
        spokenFont: NSFont,
        translatedFont: NSFont,
        width: CGFloat
    ) -> CGFloat {
        self.placedFrames(
            rows: rows,
            spokenFont: spokenFont,
            translatedFont: translatedFont,
            width: width,
            reserveGrowth: true
        ).height
    }

    /// Frames for the rows that have ink. `reserveGrowth` inserts an empty
    /// title slot where the next line will land, above the spoken line.
    static func placedFrames(
        rows: [Row],
        spokenFont: NSFont,
        translatedFont: NSFont,
        width: CGFloat,
        reserveGrowth: Bool
    ) -> (frames: [CGRect], height: CGFloat) {
        var layout = rows
        if reserveGrowth {
            if let titleIndex = layout.lastIndex(where: { !$0.isSpoken }) {
                if width >= Self.minimumWrapWidth,
                   self.lastLineIsNearlyFull(layout[titleIndex].text, font: translatedFont, width: width)
                {
                    layout.insert(Row(text: "", isSpoken: false), at: titleIndex + 1)
                }
            } else if !layout.isEmpty {
                layout.insert(Row(text: "", isSpoken: false), at: 0)
            }
        }
        let all = self.lineFrames(
            rows: layout,
            spokenFont: spokenFont,
            translatedFont: translatedFont,
            width: width
        )
        var frames: [CGRect] = []
        frames.reserveCapacity(rows.count)
        for (index, row) in layout.enumerated() where !(row.text.isEmpty && !row.isSpoken) {
            if index < all.count {
                frames.append(all[index])
            }
        }
        let height: CGFloat
        if let last = all.last {
            height = last.maxY + Self.boardTopClearance
        } else {
            height = self.displayHeight(
                rows: [],
                spokenFont: spokenFont,
                translatedFont: translatedFont
            )
        }
        return (frames, height)
    }

    static func lastLineIsNearlyFull(_ text: String, font: NSFont, width: CGFloat) -> Bool {
        let usable = self.fieldInkWidth(width, font: font)
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
        return max(typographic, ink) + Self.linePad + Self.lineTopSlack
    }

    /// Line height for a specific string. `font`'s own metrics (ascender,
    /// descender, boundingRectForFont) describe its native glyphs only. Korean,
    /// Thai, and other scripts the UI font does not cover render through
    /// CoreText's font-substitution cascade, whose real ascent/descent can
    /// exceed what the base font reports — use `inkHeight` so the reserved
    /// row box actually fits what gets drawn.
    static func lineHeight(for text: String, font: NSFont) -> CGFloat {
        let typographic = ceil(font.ascender - font.descender + max(0, font.leading))
        let ink = Self.inkHeight(for: text, font: font)
        return max(typographic, ink) + Self.linePad + Self.lineTopSlack
    }

    /// Real rendered glyph height for `text` in `font`, after CoreText resolves
    /// substitute fonts per character run. Falls back to the base font's own
    /// bounding box when there is no text yet to measure (opening/empty state).
    static func inkHeight(for text: String, font: NSFont) -> CGFloat {
        guard !text.isEmpty else {
            return ceil(font.boundingRectForFont.height)
        }
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font])
        )
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return ceil(ascent + descent + leading)
    }

    /// Frames in the caption view's top-down space. Height uses the same walk,
    /// so the SwiftUI slot and the drawn lines cannot disagree.
    static func lineFrames(
        rows: [Row],
        spokenFont: NSFont,
        translatedFont: NSFont,
        width: CGFloat
    ) -> [CGRect] {
        var frames: [CGRect] = []
        frames.reserveCapacity(rows.count)
        var y = Self.boardTopClearance
        let rowWidth = max(width, 1)
        for (index, row) in rows.enumerated() {
            if index > 0 {
                y += Self.rowSpacing
                if rows[index - 1].isSpoken != row.isSpoken {
                    y += Self.spokenPairGap
                }
            }
            let height = Self.lineHeight(for: row.text, font: row.isSpoken ? spokenFont : translatedFont)
            frames.append(CGRect(x: 0, y: y, width: rowWidth, height: height))
            y += height
        }
        return frames
    }

    static func boardHeight(
        rows: [Row],
        spokenFont: NSFont,
        translatedFont: NSFont
    ) -> CGFloat {
        let frames = Self.lineFrames(
            rows: rows,
            spokenFont: spokenFont,
            translatedFont: translatedFont,
            width: 1
        )
        guard let last = frames.last else { return 0 }
        return last.maxY + Self.boardTopClearance
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
        let spokenLines = self.visualLines(spoken, font: spokenFont, width: width)
        let translatedLines = self.visualLines(translated, font: translatedFont, width: width)
        var rows: [Row] = []
        rows.reserveCapacity(spokenLines.count + translatedLines.count)
        for line in translatedLines {
            self.append(line, isSpoken: false, onto: &rows)
        }
        for line in spokenLines {
            self.append(line, isSpoken: true, onto: &rows)
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

        let spokenProgress = self.progress(
            lines: self.visualLines(spoken, font: spokenFont, width: width),
            printed: printedSpoken
        )
        let translatedProgress = self.progress(
            lines: self.visualLines(translated, font: translatedFont, width: width),
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
        if width < Self.minimumWrapWidth {
            return [trimmed]
        }
        let usableWidth = self.fieldInkWidth(width, font: font)
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

    /// Width the caption cell actually draws into. Wrap uses this so the last
    /// word fills the line and is not clipped by the field inset.
    static func fieldInkWidth(_ width: CGFloat, font: NSFont) -> CGFloat {
        let field = max(width, 1)
        return max(field - Self.horizontalInkInset(font: font), 1)
    }

    private struct InsetKey: Hashable {
        let fontName: String
        let fontSize: CGFloat
    }

    private static var insetCache: [InsetKey: CGFloat] = [:]

    private static func horizontalInkInset(font: NSFont) -> CGFloat {
        let key = InsetKey(fontName: font.fontName, fontSize: font.pointSize)
        self.cacheLock.lock()
        if let cached = self.insetCache[key] {
            self.cacheLock.unlock()
            return cached
        }
        self.cacheLock.unlock()
        let cell = TheaterCaptionInkCell(textCell: String(repeating: "M", count: 40))
        cell.font = font
        cell.isBordered = false
        cell.isBezeled = false
        cell.usesSingleLineMode = true
        cell.isScrollable = false
        cell.lineBreakMode = .byClipping
        let bounds = NSRect(x: 0, y: 0, width: 800, height: 240)
        let title = cell.titleRect(forBounds: bounds)
        let inset = max(Self.textInset, ceil(bounds.width - title.width))
        self.cacheLock.lock()
        self.insetCache[key] = inset
        self.cacheLock.unlock()
        return inset
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
            while !piece.isEmpty, self.lineWidth(piece, font: font) > width, piece.count > 1 {
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
            if self.lineWidth(candidate, font: font) > width {
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
            if !head.isEmpty, self.lineWidth(next, font: font) > width {
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

/// Single-line caption cell. Glyphs sit at the top of the measured slot, so a
/// taller line box cannot slide them. Wrap uses this cell's title width.
final class TheaterCaptionInkCell: NSTextFieldCell {
    override func titleRect(forBounds rect: NSRect) -> NSRect {
        var title = super.titleRect(forBounds: rect)
        guard let font = self.font else { return title }
        let textHeight = TheaterBilingualWrap.inkHeight(for: self.stringValue, font: font)
        let slack = min(TheaterBilingualWrap.lineTopSlack, max(rect.height - 1, 0))
        title.origin.y = rect.minY + slack
        title.size.height = min(rect.height - slack, max(textHeight, 1))
        return title
    }
}
