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
        XCTAssertEqual(repeated.map(\.text), ["Hello.", "How are you"])
        XCTAssertEqual(repeated.last?.id, TheaterCaptionFlow.liveID(after: [1]))

        let midTalk = TheaterCaptionFlow.lines(
            committed: [],
            draft: "",
            sourceDraft: "Hello. Hello. How are you",
            spokenDisplay: .isTheCaption
        )
        XCTAssertEqual(midTalk.map(\.text), ["Hello. How are you"])

        let pairedSame = TheaterCaptionFlow.lines(
            committed: [],
            draft: "Hello.",
            sourceDraft: "Hello",
            spokenDisplay: .paired
        )
        XCTAssertEqual(pairedSame.last?.text, "Hello.")
        XCTAssertEqual(pairedSame.last?.source, "")
    }
}
