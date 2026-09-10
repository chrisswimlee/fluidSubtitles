import Foundation

/// Splits a growing lecture transcript into finished clauses and an open tail.
/// Used so Theater commits one sentence at a time instead of the whole talk.
enum TranslationClauseSegmenter {
    struct Split: Equatable {
        var completed: [String]
        var tail: String
    }

    enum CommitDecision: Equatable {
        case ignore
        case commitNow
        case waitForStability
    }

    static func languageCode(from languageID: String) -> String {
        languageID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .first
            .map(String.init) ?? languageID.lowercased()
    }

    static func isVerbFinalLanguage(_ languageID: String) -> Bool {
        switch self.languageCode(from: languageID) {
        case "ko", "ja":
            return true
        default:
            return false
        }
    }

    static func split(_ text: String, languageID: String) -> Split {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Split(completed: [], tail: "") }

        var completed: [String] = []
        var start = trimmed.startIndex
        var index = trimmed.startIndex

        while index < trimmed.endIndex {
            let next = trimmed.index(after: index)
            if self.isBoundary(in: trimmed, at: index, languageID: languageID) {
                let piece = String(trimmed[start..<next]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty {
                    completed.append(piece)
                }
                start = next
                while start < trimmed.endIndex, trimmed[start].isWhitespace {
                    start = trimmed.index(after: start)
                }
                index = start
                continue
            }
            index = next
        }

        var tail = start < trimmed.endIndex
            ? String(trimmed[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""

        // Keep a finished-looking tail open until the presentation settle
        // so ASR can still revise the last words.

        while tail.count >= LiveTranslationTiming.maxDraftCharacters {
            let forced = self.forceCut(tail)
            if forced.head.isEmpty { break }
            completed.append(forced.head)
            tail = forced.rest
        }

        return Split(completed: completed, tail: tail)
    }

    static func looksComplete(_ text: String, languageID: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if let last = trimmed.unicodeScalars.last, Self.terminalPunctuation.contains(last) {
            return true
        }
        switch self.languageCode(from: languageID) {
        case "ko":
            return self.hasKoreanPredicateEnding(trimmed)
        case "ja":
            return self.hasJapanesePredicateEnding(trimmed)
        case "th":
            return self.hasThaiClauseEnding(trimmed)
        default:
            return false
        }
    }

    static func decision(forTail tail: String, languageID: String) -> CommitDecision {
        let trimmed = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .ignore }
        if trimmed.count >= LiveTranslationTiming.maxDraftCharacters { return .commitNow }
        return .waitForStability
    }

    static func settleNanoseconds(unreadCount: Int, tail: String, languageID: String) -> UInt64 {
        if unreadCount > 0 {
            return LiveTranslationTiming.completeSettleNanoseconds(languageID: languageID)
        }
        if self.looksComplete(tail, languageID: languageID) {
            return LiveTranslationTiming.completeSettleNanoseconds(languageID: languageID)
        }
        if tail.count >= LiveTranslationTiming.maxDraftCharacters {
            return 0
        }
        return LiveTranslationTiming.openSettleNanoseconds(languageID: languageID)
    }

    static func isReadyToCommit(
        _ text: String,
        languageID: String,
        allowPauseFinalize: Bool = false
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if trimmed.count >= LiveTranslationTiming.maxDraftCharacters { return true }
        if self.looksComplete(trimmed, languageID: languageID) { return true }
        return allowPauseFinalize && self.isPauseFinalizable(trimmed, languageID: languageID)
    }

    static func isPauseFinalizable(_ text: String, languageID: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if self.looksComplete(trimmed, languageID: languageID) { return true }
        if self.isVerbFinalLanguage(languageID) {
            return trimmed.count >= LiveTranslationTiming.minPauseFinalizeCharactersVerbFinal
        }
        if self.languageCode(from: languageID) == "th" {
            return trimmed.count >= LiveTranslationTiming.minPauseFinalizeCharactersThai
        }
        let words = trimmed.split { $0.isWhitespace }.filter { !$0.isEmpty }
        return words.count >= LiveTranslationTiming.minPauseFinalizeWords
            || trimmed.count >= LiveTranslationTiming.minPauseFinalizeCharacters
    }

    static func shouldRestartSettle(previous: String, incoming: String) -> Bool {
        let next = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        if next.isEmpty { return false }
        if last.isEmpty { return true }
        if self.isSameClause(last, next) { return false }
        if self.shouldIgnoreAsStalePrefix(previous: last, incoming: next) { return false }
        return true
    }

    static func isCompactScript(_ languageID: String) -> Bool {
        switch self.languageCode(from: languageID) {
        case "ko", "ja", "zh", "th":
            return true
        default:
            return false
        }
    }

    static func isSameClause(_ left: String, _ right: String) -> Bool {
        let a = self.normalized(left)
        let b = self.normalized(right)
        return !a.isEmpty && a == b
    }

    static func shouldReplaceLast(previous: String, incoming: String) -> Bool {
        let left = self.normalized(previous)
        let right = self.normalized(incoming)
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left == right {
            return previous.trimmingCharacters(in: .whitespacesAndNewlines)
                != incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return right.hasPrefix(left) || right.hasPrefix(left + " ")
    }

    static func shouldIgnoreAsStalePrefix(previous: String, incoming: String) -> Bool {
        let left = self.normalized(previous)
        let right = self.normalized(incoming)
        guard !left.isEmpty, !right.isEmpty, left != right else { return false }
        return left.hasPrefix(right) || left.hasPrefix(right + " ")
    }

    static func unreadCompleted(completed: [String], already: [String]) -> [String] {
        if already.isEmpty { return completed }

        var additions: [String] = []
        var alreadyIndex = 0

        for seen in completed {
            if alreadyIndex < already.count, self.isSameClause(already[alreadyIndex], seen) {
                if alreadyIndex == already.count - 1,
                   self.shouldReplaceLast(previous: already[alreadyIndex], incoming: seen)
                {
                    additions.append(seen)
                }
                alreadyIndex += 1
                continue
            }
            if let last = already.last, self.shouldReplaceLast(previous: last, incoming: seen) {
                additions.append(seen)
                alreadyIndex = already.count
                continue
            }
            if already.contains(where: { self.isSameClause($0, seen) }) {
                continue
            }
            if already.contains(where: { self.shouldIgnoreAsStalePrefix(previous: $0, incoming: seen) }) {
                continue
            }
            additions.append(seen)
        }
        return additions
    }

    /// ASR partials are cumulative. After a clause is committed, only the leftover
    /// suffix should stay open. Otherwise Theater re-translates the whole talk.
    static func leftoverTail(_ text: String, already: [String]) -> String {
        var remainder = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for chunk in already {
            guard let next = self.consumePrefix(remainder, prefix: chunk) else { break }
            remainder = next
        }
        return remainder.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Join committed translations for typing or history.
    static func joinTranslatedLines(_ lines: [String], languageID: String) -> String {
        let cleaned = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        switch self.languageCode(from: languageID) {
        case "ko", "th", "ja", "zh":
            return cleaned.joined()
        default:
            return cleaned.joined(separator: " ")
        }
    }
}

extension TranslationClauseSegmenter {
    fileprivate static let terminalPunctuation = CharacterSet(charactersIn: ".!?。！？…")

    fileprivate static let koreanEndings: [String] = [
        "습니까", "습니다", "ㅂ니까", "ㅂ니다", "입니다",
        "이에요", "예요", "어요", "아요", "해요", "네요", "군요",
        "십시오", "세요", "거든요", "잖아요", "는데요",
        "할게요", "을게요", "게요", "니까", "을까", "할까", "일까",
        "죠",
        "했다", "였다", "았다", "었다", "인다", "는다", "된다",
    ]

    fileprivate static let shortKoreanEndings: Set<String> = ["죠"]

    fileprivate static let japaneseEndings: [String] = [
        "ました", "ましたか", "です", "でした", "ません", "ます", "でしょうか",
    ]

    fileprivate static let thaiEndings: [String] = [
        "ครับผม", "ครับ", "ค่ะ", "คะ", "จ้ะ", "นะ", "เลย", "ไหม", "มั้ย",
        "ด้วย", "แล้ว", "ล่ะ", "สิ",
    ]

    fileprivate static let shortThaiEndings: Set<String> = ["นะ", "สิ"]

    fileprivate static func isBoundary(in text: String, at index: String.Index, languageID _: String) -> Bool {
        let character = text[index]
        let next = text.index(after: index)
        let atEnd = next == text.endIndex
        let followedBySpace = !atEnd && text[next].isWhitespace

        if let scalar = character.unicodeScalars.first, Self.terminalPunctuation.contains(scalar) {
            if character == ".", self.isDecimalPoint(in: text, at: index) {
                return false
            }
            return atEnd || followedBySpace || self.isTerminal(text[next])
        }

        return false
    }

    fileprivate static func isTerminal(_ character: Character) -> Bool {
        character.unicodeScalars.contains { Self.terminalPunctuation.contains($0) }
    }

    fileprivate static func isDecimalPoint(in text: String, at index: String.Index) -> Bool {
        guard text[index] == ".", index > text.startIndex else { return false }
        let previous = text.index(before: index)
        let next = text.index(after: index)
        guard next < text.endIndex else { return false }
        return text[previous].isNumber && text[next].isNumber
    }

    fileprivate static func hasKoreanPredicateEnding(_ text: String) -> Bool {
        self.hasEnding(text, endings: Self.koreanEndings)
    }

    fileprivate static func hasJapanesePredicateEnding(_ text: String) -> Bool {
        if let last = text.last, last == "か" || last == "だ" || last == "よ" {
            return true
        }
        return self.hasEnding(text, endings: Self.japaneseEndings)
    }

    fileprivate static func hasThaiClauseEnding(_ text: String) -> Bool {
        self.hasEnding(text, endings: Self.thaiEndings)
    }

    fileprivate static func hasEnding(_ text: String, endings: [String]) -> Bool {
        let folded = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return endings.contains { ending in
            self.matchesEnding(folded, ending: ending)
                || self.matchesEnding(folded, ending: ending + ".")
                || self.matchesEnding(folded, ending: ending + "?")
        }
    }

    fileprivate static func matchesEnding(_ text: String, ending: String) -> Bool {
        guard text.hasSuffix(ending) else { return false }
        let bare = ending.trimmingCharacters(in: CharacterSet(charactersIn: ".?"))
        if Self.shortKoreanEndings.contains(bare) || Self.shortThaiEndings.contains(bare) || bare.count <= 1 {
            return self.hasScriptBoundary(beforeSuffix: ending, in: text)
        }
        return true
    }

    fileprivate static func hasScriptBoundary(beforeSuffix suffix: String, in text: String) -> Bool {
        guard text.count > suffix.count else { return false }
        let previous = text[text.index(text.endIndex, offsetBy: -suffix.count - 1)]
        if Self.shortKoreanEndings.contains(suffix.trimmingCharacters(in: CharacterSet(charactersIn: ".?"))) {
            return previous.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) }
        }
        if Self.shortThaiEndings.contains(suffix.trimmingCharacters(in: CharacterSet(charactersIn: ".?"))) {
            return previous.unicodeScalars.contains { (0x0E00...0x0E7F).contains($0.value) }
        }
        return previous.isLetter || previous.isNumber
    }

    fileprivate static func forceCut(_ text: String) -> (head: String, rest: String) {
        let limit = LiveTranslationTiming.maxDraftCharacters
        guard text.count > limit else { return (text, "") }

        let headLimit = text.index(text.startIndex, offsetBy: limit)
        var cut = headLimit
        if let space = text[..<headLimit].lastIndex(where: { $0.isWhitespace }) {
            cut = space
        }
        let head = String(text[text.startIndex..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
        let rest = String(text[cut...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if head.isEmpty {
            return (String(text[text.startIndex..<headLimit]), String(text[headLimit...]))
        }
        return (head, rest)
    }

    fileprivate static func normalized(_ text: String) -> String {
        self.stripped(text)
    }

    fileprivate static func consumePrefix(_ text: String, prefix: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixN = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !prefixN.isEmpty else { return trimmed }
        if self.normalized(trimmed) == self.normalized(prefixN) { return "" }
        if self.stripped(trimmed) == self.stripped(prefixN) { return "" }

        let textTokens = self.tokens(trimmed)
        let prefixTokens = self.tokens(prefixN)
        if !prefixTokens.isEmpty,
           textTokens.count >= prefixTokens.count,
           zip(textTokens, prefixTokens).allSatisfy({ self.tokenKey($0) == self.tokenKey($1) })
        {
            return textTokens.dropFirst(prefixTokens.count).joined(separator: " ")
        }

        if let leftover = self.dropWhileMatching(trimmed, prefix: prefixN, using: self.normalized) {
            return leftover
        }
        return self.dropWhileMatching(trimmed, prefix: prefixN, using: self.stripped)
    }

    fileprivate static func dropWhileMatching(
        _ text: String,
        prefix: String,
        using fold: (String) -> String
    ) -> String? {
        let target = fold(prefix)
        guard !target.isEmpty else { return text }

        var built = ""
        var index = text.startIndex
        while index < text.endIndex {
            built.append(text[index])
            index = text.index(after: index)
            if fold(built) == target {
                return String(text[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    fileprivate static func tokens(_ text: String) -> [String] {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
    }

    fileprivate static func tokenKey(_ token: String) -> String {
        token
            .lowercased()
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
    }

    fileprivate static func stripped(_ text: String) -> String {
        let kept = text.lowercased().compactMap { character -> Character? in
            if character.isLetter || character.isNumber { return character }
            if character.isWhitespace { return " " }
            return nil
        }
        return String(kept)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct LectureCaptionEntry: Equatable, Identifiable {
    let id: UInt64
    var source: String
    var translated: String
    var wasPolished: Bool = false
}

/// Lecture caption history: one translated line per source clause, with prefix rewrite.
struct LectureCaptionLog: Equatable {
    var entries: [LectureCaptionEntry] = []
    private var nextID: UInt64 = 1

    var sourceLines: [String] { self.entries.map(\.source) }
    var translatedLines: [String] { self.entries.map(\.translated) }
    var lineIDs: [UInt64] { self.entries.map(\.id) }

    var contextSourceLines: [String] {
        Array(self.sourceLines.suffix(LiveTranslationTiming.contextSentenceCount))
    }

    func contextSourceLines(languageID: String) -> [String] {
        Array(self.sourceLines.suffix(LiveTranslationTiming.contextCount(languageID: languageID)))
    }

    func contextTranslatedLines(count: Int = LiveTranslationTiming.polishPriorCaptionCount) -> [String] {
        Array(self.translatedLines.suffix(count))
    }

    var captionPairs: [CaptionHistoryPair] {
        self.entries.map {
            CaptionHistoryPair(source: $0.source, translated: $0.translated, wasPolished: $0.wasPolished)
        }
    }

    var didPolishAnyLine: Bool {
        self.entries.contains(where: \.wasPolished)
    }

    @discardableResult
    mutating func commit(source: String, translated: String) -> (id: UInt64, trimmedCount: Int)? {
        let cleanedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedTranslation = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedSource.isEmpty, !cleanedTranslation.isEmpty else { return nil }

        if let lastSource = self.entries.last?.source {
            if TranslationClauseSegmenter.shouldReplaceLast(previous: lastSource, incoming: cleanedSource) {
                self.entries[self.entries.count - 1].source = cleanedSource
                self.entries[self.entries.count - 1].translated = cleanedTranslation
                self.entries[self.entries.count - 1].wasPolished = false
                let trimmed = self.trimIfNeeded()
                return (self.entries.last?.id ?? self.nextID, trimmed)
            }
            if lastSource == cleanedSource { return nil }
            if TranslationClauseSegmenter.shouldIgnoreAsStalePrefix(previous: lastSource, incoming: cleanedSource) {
                return nil
            }
        }

        let id = self.nextID
        self.entries.append(
            LectureCaptionEntry(id: id, source: cleanedSource, translated: cleanedTranslation)
        )
        self.nextID += 1
        return (id, self.trimIfNeeded())
    }

    @discardableResult
    mutating func updateTranslated(id: UInt64, translated: String, wasPolished: Bool) -> Bool {
        let cleaned = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, let index = self.entries.firstIndex(where: { $0.id == id }) else {
            return false
        }
        self.entries[index].translated = cleaned
        self.entries[index].wasPolished = wasPolished
        return true
    }

    mutating func replaceTranslatedLines(_ lines: [String]) {
        let cleaned = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var next = self.nextID
        var rebuilt: [LectureCaptionEntry] = []
        for (index, line) in cleaned.enumerated() {
            if index < self.entries.count {
                var entry = self.entries[index]
                entry.translated = line
                rebuilt.append(entry)
            } else {
                rebuilt.append(LectureCaptionEntry(id: next, source: line, translated: line))
                next += 1
            }
        }
        self.entries = rebuilt
        self.nextID = next
        self.trimIfNeeded()
    }

    @discardableResult
    private mutating func trimIfNeeded() -> Int {
        guard self.entries.count > LiveTranslationTiming.maxCommittedLines else { return 0 }
        let overflow = self.entries.count - LiveTranslationTiming.maxCommittedLines
        self.entries.removeFirst(overflow)
        return overflow
    }
}

enum LiveTranslationConfirm {
    static func shouldReDecode(
        unread: [String],
        tail: String,
        languageID: String,
        isFinal: Bool
    ) -> Bool {
        if isFinal { return true }
        if !unread.isEmpty { return false }
        if TranslationClauseSegmenter.looksComplete(tail, languageID: languageID) { return false }
        return TranslationClauseSegmenter.isReadyToCommit(
            tail,
            languageID: languageID,
            allowPauseFinalize: true
        )
    }
}
