@testable import FluidSubtitles_Debug
import Foundation
import XCTest

@MainActor
final class CustomDictionaryManualEntryTests: XCTestCase {
    func testKeepsWhitespaceOnlyReplacements() {
        XCTAssertEqual(CustomDictionaryManualEntry.sanitizedReplacement("\n"), "\n")
        XCTAssertEqual(CustomDictionaryManualEntry.sanitizedReplacement(" "), " ")
        XCTAssertEqual(CustomDictionaryManualEntry.sanitizedReplacement("\t"), "\t")
        XCTAssertEqual(CustomDictionaryManualEntry.sanitizedReplacement(""), "")
        XCTAssertEqual(CustomDictionaryManualEntry.sanitizedReplacement("  fluidSubtitles \n"), "fluidSubtitles")
    }

    func testRendersWhitespaceReplacementsVisibly() {
        XCTAssertEqual(CustomDictionaryManualEntry.replacementDisplayText("\n"), "⏎")
        XCTAssertEqual(CustomDictionaryManualEntry.replacementDisplayText(" "), "␣")
        XCTAssertEqual(CustomDictionaryManualEntry.replacementDisplayText("\t"), "⇥")
        XCTAssertEqual(CustomDictionaryManualEntry.replacementDisplayText(" \n"), "␣⏎")
        XCTAssertEqual(CustomDictionaryManualEntry.replacementDisplayText("fluidSubtitles"), "fluidSubtitles")
        XCTAssertEqual(CustomDictionaryManualEntry.replacementDisplayText(""), "")
    }

    func testInstantReplacementDoesNotEnterParakeetBoostVocabulary() {
        let replacement = SettingsStore.CustomDictionaryEntry(
            triggers: ["sean"],
            replacement: "Shaun"
        )
        let explicitBoost = ParakeetVocabularyStore.VocabularyConfig.Term(
            text: "fluidSubtitles",
            weight: 10,
            aliases: ["fluid subtitles"]
        )

        self.withRestoredDictionary([replacement]) {
            let terms = ParakeetVocabularyStore.normalizedBoostTerms([explicitBoost])

            XCTAssertEqual(terms.map(\.text), ["fluidSubtitles"])
            XCTAssertEqual(terms.first?.aliases, ["fluid subtitles"])
            XCTAssertFalse(terms.contains { $0.text.caseInsensitiveCompare("Shaun") == .orderedSame })
            XCTAssertFalse(terms.contains { $0.aliases.contains("sean") })
        }
    }

    func testInstantReplacementStillRequiresExactWholeWordTrigger() {
        let replacement = SettingsStore.CustomDictionaryEntry(
            triggers: ["sean"],
            replacement: "Shaun"
        )

        self.withRestoredDictionary([replacement]) {
            XCTAssertEqual(ASRService.applyCustomDictionary("Did you mean Monday?"), "Did you mean Monday?")
            XCTAssertEqual(ASRService.applyCustomDictionary("Ask sean Monday."), "Ask Shaun Monday.")
        }
    }

    func testWhitespaceReplacementSurvivesTransferAndReplacement() throws {
        let document = DictionaryTransferDocument(
            replacements: [DictionaryTransferReplacement(from: ["new line"], to: "\n")],
            customWords: []
        )

        let data = try DictionaryTransferService.shared.encode(document)
        let decoded = try DictionaryTransferService.shared.decode(data)
        let state = try DictionaryTransferService.importState(
            document: decoded,
            mode: .replace,
            currentReplacements: [],
            currentCustomWords: []
        )

        XCTAssertEqual(state.replacements.first?.replacement, "\n")
        self.withRestoredDictionary(state.replacements) {
            XCTAssertEqual(ASRService.applyCustomDictionary("first new line second"), "first\nsecond")
        }
    }

    func testWhitespaceReplacementsOwnAdjacentHorizontalSeparators() {
        let entries = [
            SettingsStore.CustomDictionaryEntry(triggers: ["new line"], replacement: "\n"),
            SettingsStore.CustomDictionaryEntry(triggers: ["new paragraph"], replacement: "\n\n"),
            SettingsStore.CustomDictionaryEntry(triggers: ["tab over"], replacement: "\t"),
            SettingsStore.CustomDictionaryEntry(triggers: ["little space"], replacement: " "),
        ]

        self.withRestoredDictionary(entries) {
            XCTAssertEqual(ASRService.applyCustomDictionary("first new line second"), "first\nsecond")
            XCTAssertEqual(ASRService.applyCustomDictionary("first  new paragraph  second"), "first\n\nsecond")
            XCTAssertEqual(ASRService.applyCustomDictionary("first tab over second"), "first\tsecond")
            XCTAssertEqual(ASRService.applyCustomDictionary("first   little space   second"), "first second")
            XCTAssertEqual(ASRService.applyCustomDictionary("first\n  new line  second"), "first\n\nsecond")
        }
    }

    func testTransferStillRejectsEmptyAndTrimsVisibleReplacement() throws {
        let document = DictionaryTransferDocument(
            replacements: [
                DictionaryTransferReplacement(from: ["empty"], to: ""),
                DictionaryTransferReplacement(from: ["fluid subtitles"], to: " fluidSubtitles \n"),
            ],
            customWords: []
        )

        let decoded = try DictionaryTransferService.shared.decode(DictionaryTransferService.shared.encode(document))

        XCTAssertEqual(decoded.replacements.count, 1)
        XCTAssertEqual(decoded.replacements.first?.to, "fluidSubtitles")
    }

    private func withRestoredDictionary(_ entries: [SettingsStore.CustomDictionaryEntry], run: () -> Void) {
        let original = SettingsStore.shared.customDictionaryEntries
        defer {
            SettingsStore.shared.customDictionaryEntries = original
            ASRService.invalidateDictionaryCache()
        }
        SettingsStore.shared.customDictionaryEntries = entries
        ASRService.invalidateDictionaryCache()
        run()
    }
}
