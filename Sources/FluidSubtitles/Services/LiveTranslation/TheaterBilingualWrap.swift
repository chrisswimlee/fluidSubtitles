import AppKit
import Foundation

/// Splits a bilingual caption into visual lines and stacks them:
/// translation title first, spoken undertone below.
///
/// Wrap is a greedy left-to-right fill so a printed word does not jump to
/// another line when the sentence grows. Spoken and translated blocks
/// reveal independently. The live title grows as it types — empty wrap slots
/// are not reserved ahead of the printed Show-as line.
enum TheaterBilingualWrap {
    struct Row: Equatable {
        let text: String
        let isSpoken: Bool
    }

    /// Horizontal inset of the caption line fields. Measuring wrap at the
    /// full view width makes a fitting line clip. NSTextField draws a little
    /// wider than `size(withAttributes:)`, so keep slack here.
    static let textInset: CGFloat = 12
    static let wrapSlack: CGFloat = 4

    /// Below this, Theater has not laid out yet. Do not invent per-glyph wraps.
    static let minimumWrapWidth: CGFloat = 32

    /// Ignore GeometryReader jitter below this so wrap lines stay put.
    static let wrapWidthHysteresis: CGFloat = 24

    static let rowSpacing: CGFloat = 2

    static func lineHeight(for font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + max(0, font.leading))
    }

    static func boardHeight(
        rows: [Row],
        spokenFont: NSFont,
        translatedFont: NSFont
    ) -> CGFloat {
        guard !rows.isEmpty else { return 0 }
        var height: CGFloat = 0
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
        for line in translatedLines {
            self.append(line, isSpoken: false, onto: &rows)
        }
        for line in spokenLines {
            self.append(line, isSpoken: true, onto: &rows)
        }
        return rows
    }

    /// Same stacking as `rows`. Live Show-as wrap lines that have not started
    /// printing are omitted so a blank title band does not pop in. Spoken
    /// undertone rows stay so the reference line does not jump.
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
                revealed.append(self.reveal(row, index: spokenIndex, progress: spokenProgress))
                spokenIndex += 1
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
        if width >= Self.minimumWrapWidth,
           locked >= Self.minimumWrapWidth,
           abs(width - locked) < Self.wrapWidthHysteresis
        {
            return locked
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

    /// Fill left to right and lock a line once the next token does not fit.
    /// Remeasuring the whole sentence with AppKit wrap can move a printed word.
    private static func fillLines(_ text: String, font: NSFont, width: CGFloat) -> [String] {
        var lines: [String] = []
        var current = ""
        for token in self.tokens(text) {
            if current.isEmpty {
                let start = String(token.drop(while: { $0.isWhitespace }))
                current = start.isEmpty ? token : start
                continue
            }
            let candidate = current + token
            if self.lineWidth(candidate, font: font) + Self.wrapSlack <= width {
                current = candidate
                continue
            }
            lines.append(current)
            let next = String(token.drop(while: { $0.isWhitespace }))
            current = next.isEmpty ? token : next
        }
        if !current.isEmpty {
            lines.append(current)
        }
        return lines.isEmpty ? [text] : lines
    }

    private static func tokens(_ text: String) -> [String] {
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

    private enum TokenKind {
        case space
        case latin
        case other
    }

    private static func lineWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
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
