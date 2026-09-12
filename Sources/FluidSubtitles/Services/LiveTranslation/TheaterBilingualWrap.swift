import AppKit
import Foundation

/// Splits a bilingual caption into visual lines and interleaves them:
/// Latin with Hangul or Thai — instead of a full spoken block then a full translation.
///
/// Wrap is measured on the finished sentence so line breaks do not jump while
/// the typewriter is still printing. Later wrap-pairs stay hidden until the
/// current pair has finished.
enum TheaterBilingualWrap {
    struct Row: Equatable {
        let text: String
        let isSpoken: Bool
    }

    /// Horizontal inset of `NSTextField(wrappingLabelWithString:)`. Measuring
    /// wrap at the full view width makes a "fitting" line clip.
    static let textInset: CGFloat = 8

    /// Below this, Theater has not laid out yet. Do not invent per-glyph wraps.
    static let minimumWrapWidth: CGFloat = 32

    static func rows(
        spoken: String,
        translated: String,
        font: NSFont,
        width: CGFloat
    ) -> [Row] {
        let usable = Self.usableWidth(width)
        let spokenLines = self.visualLines(spoken, font: font, width: usable)
        let translatedLines = self.visualLines(translated, font: font, width: usable)
        if spokenLines.isEmpty {
            return translatedLines.map { Row(text: $0, isSpoken: false) }
        }
        if translatedLines.isEmpty {
            return spokenLines.map { Row(text: $0, isSpoken: true) }
        }

        let englishFirst = (self.looksHangul(spoken) || self.looksThai(spoken))
            && self.looksLatin(translated)
        let count = max(spokenLines.count, translatedLines.count)
        var rows: [Row] = []
        rows.reserveCapacity(count * 2)
        for index in 0..<count {
            let spokenLine = index < spokenLines.count ? spokenLines[index] : ""
            let translatedLine = index < translatedLines.count ? translatedLines[index] : ""
            if englishFirst {
                self.append(translatedLine, isSpoken: false, onto: &rows)
                self.append(spokenLine, isSpoken: true, onto: &rows)
            } else {
                self.append(spokenLine, isSpoken: true, onto: &rows)
                self.append(translatedLine, isSpoken: false, onto: &rows)
            }
        }
        return rows
    }

    /// Same pairing as `rows`, but only the wrap-pairs the typewriter has reached.
    static func revealedRows(
        spoken: String,
        translated: String,
        printedSpoken: String,
        printedTranslated: String,
        font: NSFont,
        width: CGFloat
    ) -> [Row] {
        let template = self.rows(spoken: spoken, translated: translated, font: font, width: width)
        guard !template.isEmpty else { return [] }
        if printedSpoken == spoken, printedTranslated == translated {
            return template
        }

        let usable = Self.usableWidth(width)
        let spokenProgress = self.progress(
            lines: self.visualLines(spoken, font: font, width: usable),
            printed: printedSpoken
        )
        let translatedProgress = self.progress(
            lines: self.visualLines(translated, font: font, width: usable),
            printed: printedTranslated
        )

        var spokenIndex = 0
        var translatedIndex = 0
        var revealed: [Row] = []
        for group in self.groupedPairs(template) {
            var groupFinished = true
            for row in group {
                let index: Int
                let state: LineProgress
                if row.isSpoken {
                    index = spokenIndex
                    spokenIndex += 1
                    state = spokenProgress
                } else {
                    index = translatedIndex
                    translatedIndex += 1
                    state = translatedProgress
                }
                let step = self.reveal(row, index: index, progress: state)
                if let visible = step.row {
                    revealed.append(visible)
                }
                if !step.finished {
                    groupFinished = false
                    break
                }
            }
            if !groupFinished {
                break
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
        let storage = NSTextStorage(string: trimmed, attributes: [
            .font: font,
        ])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: usableWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 0
        container.lineBreakMode = .byWordWrapping
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)

        let glyphRange = manager.glyphRange(for: container)
        guard glyphRange.length > 0 else { return [trimmed] }

        var lines: [String] = []
        let nsText = trimmed as NSString
        manager.enumerateLineFragments(forGlyphRange: glyphRange) { _, _, _, fragmentGlyphs, _ in
            let characters = manager.characterRange(forGlyphRange: fragmentGlyphs, actualGlyphRange: nil)
            var line = nsText.substring(with: characters)
            if line.hasSuffix("\n") {
                line.removeLast()
            }
            lines.append(line)
        }
        return lines.isEmpty ? [trimmed] : lines
    }

    private struct LineProgress {
        var completeCount: Int
        var partial: String
        var finished: Bool
    }

    private static func usableWidth(_ width: CGFloat) -> CGFloat {
        max(width - Self.textInset, 1)
    }

    private static func append(_ text: String, isSpoken: Bool, onto rows: inout [Row]) {
        guard !text.isEmpty else { return }
        rows.append(Row(text: text, isSpoken: isSpoken))
    }

    private static func groupedPairs(_ rows: [Row]) -> [[Row]] {
        var groups: [[Row]] = []
        var index = 0
        while index < rows.count {
            if index + 1 < rows.count, rows[index].isSpoken != rows[index + 1].isSpoken {
                groups.append([rows[index], rows[index + 1]])
                index += 2
            } else {
                groups.append([rows[index]])
                index += 1
            }
        }
        return groups
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
            if line.hasPrefix(remaining) {
                return LineProgress(completeCount: complete, partial: remaining, finished: false)
            }
            if remaining.count >= line.count {
                remaining = String(remaining.dropFirst(line.count))
                complete += 1
                continue
            }
            return LineProgress(completeCount: complete, partial: remaining, finished: false)
        }
        return LineProgress(completeCount: complete, partial: "", finished: remaining.isEmpty)
    }

    private static func reveal(
        _ row: Row,
        index: Int,
        progress: LineProgress
    ) -> (row: Row?, finished: Bool) {
        if index < progress.completeCount {
            return (row, true)
        }
        if progress.finished {
            return (row, true)
        }
        if index == progress.completeCount {
            if progress.partial.isEmpty {
                return (nil, false)
            }
            return (Row(text: progress.partial, isSpoken: row.isSpoken), false)
        }
        return (nil, false)
    }

    private static func looksLatin(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            CharacterSet.letters.contains(scalar) && scalar.isASCII
        }
    }

    private static func looksHangul(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let value = scalar.value
            return (0xAC00...0xD7A3).contains(value)
                || (0x1100...0x11FF).contains(value)
                || (0x3130...0x318F).contains(value)
        }
    }

    private static func looksThai(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x0E00...0x0E7F).contains(scalar.value)
        }
    }
}
