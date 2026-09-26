import AppKit
import Carbon
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
            "and shipped"
        )
        XCTAssertEqual(
            TranslationClauseSegmenter.leftoverTail(
                "이전문장입니다저는 모델을 학습했습니다그걸 적용하면",
                already: ["저는 모델을 학습했습니다"]
            ),
            "그걸 적용하면"
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
        XCTAssertEqual(
            TranslationClauseSegmenter.printableCommitUnit(
                "Today we trained the model. Then we applied it. And we shipped it.",
                already: ["Today we trained the model."],
                languageID: "en",
                allowPauseFinalize: false
            ),
            "Then we applied it."
        )
        XCTAssertEqual(
            TranslationClauseSegmenter.printableCommitUnit(
                "Today we trained the model. Then we applied it.",
                already: [],
                languageID: "en",
                allowPauseFinalize: false
            ),
            "Today we trained the model."
        )
        XCTAssertFalse(
            TranslationClauseSegmenter.shouldReplaceLast(
                previous: "Today we trained the model.",
                incoming: "Today we trained the model. Then we applied it."
            )
        )
        XCTAssertEqual(
            TranslationClauseSegmenter.leftoverTail(
                "Today we trained the model. Then we applied it.",
                already: ["Today we trained the modal."],
                languageID: "en"
            ),
            "Then we applied it."
        )
        XCTAssertEqual(
            TranslationClauseSegmenter.leftoverTail(
                "Today we trained the model. Then we applied it.",
                already: ["Today we trained the modal.", "Then we applied it."],
                languageID: "en"
            ),
            ""
        )
        XCTAssertTrue(
            TranslationClauseSegmenter.isAlreadyPrintedSource(
                "Today we trained the model.",
                already: ["Today we trained the modal.", "Then we applied it."],
                languageID: "en"
            )
        )
        XCTAssertEqual(
            TranslationClauseSegmenter.printableCommitUnit(
                "Today we trained the model. Then we applied it.",
                already: ["Today we trained the modal.", "Then we applied it."],
                languageID: "en",
                allowPauseFinalize: false
            ),
            nil
        )
    }

    /// lineCut / liveOpenText are commit-time helpers. Live display uses leftover.
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
        let jammedLive = TranslationClauseSegmenter.liveOpenText(
            "Today we trained the model.Then we applied it.And we shipped it to",
            languageID: "en"
        )
        XCTAssertTrue(jammedLive.hasPrefix("Today we trained"))
        XCTAssertFalse(jammedLive.hasSuffix("Today we trained the model."))
        XCTAssertEqual(
            TranslationClauseSegmenter.liveOpenText(spoken, languageID: "en").split(whereSeparator: { $0.isWhitespace }).count,
            LiveTranslationTiming.maxLineWords
        )
        let preview = TranslationClauseSegmenter.livePreview(
            "Today we trained the model.Then we applied it.And we shipped it to",
            languageID: "en"
        )
        XCTAssertFalse(preview.open.isEmpty)
        XCTAssertFalse(
            TranslationClauseSegmenter.hasUnreadSpeechAfterCompleted(
                "Today we trained the model. Then we applied it",
                languageID: "en"
            )
        )
        let longFirst = (1...12).map { "word\($0)" }.joined(separator: " ") + ". And more"
        XCTAssertTrue(
            TranslationClauseSegmenter.hasUnreadSpeechAfterCompleted(longFirst, languageID: "en")
        )
        XCTAssertFalse(
            TranslationClauseSegmenter.hasUnreadSpeechAfterCompleted(
                "Today we trained the model.",
                languageID: "en"
            )
        )
        let runOn = (1...20).map { "word\($0)" }.joined(separator: " ")
        let liveRunOn = TranslationClauseSegmenter.liveOpenText(runOn, languageID: "en")
        XCTAssertEqual(liveRunOn.split(separator: " ").count, LiveTranslationTiming.maxLineWords)
        XCTAssertTrue(liveRunOn.hasPrefix("word1 "))
        XCTAssertTrue(liveRunOn.hasSuffix("word12"))
        XCTAssertEqual(
            TranslationClauseSegmenter.decision(forTail: runOn, languageID: "en"),
            .commitNow
        )
        let lowercase = TranslationClauseSegmenter.split(
            "Today we trained the model.then we applied it.",
            languageID: "en"
        )
        XCTAssertEqual(lowercase.completed, ["Today we trained the model.", "then we applied it."])
        XCTAssertEqual(lowercase.tail, "")
    }

    func testGrowthUpdatesTheRowAndAFollowingSentenceStaysItsOwnLine() {
        var log = LectureCaptionLog()
        let first = log.commit(source: "Hello", translated: "안녕")
        XCTAssertEqual(first?.id, 1)
        XCTAssertTrue(
            TranslationClauseSegmenter.isInPlaceGrowth(
                previous: "Hello",
                incoming: "Hello world today"
            )
        )
        XCTAssertTrue(
            log.applyGrowth(
                id: 1,
                source: "Hello world today",
                translated: "안녕 세상 오늘"
            )
        )
        XCTAssertEqual(log.sourceLines, ["Hello world today"])
        XCTAssertEqual(log.translatedLines, ["안녕 세상 오늘"])
        XCTAssertEqual(log.lineIDs, [1])
        XCTAssertEqual(
            TheaterBoardAdmission.decide(
                "Hello world today",
                languageID: "en",
                phase: .propose,
                context: TheaterBoardAdmission.Context(peelSources: ["Hello"])
            ),
            .skip(.revisesNewest)
        )

        let following = "Hello world today. Next we measure it."
        let followingTail = TranslationClauseSegmenter.leftoverTail(
            following,
            already: ["Hello world today"],
            languageID: "en"
        )
        XCTAssertTrue(followingTail.contains("Next we measure it"))
        XCTAssertFalse(followingTail.contains("Hello world today"))
        XCTAssertEqual(
            TheaterBoardAdmission.decide(
                "Next we measure it.",
                languageID: "en",
                phase: .propose,
                context: TheaterBoardAdmission.Context(peelSources: ["Hello world today"])
            ),
            .admit
        )
        log.commit(source: "Next we measure it.", translated: "다음으로 측정합니다.")
        XCTAssertEqual(log.sourceLines, ["Hello world today", "Next we measure it."])
        XCTAssertEqual(log.lineIDs, [1, 2])

        let model = "Today we trained the model."
        let appliedTail = TranslationClauseSegmenter.leftoverTail(
            "Today we trained the model. Then we applied it.",
            already: [model],
            languageID: "en"
        )
        XCTAssertTrue(appliedTail.contains("Then we applied it"))
        XCTAssertFalse(appliedTail.hasPrefix("Today"))
        XCTAssertEqual(
            TheaterBoardAdmission.decide(
                "Then we applied it.",
                languageID: "en",
                phase: .publish,
                context: TheaterBoardAdmission.Context(
                    peelSources: [model],
                    commitIdentities: [TranslationClauseSegmenter.clauseIdentity("Then we applied it.")],
                    requiresTrackedIdentity: true
                )
            ),
            .admit
        )
    }

    func testTheaterCaptionFlowAppendsDownwardWithoutRewritingEarlierLines() {
        let first = TheaterCaptionFlow.lines(board: .make(translated: ["Hello."], ids: [1]))
        XCTAssertEqual(first.map(\.text), ["Hello."])
        XCTAssertEqual(first.map(\.isCurrent), [true])
        XCTAssertEqual(first.first?.id, "c-1")

        let second = TheaterCaptionFlow.lines(board: .make(
            translated: ["Hello.", "Next we measure it."],
            ids: [1, 2]
        ))
        XCTAssertEqual(second.map(\.text), ["Hello.", "Next we measure it."])
        XCTAssertEqual(second.first?.isCurrent, false)
        XCTAssertEqual(second.first?.id, "c-1")
        XCTAssertEqual(second.last?.id, "c-2")

        let withDraft = TheaterCaptionFlow.lines(board: .make(translated: ["Hello."], ids: [1]))
        XCTAssertEqual(withDraft.map(\.text), ["Hello."])
        XCTAssertEqual(withDraft.last?.id, "c-1")
        XCTAssertFalse(withDraft.contains { $0.isDraft })

        let liveSource = TheaterCaptionFlow.lines(board: .make(translated: ["Hello."], ids: [1]))
        XCTAssertEqual(liveSource.map(\.text), ["Hello."])
        XCTAssertEqual(liveSource.last?.id, "c-1")
        XCTAssertEqual(liveSource.last?.isDraft, false)

        let firstWords = TheaterCaptionFlow.lines(board: .make(translated: []))
        XCTAssertTrue(firstWords.isEmpty)

        let translatedLive = TheaterCaptionFlow.lines(board: .make(translated: ["Hello."], sources: ["안녕."], ids: [1]))
        XCTAssertEqual(translatedLive.last?.text, "Hello.")
        XCTAssertEqual(translatedLive.last?.source, "안녕.")
        XCTAssertEqual(translatedLive.last?.id, "c-1")
        XCTAssertFalse(translatedLive.contains { $0.isDraft })

        let committedKeepsLiveIdentity = TheaterCaptionFlow.lines(board: .make(translated: ["안녕."], sources: ["Hello we trained"], ids: [1]))
        XCTAssertEqual(committedKeepsLiveIdentity.last?.id, "c-1")
        XCTAssertEqual(committedKeepsLiveIdentity.last?.text, "안녕.")
        XCTAssertEqual(committedKeepsLiveIdentity.last?.source, "Hello we trained")
        XCTAssertEqual(committedKeepsLiveIdentity.last?.isCurrent, true)

        let nextLineHighlights = TheaterCaptionFlow.lines(board: .make(translated: ["안녕."], sources: ["Hello we trained"], ids: [1]))
        XCTAssertEqual(nextLineHighlights.map(\.id), ["c-1"])
        XCTAssertEqual(nextLineHighlights.last?.isCurrent, true)
        XCTAssertEqual(nextLineHighlights.last?.text, "안녕.")
        XCTAssertEqual(nextLineHighlights.last?.isDraft, false)

        let spokenLeads = TheaterCaptionFlow.lines(board: .make(translated: ["안녕."], sources: ["Hello we trained"], ids: [1]))
        XCTAssertEqual(spokenLeads.map(\.text), ["안녕."])
        XCTAssertEqual(spokenLeads.map(\.source), ["Hello we trained"])
        XCTAssertEqual(spokenLeads.map(\.id), ["c-1"])
        XCTAssertEqual(spokenLeads.last?.isDraft, false)

        let spokenThenTranslation = TheaterCaptionFlow.lines(board: .make(translated: ["안녕."], sources: ["Hello we trained"], ids: [1]))
        XCTAssertEqual(spokenThenTranslation.last?.text, "안녕.")
        XCTAssertEqual(spokenThenTranslation.last?.source, "Hello we trained")
        XCTAssertEqual(spokenThenTranslation.last?.id, "c-1")

        let reprinted = TheaterCaptionFlow.lines(board: .make(translated: ["I trained the model."], sources: ["저는 모델을 학습했습니다"], ids: [1]))
        XCTAssertEqual(reprinted.map(\.text), ["I trained the model."])
        XCTAssertEqual(reprinted.last?.isDraft, false)

        let restitch = TheaterCaptionFlow.lines(board: .make(translated: ["오늘 모델을 학습했습니다."], sources: ["Today we trained the model."], ids: [1]))
        XCTAssertEqual(restitch.map(\.text), ["오늘 모델을 학습했습니다."])
        XCTAssertEqual(restitch.last?.source, "Today we trained the model.")
        XCTAssertEqual(restitch.last?.isDraft, false)

        let many = (1...16).map { "Line \($0)." }
        let recent = TheaterCaptionFlow.lines(board: .make(translated: many, ids: Array(1...16).map(UInt64.init)))
        XCTAssertEqual(recent.count, many.count)
        XCTAssertEqual(recent.map(\.text), many)
        XCTAssertEqual(recent.first?.id, "c-1")
        XCTAssertEqual(recent.last?.id, "c-16")
        XCTAssertEqual(recent.last?.text, "Line 16.")

        func cue(
            translating: Bool = true,
            listening: Bool = true,
            paused: Bool = false,
            spoken: String = "Then we applied it.",
            last: String = "오늘 모델을 학습했습니다.",
            wait: Int? = nil
        ) -> TheaterPaceCue.Snapshot? {
            TheaterPaceCue.snapshot(
                isTranslating: translating,
                isListening: listening,
                isPaused: paused,
                liveSpoken: spoken,
                lastTranslation: last,
                pendingWaitMilliseconds: wait
            )
        }
        XCTAssertNil(cue(listening: false))
        XCTAssertNil(cue(translating: false))
        XCTAssertNil(cue(paused: true, wait: 4000))
        // Mid-sentence speech with nothing waiting is not "behind".
        XCTAssertEqual(cue()?.kind, .caughtUp)
        XCTAssertEqual(cue(wait: 800)?.kind, .caughtUp)
        XCTAssertEqual(cue(wait: 4200)?.kind, .behind)
        XCTAssertEqual(cue(wait: 4200)?.label, "Behind · 4s")
        XCTAssertEqual(cue(spoken: "")?.kind, .caughtUp)
        XCTAssertNil(cue(spoken: "", last: ""))

        let recentPlusLive = TheaterCaptionFlow.lines(board: .make(translated: many, ids: Array(1...16).map(UInt64.init)))
        XCTAssertEqual(recentPlusLive.count, many.count)
        XCTAssertEqual(recentPlusLive.first?.id, "c-1")
        XCTAssertEqual(recentPlusLive.last?.id, "c-16")
        XCTAssertEqual(recentPlusLive.last?.text, "Line 16.")
        XCTAssertFalse(recentPlusLive.contains { $0.text == "Line 17 lives here" })

        let hiddenSpoken = TheaterCaptionFlow.lines(board: .make(translated: ["안녕."], sources: ["Hello we trained"], ids: [1]))
        XCTAssertEqual(hiddenSpoken.map(\.id), ["c-1"])
        XCTAssertTrue(hiddenSpoken.allSatisfy { $0.source == "Hello we trained" || $0.text == "안녕." })
        XCTAssertFalse(hiddenSpoken.contains { $0.text == "And we shipped it" || $0.source == "And we shipped it" })

        let hiddenUntilTranslation = TheaterCaptionFlow.lines(board: .make(translated: ["안녕."], sources: ["Hello we trained"], ids: [1]))
        XCTAssertEqual(hiddenUntilTranslation.last?.text, "안녕.")
        XCTAssertEqual(hiddenUntilTranslation.last?.source, "Hello we trained")
        XCTAssertEqual(hiddenUntilTranslation.last?.id, "c-1")
        XCTAssertFalse(hiddenUntilTranslation.contains { $0.isDraft })

        let duplicateSpoken = TheaterCaptionFlow.lines(board: .make(translated: ["안녕."], sources: ["Hello we trained the model."], ids: [1]))
        XCTAssertEqual(duplicateSpoken.map(\.text), ["안녕."])
        XCTAssertEqual(duplicateSpoken.map(\.source), ["Hello we trained the model."])
        XCTAssertEqual(duplicateSpoken.map(\.id), ["c-1"])

        let duplicateDraft = TheaterCaptionFlow.lines(board: .make(translated: ["안녕."], sources: ["Hello we trained the model."], ids: [1]))
        XCTAssertEqual(duplicateDraft.count, 1)
        XCTAssertEqual(duplicateDraft.last?.text, "안녕.")
        XCTAssertEqual(duplicateDraft.last?.id, "c-1")

        let englishThenKoreanStaysOneRow = TheaterCaptionFlow.lines(board: .make(translated: ["오늘 모델을 학습했습니다."], sources: ["Today we trained the model."], ids: [1]))
        XCTAssertEqual(englishThenKoreanStaysOneRow.count, 1)
        XCTAssertEqual(englishThenKoreanStaysOneRow.last?.source, "Today we trained the model.")
        XCTAssertEqual(englishThenKoreanStaysOneRow.last?.text, "오늘 모델을 학습했습니다.")
        XCTAssertEqual(englishThenKoreanStaysOneRow.last?.id, "c-1")

        let open = TheaterCaptionFlow.lines(board: .make(translated: []))
        let afterCommit = TheaterCaptionFlow.lines(board: .make(translated: ["Hello we trained"], sources: ["Hello we trained"], ids: [1]))
        XCTAssertTrue(open.isEmpty)
        XCTAssertEqual(afterCommit.last?.id, "c-1")
        XCTAssertEqual(afterCommit.count, 1)

        let afterUndoNextID = TheaterCaptionFlow.lines(board: .make(translated: ["Hello."], ids: [1]))
        XCTAssertEqual(afterUndoNextID.last?.id, "c-1")
        XCTAssertEqual(afterUndoNextID.last?.text, "Hello.")
        XCTAssertFalse(afterUndoNextID.contains { $0.isDraft })

        let pinnedThenLive = TheaterCaptionFlow.lines(board: .make(translated: []))
        XCTAssertTrue(pinnedThenLive.isEmpty)
        let inFlightLive = TheaterCaptionFlow.lines(board: .make(translated: []))
        XCTAssertTrue(inFlightLive.isEmpty)
    }

    func testTheaterLinePrinterGrowsALineWithoutRewinding() throws {
        throw XCTSkip("retired typewriter / stable-text surface")
    }

    func testLineChangeDoesNotResetProgressOnPendingToCommittedHandoff() throws {
        throw XCTSkip("retired typewriter / stable-text surface")
    }

    func testLineChangeResetsProgressForAGenuinelyDifferentClause() throws {
        throw XCTSkip("retired typewriter / stable-text surface")
    }

    func testBilingualWrapStacksSpokenAboveTranslation() {
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
        XCTAssertFalse(rows[0].isSpoken)
        let spokenIndexes = rows.enumerated().compactMap { $0.element.isSpoken ? $0.offset : nil }
        let translatedIndexes = rows.enumerated().compactMap { $0.element.isSpoken ? nil : $0.offset }
        // Show-as stays on top. The spoken line keeps one block underneath it.
        XCTAssertEqual(translatedIndexes, Array(0..<translatedIndexes.count))
        XCTAssertEqual(spokenIndexes.first, translatedIndexes.count)
        let frames = TheaterBilingualWrap.lineFrames(
            rows: rows,
            spokenFont: font,
            translatedFont: font,
            width: 140
        )
        XCTAssertEqual(frames.count, rows.count)
        for index in frames.indices.dropFirst() {
            let gap = frames[index].minY - frames[index - 1].maxY
            let crossesPair = rows[index].isSpoken != rows[index - 1].isSpoken
            let expected = TheaterBilingualWrap.rowSpacing
                + (crossesPair ? TheaterBilingualWrap.spokenPairGap : 0)
            XCTAssertEqual(gap, expected)
        }
        XCTAssertEqual(
            TheaterBilingualWrap.boardHeight(rows: rows, spokenFont: font, translatedFont: font),
            (frames.last?.maxY ?? 0) + TheaterBilingualWrap.boardTopClearance
        )
    }

    func testBilingualWrapPutsSpokenKoreanAboveEnglishTitle() {
        let font = NSFont.systemFont(ofSize: 48, weight: .semibold)
        let rows = TheaterBilingualWrap.rows(
            spoken: "안녕하세요 여러분 오늘도 반갑습니다",
            translated: "Hello world today friends",
            font: font,
            width: 140
        )
        XCTAssertGreaterThanOrEqual(rows.count, 4)
        XCTAssertFalse(rows[0].isSpoken)
        XCTAssertTrue(rows.contains(where: \.isSpoken))
        XCTAssertEqual(rows.filter(\.isSpoken).map(\.text).joined(), "안녕하세요 여러분 오늘도 반갑습니다")
        XCTAssertEqual(rows.filter { !$0.isSpoken }.map(\.text).joined(), "Hello world today friends")
    }

    func testBilingualWrapPutsSpokenThaiAboveEnglishTitle() {
        let font = NSFont.systemFont(ofSize: 48, weight: .semibold)
        let rows = TheaterBilingualWrap.rows(
            spoken: "สวัสดีครับทุกคน วันนี้ก็ยินดีที่ได้พบกัน",
            translated: "Hello world today friends",
            font: font,
            width: 140
        )
        XCTAssertGreaterThanOrEqual(rows.count, 4)
        XCTAssertFalse(rows[0].isSpoken)
        XCTAssertTrue(rows.contains(where: \.isSpoken))
        XCTAssertEqual(rows.filter(\.isSpoken).map(\.text).joined(), "สวัสดีครับทุกคน วันนี้ก็ยินดีที่ได้พบกัน")
        XCTAssertEqual(rows.filter { !$0.isSpoken }.map(\.text).joined(), "Hello world today friends")
    }

    func testBilingualWrapPutsSpokenEnglishAboveThaiTitle() {
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
        XCTAssertFalse(rows[0].isSpoken)
        XCTAssertTrue(rows.contains(where: \.isSpoken))
        XCTAssertEqual(rows.filter(\.isSpoken).map(\.text).joined(), spoken)
        XCTAssertEqual(rows.filter { !$0.isSpoken }.map(\.text).joined(), translated)
    }

    func testBilingualWrapRevealsSpokenAndTranslatedIndependently() {
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
        XCTAssertGreaterThan(template.filter(\.isSpoken).count, 1)

        let firstSpoken = template.first { $0.isSpoken }?.text ?? ""
        let firstKorean = template.first { !$0.isSpoken }?.text ?? ""
        XCTAssertGreaterThan(firstKorean.count, 1)
        let partialKorean = String(firstKorean.dropLast())

        let whileTyping = TheaterBilingualWrap.revealedRows(
            spoken: spoken,
            translated: translated,
            printedSpoken: firstSpoken,
            printedTranslated: partialKorean,
            font: font,
            width: 140
        )
        XCTAssertEqual(whileTyping.filter(\.isSpoken).map(\.text).joined(), firstSpoken)
        XCTAssertEqual(whileTyping.filter(\.isSpoken).count, 1)
        XCTAssertEqual(whileTyping.filter { !$0.isSpoken }.map(\.text).joined(), partialKorean)

        let englishAhead = TheaterBilingualWrap.revealedRows(
            spoken: spoken,
            translated: translated,
            printedSpoken: spoken,
            printedTranslated: partialKorean,
            font: font,
            width: 140
        )
        XCTAssertEqual(englishAhead.filter(\.isSpoken).count, template.filter(\.isSpoken).count)
        XCTAssertEqual(englishAhead.filter { !$0.isSpoken }.map(\.text).joined(), partialKorean)

        let finished = TheaterBilingualWrap.revealedRows(
            spoken: spoken,
            translated: translated,
            printedSpoken: spoken,
            printedTranslated: translated,
            font: font,
            width: 140
        )
        XCTAssertEqual(finished, template)
        XCTAssertLessThanOrEqual(
            whileTyping.filter { !$0.isSpoken }.count,
            template.filter { !$0.isSpoken }.count
        )
        XCTAssertEqual(englishAhead.filter(\.isSpoken).count, template.filter(\.isSpoken).count)
    }

    func testBilingualWrapOmitsUnrevealedTitleRowsSoHeightGrowsWithPrint() {
        let font = NSFont.systemFont(ofSize: 48, weight: .semibold)
        let spoken = "Hello world today friends"
        let translated = "안녕하세요 여러분 오늘도"
        let template = TheaterBilingualWrap.rows(
            spoken: spoken,
            translated: translated,
            font: font,
            width: 140
        )
        XCTAssertGreaterThan(template.filter(\.isSpoken).count, 1)
        XCTAssertGreaterThan(template.filter { !$0.isSpoken }.count, 1)

        let firstSpoken = template.first { $0.isSpoken }?.text ?? ""
        let reserved = TheaterBilingualWrap.revealedRows(
            spoken: spoken,
            translated: translated,
            printedSpoken: firstSpoken,
            printedTranslated: "",
            font: font,
            width: 140
        )
        XCTAssertEqual(reserved.filter(\.isSpoken).map(\.text).joined(), firstSpoken)
        XCTAssertEqual(reserved.filter(\.isSpoken).count, 1)
        XCTAssertTrue(reserved.filter { !$0.isSpoken }.isEmpty)
        XCTAssertLessThan(
            TheaterBilingualWrap.boardHeight(rows: reserved, spokenFont: font, translatedFont: font),
            TheaterBilingualWrap.boardHeight(rows: template, spokenFont: font, translatedFont: font)
        )
    }

    func testBilingualWrapKeepsAnEarlierLineWhenTheSentenceGrows() {
        let font = NSFont.systemFont(ofSize: 32, weight: .semibold)
        let width: CGFloat = 220
        let first = TheaterBilingualWrap.visualLines("Hello there friends", font: font, width: width)
        let grown = TheaterBilingualWrap.visualLines(
            "Hello there friends today we trained the model together",
            font: font,
            width: width
        )
        XCTAssertFalse(first.isEmpty)
        XCTAssertGreaterThanOrEqual(grown.count, first.count)
        XCTAssertTrue(grown[0].hasPrefix(first[0]))
    }

    func testBilingualWrapKeepsAFittingPhraseOnOneLine() {
        let font = NSFont.systemFont(ofSize: 32, weight: .semibold)
        let lines = TheaterBilingualWrap.visualLines("Hello there", font: font, width: 2000)
        XCTAssertEqual(lines, ["Hello there"])
    }

    func testBilingualWrapFillsTheBoardInsteadOfWrappingEarly() {
        let font = NSFont.systemFont(ofSize: 32, weight: .semibold)
        let text = "Hello there friends"
        var lo: CGFloat = 80
        var hi: CGFloat = 900
        while hi - lo > 1 {
            let mid = floor((lo + hi) / 2)
            if TheaterBilingualWrap.visualLines(text, font: font, width: mid).count == 1 {
                hi = mid
            } else {
                lo = mid
            }
        }
        XCTAssertEqual(TheaterBilingualWrap.visualLines(text, font: font, width: hi + 6), [text])
        XCTAssertGreaterThan(TheaterBilingualWrap.visualLines(text, font: font, width: max(lo - 2, 80)).count, 1)
    }

    func testBoardHeightGrowsWhenTheTitleWraps() {
        let font = NSFont.systemFont(ofSize: 32, weight: .semibold)
        let spoken = NSFont.systemFont(ofSize: 24, weight: .semibold)
        let text = "Hello there friends today"
        var lo: CGFloat = 80
        var hi: CGFloat = 900
        while hi - lo > 1 {
            let mid = floor((lo + hi) / 2)
            if TheaterBilingualWrap.visualLines(text, font: font, width: mid).count > 1 {
                lo = mid
            } else {
                hi = mid
            }
        }
        let width = max(lo, 80)
        let wrapped = TheaterBilingualWrap.visualLines(text, font: font, width: width)
        XCTAssertGreaterThan(wrapped.count, 1)
        XCTAssertTrue(TheaterBilingualWrap.lastLineIsNearlyFull(wrapped[0], font: font, width: width))
        let before = TheaterBilingualWrap.rows(
            spoken: "",
            translated: wrapped[0],
            spokenFont: spoken,
            translatedFont: font,
            width: width
        )
        let after = TheaterBilingualWrap.rows(
            spoken: "",
            translated: text,
            spokenFont: spoken,
            translatedFont: font,
            width: width
        )
        XCTAssertEqual(before.filter { !$0.isSpoken }.count, 1)
        XCTAssertGreaterThan(after.filter { !$0.isSpoken }.count, 1)
        XCTAssertGreaterThan(
            TheaterBilingualWrap.boardHeight(rows: after, spokenFont: spoken, translatedFont: font),
            TheaterBilingualWrap.boardHeight(rows: before, spokenFont: spoken, translatedFont: font)
        )
    }

    func testReservedSlotDoesNotMoveANearlyFullTitleLine() {
        let font = NSFont.systemFont(ofSize: 32, weight: .semibold)
        let spoken = NSFont.systemFont(ofSize: 24, weight: .semibold)
        let text = "Hello there friends today"
        var lo: CGFloat = 80
        var hi: CGFloat = 900
        while hi - lo > 1 {
            let mid = floor((lo + hi) / 2)
            if TheaterBilingualWrap.visualLines(text, font: font, width: mid).count > 1 {
                lo = mid
            } else {
                hi = mid
            }
        }
        let width = max(lo, 80)
        let title = TheaterBilingualWrap.visualLines(text, font: font, width: width)[0]
        XCTAssertTrue(TheaterBilingualWrap.lastLineIsNearlyFull(title, font: font, width: width))
        let rows = TheaterBilingualWrap.rows(
            spoken: "",
            translated: title,
            spokenFont: spoken,
            translatedFont: font,
            width: width
        )
        let tight = TheaterBilingualWrap.placedFrames(
            rows: rows,
            spokenFont: spoken,
            translatedFont: font,
            width: width,
            reserveGrowth: false
        )
        let reserved = TheaterBilingualWrap.placedFrames(
            rows: rows,
            spokenFont: spoken,
            translatedFont: font,
            width: width,
            reserveGrowth: true
        )
        XCTAssertGreaterThan(reserved.height, tight.height)
        XCTAssertEqual(reserved.frames.first?.minY ?? -1, tight.frames.first?.minY ?? -2, accuracy: 0.5)
        XCTAssertGreaterThan(
            TheaterBilingualWrap.reservedDisplayHeight(
                rows: rows,
                spokenFont: spoken,
                translatedFont: font,
                width: width
            ),
            TheaterBilingualWrap.displayHeight(
                rows: rows,
                spokenFont: spoken,
                translatedFont: font
            )
        )
    }

    func testBilingualWrapKeepsTrailingPunctuationOnTheSameToken() {
        let font = NSFont.systemFont(ofSize: 32, weight: .semibold)
        let lines = TheaterBilingualWrap.visualLines("Hello, there.", font: font, width: 2000)
        XCTAssertEqual(lines, ["Hello, there."])
        let tight = TheaterBilingualWrap.visualLines("안녕하세요.", font: font, width: 80)
        XCTAssertFalse(tight.contains("."))
        XCTAssertTrue(tight.contains { $0.contains("요.") || $0.hasSuffix(".") })
    }

    func testLayoutWrapWidthIgnoresTheFirstFrameUntilTheBoardIsReal() {
        XCTAssertNil(TheaterBilingualWrap.layoutWrapWidth(proposed: 1, locked: 0))
        XCTAssertNil(TheaterBilingualWrap.layoutWrapWidth(proposed: 40, locked: 0))
        XCTAssertEqual(TheaterBilingualWrap.layoutWrapWidth(proposed: 40, locked: 800), 800)
        XCTAssertEqual(TheaterBilingualWrap.layoutWrapWidth(proposed: 900, locked: 0), 900)
    }

    func testBoardScrollPinsBottomOnlyWhenTheBoardOverflows() {
        XCTAssertFalse(TheaterBoardScroll.pinsToBottom(boardHeight: 200, viewportHeight: 400))
        XCTAssertTrue(TheaterBoardScroll.pinsToBottom(boardHeight: 400, viewportHeight: 400))
        XCTAssertTrue(TheaterBoardScroll.showsOpeningOfLine(lineHeight: 420, viewportHeight: 400))
        XCTAssertFalse(TheaterBoardScroll.showsOpeningOfLine(lineHeight: 180, viewportHeight: 400))
        XCTAssertFalse(TheaterBoardScroll.shouldFollowReveal(from: 120, to: 80))
        XCTAssertFalse(TheaterBoardScroll.shouldFollowReveal(from: 120, to: 120))
        XCTAssertTrue(TheaterBoardScroll.shouldFollowReveal(from: 120, to: 180))
    }

    func testOpeningBoardHeightClearsOneTitleLine() {
        let font = NSFont.systemFont(ofSize: 48, weight: .semibold)
        XCTAssertGreaterThanOrEqual(
            TheaterBilingualWrap.openingBoardHeight(font: font),
            TheaterBilingualWrap.lineHeight(for: font)
        )
    }

    func testDisplayHeightKeepsAnEmptyFirstPaintAtOneTitleLine() {
        let spoken = NSFont.systemFont(ofSize: 32, weight: .semibold)
        let translated = NSFont.systemFont(ofSize: 48, weight: .semibold)
        XCTAssertEqual(
            TheaterBilingualWrap.displayHeight(
                rows: [],
                spokenFont: spoken,
                translatedFont: translated
            ),
            TheaterBilingualWrap.openingBoardHeight(font: translated)
        )
        let spokenOnly = TheaterBilingualWrap.rows(
            spoken: "Hello there",
            translated: "",
            spokenFont: spoken,
            translatedFont: translated,
            width: 800
        )
        // Once real rows exist, displayHeight reports their actual height
        // rather than also reserving room for a full translated-size line
        // that is not on screen (see the doc comment on displayHeight).
        XCTAssertEqual(
            TheaterBilingualWrap.displayHeight(
                rows: spokenOnly,
                spokenFont: spoken,
                translatedFont: translated
            ),
            TheaterBilingualWrap.boardHeight(
                rows: spokenOnly,
                spokenFont: spoken,
                translatedFont: translated
            )
        )
    }

    func testResolvedWrapWidthRewrapsWhenTheBoardGetsNarrower() {
        XCTAssertEqual(
            TheaterBilingualWrap.resolvedWrapWidth(proposed: 800, locked: 823),
            800
        )
        XCTAssertEqual(
            TheaterBilingualWrap.resolvedWrapWidth(proposed: 812, locked: 800),
            800
        )
    }

    func testCaptionInkStaysAtTheTopOfTheLineSlot() {
        let font = NSFont.systemFont(ofSize: 48, weight: .semibold)
        let cell = TheaterCaptionInkCell(textCell: "Hello there")
        cell.font = font
        cell.isBordered = false
        cell.isBezeled = false
        cell.usesSingleLineMode = true
        let bounds = NSRect(
            x: 0,
            y: 0,
            width: 800,
            height: TheaterBilingualWrap.lineHeight(for: font)
        )
        let title = cell.titleRect(forBounds: bounds)
        XCTAssertEqual(title.minY, bounds.minY + TheaterBilingualWrap.lineTopSlack, accuracy: 0.5)
        XCTAssertLessThanOrEqual(title.height, bounds.height + 0.5)
        let ink = TheaterBilingualWrap.fieldInkWidth(800, font: font)
        XCTAssertGreaterThan(ink, 600)
        XCTAssertLessThanOrEqual(ink, 800)
        let text = "Today we trained the model then we applied it together now"
        let lines = TheaterBilingualWrap.visualLines(text, font: font, width: 420)
        XCTAssertGreaterThan(lines.count, 1)
        XCTAssertEqual(lines.joined().filter { !$0.isWhitespace }, text.filter { !$0.isWhitespace })
    }

    func testCaptionLineHeightClearsTheFontInk() {
        let font = NSFont.systemFont(ofSize: 48, weight: .semibold)
        XCTAssertGreaterThanOrEqual(
            TheaterBilingualWrap.lineHeight(for: font),
            ceil(font.boundingRectForFont.height)
        )
    }

    func testTranslatedCaptionIsLargerThanTheSpokenLine() {
        let spoken = TheaterCaptionScale.spokenSize(setting: 42)
        let translated = TheaterCaptionScale.translatedSize(setting: 42)
        XCTAssertEqual(spoken, 42 * TheaterCaptionScale.spokenMultiplier)
        XCTAssertGreaterThan(translated, spoken)
        XCTAssertEqual(translated, 42 * TheaterCaptionScale.translatedMultiplier)

        let spokenFont = NSFont.systemFont(ofSize: spoken, weight: .semibold)
        let translatedFont = NSFont.systemFont(ofSize: translated, weight: .semibold)
        let rows = TheaterBilingualWrap.rows(
            spoken: "Hello there",
            translated: "안녕하세요",
            spokenFont: spokenFont,
            translatedFont: translatedFont,
            width: 800
        )
        let mixed = TheaterBilingualWrap.boardHeight(
            rows: rows,
            spokenFont: spokenFont,
            translatedFont: translatedFont
        )
        let sameSize = TheaterBilingualWrap.boardHeight(
            rows: rows,
            spokenFont: spokenFont,
            translatedFont: spokenFont
        )
        XCTAssertGreaterThan(mixed, sameSize)
    }

    func testTheaterWindowFillsTheVisibleScreenInsteadOfTheLegacyStrip() {
        let visible = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(
            TheaterWindowPlacement.resolvedFrame(stored: nil, visible: visible),
            visible
        )
        XCTAssertTrue(
            TheaterWindowPlacement.shouldFillScreen(
                stored: CGRect(x: 80, y: 80, width: 1100, height: 440),
                visible: visible
            )
        )
        XCTAssertEqual(
            TheaterWindowPlacement.resolvedFrame(
                stored: CGRect(x: 80, y: 80, width: 1100, height: 440),
                visible: visible
            ),
            visible
        )
        let custom = CGRect(x: 100, y: 80, width: 1600, height: 900)
        XCTAssertFalse(TheaterWindowPlacement.shouldFillScreen(stored: custom, visible: visible))
        XCTAssertEqual(
            TheaterWindowPlacement.resolvedFrame(stored: custom, visible: visible),
            visible
        )
        XCTAssertEqual(
            TheaterWindowPlacement.resolvedPopupFrame(
                stored: custom,
                visible: visible,
                preset: .lowerThird
            ),
            TheaterPositionPreset.lowerThird.frame(in: visible)
        )
        let hanging = CGRect(x: -80, y: -40, width: 900, height: 400)
        let fitted = TheaterWindowPlacement.resolvedPopupFrame(
            stored: hanging,
            visible: visible,
            keepUserSize: true
        )
        XCTAssertTrue(visible.contains(fitted))
        XCTAssertEqual(fitted.size, hanging.size)
        XCTAssertEqual(
            TheaterCaptionScale.displaySize(setting: 42, stageWidth: 1100),
            42
        )
        XCTAssertGreaterThan(
            TheaterCaptionScale.displaySize(setting: 42, stageWidth: 1920),
            42
        )
    }

    func testBilingualWrapDoesNotInventGlyphLinesBeforeLayout() {
        let font = NSFont.systemFont(ofSize: 48, weight: .semibold)
        let rows = TheaterBilingualWrap.rows(
            spoken: "Hello world today friends",
            translated: "안녕하세요 여러분",
            font: font,
            width: 8
        )
        XCTAssertEqual(rows.map(\.text), ["안녕하세요 여러분", "Hello world today friends"])
        XCTAssertEqual(rows.map(\.isSpoken), [false, true])
    }

    func testTheaterCaptionFlowKeepsPendingClausesOffTheBoard() {
        let lines = TheaterCaptionFlow.lines(board: .make(translated: ["Hello."], sources: ["안녕."], ids: [1]))
        XCTAssertEqual(lines.map(\.id), ["c-1"])
        XCTAssertEqual(lines.map(\.text), ["Hello."])
        XCTAssertEqual(lines.map(\.source), ["안녕."])
        XCTAssertEqual(lines.first?.isDraft, false)
        XCTAssertFalse(lines.contains { $0.text == "Today we trained the model." || $0.text == "And we shipped it" })
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

    func testTheaterPresentationStyleDefaultsToPopup() {
        XCTAssertEqual(TheaterPresentationStyle.resolved(nil), .popup)
        XCTAssertEqual(TheaterPresentationStyle.resolved(""), .popup)
        XCTAssertEqual(TheaterPresentationStyle.resolved("transparent"), .transparent)
        XCTAssertEqual(TheaterPresentationStyle.popup.toggled, .transparent)
        XCTAssertEqual(TheaterPresentationStyle.transparent.displayName, "Overlay")
        XCTAssertEqual(TheaterPresentationStyle.popup.displayName, "Pop-up")
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
    func testTranslationPriorsStayInsideThisListen() {
        let subscriber = LiveTranslationSubscriber()
        subscriber.seedCommittedForTesting(source: "Yesterday we trained the model.", translated: "어제 모델을 학습했습니다.")
        subscriber.seedCommittedForTesting(source: "It was a long day.", translated: "긴 하루였습니다.")
        subscriber.beginListening()
        let first = subscriber.priorClausesForTesting(incoming: "Today we measure it.")
        XCTAssertTrue(first.sources.isEmpty)
        XCTAssertTrue(first.translations.isEmpty)

        subscriber.seedCommittedForTesting(source: "Today we measure it.", translated: "오늘은 측정합니다.")
        let second = subscriber.priorClausesForTesting(incoming: "Then we stop.")
        XCTAssertEqual(second.sources, ["Today we measure it."])
        XCTAssertEqual(second.translations, ["오늘은 측정합니다."])
        XCTAssertFalse(second.sources.contains(where: { $0.contains("Yesterday") }))
    }

    @MainActor
    func testLanguageChangeClearsListenHistoryPriors() {
        let subscriber = LiveTranslationSubscriber()
        subscriber.beginListening()
        subscriber.seedCommittedForTesting(source: "Today we measure it.", translated: "오늘은 측정합니다.")
        XCTAssertEqual(
            subscriber.priorClausesForTesting(incoming: "Then we stop.").sources,
            ["Today we measure it."]
        )
        subscriber.noteLanguagePairChanged()
        XCTAssertTrue(subscriber.priorClausesForTesting(incoming: "Then we stop.").sources.isEmpty)
        XCTAssertEqual(subscriber.listenHistoryCountForTesting, 0)
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
    func testUndoLastCaptionKeepsEarlierLines() {
        let subscriber = LiveTranslationSubscriber()
        subscriber.seedCommittedForTesting(source: "Hello.", translated: "안녕.")
        subscriber.seedCommittedForTesting(source: "Next.", translated: "다음.")
        XCTAssertEqual(subscriber.committedLines, ["안녕.", "다음."])
        subscriber.removeLastCommittedLine()
        XCTAssertEqual(subscriber.committedLines, ["안녕."])
        XCTAssertEqual(subscriber.deliveryDocument(), "안녕.")
        subscriber.removeLastCommittedLine()
        XCTAssertTrue(subscriber.committedLines.isEmpty)
        XCTAssertTrue(subscriber.deliveryDocument().isEmpty)
    }

    @MainActor
    func testClearBoardWipesTheSnapshotAndKeepsListen() {
        let controller = LiveTranslationController.shared
        let savedSnapshot = SettingsStore.shared.theaterBoardSnapshot
        let archiveURL = AppSupportDirectory.url().appendingPathComponent("TheaterSession.jsonl")
        let archiveBackup = FileManager.default.temporaryDirectory
            .appendingPathComponent("theater-clear-backup-\(UUID().uuidString).jsonl")
        let hadArchive = FileManager.default.fileExists(atPath: archiveURL.path)
        if hadArchive {
            try? FileManager.default.copyItem(at: archiveURL, to: archiveBackup)
        }
        defer {
            controller.cancelSession()
            controller.subscriber.reset()
            SettingsStore.shared.theaterBoardSnapshot = savedSnapshot
            try? FileManager.default.removeItem(at: archiveURL)
            if hadArchive {
                try? FileManager.default.copyItem(at: archiveBackup, to: archiveURL)
            }
            try? FileManager.default.removeItem(at: archiveBackup)
        }
        controller.cancelSession()
        controller.subscriber.reset()
        SettingsStore.shared.theaterBoardSnapshot = nil
        controller.beginSession(kind: .captions)
        controller.subscriber.seedCommittedForTesting(source: "Hello.", translated: "안녕.")
        controller.persistBoard()
        XCTAssertEqual(controller.subscriber.committedLines, ["안녕."])
        XCTAssertNotNil(SettingsStore.shared.theaterBoardSnapshot)
        XCTAssertTrue(controller.hasClearableBoard)

        controller.clearBoard()
        XCTAssertTrue(controller.isSessionActive)
        XCTAssertTrue(controller.subscriber.committedLines.isEmpty)
        XCTAssertTrue(controller.subscriber.deliveryDocument().isEmpty)
        XCTAssertNil(SettingsStore.shared.theaterBoardSnapshot)
        XCTAssertFalse(controller.hasClearableBoard)
    }

    @MainActor
    func testNewCaptionListenStartsWithAFreshBoard() {
        let controller = LiveTranslationController.shared
        let savedSnapshot = SettingsStore.shared.theaterBoardSnapshot
        defer {
            controller.cancelSession()
            controller.subscriber.reset()
            SettingsStore.shared.theaterBoardSnapshot = savedSnapshot
        }
        controller.cancelSession()
        controller.subscriber.reset()
        controller.subscriber.seedCommittedForTesting(source: "Yesterday.", translated: "어제.")
        controller.persistBoard()
        XCTAssertEqual(controller.subscriber.committedLines, ["어제."])
        XCTAssertNotNil(SettingsStore.shared.theaterBoardSnapshot)

        controller.beginSession(kind: .captions)
        XCTAssertTrue(controller.subscriber.committedLines.isEmpty)
        XCTAssertTrue(controller.subscriber.deliveryDocument().isEmpty)
        XCTAssertNil(SettingsStore.shared.theaterBoardSnapshot)
        controller.cancelSession()
    }

    @MainActor
    func testLaunchDiscardsAPersistedTheaterBoard() {
        let controller = LiveTranslationController.shared
        let savedSnapshot = SettingsStore.shared.theaterBoardSnapshot
        defer {
            controller.cancelSession()
            controller.subscriber.reset()
            SettingsStore.shared.theaterBoardSnapshot = savedSnapshot
        }
        controller.cancelSession()
        controller.subscriber.reset()
        controller.subscriber.seedCommittedForTesting(source: "Crash leftover.", translated: "남은 자막.")
        controller.persistBoard()
        XCTAssertNotNil(SettingsStore.shared.theaterBoardSnapshot)

        controller.startFreshTheaterBoard()
        XCTAssertTrue(controller.subscriber.committedLines.isEmpty)
        XCTAssertTrue(controller.subscriber.deliveryDocument().isEmpty)
        XCTAssertNil(SettingsStore.shared.theaterBoardSnapshot)
        controller.restoreBoardIfNeeded()
        XCTAssertTrue(controller.subscriber.committedLines.isEmpty)
    }

    func testCaptionLogKeepsALongLecture() {
        var log = LectureCaptionLog()
        let cap = LiveTranslationTiming.maxCommittedLines
        for index in 1...cap {
            log.commit(source: "line \(index)", translated: "caption \(index)")
        }
        XCTAssertEqual(log.translatedLines.count, cap)
        XCTAssertEqual(log.translatedLines.first, "caption 1")
        XCTAssertEqual(log.lineIDs.first, 1)
        XCTAssertEqual(log.lineIDs.last, UInt64(cap))
        XCTAssertEqual(LiveTranslationTiming.maxCommittedLines, LiveTranslationTiming.visibleTheaterLines)
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

    func testThinStartersDoNotPrintAndLongRunOnsFollowAlong() throws {
        throw XCTSkip("retired typewriter / stable-text surface")
    }

    @MainActor
    func testNewListenCanRepeatTheLastGreeting() {
        let subscriber = LiveTranslationSubscriber()
        subscriber.seedCommittedForTesting(source: "Hello everyone.", translated: "안녕하세요.")
        subscriber.beginListening()
        subscriber.handlePartial("Hello everyone.")
        XCTAssertEqual(subscriber.sourceDraft, "Hello everyone.")
    }

    func testBreathCutAndNewListenDoNotRewriteTheBoard() {
        let andRun = "Today we trained the model and then we applied it to production data today"
        let andCut = TranslationClauseSegmenter.nextCommitUnit(
            andRun,
            languageID: "en",
            allowPauseFinalize: false
        )
        XCTAssertEqual(andCut?.unit, "Today we trained the model")
        XCTAssertTrue(andCut?.rest.hasPrefix("and") ?? false)

        let butRun = "Today we trained the model but then we applied it to production data today"
        let butCut = TranslationClauseSegmenter.nextCommitUnit(
            butRun,
            languageID: "en",
            allowPauseFinalize: false
        )
        XCTAssertEqual(butCut?.unit, "Today we trained the model")
        XCTAssertTrue(butCut?.rest.hasPrefix("but") ?? false)

        let soRun = "Today we trained the model so then we applied it to production data today"
        let soCut = TranslationClauseSegmenter.nextCommitUnit(
            soRun,
            languageID: "en",
            allowPauseFinalize: false
        )
        XCTAssertEqual(soCut?.unit, "Today we trained the model")
        XCTAssertTrue(soCut?.rest.hasPrefix("so") ?? false)

        var isolated = LectureCaptionLog()
        isolated.commit(source: "Hello everyone.", translated: "안녕하세요.")
        XCTAssertNotNil(
            isolated.commit(
                source: "Hello everyone today.",
                translated: "안녕하세요 여러분."
            )
        )
        XCTAssertEqual(isolated.sourceLines, ["Hello everyone.", "Hello everyone today."])

        var sameListen = LectureCaptionLog()
        let hello = sameListen.commit(source: "Hello", translated: "안녕")
        XCTAssertEqual(hello?.id, 1)
        XCTAssertTrue(
            sameListen.applyGrowth(id: 1, source: "Hello world today", translated: "안녕 세상 오늘")
        )
        XCTAssertEqual(sameListen.sourceLines, ["Hello world today"])
        XCTAssertEqual(sameListen.lineIDs, [1])
    }

    func testLectureTimingWaitsForANaturalPause() {
        XCTAssertEqual(
            Double(LiveTranslationTiming.openSettleNanoseconds(languageID: "en")) / 1_000_000_000,
            1.2,
            accuracy: 0.01
        )
        XCTAssertEqual(
            Double(LiveTranslationTiming.completeSettleNanoseconds(languageID: "en")) / 1_000_000_000,
            0.5,
            accuracy: 0.01
        )
        XCTAssertEqual(
            Double(LiveTranslationTiming.openSettleNanoseconds(languageID: "ko")) / 1_000_000_000,
            2.0,
            accuracy: 0.01
        )
        XCTAssertEqual(
            Double(LiveTranslationTiming.openSettleNanoseconds(languageID: "th")) / 1_000_000_000,
            1.5,
            accuracy: 0.01
        )
        XCTAssertEqual(
            TranslationClauseSegmenter.settleNanoseconds(
                unreadCount: 0,
                tail: "Then we applied it today",
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
        XCTAssertEqual(LiveTranslationTiming.visibleTheaterLines, 48)
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
        XCTAssertFalse(TranslationClauseSegmenter.isCaptionReadyConnective("그건 그렇거든요", languageID: "ko"))
        XCTAssertFalse(TranslationClauseSegmenter.looksComplete("제가 할게요", languageID: "ko"))
        XCTAssertTrue(
            TranslationClauseSegmenter.looksComplete("이번 분기 매출은 목표를 크게 넘겼거든요", languageID: "ko")
        )
        XCTAssertTrue(
            TranslationClauseSegmenter.isCaptionReadyConnective(
                "今日の講義ではそのモデルを学習したので",
                languageID: "ja"
            )
        )
        XCTAssertEqual(LiveTranslationTiming.completeSettleNanoseconds(languageID: "ko"), 1_000_000_000)
        XCTAssertEqual(LiveTranslationTiming.completeSettleNanoseconds(languageID: "ja"), 1_000_000_000)
        XCTAssertEqual(LiveTranslationTiming.openSettleNanoseconds(languageID: "ko"), 2_000_000_000)
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
        XCTAssertTrue(LiveTranslationConfirm.requiresConfirmBeforePrint(languageID: "ja"))
        XCTAssertTrue(LiveTranslationConfirm.requiresConfirmBeforePrint(languageID: "th"))
        XCTAssertFalse(LiveTranslationConfirm.requiresConfirmBeforePrint(languageID: "en"))
        XCTAssertFalse(LiveTranslationConfirm.shouldReDecode(isFinal: false, languageID: "ko"))
        XCTAssertFalse(LiveTranslationConfirm.shouldReDecode(isFinal: false, languageID: "en"))
        XCTAssertTrue(LiveTranslationConfirm.shouldReDecode(isFinal: false, isPause: true, languageID: "ko"))
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

        let previous = "Today we trained the modal."
        let corrected = "Today we trained the model."
        XCTAssertFalse(
            TranslationClauseSegmenter.isInPlaceGrowth(previous: previous, incoming: corrected)
        )
        let spelling = TheaterBoardAdmission.Context(
            peelSources: [previous],
            commitIdentities: [TranslationClauseSegmenter.clauseIdentity(corrected)],
            latestHypothesis: corrected
        )
        for phase in [TheaterBoardAdmission.Phase.propose, .publish] {
            var context = spelling
            context.requiresTrackedIdentity = phase == .publish
            XCTAssertEqual(
                TheaterBoardAdmission.decide(corrected, languageID: "en", phase: phase, context: context),
                .skip(.revisesNewest),
                "\(phase)"
            )
        }
    }

    func testLeftoverTailDropsALongOffscreenPrefixWithoutReprinting() {
        let hidden = (1...40).map { "This is committed sentence number \($0) of the talk." }
        let printed = (41...43).map { "This is committed sentence number \($0) of the talk." }
        let tail = "And this is the open tail we are speaking now"
        let transcript = (hidden + printed).joined(separator: " ") + " " + tail
        XCTAssertEqual(
            TranslationClauseSegmenter.leftoverTail(
                transcript,
                already: hidden + printed,
                languageID: "en"
            ),
            tail
        )
    }

    func testLeftoverTailDropsOffscreenPrefixOfACumulativeTalk() {
        let hidden = (1...12).map { "This is committed sentence number \($0) of the talk." }
        let printed = (13...24).map { "This is committed sentence number \($0) of the talk." }
        let tail = "And this is the open tail we are speaking now"
        let transcript = (hidden + printed).joined(separator: " ") + " " + tail
        XCTAssertEqual(
            TranslationClauseSegmenter.leftoverTail(
                transcript,
                already: printed,
                languageID: "en"
            ),
            tail
        )
    }

    /// Theater peels printed clauses off the cumulative transcript on every ASR
    /// tick (200 ms on Parakeet). Rescanning the transcript once per committed
    /// line cost 216 ms on a full board, which froze the live line on long talks.
    func testPeelStaysAffordableOnAFullBoard() {
        let already = (1...LiveTranslationTiming.peelWindowLines)
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

    /// A 200-clause cumulative string must peel to the newest unread sentence in
    /// roughly linear time in the leftover — not a per-clause rescan of the talk.
    func testPeelStaysLinearOnA200ClauseTalk() {
        let sentences = (0..<200).map { index in
            "Point \(index) is that the model improves everything we measured."
        }
        let already = Array(sentences.dropLast())
        let newest = sentences.last!
        let transcript = sentences.joined(separator: " ")

        let started = ProcessInfo.processInfo.systemUptime
        let leftover = TranslationClauseSegmenter.leftoverTail(
            transcript,
            already: already,
            languageID: "en"
        )
        let elapsed = ProcessInfo.processInfo.systemUptime - started

        XCTAssertEqual(leftover, newest)
        XCTAssertLessThan(
            elapsed,
            0.5,
            "Peeling 199 printed clauses took \(elapsed)s; expected under 0.5s."
        )
    }

    /// Same peel with only the sliding peel window: older clauses are offscreen
    /// but still sit in the cumulative string ahead of the window.
    func testPeelWindowStaysLinearOnA200ClauseTalk() {
        let sentences = (0..<200).map { index in
            "Point \(index) is that the model improves everything we measured."
        }
        let already = Array(sentences.dropLast().suffix(LiveTranslationTiming.peelWindowLines))
        let newest = sentences.last!
        let transcript = sentences.joined(separator: " ")

        let started = ProcessInfo.processInfo.systemUptime
        let leftover = TranslationClauseSegmenter.leftoverTail(
            transcript,
            already: already,
            languageID: "en"
        )
        let elapsed = ProcessInfo.processInfo.systemUptime - started

        XCTAssertEqual(leftover, newest)
        XCTAssertLessThan(elapsed, 0.5, "Peel-window peel took \(elapsed)s")
    }

    /// Bound live transcripts + peel window must keep the newest unread Point
    /// sentence. Similar endings must not over-peel.
    func testBoundedPeelWindowKeepsNewestLongTalkSentence() {
        let topics = ["the model", "the dataset", "attention", "the encoder", "our results", "the baseline"]
        let verbs = ["improves", "changes", "explains", "limits", "shapes", "drives"]
        func sentence(_ index: Int) -> String {
            "Point \(index) is that \(topics[index % topics.count]) "
                + "\(verbs[(index / 6) % verbs.count]) everything we measured."
        }
        var transcript = ""
        for index in 0..<80 {
            transcript = (transcript + " " + sentence(index)).trimmingCharacters(in: .whitespaces)
            let bounded = StreamingTranscriptStitcher.boundLiveTranscript(transcript)
            let already = (max(0, index - LiveTranslationTiming.peelWindowLines)..<index).map(sentence)
            let leftover = TranslationClauseSegmenter.leftoverTail(
                bounded,
                already: already,
                languageID: "en"
            )
            XCTAssertEqual(
                leftover,
                sentence(index),
                "index=\(index) already=\(already.count) boundedChars=\(bounded.count)"
            )
        }
    }

    func testLongTalkNeighborsAreNotTreatedAsRevisionsOrOverPeeled() {
        let a = "Point 0 is that the model improves everything we measured."
        let b = "Point 1 is that the dataset improves everything we measured."
        let c = "Point 2 is that attention improves everything we measured."
        XCTAssertFalse(
            TranslationClauseSegmenter.shouldReviseCommitted(previous: a, incoming: b, languageID: "en")
        )
        XCTAssertEqual(
            TranslationClauseSegmenter.leftoverTail(
                [a, b, c].joined(separator: " "),
                already: [a],
                languageID: "en"
            ),
            [b, c].joined(separator: " ")
        )
        XCTAssertEqual(
            TranslationClauseSegmenter.nextCompletedSentence(
                [b, c].joined(separator: " "),
                languageID: "en"
            )?.unit,
            b
        )
    }

    func testPeelHandlesARevisedTranscriptWithoutRescanningPerLine() {
        let already = (1...LiveTranslationTiming.peelWindowLines)
            .map { "This is committed sentence number \($0) of the talk." }
        // ASR dropped the sentence-final punctuation it had emitted earlier.
        let transcript = (1...LiveTranslationTiming.peelWindowLines)
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

    func testTypewriterAdvancesKoreanOneChunkAfterEnglishHasPrinted() throws {
        throw XCTSkip("retired typewriter / stable-text surface")
    }

    func testSpokenCorrectionWindowClosesAfterTheFirstKoreanCharacter() throws {
        throw XCTSkip("retired typewriter / stable-text surface")
    }

    func testUnpunctuatedRestitchPeelsSentenceOne() throws {
        throw XCTSkip("retired typewriter / stable-text surface")
    }

    func testLiveHeightStaysAtSpokenBlockUntilTheTitlePrints() {
        let font = NSFont.systemFont(ofSize: 48, weight: .semibold)
        let spoken = "Hello world today friends"
        let translated = "안녕하세요 여러분 오늘도"
        let spokenOnly = TheaterBilingualWrap.revealedRows(
            spoken: spoken,
            translated: translated,
            printedSpoken: spoken,
            printedTranslated: "",
            font: font,
            width: 140
        )
        XCTAssertTrue(spokenOnly.allSatisfy(\.isSpoken))
        XCTAssertEqual(
            TheaterBilingualWrap.boardHeight(rows: spokenOnly, spokenFont: font, translatedFont: font),
            TheaterBilingualWrap.boardHeight(
                rows: TheaterBilingualWrap.rows(spoken: spoken, translated: "", font: font, width: 140),
                spokenFont: font,
                translatedFont: font
            )
        )
        let hiddenSpoken = TheaterBilingualWrap.rows(
            spoken: "",
            translated: translated,
            font: font,
            width: 140
        )
        XCTAssertTrue(hiddenSpoken.allSatisfy { !$0.isSpoken })
        XCTAssertFalse(hiddenSpoken.isEmpty)
    }

    func testShowAsEnglishUsesLatinFlowAndKoreanUsesCompactPace() throws {
        throw XCTSkip("retired typewriter / stable-text surface")
    }

    func testFollowAlongIsATwelveWordBackstopNotAnEightWordCut() {
        XCTAssertFalse(
            TranslationClauseSegmenter.shouldFollowAlong(
                "one two three four five",
                languageID: "en"
            )
        )
        XCTAssertFalse(
            TranslationClauseSegmenter.shouldFollowAlong(
                "Then we applied it to the new data set",
                languageID: "en"
            )
        )
        XCTAssertFalse(
            TranslationClauseSegmenter.isReadyToCommit(
                "one two three four five",
                languageID: "en"
            )
        )
        let twelve = (1...12).map { "word\($0)" }.joined(separator: " ")
        XCTAssertTrue(TranslationClauseSegmenter.shouldFollowAlong(twelve, languageID: "en"))
        XCTAssertEqual(
            Double(LiveTranslationTiming.completeSettleNanoseconds(languageID: "ko")) / 1_000_000_000,
            1.0,
            accuracy: 0.01
        )
        XCTAssertEqual(
            Double(LiveTranslationTiming.completeSettleNanoseconds(languageID: "th")) / 1_000_000_000,
            0.8,
            accuracy: 0.01
        )
        XCTAssertEqual(TheaterReadiness.spokenLineTranslate.contains("original language"), true)
    }

    func testQueuedPendingRowsStayOffTheBoard() {
        let rows = TheaterCaptionFlow.lines(board: .make(translated: []))
        XCTAssertTrue(rows.isEmpty)
    }

    func testEnglishOnlyCaptionPaintsCommittedLinesOnly() {
        let same = TheaterCaptionFlow.lines(board: .make(translated: []))
        XCTAssertTrue(same.isEmpty)

        let restitch = TheaterCaptionFlow.lines(board: .make(translated: ["Today we trained the model."], sources: ["Today we trained the model."], ids: [1]))
        XCTAssertEqual(restitch.map(\.text), ["Today we trained the model."])
        XCTAssertEqual(restitch.last?.source, "Today we trained the model.")
        XCTAssertEqual(restitch.last?.isDraft, false)

        let unpunctuated = TheaterCaptionFlow.lines(board: .make(translated: ["Today we trained the model"], sources: ["Today we trained the model"], ids: [1]))
        XCTAssertEqual(unpunctuated.map(\.text), ["Today we trained the model"])
        XCTAssertEqual(unpunctuated.count, 1)

        let jammed = TheaterCaptionFlow.lines(board: .make(translated: []))
        XCTAssertTrue(jammed.isEmpty)

        let pairedRestitch = TheaterCaptionFlow.lines(board: .make(translated: ["오늘 모델을 학습했습니다."], sources: ["Today we trained the model."], ids: [1]))
        XCTAssertEqual(pairedRestitch.map(\.text), ["오늘 모델을 학습했습니다."])
        XCTAssertEqual(pairedRestitch.last?.source, "Today we trained the model.")
        XCTAssertEqual(pairedRestitch.count, 1)
        XCTAssertFalse(pairedRestitch.contains { $0.isDraft })
    }

    func testEnglishOnlyPrinterPeelsTheNextTitleAfterSentenceOne() throws {
        throw XCTSkip("retired typewriter / stable-text surface")
    }

    func testWrapProgressKeepsTheFirstLineWhenASpaceWasDropped() {
        let font = NSFont.systemFont(ofSize: 32, weight: .semibold)
        let text = "Hello world today friends then we applied it together"
        let lines = TheaterBilingualWrap.visualLines(text, font: font, width: 220)
        XCTAssertGreaterThan(lines.count, 1)
        let revealed = TheaterBilingualWrap.revealedRows(
            spoken: "",
            translated: text,
            printedSpoken: "",
            printedTranslated: text,
            font: font,
            width: 220
        )
        XCTAssertEqual(revealed.map(\.text), lines)
        let first = lines[0]
        let mid = TheaterBilingualWrap.revealedRows(
            spoken: "",
            translated: text,
            printedSpoken: "",
            printedTranslated: first + " " + String(lines[1].prefix(2)),
            font: font,
            width: 220
        )
        XCTAssertEqual(mid.first?.text, first)
        XCTAssertEqual(String(mid.dropFirst().first?.text.prefix(2) ?? ""), String(lines[1].prefix(2)))
    }

    func testPairingsGrowThisCaptionAndHoldAPeeledTail() throws {
        throw XCTSkip("retired typewriter / stable-text surface")
    }
}

final class TheaterPresenterAidTests: XCTestCase {
    private let visible = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    func testPresetsStayInsideSafeMargin() {
        let safe = self.visible.insetBy(dx: 96, dy: 54)
        for preset in TheaterPositionPreset.allCases {
            let frame = preset.frame(in: self.visible)
            if preset == .fillScreen {
                // Fill screen is the one preset that covers the visible display.
                XCTAssertEqual(frame, self.visible, "fillScreen should cover the display")
            } else {
                XCTAssertTrue(safe.contains(frame), "\(preset) leaves the safe margin")
            }
        }
    }

    func testPresetShapes() {
        let lower = TheaterPositionPreset.lowerThird.frame(in: self.visible)
        let top = TheaterPositionPreset.topBand.frame(in: self.visible)
        let side = TheaterPositionPreset.sideColumn.frame(in: self.visible)
        XCTAssertEqual(lower.minY, 54, accuracy: 0.5)
        XCTAssertEqual(top.maxY, 1026, accuracy: 0.5)
        XCTAssertEqual(lower.height, top.height, accuracy: 0.5)
        XCTAssertEqual(side.maxX, 1824, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(side.width, TheaterPositionPreset.sideColumnMinimumWidth)
    }

    func testPresetsFollowOffsetDisplay() {
        let projector = CGRect(x: 1920, y: -200, width: 1280, height: 720)
        let frame = TheaterPositionPreset.lowerThird.frame(in: projector)
        XCTAssertTrue(projector.contains(frame))
    }

    func testPresenterHotkeysRequireControlOption() {
        let chord: NSEvent.ModifierFlags = [.control, .option]
        XCTAssertEqual(TheaterPresenterHotkey.action(keyCode: UInt16(kVK_ANSI_H), modifiers: chord), .toggleVisible)
        XCTAssertEqual(TheaterPresenterHotkey.action(keyCode: UInt16(kVK_ANSI_P), modifiers: chord), .togglePause)
        XCTAssertEqual(TheaterPresenterHotkey.action(keyCode: UInt16(kVK_ANSI_K), modifiers: chord), .clear)
        XCTAssertEqual(TheaterPresenterHotkey.action(keyCode: UInt16(kVK_ANSI_C), modifiers: chord), .copy)
        XCTAssertEqual(TheaterPresenterHotkey.action(keyCode: UInt16(kVK_ANSI_Z), modifiers: chord), .undo)
        XCTAssertEqual(TheaterPresenterHotkey.action(keyCode: UInt16(kVK_ANSI_Equal), modifiers: chord), .fontLarger)
        XCTAssertEqual(TheaterPresenterHotkey.action(keyCode: UInt16(kVK_ANSI_Minus), modifiers: chord), .fontSmaller)
        XCTAssertEqual(TheaterPresenterHotkey.action(keyCode: UInt16(kVK_ANSI_T), modifiers: chord), .toggleTools)
        XCTAssertEqual(TheaterPresenterHotkey.action(keyCode: UInt16(kVK_ANSI_L), modifiers: chord), .listen)
        XCTAssertNil(TheaterPresenterHotkey.action(keyCode: UInt16(kVK_ANSI_H), modifiers: [.control]))
        XCTAssertNil(TheaterPresenterHotkey.action(keyCode: UInt16(kVK_ANSI_H), modifiers: [.control, .option, .command]))
        XCTAssertNil(TheaterPresenterHotkey.action(keyCode: UInt16(kVK_ANSI_A), modifiers: chord))
        // Caps Lock / Fn must not break the chord.
        XCTAssertEqual(
            TheaterPresenterHotkey.action(keyCode: UInt16(kVK_ANSI_P), modifiers: [.control, .option, .capsLock]),
            .togglePause
        )
    }
}

final class TheaterStableTextTests: XCTestCase {
    func testShowsOnlyWordsTwoGuessesAgreeOn() throws {
        throw XCTSkip("retired typewriter / stable-text surface")
    }

    func testRevisedTailNeverShrinksShownText() throws {
        throw XCTSkip("retired typewriter / stable-text surface")
    }

    func testCutsBackToWholeWord() throws {
        throw XCTSkip("retired typewriter / stable-text surface")
    }

    func testCommittedClauseLeavingResetsToNewLeftover() throws {
        throw XCTSkip("retired typewriter / stable-text surface")
    }
}

final class TheaterStableTextRefreshTests: XCTestCase {
    func testRepeatedRefreshOfSameGuessDoesNotConfirmIt() throws {
        throw XCTSkip("retired typewriter / stable-text surface")
    }
}

final class TheaterPrintCatchUpTests: XCTestCase {
    func testLargeBacklogTypesFaster() throws {
        throw XCTSkip("retired typewriter / stable-text surface")
    }
}

final class TheaterRunOnCutTests: XCTestCase {
    func testUnpunctuatedRunOnPrintsWhileTalking() {
        let runOn = Array(repeating: "and then we kept going with the model", count: 8).joined(separator: " ")
        XCTAssertGreaterThanOrEqual(runOn.count, LiveTranslationTiming.maxDraftCharacters)
        let next = TranslationClauseSegmenter.nextCompletedSentence(runOn, languageID: "en")
        XCTAssertNotNil(next)
        XCTAssertFalse(next?.rest.isEmpty ?? true)
    }

    func testShortUnpunctuatedSpeechStillWaits() {
        XCTAssertNil(TranslationClauseSegmenter.nextCompletedSentence("and then we kept going", languageID: "en"))
    }
}

@MainActor
final class TheaterSentenceEndCommitTests: XCTestCase {
    func testLoneFinishedSentenceIsACommitUnit() {
        let next = TranslationClauseSegmenter.nextCompletedSentence(
            "Today we trained the model.",
            languageID: "en"
        )
        XCTAssertEqual(next?.unit, "Today we trained the model.")
        XCTAssertEqual(next?.rest, "")
    }

    func testALaterSentencePrintsBeforeASlowEarlierTranslation() async {
        let settings = SettingsStore.shared
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        defer {
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
        }
        settings.translationSourceLanguageID = "en"
        settings.translationTargetLanguageID = "ko"
        let engine = FakeTranslationEngine()
        engine.result = .success("번역")
        engine.delayByText = [
            "Today we trained the model.": 400_000_000,
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let subscriber = LiveTranslationSubscriber(translator: engine, archive: LectureCaptionArchive(url: url))
        subscriber.beginListening()
        let spoken = "Today we trained the model. Then we applied it."
        subscriber.handlePartial(spoken)
        subscriber.handlePartial(spoken)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.2
        while !engine.calls.contains(where: { $0.contains("Then we applied it") }),
              ProcessInfo.processInfo.systemUptime < deadline
        {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(
            engine.calls.contains { $0.contains("Then we applied it") },
            "the next sentence must be sent for translation while the earlier one is still running: \(engine.calls)"
        )
        await subscriber.waitForIdleForTesting()
        XCTAssertEqual(
            subscriber.committedSourceLines,
            ["Today we trained the model.", "Then we applied it."]
        )
    }

    func testFinishedSentenceTranslatesOnceTwoUpdatesAgree() async {
        let settings = SettingsStore.shared
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        defer {
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
        }
        settings.translationSourceLanguageID = "en"
        settings.translationTargetLanguageID = "ko"
        let engine = FakeTranslationEngine()
        engine.result = .success("오늘 모델을 학습했습니다.")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let subscriber = LiveTranslationSubscriber(translator: engine, archive: LectureCaptionArchive(url: url))
        subscriber.beginListening()
        subscriber.handlePartial("Today we trained the model.")
        XCTAssertTrue(engine.calls.isEmpty, "one update is not enough")
        subscriber.handlePartial("Today we trained the model.")
        await subscriber.waitForIdleForTesting()
        XCTAssertEqual(engine.calls.count, 1)
    }

    func testLoneFinishedSentencePrintsWithoutASecondSentence() async {
        let settings = SettingsStore.shared
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        defer {
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
        }
        settings.translationSourceLanguageID = "en"
        settings.translationTargetLanguageID = "ko"
        let engine = FakeTranslationEngine()
        engine.result = .success("환영합니다.")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let subscriber = LiveTranslationSubscriber(translator: engine, archive: LectureCaptionArchive(url: url))
        subscriber.beginListening()
        subscriber.handlePartial("Welcome to the lecture.")
        XCTAssertTrue(engine.calls.isEmpty, "one update is not enough")
        await subscriber.waitForIdleForTesting()
        XCTAssertTrue(
            subscriber.committedSourceLines.isEmpty,
            "a single emission does not lock, even after the recognizer goes quiet"
        )
        subscriber.handlePartial("Welcome to the lecture.")
        await subscriber.waitForIdleForTesting()
        XCTAssertEqual(subscriber.committedSourceLines, ["Welcome to the lecture."])
    }
}

/// Scripted talks through the real subscriber: what gets translated, in what order.
@MainActor
final class TheaterTalkSimulationTests: XCTestCase {
    private var originalSource = ""
    private var originalTarget = ""

    override func setUp() async throws {
        let settings = SettingsStore.shared
        self.originalSource = settings.translationSourceLanguageID
        self.originalTarget = settings.translationTargetLanguageID
        settings.translationSourceLanguageID = "en"
        settings.translationTargetLanguageID = "ko"
    }

    override func tearDown() async throws {
        SettingsStore.shared.translationSourceLanguageID = self.originalSource
        SettingsStore.shared.translationTargetLanguageID = self.originalTarget
    }

    private func makeSubscriber() -> (LiveTranslationSubscriber, FakeTranslationEngine) {
        let engine = FakeTranslationEngine()
        engine.result = .success("번역")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let subscriber = LiveTranslationSubscriber(translator: engine, archive: LectureCaptionArchive(url: url))
        subscriber.beginListening()
        return (subscriber, engine)
    }

    private func settle() async {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    func testContinuousTalkTranslatesEachSentenceOnceInOrder() async {
        let (subscriber, _) = self.makeSubscriber()
        for partial in [
            "Today we",
            "Today we trained the",
            "Today we trained the model.",
            "Today we trained the model. Then we",
            "Today we trained the model. Then we tested it.",
            "Today we trained the model. Then we tested it.",
        ] {
            subscriber.handlePartial(partial)
            await self.settle()
        }
        await subscriber.waitForIdleForTesting()
        // Engine calls include the context request (prior + new), so check the board.
        XCTAssertEqual(subscriber.committedSourceLines, ["Today we trained the model.", "Then we tested it."])
        XCTAssertEqual(subscriber.sourceDraft, "")
    }

    func testLaterTranslationWaitsUntilTheEarlierSentenceLands() async {
        let engine = HeldTranslationEngine()
        let first = "Today we trained the model."
        let second = "Then we tested it."
        engine.holdIf = { text in
            text.contains(first) && !text.contains("Then we tested")
        }
        engine.translation = { text in
            text.contains("Then we tested") ? "둘" : "하나"
        }
        defer { engine.release() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let subscriber = LiveTranslationSubscriber(
            translator: engine,
            archive: LectureCaptionArchive(url: url)
        )
        subscriber.beginListening()
        for partial in [first, first, "\(first) \(second)", "\(first) \(second)"] {
            subscriber.handlePartial(partial)
            await self.settle()
        }
        // Each finished sentence starts translation as soon as it is accepted.
        // Apple's mailbox serialises the session calls; this fake engine has no
        // mailbox, so the second call is allowed to reach it. What must hold is
        // the board: the later, faster translation stays off it until the
        // earlier sentence has landed.
        XCTAssertEqual(engine.calls.first, first)
        XCTAssertEqual(
            subscriber.committedSourceLines,
            [],
            "a fast later translation must stay off the board: \(subscriber.committedSourceLines)"
        )
        engine.release()
        await subscriber.waitForIdleForTesting()
        XCTAssertTrue(engine.calls.contains { $0.contains("Then we tested") })
        XCTAssertEqual(subscriber.committedSourceLines, [first, second])
    }

    func testFinishedSentenceStartsBeforeAnyPause() async {
        let (subscriber, engine) = self.makeSubscriber()
        subscriber.handlePartial("Welcome to the lecture.")
        await self.settle()
        subscriber.handlePartial("Welcome to the lecture.")
        await self.settle()
        // No silence hold, no end of utterance: printing already started.
        XCTAssertEqual(engine.calls, ["Welcome to the lecture."])
    }

    func testFinishedSentencePrintsWhileTheOpenTailStaysOff() async {
        let (subscriber, _) = self.makeSubscriber()
        let open = "Hello. This is sen"
        subscriber.handlePartial(open)
        subscriber.handlePartial(open)
        await subscriber.waitForIdleForTesting()
        XCTAssertEqual(subscriber.committedSourceLines, ["Hello."])
        XCTAssertEqual(subscriber.liveSpokenText, "This is sen")
        let done = "Hello. This is the second sentence."
        subscriber.handlePartial(done)
        XCTAssertEqual(
            subscriber.committedSourceLines,
            ["Hello."],
            "one update of the next sentence is not enough"
        )
        subscriber.handlePartial(done)
        await subscriber.waitForIdleForTesting()
        XCTAssertEqual(
            subscriber.committedSourceLines,
            ["Hello.", "This is the second sentence."]
        )
    }

    func testRestitchAfterLoneCommitDoesNotDuplicate() async {
        let (subscriber, engine) = self.makeSubscriber()
        subscriber.handlePartial("We trained the model.")
        await self.settle()
        subscriber.handlePartial("We trained the model.")
        await self.settle()
        subscriber.handlePartial("We trained the model on new data.")
        await self.settle()
        subscriber.handlePartial("We trained the model on new data. It worked well")
        await self.settle()
        subscriber.handlePartial("We trained the model on new data. It worked well.")
        await self.settle()
        subscriber.handlePartial("We trained the model on new data. It worked well.")
        await subscriber.waitForIdleForTesting()
        // The newest line is fixed in place: no "on new data." fragment row.
        XCTAssertEqual(subscriber.committedSourceLines, ["We trained the model on new data.", "It worked well."])
        XCTAssertTrue(engine.calls.contains("It worked well."))
        XCTAssertEqual(engine.calls.filter { $0 == "It worked well." }.count, 1)
    }

    func testRestitchAfterNextSentenceStartedFixesNewestLine() async {
        let (subscriber, _) = self.makeSubscriber()
        subscriber.handlePartial("We trained the model. And")
        await self.settle()
        subscriber.handlePartial("We trained the model on new data. And then")
        await self.settle()
        subscriber.handlePartial("We trained the model on new data. And then it worked.")
        await self.settle()
        subscriber.handlePartial("We trained the model on new data. And then it worked.")
        await subscriber.waitForIdleForTesting()
        XCTAssertEqual(
            subscriber.committedSourceLines,
            ["We trained the model on new data.", "And then it worked."]
        )
    }

    func testRealNextSentenceIsNotMergedIntoPrintedLine() async {
        let (subscriber, _) = self.makeSubscriber()
        subscriber.handlePartial("We trained the model.")
        await self.settle()
        subscriber.handlePartial("We trained the model.")
        await self.settle()
        subscriber.handlePartial("We trained the model. on the other hand it failed.")
        await self.settle()
        subscriber.handlePartial("We trained the model. on the other hand it failed.")
        await subscriber.waitForIdleForTesting()
        // The period stayed, so this is a new line even though it starts lowercase.
        XCTAssertEqual(subscriber.committedSourceLines.first, "We trained the model.")
    }

    func testSimilarNextSentenceIsNotSwallowedAsARevision() async {
        let (subscriber, _) = self.makeSubscriber()
        let first = "We tested it on English data."
        let second = "We tested it on Korean data."
        subscriber.handlePartial(first)
        await self.settle()
        subscriber.handlePartial(first)
        await self.settle()
        subscriber.handlePartial(first + " " + second)
        await self.settle()
        subscriber.handlePartial(first + " " + second)
        await subscriber.waitForIdleForTesting()
        XCTAssertEqual(subscriber.committedSourceLines, [first, second])
    }

    func testResumingSpeechCancelsTheSilentTailPrint() async {
        let settings = SettingsStore.shared
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        defer {
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
        }
        settings.translationSourceLanguageID = "en"
        settings.translationTargetLanguageID = "ko"
        let (subscriber, _) = self.makeSubscriber()
        subscriber.handlePartial("and that's it")
        await self.settle()
        subscriber.noteSilenceHold()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertTrue(subscriber.committedSourceLines.isEmpty, "a short pause keeps the tail open")
        subscriber.noteSpeechStart(uptime: ProcessInfo.processInfo.systemUptime)
        subscriber.handlePartial("and that's it for today.")
        await self.settle()
        subscriber.handlePartial("and that's it for today.")
        await subscriber.waitForIdleForTesting()
        XCTAssertEqual(subscriber.committedSourceLines, ["and that's it for today."])
    }

    func testSilentTailPrintsAfterSustainedSilence() async {
        let (subscriber, engine) = self.makeSubscriber()
        subscriber.handlePartial("and that's it")
        await self.settle()
        subscriber.noteSilenceHold()
        await subscriber.waitForIdleForTesting()
        XCTAssertEqual(engine.calls, ["and that's it"])
    }

    func testUnpunctuatedPauseWaitsForTheOpenTail() async {
        let settings = SettingsStore.shared
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        defer {
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
        }
        settings.translationSourceLanguageID = "en"
        settings.translationTargetLanguageID = "ko"
        let (subscriber, _) = self.makeSubscriber()
        subscriber.handlePartial("so this is how the attention layer works")
        await self.settle()
        subscriber.noteSilenceHold()
        try? await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertTrue(
            subscriber.committedSourceLines.isEmpty,
            "a one-second quiet keeps an unpunctuated clause open"
        )
        await subscriber.waitForIdleForTesting()
        XCTAssertEqual(
            subscriber.committedSourceLines,
            ["so this is how the attention layer works"]
        )
    }
}

/// An hour-scale talk through the real subscriber, fed like ASRService feeds it:
/// the cumulative transcript, bounded by `boundLiveTranscript`.
@MainActor
final class TheaterLongTalkTests: XCTestCase {
    func testLongTalkPrintsEverySentenceOnceWithoutSlowingDown() async {
        // 600 sentences through real settle and end-of-utterance timers take
        // about 75 s on an M-series Mac and longer on a hosted runner.
        self.executionTimeAllowance = 300
        let settings = SettingsStore.shared
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        defer {
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
        }
        settings.translationSourceLanguageID = "en"
        settings.translationTargetLanguageID = "ko"
        let engine = FakeTranslationEngine()
        engine.result = .success("번역")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let subscriber = LiveTranslationSubscriber(translator: engine, archive: LectureCaptionArchive(url: url))
        subscriber.beginListening()

        let topics = ["the model", "the dataset", "attention", "the encoder", "our results", "the baseline"]
        let verbs = ["improves", "changes", "explains", "limits", "shapes", "drives"]
        let sentenceCount = 600
        var transcript = ""
        var printed: [String] = []
        var firstBatch: TimeInterval = 0
        var lastBatch: TimeInterval = 0
        for index in 0..<sentenceCount {
            let sentence = "Point \(index) is that \(topics[index % topics.count]) "
                + "\(verbs[(index / 6) % verbs.count]) everything we measured."
            let words = sentence.split(separator: " ")
            let half = words.prefix(words.count / 2).joined(separator: " ")
            let started = ProcessInfo.processInfo.systemUptime
            for partial in [transcript + " " + half, transcript + " " + sentence, transcript + " " + sentence] {
                subscriber.handlePartial(StreamingTranscriptStitcher.boundLiveTranscript(partial))
                await Task.yield()
            }
            await subscriber.waitForIdleForTesting()
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            if index < 50 { firstBatch += elapsed }
            if index >= sentenceCount - 50 { lastBatch += elapsed }
            transcript = (transcript + " " + sentence).trimmingCharacters(in: .whitespaces)
            // The board keeps the latest lines. Count each new row once.
            let seen = Set(printed)
            printed.append(contentsOf: subscriber.committedSourceLines.filter { !seen.contains($0) })
        }
        XCTAssertEqual(subscriber.captionPairs.count, sentenceCount, "history/export must hold the whole talk")
        let unique = Set(printed)
        XCTAssertEqual(printed.count, unique.count, "a sentence printed twice")
        XCTAssertEqual(
            subscriber.captionPairs.map(\.source).count,
            Set(subscriber.captionPairs.map(\.source)).count,
            "history holds a sentence twice"
        )
        XCTAssertEqual(unique.count, sentenceCount, "sentences missing: \(sentenceCount - unique.count)")
        XCTAssertLessThan(lastBatch, max(firstBatch * 3, 0.5), "per-sentence work grew over the talk")
        print("LONG first50=\(firstBatch)s last50=\(lastBatch)s printed=\(unique.count) calls=\(engine.calls.count)")
    }
}




final class TheaterStableTextScriptTests: XCTestCase {
    func testLiveLineGrowsWhileTalkingInEveryScript() throws {
        throw XCTSkip("retired typewriter / stable-text surface")
    }
}

final class TheaterBoardAdmissionTests: XCTestCase {
    private func context(
        peel: [String] = [],
        inFlight: [String] = [],
        identities: Set<String> = [],
        hypothesis: String = ""
    ) -> TheaterBoardAdmission.Context {
        TheaterBoardAdmission.Context(
            peelSources: peel,
            inFlightSources: inFlight,
            commitIdentities: identities,
            latestHypothesis: hypothesis,
            requiresTrackedIdentity: false
        )
    }

    func testAdmissionSkipsEachReasonAndAdmitsAFinishedSentence() {
        let sentence = "Today we trained the model."
        let cases: [(TheaterBoardAdmission.Phase, TheaterBoardAdmission.Context, String, TheaterBoardAdmission.Decision)] = [
            (.propose, self.context(), "", .skip(.empty)),
            (.publish, self.context(), "", .skip(.empty)),
            (.propose, self.context(), "thanks for watching", .skip(.junk)),
            (.publish, self.context(), "thanks for watching", .skip(.junk)),
            (.propose, self.context(), "It.", .skip(.tooThin)),
            (.publish, self.context(), "It.", .skip(.tooThin)),
            (.propose, self.context(inFlight: [sentence]), sentence, .skip(.inFlight)),
            (.propose, self.context(peel: [sentence]), sentence, .skip(.sameAsPrinted)),
            (
                .propose,
                self.context(peel: [sentence, "Then we applied it."]),
                sentence,
                .skip(.revisesEarlier)
            ),
            (.propose, self.context(), sentence, .admit),
        ]
        for (phase, context, source, expected) in cases {
            XCTAssertEqual(
                TheaterBoardAdmission.decide(source, languageID: "en", phase: phase, context: context),
                expected,
                "\(phase) \(source)"
            )
        }
    }

    func testPublishRequiresATrackedIdentityAndIgnoresItsOwnInFlightEntry() {
        let sentence = "Today we trained the model."
        let key = TranslationClauseSegmenter.clauseIdentity(sentence)
        var missing = self.context(inFlight: [sentence])
        missing.requiresTrackedIdentity = true
        XCTAssertEqual(
            TheaterBoardAdmission.decide(sentence, languageID: "en", phase: .publish, context: missing),
            .skip(.untracked)
        )
        var tracked = missing
        tracked.commitIdentities = [key]
        XCTAssertEqual(
            TheaterBoardAdmission.decide(sentence, languageID: "en", phase: .publish, context: tracked),
            .admit
        )
    }

    func testAThinPrefixGrowthIsNotASecondRow() {
        let decision = TheaterBoardAdmission.decide(
            "It worked.",
            languageID: "en",
            phase: .propose,
            context: self.context(peel: ["It"])
        )
        XCTAssertEqual(decision, .skip(.revisesNewest))
    }

    func testACloseSpellingOfTheNewestLineIsNotANewRow() {
        let sentence = "Today we trained the model."
        let base = self.context(
            peel: ["Today we trained the modal."],
            identities: [TranslationClauseSegmenter.clauseIdentity(sentence)],
            hypothesis: sentence
        )
        for phase in [TheaterBoardAdmission.Phase.propose, .publish] {
            var context = base
            context.requiresTrackedIdentity = phase == .publish
            XCTAssertEqual(
                TheaterBoardAdmission.decide(sentence, languageID: "en", phase: phase, context: context),
                .skip(.revisesNewest),
                "\(phase)"
            )
        }
    }
}
