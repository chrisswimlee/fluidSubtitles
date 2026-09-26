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

    // MARK: - marked context

    func testMarkedPayloadWrapsOnlyTheNewClause() {
        let payload = LiveTranslationCommitContext.markedContextPayload(
            priors: ["저는 모델을 학습했습니다."],
            current: "그걸 적용했습니다.",
            languageID: "ko"
        )
        XCTAssertEqual(
            payload,
            "저는 모델을 학습했습니다.\n"
                + LiveTranslationCommitContext.contextClauseStart
                + "그걸 적용했습니다."
                + LiveTranslationCommitContext.contextClauseEnd
        )
        let english = LiveTranslationCommitContext.markedContextPayload(
            priors: ["Hello."],
            current: "Next.",
            languageID: "en"
        )
        XCTAssertEqual(
            english,
            "Hello.\n"
                + LiveTranslationCommitContext.contextClauseStart
                + "Next."
                + LiveTranslationCommitContext.contextClauseEnd
        )
    }

    func testLineBoundNewTranslationKeepsTheLastLineWhenMarksAreGone() {
        XCTAssertEqual(
            LiveTranslationCommitContext.lineBoundNewTranslation(
                "Applied the model today.\nI applied it.",
                priorTranslations: ["I trained the model."],
                isolatedSource: "그걸 적용했습니다.",
                targetID: "en"
            ),
            "I applied it."
        )
        XCTAssertNil(
            LiveTranslationCommitContext.lineBoundNewTranslation(
                "I applied it.\nI trained the model.",
                priorTranslations: ["I trained the model."],
                isolatedSource: "그걸 적용했습니다.",
                targetID: "en"
            )
        )
    }

    func testMarkedNewTranslationReadsAReorderedSpan() {
        let start = LiveTranslationCommitContext.contextClauseStart
        let end = LiveTranslationCommitContext.contextClauseEnd
        XCTAssertEqual(
            LiveTranslationCommitContext.markedNewTranslation(
                "\(start)I applied it.\(end) I trained the model."
            ),
            "I applied it."
        )
    }

    func testMarkedNewTranslationRejectsMissingDoubledAndEmptySpans() {
        let start = LiveTranslationCommitContext.contextClauseStart
        let end = LiveTranslationCommitContext.contextClauseEnd
        XCTAssertNil(LiveTranslationCommitContext.markedNewTranslation("I applied it."))
        XCTAssertNil(
            LiveTranslationCommitContext.markedNewTranslation("\(start)\(start)I applied it.\(end)")
        )
        XCTAssertNil(
            LiveTranslationCommitContext.markedNewTranslation("\(end)I applied it.\(start)")
        )
        XCTAssertNil(LiveTranslationCommitContext.markedNewTranslation("\(start)   \(end)"))
    }

    // MARK: - peeledNewTranslation

    func testPeeledNewTranslationReturnsLeftoverAfterPriorClause() {
        let result = LiveTranslationCommitContext.peeledNewTranslation(
            "Hello world. Next sentence.",
            priorTranslations: ["Hello world."],
            targetID: "en"
        )
        XCTAssertEqual(result, "Next sentence.")
        XCTAssertEqual(
            LiveTranslationCommitContext.peeledNewTranslation(
                "오늘 모델을 학습했습니다. 그걸 적용했습니다.",
                priorTranslations: ["오늘 모델을 학습했습니다."],
                targetID: "ko"
            ),
            "그걸 적용했습니다."
        )
    }

    func testSanePeeledCaptionRejectsAPriorClauseStillInTheLeftover() {
        XCTAssertFalse(
            LiveTranslationCommitContext.isSanePeeledCaption(
                "then applied it. It worked well.",
                isolatedSource: "It worked well.",
                targetID: "en"
            )
        )
        XCTAssertTrue(
            LiveTranslationCommitContext.isSanePeeledCaption(
                "It worked well.",
                isolatedSource: "It worked well.",
                targetID: "en"
            )
        )
    }

    func testPreferConfirmationRejectsANearMatchWhenLiveLeftoverIsEmpty() {
        XCTAssertFalse(
            LiveTranslationCommitContext.shouldPreferConfirmation(
                "A model trained well on the data.",
                over: "",
                already: ["The model trained well on the data."]
            )
        )
        XCTAssertTrue(
            LiveTranslationCommitContext.shouldPreferConfirmation(
                "Then we applied it.",
                over: "",
                already: ["The model trained well on the data."]
            )
        )
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

    func testLeftoverContainsPriorCaptionDoesNotMatchInsideALongerWord() {
        XCTAssertFalse(
            LiveTranslationCommitContext.leftoverContainsPriorCaption(
                "Okay we trained the model.",
                priors: ["OK"]
            )
        )
        XCTAssertFalse(
            LiveTranslationCommitContext.leftoverContainsPriorCaption(
                "This is a high quality model.",
                priors: ["Hi"]
            )
        )
        XCTAssertTrue(
            LiveTranslationCommitContext.leftoverContainsPriorCaption(
                "Today the model performed well.",
                priors: ["The model"]
            )
        )
        XCTAssertTrue(
            LiveTranslationCommitContext.leftoverContainsPriorCaption(
                "Today the model performed well.",
                priors: ["The model."]
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

    func testLeftoverContainsPriorCaptionMatchesShortUnspacedPriors() {
        XCTAssertTrue(
            LiveTranslationCommitContext.leftoverContainsPriorCaption(
                "สวัสดีครับทุกคน วันนี้เราจะคุยกัน",
                priors: ["สวัสดีครับ"]
            )
        )
        XCTAssertTrue(
            LiveTranslationCommitContext.leftoverContainsPriorCaption(
                "はい、今日はいい天気ですね",
                priors: ["今日はいい"]
            )
        )
        XCTAssertFalse(
            LiveTranslationCommitContext.leftoverContainsPriorCaption(
                "今日はいい天気ですね",
                priors: ["今日"]
            )
        )
    }

    func testSegmenterContainsKeepsWholeWordsForOneWordClauses() {
        XCTAssertFalse(TranslationClauseSegmenter.contains("Italy is lovely.", clause: "It."))
        XCTAssertFalse(TranslationClauseSegmenter.contains("A catalog.", clause: "cat"))
        XCTAssertTrue(TranslationClauseSegmenter.contains("It is lovely.", clause: "It"))
        XCTAssertTrue(TranslationClauseSegmenter.contains("はい 今日はいい天気", clause: "今日は"))
    }
}
