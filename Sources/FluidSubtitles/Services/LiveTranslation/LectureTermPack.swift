import Foundation

/// Lecture glossary files. Accepts this app's dictionary JSON, a TypeWhisper-style
/// terms/corrections pack, or a bare JSON list of names.
enum LectureTermPack {
    static func document(from data: Data) throws -> DictionaryTransferDocument {
        if let pack = try? JSONDecoder().decode(TypeWhisperDictionaryFile.self, from: data),
           pack.usesCorrectionMapping
        {
            return pack.asDocument()
        }
        do {
            return try JSONDecoder().decode(DictionaryTransferDocument.self, from: data)
        } catch {
            if let terms = try? JSONDecoder().decode([String].self, from: data) {
                let words = terms
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if !words.isEmpty {
                    return DictionaryTransferDocument(replacements: [], customWords: words)
                }
            }
            throw DictionaryTransferServiceError.invalidJSON
        }
    }
}

private struct TypeWhisperDictionaryFile: Decodable {
    var terms: [String]?
    var corrections: [Correction]?

    var usesCorrectionMapping: Bool {
        !(self.corrections ?? []).isEmpty
    }

    func asDocument() -> DictionaryTransferDocument {
        let replacements = (self.corrections ?? []).compactMap { correction -> DictionaryTransferReplacement? in
            let from = correction.original.trimmingCharacters(in: .whitespacesAndNewlines)
            let to = correction.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !from.isEmpty, !to.isEmpty else { return nil }
            return DictionaryTransferReplacement(from: [from], to: to)
        }
        let words = (self.terms ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return DictionaryTransferDocument(replacements: replacements, customWords: words)
    }

    struct Correction: Decodable {
        let original: String
        let replacement: String

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.original = try container.decodeIfPresent(String.self, forKey: .original)
                ?? container.decode(String.self, forKey: .from)
            self.replacement = try container.decodeIfPresent(String.self, forKey: .replacement)
                ?? container.decode(String.self, forKey: .to)
        }

        private enum CodingKeys: String, CodingKey {
            case original
            case replacement
            case from
            case to
        }
    }
}
