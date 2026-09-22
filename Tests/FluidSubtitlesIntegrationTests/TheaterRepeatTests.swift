import XCTest
@testable import FluidSubtitles_Debug

@MainActor
final class TheaterRepeatTests: XCTestCase {
    func testLeftoverCollapsesAWhisperSentenceStutter() {
        XCTAssertEqual(
            TranslationClauseSegmenter.collapseRepeatedSpeech(
                "Hello. Hello. How are you",
                languageID: "en"
            ),
            "Hello. How are you"
        )
        XCTAssertEqual(
            TranslationClauseSegmenter.leftoverTail(
                "Today we trained the model. Today we trained the model. Then we applied it",
                already: [],
                languageID: "en"
            ),
            "Today we trained the model. Then we applied it"
        )
        XCTAssertEqual(
            TranslationClauseSegmenter.leftoverTail(
                "I think I think we should go",
                already: [],
                languageID: "en"
            ),
            "I think we should go"
        )
        XCTAssertEqual(
            TranslationClauseSegmenter.leftoverTail(
                "안녕하세요 안녕하세요 여러분",
                already: [],
                languageID: "ko"
            ),
            "안녕하세요 여러분"
        )
    }

    func testLeftoverPeelsASecondCopyAfterACommit() {
        XCTAssertEqual(
            TranslationClauseSegmenter.leftoverTail(
                "Today we trained the model. Today we trained the model Then we applied it",
                already: ["Today we trained the model."],
                languageID: "en"
            ),
            "Then we applied it"
        )
        XCTAssertEqual(
            TranslationClauseSegmenter.leftoverTail(
                "Hello. Hello. How are you",
                already: ["Hello."],
                languageID: "en"
            ),
            "How are you"
        )
    }

    func testNaturalDoubledWordsStay() {
        XCTAssertEqual(
            TranslationClauseSegmenter.leftoverTail(
                "the the model is ready",
                already: [],
                languageID: "en"
            ),
            "the the model is ready"
        )
        XCTAssertEqual(
            TranslationClauseSegmenter.leftoverTail(
                "Today we trained the model. Then we applied it",
                already: [],
                languageID: "en"
            ),
            "Today we trained the model. Then we applied it"
        )
    }

    func testBoardDoesNotReprintTheCommittedClause() {
        let repeated = TheaterCaptionFlow.lines(
            committed: ["Hello."],
            committedIDs: [1],
            committedSources: ["Hello."],
            draft: "",
            sourceDraft: "Hello. Hello. How are you",
            spokenDisplay: .isTheCaption
        )
        XCTAssertEqual(repeated.map(\.text), ["Hello."])
        XCTAssertEqual(repeated.last?.id, "c-1")
        XCTAssertFalse(repeated.contains { $0.isDraft })

        let midTalk = TheaterCaptionFlow.lines(
            committed: [],
            draft: "",
            sourceDraft: "Hello. Hello. How are you",
            spokenDisplay: .isTheCaption
        )
        XCTAssertTrue(midTalk.isEmpty)

        let pairedSame = TheaterCaptionFlow.lines(
            committed: [],
            draft: "Hello.",
            sourceDraft: "Hello",
            spokenDisplay: .paired
        )
        XCTAssertTrue(pairedSame.isEmpty)
    }

    func testLeftoverKeepsASupersetSentenceAfterAPrintedPrefix() {
        XCTAssertEqual(
            TranslationClauseSegmenter.leftoverTail(
                "We trained the model. We trained the model on Korean data too.",
                already: ["We trained the model."],
                languageID: "en"
            ),
            "We trained the model on Korean data too."
        )
        XCTAssertEqual(
            TranslationClauseSegmenter.leftoverTail(
                "Thank you. Thank you very much for coming today.",
                already: ["Thank you."],
                languageID: "en"
            ),
            "Thank you very much for coming today."
        )
        XCTAssertEqual(
            TranslationClauseSegmenter.leftoverTail(
                "We trained the model on Korean data too.",
                already: ["We trained the model."],
                languageID: "en"
            ),
            "We trained the model on Korean data too."
        )
        XCTAssertTrue(
            TranslationClauseSegmenter.isInPlaceGrowth(
                previous: "We trained the model.",
                incoming: "We trained the model on Korean data too."
            )
        )
    }

    func testCompactWhitespaceRestitchIsTheSameClause() {
        XCTAssertTrue(
            TranslationClauseSegmenter.isSameClause(
                "오늘 모델을 학습했습니다",
                "오늘모델을 학습했습니다"
            )
        )
        XCTAssertTrue(
            TranslationClauseSegmenter.isAlreadyPrintedSource(
                "오늘모델을 학습했습니다",
                already: ["오늘 모델을 학습했습니다"],
                languageID: "ko"
            )
        )
        XCTAssertEqual(
            TranslationClauseSegmenter.leftoverTail(
                "오늘모델을 학습했습니다 그리고 적용했습니다",
                already: ["오늘 모델을 학습했습니다"],
                languageID: "ko"
            ),
            "그리고 적용했습니다"
        )
        XCTAssertTrue(
            TranslationClauseSegmenter.isSameClause(
                "วันนี้เราฝึกโมเดลครับ",
                "วันนี้ เราฝึกโมเดลครับ"
            )
        )
    }

    func testHiddenPendingDoesNotPaintALiveCaption() {
        let lines = TheaterCaptionFlow.lines(
            committed: ["안녕."],
            committedIDs: [1],
            nextCaptionID: 2,
            committedSources: ["Hello."],
            draft: "그리고 출시했습니다",
            sourceDraft: "And we shipped it",
            pendingSources: ["We trained the model."],
            spokenDisplay: .hidden
        )
        XCTAssertEqual(lines.map(\.text), ["안녕."])
        XCTAssertEqual(lines.map(\.source), ["Hello."])
        XCTAssertEqual(lines.last?.id, "c-1")
        XCTAssertFalse(lines.contains { $0.isDraft })
        // liveID still reserves the next committed slot for pending + in-flight.
        XCTAssertEqual(
            TheaterCaptionFlow.liveID(after: [1], nextID: 2, pendingCount: 1),
            "c-3"
        )
    }


    func testDoubleStopDoesNotStartASecondFinish() {
        let controller = LiveTranslationController.shared
        controller.cancelSession()
        controller.subscriber.reset()
        controller.beginSession(kind: .insert)
        controller.stopListening()
        XCTAssertTrue(controller.isFinishingSessionForTesting)
        controller.stopListening()
        XCTAssertTrue(controller.isFinishingSessionForTesting)
        controller.cancelSession()
        XCTAssertFalse(controller.isFinishingSessionForTesting)
        controller.subscriber.reset()
    }
}
