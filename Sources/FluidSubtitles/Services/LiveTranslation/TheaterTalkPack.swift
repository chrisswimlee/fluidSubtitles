import AppKit
import Foundation
import PDFKit

/// Local notes or a deck for this talk. Terms stay on the Mac and bias
/// glossary lock plus the optional local LLM. This is not Screen Recording.
nonisolated enum TheaterTalkPack {
    static let maxTerms = 200
    static let maxPromptTerms = 80

    struct Document: Equatable {
        var fileName: String
        var terms: [String]
        var sourceCharacterCount: Int
    }

    enum LoadError: LocalizedError {
        case empty
        case unreadable

        var errorDescription: String? {
            switch self {
            case .empty:
                return "That file has no names Theater can keep."
            case .unreadable:
                return "Theater could not read that file on this Mac."
            }
        }
    }

    static func load(from url: URL) throws -> Document {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let data = try Data(contentsOf: url)
        return try self.document(from: data, fileName: url.lastPathComponent)
    }

    static func document(from data: Data, fileName: String) throws -> Document {
        if let pack = try? LectureTermPack.document(from: data) {
            let terms = self.cappedUnique(
                pack.customWords.map(\.text) + pack.replacements.flatMap { $0.from + [$0.to] }
            )
            guard !terms.isEmpty else { throw LoadError.empty }
            return Document(fileName: fileName, terms: terms, sourceCharacterCount: data.count)
        }

        let text = try self.plainText(from: data, fileName: fileName)
        let terms = self.extractTerms(from: text)
        guard !terms.isEmpty else { throw LoadError.empty }
        return Document(fileName: fileName, terms: terms, sourceCharacterCount: text.count)
    }

    /// Names and repeated domain words. The full slide dump is not the glossary.
    static func extractTerms(from text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var seen: [String: String] = [:]
        var counts: [String: Int] = [:]

        func remember(_ raw: String) {
            let token = self.normalizedTerm(raw)
            guard token.count >= 2 else { return }
            let key = token.lowercased()
            if seen[key] == nil {
                seen[key] = token
            }
            counts[key, default: 0] += 1
        }

        for phrase in self.capitalizedPhrases(in: trimmed) {
            remember(phrase)
        }
        for token in self.tokens(in: trimmed) {
            remember(token)
        }

        var picked: [String] = []
        for (key, display) in seen {
            if self.shouldKeep(display, count: counts[key, default: 0]) {
                picked.append(display)
            }
        }
        return self.cappedUnique(picked)
    }

    static func promptTerms(from terms: [String]) -> [String] {
        Array(terms.prefix(Self.maxPromptTerms))
    }

    /// Drops leftover slide chrome from an older import before glossary lock.
    static func sanitizedTerms(_ terms: [String]) -> [String] {
        self.cappedUnique(terms.filter { self.shouldKeep($0, count: 2) })
    }

    private static func plainText(from data: Data, fileName: String) throws -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if ext == "pdf" {
            guard let document = PDFDocument(data: data) else { throw LoadError.unreadable }
            var pages: [String] = []
            pages.reserveCapacity(document.pageCount)
            for index in 0..<document.pageCount {
                pages.append(document.page(at: index)?.string ?? "")
            }
            let text = pages.joined(separator: "\n")
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw LoadError.empty
            }
            return text
        }
        if ext == "rtf" {
            let attributed = try NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            )
            return attributed.string
        }
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
        else {
            throw LoadError.unreadable
        }
        return text
    }

    private static func shouldKeep(_ token: String, count: Int) -> Bool {
        if Self.stopwords.contains(token.lowercased()) { return false }
        if self.isCJKTerm(token) {
            return self.shouldKeepCJK(token, count: count)
        }
        if self.isAcronym(token) || self.isFiscalToken(token) { return true }
        if token.contains(where: \.isWhitespace) { return self.isUsefulProperPhrase(token) }
        if self.isCamelCase(token) { return true }
        if token.contains("-") {
            return count >= 2 || self.isAcronym(token) || self.isCamelCase(token)
        }
        if self.isLatinLowercase(token) { return false }
        if token.first?.isUppercase == true, token.count >= 3 { return count >= 2 }
        return false
    }

    private static func shouldKeepCJK(_ token: String, count: Int) -> Bool {
        guard token.count >= 2, token.count <= 16 else { return false }
        if Self.cjkStopwords.contains(token) { return false }
        if self.hasFunctionEnding(token) { return false }
        if self.hasEmbeddedJapaneseParticle(token) { return false }
        if self.isThaiTerm(token), Self.thaiFunctionPrefixes.contains(where: { token.hasPrefix($0) }) {
            return false
        }
        if count >= 2 { return true }
        return token.count >= 3
    }

    private static func isThaiTerm(_ token: String) -> Bool {
        token.unicodeScalars.contains { (0x0E00...0x0E7F).contains($0.value) }
    }

    private static func isUsefulProperPhrase(_ token: String) -> Bool {
        let words = token.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 2 else { return false }
        let first = words[0]
        if Self.stopwords.contains(first.lowercased()),
           !self.isAcronym(first),
           !self.isFiscalToken(first)
        {
            return false
        }
        let interesting = words.filter { word in
            if Self.stopwords.contains(word.lowercased()) { return false }
            return word.count >= 3 || self.isAcronym(word) || self.isFiscalToken(word)
        }
        if words.contains(where: { self.isAcronym($0) || self.isFiscalToken($0) }) {
            return true
        }
        return interesting.count >= 2
    }

    private static func tokens(in text: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .subtracting(CharacterSet(charactersIn: "-'’"))
        return text
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-'’")) }
            .filter { $0.count >= 2 }
    }

    /// Title-case runs on one line. Newlines are slide breaks, not spaces.
    private static func capitalizedPhrases(in text: String) -> [String] {
        let pattern = #"\b(?:[A-Z][A-Za-z0-9]+(?:[ \t]+[A-Z][A-Za-z0-9]+)+)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    private static func isFiscalToken(_ token: String) -> Bool {
        let folded = token.uppercased()
        if folded.range(of: #"^Q[1-4]$"#, options: .regularExpression) != nil { return true }
        if folded.range(of: #"^FY\d{2,4}$"#, options: .regularExpression) != nil { return true }
        return folded == "1H" || folded == "2H"
    }

    private static func isAcronym(_ token: String) -> Bool {
        let letters = token.filter(\.isLetter)
        return letters.count >= 2
            && letters.count <= 8
            && letters.allSatisfy(\.isUppercase)
    }

    /// Internal capital: fluidSubtitles, iPhone, MacBook. Not Welcome or Thank You.
    private static func isCamelCase(_ token: String) -> Bool {
        guard !token.contains(where: \.isWhitespace) else { return false }
        let letters = Array(token.filter(\.isLetter))
        guard letters.count >= 3 else { return false }
        guard letters.contains(where: \.isLowercase) else { return false }
        return letters.dropFirst().contains(where: \.isUppercase)
    }

    private static func isLatinLowercase(_ token: String) -> Bool {
        let letters = token.filter(\.isLetter)
        return !letters.isEmpty && letters.allSatisfy(\.isLowercase)
    }

    private static func isCJKTerm(_ token: String) -> Bool {
        token.unicodeScalars.contains { Self.isCJKScalar($0) }
    }

    private static func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
        (0xAC00...0xD7AF).contains(scalar.value)
            || (0x3040...0x30FF).contains(scalar.value)
            || (0x4E00...0x9FFF).contains(scalar.value)
            || (0x0E00...0x0E7F).contains(scalar.value)
    }

    private static func normalizedTerm(_ raw: String) -> String {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard self.isCJKTerm(token) else { return token }
        return self.peelParticle(token)
    }

    private static func peelParticle(_ token: String) -> String {
        let particles = [
            "으로", "에서", "부터", "까지",
            "은", "는", "을", "를", "이", "가", "에", "의", "도", "만", "과", "와", "로",
            "から", "まで", "より", "の", "が", "を", "は", "に", "で", "と", "も",
        ]
        for particle in particles {
            if token.count >= 2 + particle.count, token.hasSuffix(particle) {
                return String(token.dropLast(particle.count))
            }
        }
        return token
    }

    private static func hasFunctionEnding(_ token: String) -> Bool {
        Self.functionEndings.contains { token.hasSuffix($0) }
    }

    private static func hasEmbeddedJapaneseParticle(_ token: String) -> Bool {
        guard token.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) })
        else { return false }
        let particles: [Character] = ["の", "が", "を", "は", "に", "で", "と", "も"]
        guard let index = token.firstIndex(where: { particles.contains($0) }) else { return false }
        return index != token.startIndex && token.index(after: index) != token.endIndex
    }

    private static func cappedUnique(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var unique: [String] = []
        for term in terms
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .filter({ $0.count >= 2 })
            .sorted(by: { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            })
        {
            let key = term.lowercased()
            if seen.insert(key).inserted {
                unique.append(term)
            }
            if unique.count == Self.maxTerms { break }
        }
        return unique
    }

    private static let functionEndings: [String] = [
        "했습니다", "습니다", "합니다", "입니다", "됩니다", "하세요", "해요",
        "ました", "します", "ください", "です", "ます",
        "ครับ", "ค่ะ", "คะ",
    ]

    private static let thaiFunctionPrefixes: [String] = [
        "เป็น", "จะ", "ที่", "และ", "ใน", "ของ", "ได้", "แล้ว",
    ]

    private static let cjkStopwords: Set<String> = [
        "그리고", "오늘", "발표", "감사합니다", "감사", "이것", "저것",
        "ありがとう", "ございます", "本日", "これ", "それ", "あれ",
        "ครับ", "ค่ะ", "คะ", "ขอบคุณ", "เรา", "วันนี้",
    ]

    private static let stopwords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "from",
        "has", "have", "if", "in", "into", "is", "it", "its", "of", "on", "or",
        "that", "the", "their", "then", "there", "these", "this", "to", "was",
        "we", "were", "will", "with", "you", "your", "today", "next", "please",
        "slide", "slides", "page", "notes", "agenda", "review", "demo",
        "hello", "thanks", "thank", "okay", "yes", "no",
        "welcome", "steps", "caught", "behind",
    ]
}
