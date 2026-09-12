import SwiftUI
import XCTest
@testable import FluidSubtitles_Debug

// swiftlint:disable function_body_length cyclomatic_complexity type_body_length
// Tracked grandfather: existing FluidVoice-era file. New work belongs in a smaller file.

@MainActor
final class LiveTranslationClauseTests: XCTestCase {
    func testEnglishSplitsOnPunctuationAndKeepsOpenTail() {
        let split = TranslationClauseSegmenter.split(
            "Today we trained the model. Then we applied it to",
            languageID: "en"
        )
        XCTAssertEqual(split.completed, ["Today we trained the model."])
        XCTAssertEqual(split.tail, "Then we applied it to")
    }

    func testDecimalsDoNotSplitSentences() {
        let split = TranslationClauseSegmenter.split(
            "Accuracy reached 3.14 percent this week.",
            languageID: "en"
        )
        XCTAssertEqual(split.completed, ["Accuracy reached 3.14 percent this week."])
        XCTAssertEqual(split.tail, "")
    }

    func testIncompleteKoreanClauseIsNotComplete() {
        let fragment = "저는 오늘 그 모델을 실제 데이터에"
        XCTAssertFalse(TranslationClauseSegmenter.looksComplete(fragment, languageID: "ko"))
        XCTAssertEqual(
            TranslationClauseSegmenter.decision(forTail: fragment, languageID: "ko"),
            .waitForStability
        )
        XCTAssertEqual(
            TranslationClauseSegmenter.decision(forTail: "Today we trained the model.", languageID: "en"),
            .waitForStability
        )
        let split = TranslationClauseSegmenter.split(fragment, languageID: "ko")
        XCTAssertTrue(split.completed.isEmpty)
        XCTAssertEqual(split.tail, fragment)
    }

    func testKoreanPredicateEndingCompletesAClause() {
        let spoken = "저는 모델을 학습했습니다 그걸 적용하면"
        let split = TranslationClauseSegmenter.split(spoken, languageID: "ko")
        XCTAssertEqual(split.completed, ["저는 모델을 학습했습니다"])
        XCTAssertEqual(split.tail, "그걸 적용하면")
        XCTAssertTrue(TranslationClauseSegmenter.looksComplete("적용했습니다", languageID: "ko"))
        XCTAssertFalse(TranslationClauseSegmenter.looksComplete(spoken, languageID: "ko"))
        XCTAssertFalse(TranslationClauseSegmenter.looksComplete("그걸 적용하면", languageID: "ko"))
        let open = TranslationClauseSegmenter.split("저는 모델을 학습했습니다", languageID: "ko")
        XCTAssertTrue(open.completed.isEmpty)
        XCTAssertEqual(open.tail, "저는 모델을 학습했습니다")
    }

    func testJapanesePredicateEndingCompletesAClause() {
        let spoken = "モデルを学習しました それを適用すると"
        let split = TranslationClauseSegmenter.split(spoken, languageID: "ja")
        XCTAssertEqual(split.completed, ["モデルを学習しました"])
        XCTAssertEqual(split.tail, "それを適用すると")
        XCTAssertTrue(TranslationClauseSegmenter.looksComplete("学習しました", languageID: "ja"))
        let open = TranslationClauseSegmenter.split("モデルを学習しました", languageID: "ja")
        XCTAssertTrue(open.completed.isEmpty)
        XCTAssertEqual(open.tail, "モデルを学習しました")
    }

    func testOversizedTailIsForcedIntoALine() {
        let words = Array(repeating: "word", count: 80).joined(separator: " ")
        XCTAssertGreaterThan(words.count, LiveTranslationTiming.maxDraftCharacters)
        let split = TranslationClauseSegmenter.split(words, languageID: "en")
        XCTAssertFalse(split.completed.isEmpty)
        XCTAssertLessThanOrEqual(split.completed[0].count, LiveTranslationTiming.maxDraftCharacters)
        XCTAssertFalse(split.tail.isEmpty)
        XCTAssertTrue(TranslationClauseSegmenter.isVerbFinalLanguage("ko-KR"))
        XCTAssertFalse(TranslationClauseSegmenter.isVerbFinalLanguage("en"))
        XCTAssertEqual(
            TranslationClauseSegmenter.decision(forTail: words, languageID: "en"),
            .commitNow
        )
    }

    func testUnreadCompletedReturnsOnlyNewOrReplacedSentences() {
        let already = ["Today we trained the model."]
        XCTAssertEqual(
            TranslationClauseSegmenter.unreadCompleted(
                completed: ["Today we trained the model."],
                already: already
            ),
            []
        )
        XCTAssertEqual(
            TranslationClauseSegmenter.unreadCompleted(
                completed: ["Today we trained the model.", "Then we applied it."],
                already: already
            ),
            ["Then we applied it."]
        )
        XCTAssertEqual(
            TranslationClauseSegmenter.unreadCompleted(
                completed: ["Today we trained the model on last quarter's data."],
                already: already
            ),
            ["Today we trained the model on last quarter's data."]
        )
        XCTAssertEqual(
            TranslationClauseSegmenter.unreadCompleted(
                completed: ["Today we trained the model!", "Then we applied it.", "And we shipped it."],
                already: ["Today we trained the model.", "Then we applied it."]
            ),
            ["And we shipped it."]
        )
    }

    func testPunctuationOnlyRevisionsAreTheSameClause() {
        XCTAssertTrue(
            TranslationClauseSegmenter.isSameClause(
                "Today we trained the model.",
                "Today we trained the model!"
            )
        )
        XCTAssertTrue(
            TranslationClauseSegmenter.shouldReplaceLast(
                previous: "Today we trained the model.",
                incoming: "Today we trained the model!"
            )
        )
        XCTAssertEqual(
            TranslationClauseSegmenter.unreadCompleted(
                completed: ["Today we trained the model!"],
                already: ["Today we trained the model."]
            ),
            ["Today we trained the model!"]
        )
    }

    func testLeftoverTailDropsAlreadyCommittedSpeech() {
        XCTAssertEqual(
            TranslationClauseSegmenter.leftoverTail(
                "Hello we trained the model today",
                already: ["Hello we trained"]
            ),
            "the model today"
        )
        XCTAssertEqual(
            TranslationClauseSegmenter.leftoverTail(
                "Hello, we trained the model today",
                already: ["Hello we trained"]
            ),
            "the model today"
        )
        XCTAssertEqual(
            TranslationClauseSegmenter.leftoverTail(
                "Hello we trained the model today and then",
                already: ["Hello we trained", "the model today"]
            ),
            "and then"
        )
        XCTAssertEqual(
            TranslationClauseSegmenter.leftoverTail(
                "Today we trained the model. Then we applied it to",
                already: ["Today we trained the model."]
            ),
            "Then we applied it to"
        )
        XCTAssertEqual(
            TranslationClauseSegmenter.leftoverTail(
                "저는 모델을 학습했습니다그걸 적용하면",
                already: ["저는 모델을 학습했습니다"]
            ),
            "그걸 적용하면"
        )
        XCTAssertEqual(
            TranslationClauseSegmenter.leftoverTail(
                "저는 그 모델을 학습했습니다 그걸 적용하면",
                already: ["저는 모델을 학습했습니다"]
            ),
            "그걸 적용하면"
        )
        XCTAssertEqual(
            TranslationClauseSegmenter.leftoverTail(
                "Then we applied it to production",
                already: ["Yesterday we trained the model.", "Then we applied it to production"]
            ),
            ""
        )
        XCTAssertEqual(
            TranslationClauseSegmenter.leftoverTail(
                "Then we applied it to production and shipped",
                already: ["Yesterday we trained the model."]
            ),
            "Then we applied it to production and shipped"
        )
        XCTAssertEqual(
            TranslationClauseSegmenter.leftoverTail(
                "Yesterday we trained the model. Then we applied it to production and shipped",
                already: ["Then we applied it to production"]
            ),
            "Yesterday we trained the model. Then we applied it to production and shipped"
        )
        XCTAssertEqual(
            TranslationClauseSegmenter.leftoverTail(
                "이전문장입니다저는 모델을 학습했습니다그걸 적용하면",
                already: ["저는 모델을 학습했습니다"]
            ),
            "이전문장입니다저는 모델을 학습했습니다그걸 적용하면"
        )
        XCTAssertEqual(
            TranslationClauseSegmenter.leftoverTail(
                "The model is ready for production use today",
                already: ["Today we trained the model."]
            ),
            "The model is ready for production use today"
        )
        XCTAssertEqual(
            TranslationClauseSegmenter.leftoverTail(
                "Today we trained the model. Then we applied it. And we shipped it to production.",
                already: ["Today we trained the model."],
                languageID: "en"
            ),
            "Then we applied it. And we shipped it to production."
        )
        XCTAssertTrue(
            TranslationClauseSegmenter.isAlreadyPrintedSource(
                "저는 모델을 학습했습니다",
                already: ["저는 모델을 학습했습니다"]
            )
        )
        let firstEnglish = TranslationClauseSegmenter.nextCommitUnit(
            "Today we trained the model. Then we applied it. And we shipped it.",
            languageID: "en",
            allowPauseFinalize: false
        )
        XCTAssertEqual(firstEnglish?.unit, "Today we trained the model.")
        XCTAssertEqual(firstEnglish?.rest, "Then we applied it. And we shipped it.")
        let firstKorean = TranslationClauseSegmenter.nextCommitUnit(
            "저는 모델을 학습했습니다 그걸 적용하면 됩니다",
            languageID: "ko",
            allowPauseFinalize: false
        )
        XCTAssertEqual(firstKorean?.unit, "저는 모델을 학습했습니다")
        XCTAssertEqual(firstKorean?.rest, "그걸 적용하면 됩니다")
        let longTalk = Array(repeating: "word", count: 30).joined(separator: " ")
        let paused = TranslationClauseSegmenter.nextCommitUnit(
            longTalk,
            languageID: "en",
            allowPauseFinalize: true
        )
        XCTAssertEqual(paused?.unit.split(separator: " ").count, LiveTranslationTiming.maxLineWords)
        XCTAssertFalse(paused?.rest.isEmpty ?? true)
    }

    func testJammedPeriodsDoNotDumpAsOneClause() {
        let spoken = "Today we trained the model.Then we applied it.And we shipped it to production."
        let split = TranslationClauseSegmenter.split(spoken, languageID: "en")
        XCTAssertEqual(
            split.completed,
            [
                "Today we trained the model.",
                "Then we applied it.",
                "And we shipped it to production.",
            ]
        )
        XCTAssertEqual(split.tail, "")
        let next = TranslationClauseSegmenter.nextCommitUnit(
            spoken,
            languageID: "en",
            allowPauseFinalize: false
        )
        XCTAssertEqual(next?.unit, "Today we trained the model.")
        XCTAssertEqual(next?.rest, "Then we applied it.And we shipped it to production.")
        XCTAssertEqual(
            TranslationClauseSegmenter.liveOpenText(
                "Today we trained the model.Then we applied it.And we shipped it to",
                languageID: "en"
            ),
            "And we shipped it to"
        )
        XCTAssertEqual(
            TranslationClauseSegmenter.liveOpenText(spoken, languageID: "en"),
            "And we shipped it to production."
        )
        let runOn = (1...20).map { "word\($0)" }.joined(separator: " ")
        let liveRunOn = TranslationClauseSegmenter.liveOpenText(runOn, languageID: "en")
        XCTAssertEqual(liveRunOn.split(separator: " ").count, LiveTranslationTiming.maxLineWords)
        XCTAssertTrue(liveRunOn.hasPrefix("word1 "))
        XCTAssertTrue(liveRunOn.hasSuffix("word12"))
        XCTAssertEqual(
            TranslationClauseSegmenter.decision(forTail: runOn, languageID: "en"),
            .waitForStability
        )
        let lowercase = TranslationClauseSegmenter.split(
            "Today we trained the model.then we applied it.",
            languageID: "en"
        )
        XCTAssertEqual(lowercase.completed, ["Today we trained the model.", "then we applied it."])
        XCTAssertEqual(lowercase.tail, "")
    }

    func testCaptionLogReplacesPrefixInsteadOfDuplicatingTheTalk() {
        var log = LectureCaptionLog()
        log.commit(source: "Hello", translated: "안녕")
        log.commit(source: "Hello world today", translated: "안녕 세상 오늘")
        XCTAssertEqual(log.sourceLines, ["Hello world today"])
        XCTAssertEqual(log.translatedLines, ["안녕 세상 오늘"])

        log.commit(source: "Hello world", translated: "안녕 세상")
        XCTAssertEqual(log.sourceLines, ["Hello world today"])
        XCTAssertEqual(log.translatedLines, ["안녕 세상 오늘"])

        log.commit(source: "Next we measure it.", translated: "다음으로 측정합니다.")
        XCTAssertEqual(log.sourceLines, ["Hello world today", "Next we measure it."])
        XCTAssertEqual(log.contextSourceLines.last, "Next we measure it.")

        log.commit(source: "Today we trained the model.", translated: "오늘 모델을 학습했습니다.")
        log.commit(
            source: "Today we trained the model. Then we applied it.",
            translated: "오늘 모델을 학습했습니다. 그다음 적용했습니다."
        )
        XCTAssertEqual(log.sourceLines.last, "Today we trained the model. Then we applied it.")
        XCTAssertEqual(log.sourceLines.dropLast().last, "Today we trained the model.")
    }

    func testTheaterCaptionFlowAppendsDownwardWithoutRewritingEarlierLines() {
        let first = TheaterCaptionFlow.lines(
            committed: ["Hello."],
            committedIDs: [1],
            draft: ""
        )
        XCTAssertEqual(first.map(\.text), ["Hello."])
        XCTAssertEqual(first.map(\.isCurrent), [true])
        XCTAssertEqual(first.first?.id, "c-1")

        let second = TheaterCaptionFlow.lines(
            committed: ["Hello.", "Next we measure it."],
            committedIDs: [1, 2],
            draft: ""
        )
        XCTAssertEqual(second.map(\.text), ["Hello.", "Next we measure it."])
        XCTAssertEqual(second.first?.isCurrent, false)
        XCTAssertEqual(second.first?.id, "c-1")
        XCTAssertEqual(second.last?.id, "c-2")

        let withDraft = TheaterCaptionFlow.lines(
            committed: ["Hello."],
            committedIDs: [1],
            draft: "Next we measure it."
        )
        XCTAssertEqual(withDraft.map(\.text), ["Hello.", "Next we measure it."])
        XCTAssertEqual(withDraft.last?.id, TheaterCaptionFlow.currentLineID)

        let liveSource = TheaterCaptionFlow.lines(
            committed: ["Hello."],
            committedIDs: [1],
            draft: "",
            sourceDraft: "Next we measure it"
        )
        XCTAssertEqual(liveSource.map(\.text), ["Hello."])
        XCTAssertEqual(liveSource.last?.id, "c-1")
        XCTAssertEqual(liveSource.last?.isDraft, false)

        let firstWords = TheaterCaptionFlow.lines(
            committed: [],
            draft: "",
            sourceDraft: "Hello we trained"
        )
        XCTAssertTrue(firstWords.isEmpty)

        let translatedLive = TheaterCaptionFlow.lines(
            committed: ["Hello."],
            committedIDs: [1],
            committedSources: ["안녕."],
            draft: "Next we measure it.",
            sourceDraft: "다음으로 측정합니다"
        )
        XCTAssertEqual(translatedLive.last?.text, "Next we measure it.")
        XCTAssertEqual(translatedLive.last?.source, "")
        XCTAssertEqual(translatedLive.last?.id, TheaterCaptionFlow.currentLineID)

        let committedKeepsLiveIdentity = TheaterCaptionFlow.lines(
            committed: ["안녕."],
            committedIDs: [1],
            committedSources: ["Hello we trained"],
            draft: "",
            sourceDraft: ""
        )
        XCTAssertEqual(committedKeepsLiveIdentity.last?.id, "c-1")
        XCTAssertEqual(committedKeepsLiveIdentity.last?.text, "안녕.")
        XCTAssertEqual(committedKeepsLiveIdentity.last?.source, "Hello we trained")
        XCTAssertEqual(committedKeepsLiveIdentity.last?.isCurrent, true)

        let nextLineHighlights = TheaterCaptionFlow.lines(
            committed: ["안녕."],
            committedIDs: [1],
            committedSources: ["Hello we trained"],
            draft: "",
            sourceDraft: "And we shipped it"
        )
        XCTAssertEqual(nextLineHighlights.map(\.id), ["c-1"])
        XCTAssertEqual(nextLineHighlights.last?.isCurrent, true)
        XCTAssertEqual(nextLineHighlights.last?.source, "Hello we trained")

        let reprinted = TheaterCaptionFlow.lines(
            committed: ["I trained the model."],
            committedIDs: [1],
            committedSources: ["저는 모델을 학습했습니다"],
            draft: "",
            sourceDraft: "저는 모델을 학습했습니다"
        )
        XCTAssertEqual(reprinted.map(\.text), ["I trained the model."])
        XCTAssertEqual(reprinted.last?.isDraft, false)

        let many = (1...10).map { "Line \($0)." }
        let recent = TheaterCaptionFlow.lines(
            committed: many,
            committedIDs: Array(1...10).map(UInt64.init),
            draft: ""
        )
        XCTAssertEqual(recent.count, LiveTranslationTiming.visibleTheaterLines)
        XCTAssertEqual(recent.map(\.text), Array(many.suffix(LiveTranslationTiming.visibleTheaterLines)))
        XCTAssertEqual(recent.first?.id, "c-8")
        XCTAssertEqual(recent.last?.id, "c-10")

        let recentPlusLive = TheaterCaptionFlow.lines(
            committed: many,
            committedIDs: Array(1...10).map(UInt64.init),
            draft: "",
            sourceDraft: "Line 11 lives here"
        )
        XCTAssertEqual(recentPlusLive.count, LiveTranslationTiming.visibleTheaterLines)
        XCTAssertEqual(recentPlusLive.first?.id, "c-8")
        XCTAssertEqual(recentPlusLive.last?.id, "c-10")
        XCTAssertEqual(recentPlusLive.last?.text, "Line 10.")
    }

    func testTheaterLinePrinterGrowsALineWithoutRewinding() {
        XCTAssertEqual(TheaterLinePrinter.extend("", toward: "Hello world"), "Hello")
        XCTAssertEqual(TheaterLinePrinter.extend("Hello", toward: "Hello world"), "Hello world")
        XCTAssertEqual(TheaterLinePrinter.extend("안녕", toward: "안녕하세요"), "안녕하")
        XCTAssertEqual(TheaterLinePrinter.extend("Hello", toward: "Next line"), "Hello")
        XCTAssertEqual(TheaterLinePrinter.follow("", toward: "Hello world"), "Hello")
        XCTAssertEqual(TheaterLinePrinter.follow("Hello", toward: "Hello world"), "Hello world")
        XCTAssertEqual(TheaterLinePrinter.follow("Hello", toward: "Next line"), "Hello")
        XCTAssertEqual(TheaterLinePrinter.follow("Hello world", toward: ""), "Hello world")
        XCTAssertEqual(
            TheaterLinePrinter.follow("Hello world today. Then we applied it", toward: "Hello world today"),
            "Hello world today. Then we applied"
        )
        XCTAssertEqual(
            TheaterLinePrinter.follow("I went to the shop", toward: "I went to the store"),
            "I went to the s"
        )
        XCTAssertEqual(
            TheaterLinePrinter.follow("Hello world today", toward: "Hello there everyone"),
            "Hello world"
        )
        XCTAssertTrue(TheaterLinePrinter.isContinuation("Hello we trained", of: "Hello we trained the model"))
        XCTAssertFalse(TheaterLinePrinter.isContinuation("Hello we trained the model", of: "Next we applied"))
        XCTAssertTrue(
            TheaterLinePrinter.shouldAdoptPrintedCaption(
                currentSpoken: "Hello",
                currentTranslated: "안녕",
                nextSpoken: "Hello world",
                nextTranslated: "안녕 세상"
            )
        )
        XCTAssertFalse(
            TheaterLinePrinter.shouldAdoptPrintedCaption(
                currentSpoken: "Today we trained the modal.",
                currentTranslated: "오늘 모델을 학습했습니다.",
                nextSpoken: "Today we trained the model.",
                nextTranslated: "오늘 모델을 학습했어요."
            )
        )
        XCTAssertFalse(
            TheaterLinePrinter.shouldAdoptPrintedCaption(
                currentSpoken: "I went to the shop",
                currentTranslated: "",
                nextSpoken: "I went to the store",
                nextTranslated: ""
            )
        )
        XCTAssertEqual(TheaterLinePrinter.advance("Hello", toward: "Hello world"), "Hello world")
        XCTAssertEqual(TheaterLinePrinter.advance("", toward: String(repeating: "가", count: 40)).count, 1)
        XCTAssertEqual(
            TheaterLinePrinter.follow("번역문", toward: "", emptyTarget: .retract),
            "번역"
        )
    }

    func testBilingualWrapInterleavesEnglishAndKoreanLineByLine() {
        let font = NSFont.systemFont(ofSize: 48, weight: .semibold)
        let spoken = "Hello world today friends"
        let translated = "안녕하세요 여러분 오늘도"
        let rows = TheaterBilingualWrap.rows(
            spoken: spoken,
            translated: translated,
            font: font,
            width: 140
        )
        XCTAssertGreaterThanOrEqual(rows.count, 4)
        XCTAssertEqual(rows.filter(\.isSpoken).map(\.text).joined(), spoken)
        XCTAssertEqual(rows.filter { !$0.isSpoken }.map(\.text).joined(), translated)
        XCTAssertTrue(rows[0].isSpoken)
        XCTAssertFalse(rows[1].isSpoken)
        let spokenIndexes = rows.enumerated().compactMap { $0.element.isSpoken ? $0.offset : nil }
        let translatedIndexes = rows.enumerated().compactMap { $0.element.isSpoken ? nil : $0.offset }
        XCTAssertEqual(spokenIndexes[0], 0)
        XCTAssertEqual(translatedIndexes[0], 1)
        XCTAssertLessThan(spokenIndexes[1], translatedIndexes[1])
    }

    func testBilingualWrapPutsEnglishBeforeKoreanWhenKoreanIsSpoken() {
        let font = NSFont.systemFont(ofSize: 48, weight: .semibold)
        let rows = TheaterBilingualWrap.rows(
            spoken: "안녕하세요 여러분 오늘도 반갑습니다",
            translated: "Hello world today friends",
            font: font,
            width: 140
        )
        XCTAssertGreaterThanOrEqual(rows.count, 4)
        XCTAssertFalse(rows[0].isSpoken)
        XCTAssertTrue(rows[1].isSpoken)
        XCTAssertEqual(rows.filter(\.isSpoken).map(\.text).joined(), "안녕하세요 여러분 오늘도 반갑습니다")
        XCTAssertEqual(rows.filter { !$0.isSpoken }.map(\.text).joined(), "Hello world today friends")
    }

    func testBilingualWrapPutsEnglishBeforeThaiWhenThaiIsSpoken() {
        let font = NSFont.systemFont(ofSize: 48, weight: .semibold)
        let rows = TheaterBilingualWrap.rows(
            spoken: "สวัสดีครับทุกคน วันนี้ก็ยินดีที่ได้พบกัน",
            translated: "Hello world today friends",
            font: font,
            width: 140
        )
        XCTAssertGreaterThanOrEqual(rows.count, 4)
        XCTAssertFalse(rows[0].isSpoken)
        XCTAssertTrue(rows[1].isSpoken)
        XCTAssertEqual(rows.filter(\.isSpoken).map(\.text).joined(), "สวัสดีครับทุกคน วันนี้ก็ยินดีที่ได้พบกัน")
        XCTAssertEqual(rows.filter { !$0.isSpoken }.map(\.text).joined(), "Hello world today friends")
    }

    func testBilingualWrapKeepsSpokenEnglishBeforeThai() {
        let font = NSFont.systemFont(ofSize: 48, weight: .semibold)
        let spoken = "Hello world today friends"
        let translated = "สวัสดีครับทุกคน วันนี้ก็ยินดีที่ได้พบกัน"
        let rows = TheaterBilingualWrap.rows(
            spoken: spoken,
            translated: translated,
            font: font,
            width: 140
        )
        XCTAssertGreaterThanOrEqual(rows.count, 4)
        XCTAssertTrue(rows[0].isSpoken)
        XCTAssertFalse(rows[1].isSpoken)
        XCTAssertEqual(rows.filter(\.isSpoken).map(\.text).joined(), spoken)
        XCTAssertEqual(rows.filter { !$0.isSpoken }.map(\.text).joined(), translated)
    }

    func testBilingualWrapHoldsLaterPairsUntilTheCurrentLineFinishes() {
        let font = NSFont.systemFont(ofSize: 48, weight: .semibold)
        let spoken = "Hello world today friends"
        let translated = "안녕하세요 여러분 오늘도"
        let template = TheaterBilingualWrap.rows(
            spoken: spoken,
            translated: translated,
            font: font,
            width: 140
        )
        XCTAssertGreaterThanOrEqual(template.count, 4)

        let firstKorean = template.first { !$0.isSpoken }?.text ?? ""
        XCTAssertGreaterThan(firstKorean.count, 1)
        let partialKorean = String(firstKorean.dropLast())

        let whileTyping = TheaterBilingualWrap.revealedRows(
            spoken: spoken,
            translated: translated,
            printedSpoken: spoken,
            printedTranslated: partialKorean,
            font: font,
            width: 140
        )
        XCTAssertEqual(whileTyping.filter(\.isSpoken).count, 1)
        XCTAssertEqual(whileTyping.filter { !$0.isSpoken }.map(\.text).joined(), partialKorean)
        XCTAssertLessThan(whileTyping.count, template.count)

        let finished = TheaterBilingualWrap.revealedRows(
            spoken: spoken,
            translated: translated,
            printedSpoken: spoken,
            printedTranslated: translated,
            font: font,
            width: 140
        )
        XCTAssertEqual(finished, template)
    }

    func testBilingualWrapDoesNotInventGlyphLinesBeforeLayout() {
        let font = NSFont.systemFont(ofSize: 48, weight: .semibold)
        let rows = TheaterBilingualWrap.rows(
            spoken: "Hello world today friends",
            translated: "안녕하세요 여러분",
            font: font,
            width: 8
        )
        XCTAssertEqual(rows.map(\.text), ["Hello world today friends", "안녕하세요 여러분"])
    }

    func testTheaterCaptionFlowKeepsPendingClausesVisible() {
        let lines = TheaterCaptionFlow.lines(
            committed: ["Hello."],
            committedIDs: [1],
            committedSources: ["안녕."],
            draft: "",
            sourceDraft: "And we shipped it",
            pendingSources: ["Today we trained the model."]
        )
        XCTAssertEqual(lines.map(\.id), ["c-1"])
        XCTAssertEqual(lines.last?.text, "Hello.")
        XCTAssertEqual(lines.last?.isDraft, false)
        XCTAssertTrue(lines.allSatisfy { !$0.id.hasPrefix("p-") })
    }

    func testTheaterTypefaceFallsBackToSystem() {
        XCTAssertEqual(TheaterTypeface.resolved(""), .system)
        XCTAssertEqual(TheaterTypeface.resolved("Helvetica Neue"), .helveticaNeue)
        XCTAssertEqual(TheaterTypeface.resolved("missing").displayName, "System")
        XCTAssertEqual(TheaterTypeface.helveticaNeue.postScriptName, "HelveticaNeue")
        XCTAssertNotNil(TheaterTypeface.helveticaNeue.nsFont(size: 32, weight: .semibold))
    }

    func testTheaterAppearanceResolvesDarkAndLight() {
        XCTAssertEqual(TheaterAppearance.resolved(nil), .dark)
        XCTAssertEqual(TheaterAppearance.resolved(""), .dark)
        XCTAssertEqual(TheaterAppearance.resolved("light"), .light)
        XCTAssertEqual(TheaterAppearance.resolved("dark").toggled, .light)
        XCTAssertEqual(TheaterAppearance.light.colorScheme, .light)
        XCTAssertEqual(TheaterAppearance.dark.toggleSymbol, "sun.max.fill")
        XCTAssertEqual(TheaterAppearance.light.toggleSymbol, "moon.fill")
    }

    @MainActor
    func testCancelKeepsCommittedCaptions() {
        let subscriber = LiveTranslationSubscriber()
        subscriber.seedCommittedForTesting(source: "Hello we trained the model.", translated: "안녕하세요.")
        subscriber.endListening()
        XCTAssertEqual(subscriber.committedLines, ["안녕하세요."])
        XCTAssertTrue(subscriber.sourceDraft.isEmpty)
        XCTAssertEqual(subscriber.translatedDraft, "안녕하세요.")
    }

    @MainActor
    func testBeginListeningKeepsCommittedCaptions() {
        let subscriber = LiveTranslationSubscriber()
        subscriber.seedCommittedForTesting(source: "Hello we trained the model.", translated: "안녕하세요.")
        subscriber.beginListening()
        XCTAssertEqual(subscriber.committedLines, ["안녕하세요."])
        XCTAssertTrue(subscriber.sourceDraft.isEmpty)
        XCTAssertEqual(subscriber.translatedDraft, "안녕하세요.")
    }

    @MainActor
    func testInsertPostsOnlyThisListen() {
        let subscriber = LiveTranslationSubscriber()
        subscriber.seedCommittedForTesting(source: "Yesterday we trained the model.", translated: "어제 모델을 훈련했습니다.")
        subscriber.beginListening()
        subscriber.seedCommittedForTesting(source: "Today we measure it.", translated: "오늘은 측정합니다.")
        XCTAssertEqual(subscriber.deliveryDocument(), "어제 모델을 훈련했습니다.\n오늘은 측정합니다.")
        XCTAssertEqual(subscriber.pendingInsertDocument(), "오늘은 측정합니다.")
        XCTAssertEqual(subscriber.consumePendingInsertDocument(), "오늘은 측정합니다.")
        XCTAssertTrue(subscriber.pendingInsertDocument().isEmpty)
        XCTAssertEqual(subscriber.deliveryDocument(), "어제 모델을 훈련했습니다.\n오늘은 측정합니다.")
    }

    @MainActor
    func testClosingTheaterDuringInsertKeepsTheListen() {
        let controller = LiveTranslationController.shared
        controller.cancelSession()
        controller.subscriber.reset()
        controller.beginSession(kind: .insert)
        controller.subscriber.seedCommittedForTesting(source: "Hello.", translated: "안녕.")
        controller.theaterWasClosed()
        XCTAssertEqual(controller.subscriber.committedLines, ["안녕."])
        XCTAssertTrue(controller.isSessionActive)
        XCTAssertEqual(controller.listenKind, .insert)
        controller.cancelSession()
        controller.subscriber.reset()
    }

    @MainActor
    func testStaleStopDoesNotWriteIntoTheNextListen() async {
        let controller = LiveTranslationController.shared
        controller.cancelSession()
        controller.subscriber.reset()
        controller.beginSession(kind: .insert)
        controller.subscriber.seedCommittedForTesting(source: "Yesterday.", translated: "어제.")
        controller.stopListening()
        controller.beginSession(kind: .insert)
        controller.subscriber.reset()
        controller.subscriber.seedCommittedForTesting(source: "Today.", translated: "오늘.")
        let leaked = await controller.finishSession(finalSource: "This was the previous talk.")
        XCTAssertEqual(leaked, "")
        XCTAssertEqual(controller.subscriber.committedLines, ["오늘."])
        controller.cancelSession()
        controller.subscriber.reset()
    }

    @MainActor
    func testResetClearsTheBoard() {
        let subscriber = LiveTranslationSubscriber()
        subscriber.seedCommittedForTesting(source: "Hello we trained the model.", translated: "안녕하세요.")
        subscriber.reset()
        XCTAssertTrue(subscriber.committedLines.isEmpty)
        XCTAssertTrue(subscriber.deliveryDocument().isEmpty)
        XCTAssertTrue(subscriber.pendingInsertDocument().isEmpty)
    }

    @MainActor
    func testEditedLinesReplaceTheaterDocument() {
        let subscriber = LiveTranslationSubscriber()
        subscriber.seedCommittedForTesting(source: "Hello.", translated: "안녕.")
        subscriber.applyEditedLines(["Hello there.", "Next we measure it."])
        XCTAssertEqual(subscriber.committedLines, ["Hello there.", "Next we measure it."])
        XCTAssertEqual(subscriber.deliveryDocument(), "Hello there.\nNext we measure it.")
    }

    func testCaptionLogKeepsALongLecture() {
        var log = LectureCaptionLog()
        for index in 1...12 {
            log.commit(source: "line \(index)", translated: "caption \(index)")
        }
        XCTAssertEqual(log.translatedLines.count, 12)
        XCTAssertEqual(log.translatedLines.first, "caption 1")
        XCTAssertEqual(log.lineIDs.first, 1)
        XCTAssertEqual(log.lineIDs.last, 12)
        XCTAssertEqual(LiveTranslationTiming.maxCommittedLines, 200)
    }

    func testTheaterCaptionDocumentKeepsCommittedLinesAndOpenDraft() {
        XCTAssertEqual(
            PresenterCaptionController.captionDocument(
                committed: ["Hello.", "Next we measure it."],
                draft: "And then"
            ),
            "Hello.\nNext we measure it.\nAnd then"
        )
        XCTAssertEqual(
            PresenterCaptionController.captionDocument(
                committed: ["Hello."],
                draft: "Hello."
            ),
            "Hello."
        )
        XCTAssertEqual(
            PresenterCaptionController.captionDocument(committed: [], draft: ""),
            ""
        )
    }

    func testJoinTranslatedLinesUsesSpacesForEnglishAndNoneForKorean() {
        XCTAssertEqual(
            TranslationClauseSegmenter.joinTranslatedLines(
                ["Hello.", "Next we measure it."],
                languageID: "en"
            ),
            "Hello. Next we measure it."
        )
        XCTAssertEqual(
            TranslationClauseSegmenter.joinTranslatedLines(
                ["안녕하세요.", "다음으로 측정합니다."],
                languageID: "ko"
            ),
            "안녕하세요.다음으로 측정합니다."
        )
    }

    func testLectureTimingWaitsForANaturalPause() {
        XCTAssertEqual(
            Double(LiveTranslationTiming.openSettleNanoseconds(languageID: "en")) / 1_000_000_000,
            3.5,
            accuracy: 0.01
        )
        XCTAssertEqual(
            Double(LiveTranslationTiming.completeSettleNanoseconds(languageID: "en")) / 1_000_000_000,
            1.0,
            accuracy: 0.01
        )
        XCTAssertEqual(
            Double(LiveTranslationTiming.openSettleNanoseconds(languageID: "ko")) / 1_000_000_000,
            6.0,
            accuracy: 0.01
        )
        XCTAssertEqual(
            Double(LiveTranslationTiming.openSettleNanoseconds(languageID: "th")) / 1_000_000_000,
            4.0,
            accuracy: 0.01
        )
        XCTAssertEqual(
            TranslationClauseSegmenter.settleNanoseconds(
                unreadCount: 0,
                tail: "Then we applied it to the new data",
                languageID: "en"
            ),
            LiveTranslationTiming.openSettleNanoseconds(languageID: "en")
        )
        XCTAssertEqual(
            TranslationClauseSegmenter.settleNanoseconds(
                unreadCount: 1,
                tail: "",
                languageID: "en"
            ),
            LiveTranslationTiming.completeSettleNanoseconds(languageID: "en")
        )
        XCTAssertEqual(
            TranslationClauseSegmenter.settleNanoseconds(
                unreadCount: 0,
                tail: "Today we trained the model.",
                languageID: "en"
            ),
            LiveTranslationTiming.completeSettleNanoseconds(languageID: "en")
        )
        XCTAssertFalse(TranslationClauseSegmenter.isReadyToCommit("um", languageID: "en"))
        XCTAssertTrue(TranslationClauseSegmenter.isReadyToCommit("Today we trained the model.", languageID: "en"))
        XCTAssertFalse(
            TranslationClauseSegmenter.isReadyToCommit(
                "Then we applied it to the new data set",
                languageID: "en"
            )
        )
        XCTAssertTrue(
            TranslationClauseSegmenter.isReadyToCommit(
                "Then we applied it to the new data set",
                languageID: "en",
                allowPauseFinalize: true
            )
        )
        XCTAssertFalse(
            TranslationClauseSegmenter.isPauseFinalizable("okay sure", languageID: "en")
        )
        XCTAssertFalse(
            TranslationClauseSegmenter.shouldRestartSettle(
                previous: "Hello we trained the model",
                incoming: "Hello we trained the model."
            )
        )
        XCTAssertFalse(
            TranslationClauseSegmenter.shouldRestartSettle(
                previous: "Hello we trained the model today",
                incoming: "Hello we trained the model"
            )
        )
        XCTAssertTrue(
            TranslationClauseSegmenter.shouldRestartSettle(
                previous: "Hello we trained",
                incoming: "Hello we trained the model"
            )
        )
        XCTAssertEqual(LiveTranslationTiming.contextSentenceCount, 4)
        XCTAssertEqual(LiveTranslationTiming.visibleTheaterLines, 3)
        XCTAssertEqual(LiveTranslationTiming.maxDraftCharacters, 240)
        XCTAssertEqual(LiveTranslationTiming.eouHoldNanoseconds, 400_000_000)
        XCTAssertEqual(TheaterQualityScore.wordErrorRate(reference: "today we trained", hypothesis: "today we trained"), 0)
        XCTAssertEqual(TheaterQualityScore.wordErrorRate(reference: "today we trained", hypothesis: "today we measured"), 1.0 / 3.0, accuracy: 0.01)
        XCTAssertTrue(
            TheaterQualityScore.isStageAcceptable(
                reference: TheaterQualityScore.korean.spoken,
                hypothesis: TheaterQualityScore.korean.spoken,
                languageID: "ko"
            )
        )
        XCTAssertFalse(
            TheaterQualityScore.isStageAcceptable(
                reference: TheaterQualityScore.korean.spoken,
                hypothesis: "다른 문장입니다",
                languageID: "ko"
            )
        )
        XCTAssertFalse(
            TranslationClauseSegmenter.isPauseFinalizable("저는 오늘 그 모델을", languageID: "ko")
        )
        XCTAssertTrue(TranslationClauseSegmenter.looksComplete("적용했습니다", languageID: "ko"))
        XCTAssertTrue(TranslationClauseSegmenter.looksComplete("ได้เลยครับ", languageID: "th"))
        XCTAssertFalse(TranslationClauseSegmenter.isPauseFinalizable("ผมจะ", languageID: "th"))
    }

    func testKoreanConversationalEndingsCompleteAClause() {
        XCTAssertFalse(TranslationClauseSegmenter.looksComplete("그건 그렇거든요", languageID: "ko"))
        XCTAssertFalse(TranslationClauseSegmenter.looksComplete("제가 할게요", languageID: "ko"))
        XCTAssertTrue(TranslationClauseSegmenter.isInternalBoundary("그건 그렇거든요", languageID: "ko"))
        XCTAssertTrue(TranslationClauseSegmenter.looksComplete("지금 갑니까", languageID: "ko"))
        XCTAssertTrue(TranslationClauseSegmenter.looksComplete("그렇죠", languageID: "ko"))
        XCTAssertFalse(TranslationClauseSegmenter.looksComplete("hello죠", languageID: "ko"))
        XCTAssertFalse(TranslationClauseSegmenter.looksComplete("가까", languageID: "ko"))
    }

    func testThaiPoliteEndingsCompleteAClause() {
        XCTAssertTrue(TranslationClauseSegmenter.looksComplete("ได้เลยครับผม", languageID: "th"))
        XCTAssertFalse(TranslationClauseSegmenter.looksComplete("ไปเลยจ้ะ", languageID: "th"))
        XCTAssertFalse(TranslationClauseSegmenter.looksComplete("เอาล่ะ", languageID: "th"))
        XCTAssertTrue(TranslationClauseSegmenter.isInternalBoundary("ไปเลยจ้ะ", languageID: "th"))
    }

    func testCompleteKoreanSentenceIsNotLineCut() {
        let sentence = String(repeating: "그 모델을 다시 학습하고 ", count: 6) + "평가했습니다"
        XCTAssertGreaterThan(sentence.count, LiveTranslationTiming.maxLineCharacters)
        XCTAssertLessThan(sentence.count, LiveTranslationTiming.maxDraftCharacters)
        XCTAssertTrue(TranslationClauseSegmenter.looksComplete(sentence, languageID: "ko"))
        let next = TranslationClauseSegmenter.nextCommitUnit(
            sentence,
            languageID: "ko",
            allowPauseFinalize: false
        )
        XCTAssertEqual(next?.unit, sentence)
        XCTAssertEqual(next?.rest, "")
    }

    func testPolishRejectsAPriorSourceSentence() {
        XCTAssertNil(
            LLMTranslationEngine.acceptedPolished(
                "Today we trained the model. Then we applied it.",
                draft: "Then we applied it.",
                target: TranslationLanguageCatalog.english,
                priorSource: ["Today we trained the model."]
            )
        )
        XCTAssertEqual(
            LLMTranslationEngine.acceptedPolished(
                "Then we applied it.",
                draft: "Then we applied it.",
                target: TranslationLanguageCatalog.english,
                priorSource: ["Today we trained the model."]
            ),
            "Then we applied it."
        )
    }

    func testConfirmRunsOnStopAndPause() {
        XCTAssertFalse(LiveTranslationConfirm.shouldReDecode(isFinal: false))
        XCTAssertFalse(LiveTranslationConfirm.shouldReDecode(isFinal: false, isPause: false))
        XCTAssertTrue(LiveTranslationConfirm.shouldReDecode(isFinal: true))
        XCTAssertTrue(LiveTranslationConfirm.shouldReDecode(isFinal: false, isPause: true))
        XCTAssertTrue(LiveTranslationConfirm.requiresConfirmBeforePrint(languageID: "ko"))
        XCTAssertTrue(LiveTranslationConfirm.requiresConfirmBeforePrint(languageID: "th"))
        XCTAssertFalse(LiveTranslationConfirm.requiresConfirmBeforePrint(languageID: "en"))
        XCTAssertTrue(LiveTranslationConfirm.shouldReDecode(isFinal: false, languageID: "ko"))
        XCTAssertFalse(LiveTranslationConfirm.shouldReDecode(isFinal: false, languageID: "en"))
    }

    func testRevisedLastCommittedFixesAOneWordASRCorrection() {
        XCTAssertEqual(
            TranslationClauseSegmenter.revisedLastCommitted(
                confirmed: "Today we trained the model.",
                lastCommitted: "Today we trained the modal.",
                languageID: "en"
            ),
            "Today we trained the model."
        )
        XCTAssertNil(
            TranslationClauseSegmenter.revisedLastCommitted(
                confirmed: "Then we applied it.",
                lastCommitted: "Today we trained the model.",
                languageID: "en"
            )
        )
        XCTAssertTrue(
            TranslationClauseSegmenter.shouldReviseCommitted(
                previous: "오늘 모델을 학습했습니다",
                incoming: "오늘 모델을 학습했어요",
                languageID: "ko"
            )
        )
        XCTAssertFalse(
            TranslationClauseSegmenter.shouldReviseCommitted(
                previous: "Hello world today",
                incoming: "Hello world",
                languageID: "en"
            )
        )
        XCTAssertEqual(
            TranslationClauseSegmenter.revisedLastCommitted(
                confirmed: "Today we trained the model. Then we applied it.",
                lastCommitted: "Today we trained the modal.",
                languageID: "en"
            ),
            "Today we trained the model."
        )

        var log = LectureCaptionLog()
        log.commit(source: "Today we trained the modal.", translated: "오늘 모델을 학습했습니다.")
        log.commit(source: "Today we trained the model.", translated: "오늘 모델을 학습했어요.")
        XCTAssertEqual(log.sourceLines, ["Today we trained the modal."])
        XCTAssertEqual(log.translatedLines, ["오늘 모델을 학습했습니다."])
    }

    /// Theater peels printed clauses off the cumulative transcript on every ASR
    /// tick (200 ms on Parakeet). Rescanning the transcript once per committed
    /// line cost 216 ms on a full board, which froze the live line on long talks.
    func testPeelStaysAffordableOnAFullBoard() {
        let already = (1...LiveTranslationTiming.maxCommittedLines)
            .map { "This is committed sentence number \($0) of the talk." }
        let tail = "And this is the open tail we are speaking now"
        let transcript = already.joined(separator: " ") + " " + tail

        let started = ProcessInfo.processInfo.systemUptime
        let leftover = TranslationClauseSegmenter.leftoverTail(
            transcript,
            already: already,
            languageID: "en"
        )
        let milliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000

        XCTAssertEqual(leftover, tail)
        XCTAssertLessThan(
            milliseconds,
            100,
            "Peeling a full board took \(Int(milliseconds))ms; one ASR tick is 200ms."
        )
    }

    func testPeelHandlesARevisedTranscriptWithoutRescanningPerLine() {
        let already = (1...LiveTranslationTiming.maxCommittedLines)
            .map { "This is committed sentence number \($0) of the talk." }
        // ASR dropped the sentence-final punctuation it had emitted earlier.
        let transcript = (1...LiveTranslationTiming.maxCommittedLines)
            .map { "This is committed sentence number \($0) of the talk" }
            .joined(separator: " ") + " And this is the open tail we are speaking now"

        let started = ProcessInfo.processInfo.systemUptime
        let leftover = TranslationClauseSegmenter.leftoverTail(
            transcript,
            already: already,
            languageID: "en"
        )
        let milliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000

        XCTAssertEqual(leftover, "And this is the open tail we are speaking now")
        XCTAssertLessThan(milliseconds, 100)
    }

    func testCaptionLogPatchesALineByID() {
        var log = LectureCaptionLog()
        let first = log.commit(source: "Hello.", translated: "안녕하세요.")
        XCTAssertEqual(first?.id, 1)
        XCTAssertTrue(log.updateTranslated(id: 1, translated: "안녕.", wasPolished: true))
        XCTAssertEqual(log.translatedLines, ["안녕."])
        XCTAssertTrue(log.didPolishAnyLine)
        XCTAssertEqual(log.captionPairs.first?.wasPolished, true)
    }
}
