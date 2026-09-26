import XCTest
@testable import FluidSubtitles_Debug

/// Timed partials into the subscriber. Does not start ASRService.
@MainActor
enum MockASRPartialStream {
    static func play(
        ticks: [String],
        intervalNanoseconds: UInt64,
        into subscriber: LiveTranslationSubscriber
    ) async {
        for tick in ticks {
            subscriber.handlePartial(tick)
            if intervalNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: intervalNanoseconds)
            }
        }
    }
}

@MainActor
final class LiveTranslationMockASRTests: XCTestCase {
    private var originalSessionMode: TheaterSessionMode?
    private var originalSpokenLine: TheaterSpokenLineMode?

    override func setUp() async throws {
        try await super.setUp()
        self.originalSessionMode = SettingsStore.shared.theaterSessionMode
        self.originalSpokenLine = SettingsStore.shared.theaterSpokenLineMode
        SettingsStore.shared.theaterSessionMode = .translation
        SettingsStore.shared.theaterSpokenLineMode = .afterPause
    }

    override func tearDown() async throws {
        if let mode = self.originalSessionMode {
            SettingsStore.shared.theaterSessionMode = mode
        }
        if let spoken = self.originalSpokenLine {
            SettingsStore.shared.theaterSpokenLineMode = spoken
        }
        try await super.tearDown()
    }

    func testContinuousTalkCommitsEachSentenceWithoutReplacing() async {
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
        engine.delayNanoseconds = 40_000_000
        engine.resultsByText = [
            "Today we trained the model.": "오늘 모델을 학습했습니다.",
            "Then we applied it.": "그걸 적용했습니다.",
            "And we shipped it to production.": "그리고 프로덕션에 올렸습니다.",
        ]
        engine.result = .success("번역")
        let subscriber = LiveTranslationSubscriber(translator: engine)
        subscriber.beginListening()

        await MockASRPartialStream.play(
            ticks: [
                "Today we",
                "Today we trained the model.",
                "Today we trained the model. Then we applied it.",
                "Today we trained the model. Then we applied it. And we shipped it to production.",
            ],
            intervalNanoseconds: 15_000_000,
            into: subscriber
        )

        XCTAssertTrue(subscriber.committedSourceLines.isEmpty)
        XCTAssertEqual(subscriber.inFlightCaptionCount, 2)
        let liveRows = TheaterCaptionFlow.lines(board: .make(translated: subscriber.committedLines, sources: subscriber.committedSourceLines, ids: subscriber.committedLineIDs))
        XCTAssertFalse(liveRows.contains { $0.isDraft })

        await subscriber.waitForIdleForTesting()
        XCTAssertEqual(
            subscriber.committedSourceLines,
            ["Today we trained the model.", "Then we applied it."]
        )

        subscriber.handleEndOfUtterance()
        await subscriber.waitForIdleForTesting()
        XCTAssertEqual(
            subscriber.committedSourceLines,
            [
                "Today we trained the model.",
                "Then we applied it.",
                "And we shipped it to production.",
            ]
        )
        XCTAssertEqual(
            subscriber.committedLines,
            [
                "오늘 모델을 학습했습니다.",
                "그걸 적용했습니다.",
                "그리고 프로덕션에 올렸습니다.",
            ]
        )
    }

    func testThinPeriodPlusTailDoesNotMidTalkCommit() async {
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
        let subscriber = LiveTranslationSubscriber(translator: engine)
        subscriber.beginListening()
        await MockASRPartialStream.play(
            ticks: ["It.", "It. Then we applied it today"],
            intervalNanoseconds: 0,
            into: subscriber
        )
        await subscriber.waitForIdleForTesting()
        XCTAssertTrue(subscriber.committedLines.isEmpty)
        XCTAssertTrue(subscriber.liveSpokenText.contains("Then we applied"))
    }

    /// Raw Apple Speech Analyzer decodes from a Voice talk (2026-09-19 16:19).
    /// Every tick re-decodes the whole ring and the words drift. Run them
    /// through the same stitch ASRService uses, then through Voice, and the
    /// board must hold each phrase once, in order, with nothing re-added.
    func testVoiceReplayOfDriftingDecodesPrintsEachPhraseOnce() async {
        let settings = SettingsStore.shared
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        let originalMode = settings.theaterSessionMode
        defer {
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
            settings.theaterSessionMode = originalMode
        }
        settings.theaterSessionMode = .transcription
        settings.translationSourceLanguageID = "en"
        settings.translationTargetLanguageID = "en"

        let head = "I really fine about it. Cle. something. Exactly. It was no big. I mean, sure, I wasted a bit of time shaving my legs. Never mind this one week later. I met you gallery career "
        let decodes = [
            "I feel fine.",
            "I feel the fine about it.",
            "I feel the fine about it. Clear.",
            "I really fine about it. Clear.",
            "I really fine about it. Cle. Exactly.",
            "I really fine about it. Cle. something. Exactly. It was no big.",
            "I really fine about it. Cle. something. Exactly. It was not. sure.",
            "I really fine about it. Cle. something. Exactly. It was no big. I mean, sure, I wasted a bit.",
            "I really fine about it. Cle. something. Exactly. It was no big. I mean, sure, I'm wasted a bit of time shaving mine.",
            "I really fine about it. Cle. something. Exactly. It was no big. I mean, sure, I wasted a bit of time shaving my legs.",
            "I really fine about it. Cle. something. Exactly. It was no big. I mean, sure, I wasted a bit of time shaving my legs. Never...",
            "I really fine about it. Cle. something. Exactly. It was no big. I mean, sure, I wasted a bit of time shaving my legs. Never mind this one week.",
            "I really fine about it. Cle. something. Exactly. It was no big. I mean, sure, I wasted a bit of time shaving my legs. Never mind this one week later. I",
            "I really fine about it. Cle. something. Exactly. It was no big. I mean, sure, I wasted a bit of time shaving my legs. Never mind this one week later. I'm a cute gallery.",
            "I really fine about it. Cle. something. Exactly. It was no big. I mean, sure, I wasted a bit of time shaving my legs. Never mind this one week later. I met you gallery career",
            head + "I",
            head + "I wanna rip up his double daddy make",
            head + "I wanna rip up his double daddy make his bed like Tracy",
            head + "I wanna rip up his double daddy, make his bed like Tracy, Emmy.",
            head + "I wanna rip up his double daddy, make his bed like Tracy Emmy. So we set a day",
            head + "I wanna rip up his double daddy, make his bed like Tracy Emmy. So we set a day One day",
            head + "I wanna rip up his double daddy, make his bed like Tracy Emmy. So we set a day One day after tea",
            head + "I wanna rip up his double daddy, make his bed like Tracy Emmy. So we set a day One day after tea Then he comes",
            // The ring is full: the window slides and the opening drifts.
            "I feel fine about it. So yeah, see something. Exactly. It was no big. I mean, sure, I'm wasted a bit of time shaving my legs. "
                + "Never mind this one week later. I met you, gallery curator. I wanna rip up his double daddy, make his bed like Tracy Emmy. "
                + "So we set a day One day at the tent, then he comes soon, but he said",
            "Exactly. It was no big. I mean, sure, I wasted a bit of time shaving my legs. Never mind this one week later. I a Q gallery career I'm wondering about this double daddy, make his bed like Tracy and me. So we set a day One day after day Then a gall soon, but he's Saturday. He went to Saturday instead",
        ]

        let engine = FakeTranslationEngine()
        let subscriber = LiveTranslationSubscriber(translator: engine)
        subscriber.beginListening()
        var stitched = ""
        var boardSizes: [Int] = []
        for decode in decodes {
            stitched = StreamingTranscriptStitcher.stitch(committed: stitched, incoming: decode)
            stitched = StreamingTranscriptStitcher.boundLiveTranscript(stitched)
            subscriber.handlePartial(stitched)
            boardSizes.append(subscriber.committedSourceLines.count)
            let live = subscriber.liveSpokenText
            XCTAssertLessThanOrEqual(
                live.count,
                LiveTranslationTiming.maxDraftCharacters,
                "live row holds too much: \(live)"
            )
            for printed in subscriber.committedSourceLines {
                XCTAssertFalse(
                    TranslationClauseSegmenter.contains(live, clause: printed),
                    "printed line came back on the live row: \(printed) in \(live)"
                )
            }
        }
        subscriber.handleEndOfUtterance()
        await subscriber.waitForIdleForTesting()
        _ = await subscriber.translateFinal("")

        XCTAssertTrue(engine.calls.isEmpty, "Voice must not call the translator")
        XCTAssertEqual(boardSizes, boardSizes.sorted())
        let lines = subscriber.sessionSourceLinesForTesting
        XCTAssertFalse(lines.contains("It was not."), lines.joined(separator: " | "))
        for (index, line) in lines.enumerated() {
            for other in lines.dropFirst(index + 1) {
                XCTAssertFalse(
                    TranslationClauseSegmenter.isSameClause(line, other),
                    "printed twice: \(line)"
                )
                XCTAssertFalse(
                    TranslationClauseSegmenter.contains(other, clause: line),
                    "printed again inside a later line: \(line) in \(other)"
                )
            }
        }
    }

    /// Voice talk: a comma is not a line break. The run-on stays off the board
    /// until a real sentence ending survives into the next update. That sentence
    /// prints while the speaker is still going. The unfinished tail stays off.
    func testVoiceRunOnStaysOffTheBoardUntilTheLeftoverIsFinished() async {
        let settings = SettingsStore.shared
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        let originalMode = settings.theaterSessionMode
        defer {
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
            settings.theaterSessionMode = originalMode
        }
        settings.theaterSessionMode = .transcription
        settings.translationSourceLanguageID = "en"
        settings.translationTargetLanguageID = "en"

        let opening = "That calculation happens thousands of times a day, and it's quietly destroying your ability to do anything meaningful"
        let decodes = [
            "That calculation happened.",
            "That calculation happens thousands of times...",
            "That calculation happens thousands of times a day.",
            "That calculation happens thousands of times a day, and it's quietly...",
            "That calculation happens thousands of times a day, and it's quietly destroying your...",
            "That calculation happens thousands of times a day, and it's quietly destroying your ability to do...",
            opening + ".",
            opening + ", but what if I...",
            opening + ", but what if I told you that the same...",
            opening + ". But what if I told you that the same neural mechanism...",
            opening + ". But what if I told you that the same neural mechanism making you avoid...",
            opening + ". But what if I told you that the same neural mechanism making you avoid hard work...",
            opening + ". But what if I told you that the same neural mechanism making you avoid hard work can be flipped to make you...",
            opening + ". But what if I told you that the same neural mechanism making you avoid hard work can be flipped to make you crave it?",
            opening + ". But what if I told you that the same neural mechanism making you avoid hard work can be flipped to make you crave it? What if discipline could...",
            opening + ". But what if I told you that the same neural mechanism making you avoid hard work can be flipped to make you crave it? What if discipline could feel as good as scrolling?",
        ]

        let engine = FakeTranslationEngine()
        let subscriber = LiveTranslationSubscriber(translator: engine)
        subscriber.beginListening()
        var stitched = ""
        let periodReturns = decodes.firstIndex(of: opening + ". But what if I told you that the same...")
        for (index, decode) in decodes.enumerated() {
            stitched = StreamingTranscriptStitcher.stitch(committed: stitched, incoming: decode)
            stitched = StreamingTranscriptStitcher.boundLiveTranscript(stitched)
            subscriber.handlePartial(stitched)
            if let periodReturns, index <= periodReturns {
                XCTAssertTrue(
                    subscriber.committedSourceLines.isEmpty,
                    "comma run-on printed at \(index): \(subscriber.committedSourceLines)"
                )
            }
            XCTAssertLessThanOrEqual(
                subscriber.liveSpokenText.count,
                LiveTranslationTiming.maxDraftCharacters,
                "live row held a whole paragraph: \(subscriber.liveSpokenText)"
            )
        }
        XCTAssertTrue(engine.calls.isEmpty)
        XCTAssertEqual(subscriber.committedSourceLines.first, opening + ".")
        XCTAssertFalse(
            subscriber.committedSourceLines.contains { $0.contains("quietly destroying") && !$0.hasPrefix(opening) }
        )
        XCTAssertLessThanOrEqual(
            subscriber.liveSpokenText.count,
            LiveTranslationTiming.maxDraftCharacters
        )
    }

    /// Apple Speech ends every partial with "." or "…" and takes it back on
    /// the next tick. The live row shows the words only; the mark arrives
    /// with the committed line, so nothing on screen rewinds.
    func testLiveRowDropsTheProvisionalEndMark() {
        XCTAssertEqual(TheaterLiveRow.openText("I don't want to talk."), "I don't want to talk")
        XCTAssertEqual(TheaterLiveRow.openText("You always..."), "You always")
        XCTAssertEqual(TheaterLiveRow.openText("Is this baby...?"), "Is this baby")
        XCTAssertEqual(TheaterLiveRow.openText("今日はモデルを学習しました。"), "今日はモデルを学習しました")
        XCTAssertEqual(TheaterLiveRow.openText("a day, and it's quietly"), "a day, and it's quietly")
        XCTAssertEqual(TheaterLiveRow.openText("   "), "")

        // The two ticks from the 17:04 log that rewound one character each.
        let before = TheaterLiveRow.openText("I don't want to talk.")
        let after = TheaterLiveRow.openText("I don't want to talk about it.")
        XCTAssertTrue(after.hasPrefix(before))
        XCTAssertTrue(
            TheaterLiveRow.openText("You always do that.").hasPrefix(TheaterLiveRow.openText("You always..."))
        )
    }

    /// A 15-letter burst used to type in 0.57 s and then idle until the next
    /// tick. Flow now spreads it across the expected arrival window.

    func testVoiceDoesNotPrintALoneProvisionalPeriod() {
        let settings = SettingsStore.shared
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        let originalMode = settings.theaterSessionMode
        defer {
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
            settings.theaterSessionMode = originalMode
        }
        settings.theaterSessionMode = .transcription
        settings.translationSourceLanguageID = "en"
        settings.translationTargetLanguageID = "en"

        let subscriber = LiveTranslationSubscriber(translator: FakeTranslationEngine())
        subscriber.beginListening()
        subscriber.handlePartial("I don't want to talk.")
        XCTAssertTrue(subscriber.committedLines.isEmpty)
        XCTAssertEqual(subscriber.liveSpokenText, "I don't want to talk.")

        subscriber.handlePartial("I don't want to talk.")
        XCTAssertEqual(subscriber.committedLines, ["I don't want to talk."])

        subscriber.handlePartial("I don't want to talk about it.")
        XCTAssertEqual(subscriber.committedLines, ["I don't want to talk."])
        XCTAssertFalse(subscriber.committedLines.contains("I don't want to talk about it."))
    }

    func testFinishedSentencesPrintWhileTheOpenTailStaysOff() async {
        let settings = SettingsStore.shared
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        let originalMode = settings.theaterSessionMode
        defer {
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
            settings.theaterSessionMode = originalMode
        }
        settings.theaterSessionMode = .transcription
        settings.translationSourceLanguageID = "en"
        settings.translationTargetLanguageID = "en"

        let engine = FakeTranslationEngine()
        engine.result = .success("번역")
        let subscriber = LiveTranslationSubscriber(translator: engine)
        subscriber.beginListening()

        await MockASRPartialStream.play(
            ticks: [
                "Today we",
                "Today we trained the model.",
                "Today we trained the model. Then we applied it.",
                "Today we trained the model. Then we applied it. And we shipped it",
            ],
            intervalNanoseconds: 0,
            into: subscriber
        )

        XCTAssertTrue(engine.calls.isEmpty)
        XCTAssertTrue(subscriber.pendingSpokenLines.isEmpty)
        XCTAssertEqual(
            subscriber.committedSourceLines,
            ["Today we trained the model.", "Then we applied it."]
        )
        XCTAssertEqual(
            subscriber.committedLines,
            ["Today we trained the model.", "Then we applied it."]
        )
        XCTAssertEqual(subscriber.liveSpokenText, "And we shipped it")
        XCTAssertEqual(subscriber.inFlightCaptionCount, 0)
        XCTAssertFalse(
            TheaterCaptionFlow.lines(
                board: .make(
                    translated: subscriber.committedLines,
                    sources: subscriber.committedSourceLines,
                    ids: subscriber.committedLineIDs
                )
            ).contains { $0.isDraft }
        )
    }
}
