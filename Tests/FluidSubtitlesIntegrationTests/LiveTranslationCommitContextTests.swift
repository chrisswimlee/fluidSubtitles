import XCTest
@testable import FluidSubtitles_Debug

final class LiveTranslationCommitContextTests: XCTestCase {
    // MARK: - priorClauses

    private func entries(_ range: ClosedRange<Int>) -> [LectureCaptionEntry] {
        range.map {
            LectureCaptionEntry(id: UInt64($0), source: "S\($0)", translated: "T\($0)")
        }
    }

    func testPriorClausesReturnsLastFourAfterListenBatchStart() {
        let result = LiveTranslationCommitContext.priorClauses(
            entries: self.entries(1...6),
            listenBatchStart: 2,
            incoming: "Totally unrelated sentence that does not extend anything."
        )
        XCTAssertEqual(result.sources, ["S3", "S4", "S5", "S6"])
        XCTAssertEqual(result.translations, ["T3", "T4", "T5", "T6"])
    }

    func testPriorClausesClampsListenBatchStartBeyondEntryCount() {
        let result = LiveTranslationCommitContext.priorClauses(
            entries: self.entries(1...2),
            listenBatchStart: 5,
            incoming: "Totally unrelated sentence that does not extend anything."
        )
        XCTAssertEqual(result.sources, [])
        XCTAssertEqual(result.translations, [])
    }

    func testPriorClausesRespectsExplicitLimit() {
        let result = LiveTranslationCommitContext.priorClauses(
            entries: self.entries(1...3),
            listenBatchStart: 0,
            incoming: "Totally unrelated sentence that does not extend anything.",
            limit: 2
        )
        XCTAssertEqual(result.sources, ["S2", "S3"])
        XCTAssertEqual(result.translations, ["T2", "T3"])
    }

    // MARK: - peeledNewTranslation

    func testPeeledNewTranslationReturnsLeftoverAfterPriorClause() {
        let result = LiveTranslationCommitContext.peeledNewTranslation(
            "Hello world. Next sentence.",
            priorTranslations: ["Hello world."],
            targetID: "en"
        )
        XCTAssertEqual(result, "Next sentence.")
    }

    func testPeeledNewTranslationReturnsNilWhenPriorTranslationsEmpty() {
        let result = LiveTranslationCommitContext.peeledNewTranslation(
            "Hello.",
            priorTranslations: [],
            targetID: "en"
        )
        XCTAssertNil(result)
    }

    func testPeeledNewTranslationReturnsNilForBlankTranslated() {
        let result = LiveTranslationCommitContext.peeledNewTranslation(
            "   ",
            priorTranslations: ["Hello."],
            targetID: "en"
        )
        XCTAssertNil(result)
    }

    // MARK: - leftoverContainsPriorCaption

    func testLeftoverContainsPriorCaptionMatchesCaseInsensitiveSubstring() {
        XCTAssertTrue(
            LiveTranslationCommitContext.leftoverContainsPriorCaption(
                "Today the model performed well.",
                priors: ["The model"]
            )
        )
    }

    func testLeftoverContainsPriorCaptionFalseForUnrelatedText() {
        XCTAssertFalse(
            LiveTranslationCommitContext.leftoverContainsPriorCaption(
                "Completely different sentence.",
                priors: ["The model"]
            )
        )
    }

    func testLeftoverContainsPriorCaptionMatchesDiacriticInsensitive() {
        XCTAssertTrue(
            LiveTranslationCommitContext.leftoverContainsPriorCaption(
                "Café result",
                priors: ["cafe"]
            )
        )
    }

    func testLeftoverContainsPriorCaptionIgnoresSingleCharacterPriors() {
        XCTAssertFalse(
            LiveTranslationCommitContext.leftoverContainsPriorCaption(
                "Hi there",
                priors: ["H"]
            )
        )
    }

    // MARK: - shouldPreferConfirmation

    func testShouldPreferConfirmationFalseWhenConfirmedIsBlank() {
        XCTAssertFalse(
            LiveTranslationCommitContext.shouldPreferConfirmation(
                "   ",
                over: "Something heard.",
                already: []
            )
        )
    }

    func testShouldPreferConfirmationTrueWhenHeardIsBlank() {
        XCTAssertTrue(
            LiveTranslationCommitContext.shouldPreferConfirmation(
                "Confirmed text.",
                over: "   ",
                already: []
            )
        )
    }

    func testShouldPreferConfirmationTrueForSubstantiallyLongerConfirmation() {
        XCTAssertTrue(
            LiveTranslationCommitContext.shouldPreferConfirmation(
                "Today we trained the full model together.",
                over: "Hi",
                already: []
            )
        )
    }

    func testShouldPreferConfirmationFalseWhenConfirmedIsAShortUnrelatedFragment() {
        XCTAssertFalse(
            LiveTranslationCommitContext.shouldPreferConfirmation(
                "Ok",
                over: "This is a very long detailed heard sentence that keeps going.",
                already: []
            )
        )
    }

    // MARK: - isLeftoverRevision

    func testIsLeftoverRevisionTrueForIdenticalClause() {
        XCTAssertTrue(
            LiveTranslationCommitContext.isLeftoverRevision("Hello world.", of: "Hello world.")
        )
    }

    func testIsLeftoverRevisionTrueWhenIncomingExtendsPrevious() {
        XCTAssertTrue(
            LiveTranslationCommitContext.isLeftoverRevision("Hello world today", of: "Hello world")
        )
    }

    func testIsLeftoverRevisionTrueWhenIncomingIsATruncationOfPrevious() {
        XCTAssertTrue(
            LiveTranslationCommitContext.isLeftoverRevision("Hello world", of: "Hello world today")
        )
    }

    func testIsLeftoverRevisionFalseForUnrelatedClauses() {
        XCTAssertFalse(
            LiveTranslationCommitContext.isLeftoverRevision("Completely unrelated phrase", of: "Hello world")
        )
    }

    // MARK: - foldedClause

    func testFoldedClauseStripsPunctuationKeepsSpaces() {
        XCTAssertEqual(LiveTranslationCommitContext.foldedClause("Hello, World!"), "hello world")
    }

    func testFoldedClauseCollapsesRepeatedWhitespace() {
        XCTAssertEqual(LiveTranslationCommitContext.foldedClause("  Multiple   Spaces  "), "multiple spaces")
    }

    func testFoldedClauseKeepsNumbersAndNonLatinLetters() {
        XCTAssertEqual(LiveTranslationCommitContext.foldedClause("2024 모델!"), "2024 모델")
    }

    func testFoldedClauseOfEmptyStringIsEmpty() {
        XCTAssertEqual(LiveTranslationCommitContext.foldedClause(""), "")
    }
}
