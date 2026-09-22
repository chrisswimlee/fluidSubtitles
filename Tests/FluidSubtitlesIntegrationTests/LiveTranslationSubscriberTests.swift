import XCTest
@testable import FluidSubtitles_Debug

@MainActor
final class FakeTranslationEngine: TranslationEngine {
    let name = "Fake"
    var result: Result<String, Error> = .success("translated")
    var delayNanoseconds: UInt64 = 0
    var calls: [String] = []
    var resultsByText: [String: String] = [:]
    var resultQueue: [Result<String, Error>] = []
    private(set) var currentInFlight = 0
    private(set) var maxInFlight = 0

    func translate(
        _ text: String,
        source: TranslationLanguage,
        target: TranslationLanguage
    ) async throws -> String {
        self.currentInFlight += 1
        self.maxInFlight = max(self.maxInFlight, self.currentInFlight)
        defer { self.currentInFlight -= 1 }
        self.calls.append(text)
        if self.delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: self.delayNanoseconds)
        }
        if let mapped = self.resultsByText[text] {
            return mapped
        }
        if !self.resultQueue.isEmpty {
            return try self.resultQueue.removeFirst().get()
        }
        return try self.result.get()
    }
}

@MainActor
final class LiveTranslationSubscriberTests: XCTestCase {
    /// The test host shares UserDefaults with the Debug app. A talk left in
    /// Voice must not turn every EN→KO case here into a same-language one.
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

    func testEngineErrorStringDoesNotLandOnTheBoard() async {
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
        engine.result = .success("Error: quota exceeded")
        let subscriber = LiveTranslationSubscriber(translator: engine)
        subscriber.seedCommittedForTesting(source: "Yesterday.", translated: "어제.")
        subscriber.beginListening()
        let output = await subscriber.translateFinal("Today we trained the model.")
        XCTAssertEqual(subscriber.committedLines, ["어제."])
        XCTAssertTrue(subscriber.canRetryTranslation)
        XCTAssertTrue(subscriber.statusText.contains("Translation failed"))
        XCTAssertFalse(subscriber.committedLines.contains("Error: quota exceeded"))
        XCTAssertFalse(output.contains("Error: quota exceeded"))
        XCTAssertFalse(output.contains("quota exceeded"))
    }

    func testFailedTranslateDoesNotReplaceTheBoardWithSource() async {
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
        engine.result = .failure(TranslationEngineError(message: "pack missing"))
        let subscriber = LiveTranslationSubscriber(translator: engine)
        subscriber.seedCommittedForTesting(source: "Yesterday.", translated: "어제.")
        subscriber.beginListening()
        let output = await subscriber.translateFinal("Today we trained the model.")
        XCTAssertEqual(subscriber.committedLines, ["어제."])
        XCTAssertTrue(subscriber.canRetryTranslation)
        XCTAssertTrue(subscriber.statusText.contains("Translation failed"))
        XCTAssertTrue(output.isEmpty || !output.contains("Today we trained the model."))
    }

    func testBeginListeningDropsInFlightCommitsFromThePreviousListen() async {
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
        engine.delayNanoseconds = 250_000_000
        engine.result = .success("어제 번역")
        let subscriber = LiveTranslationSubscriber(translator: engine)
        let first = Task {
            await subscriber.translateFinal("Yesterday we trained the model.")
        }
        try? await Task.sleep(nanoseconds: 40_000_000)
        subscriber.beginListening()
        engine.result = .success("오늘 번역")
        engine.delayNanoseconds = 0
        let output = await subscriber.translateFinal("Today we measure it.")
        _ = await first.value
        XCTAssertFalse(subscriber.committedLines.contains("어제 번역"))
        XCTAssertEqual(output, "오늘 번역")
        XCTAssertEqual(subscriber.committedLines, ["오늘 번역"])
    }

    func testLostProtectedTermsKeepTheAppleDraft() {
        XCTAssertEqual(
            TranslationGlossary.lostProtectedTerms(
                source: "We are demoing fluidSubtitles today",
                polished: "We are demoing the app today",
                terms: ["fluidSubtitles"]
            ),
            ["fluidSubtitles"]
        )
    }

    func testBoardSnapshotRoundTripsCommittedLines() {
        let subscriber = LiveTranslationSubscriber(translator: FakeTranslationEngine())
        subscriber.seedCommittedForTesting(source: "Hello.", translated: "안녕.")
        let snapshot = subscriber.snapshot()
        subscriber.reset()
        XCTAssertTrue(subscriber.committedLines.isEmpty)
        subscriber.restore(snapshot)
        XCTAssertEqual(subscriber.committedLines, ["안녕."])
        XCTAssertEqual(subscriber.captionPairs.first?.source, "Hello.")
        XCTAssertNotNil(subscriber.exportCaptionPairs.first?.committedAt)
        XCTAssertNotEqual(subscriber.exportCaptionPairs.first?.committedAt, .distantPast)
    }

    func testBilingualAndTimedExports() {
        let pairs = [
            CaptionHistoryPair(source: "Hello.", translated: "안녕.", wasPolished: false),
            CaptionHistoryPair(source: "Next.", translated: "다음.", wasPolished: true),
        ]
        let text = TheaterCaptionExport.bilingualText(pairs: pairs)
        XCTAssertTrue(text.contains("안녕."))
        XCTAssertTrue(text.contains("Hello."))
        let srt = TheaterCaptionExport.srt(pairs: pairs)
        XCTAssertTrue(srt.contains("00:00:00,000 --> 00:00:04,000"))
        XCTAssertTrue(srt.contains("다음."))
        let vtt = TheaterCaptionExport.vtt(pairs: pairs)
        XCTAssertTrue(vtt.hasPrefix("WEBVTT"))
        XCTAssertTrue(vtt.contains("00:00:04.000 --> 00:00:08.000"))
    }

    func testHandlePartialPublishesLiveShowAsWithoutCommitting() async {
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
        engine.result = .success("안녕 세상")
        let subscriber = LiveTranslationSubscriber(translator: engine)
        subscriber.beginListening()
        subscriber.handlePartial("Hello world today")
        XCTAssertEqual(subscriber.sourceDraft, "Hello world today")
        XCTAssertTrue(subscriber.committedLines.isEmpty)

        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(engine.calls, ["Hello world today"])
        XCTAssertEqual(subscriber.liveCaptionText, "안녕 세상")
        XCTAssertTrue(subscriber.committedLines.isEmpty)
    }

    func testCommitTranslatesTheSettledLineOnce() async {
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
        engine.result = .success("안녕 세상")
        let subscriber = LiveTranslationSubscriber(translator: engine)
        subscriber.beginListening()
        subscriber.handlePartial("Hello world today")
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(engine.calls, ["Hello world today"])
        XCTAssertEqual(subscriber.liveCaptionText, "안녕 세상")
        let output = await subscriber.translateFinal("Hello world today.")
        XCTAssertEqual(engine.calls, ["Hello world today"])
        XCTAssertEqual(output, "안녕 세상")
        XCTAssertEqual(subscriber.committedLines, ["안녕 세상"])
    }

    func testLiveCaptionTextDoesNotRepeatTheLastCommittedLine() {
        let subscriber = LiveTranslationSubscriber(translator: FakeTranslationEngine())
        subscriber.seedCommittedForTesting(source: "Hello world today", translated: "안녕 세상")
        XCTAssertTrue(subscriber.liveCaptionText.isEmpty)
        subscriber.beginListening()
        XCTAssertTrue(subscriber.liveCaptionText.isEmpty)
    }

    func testTranslatePairingsKeepFinishedSentenceVisibleWhileTalking() {
        let settings = SettingsStore.shared
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        let originalMode = settings.theaterSessionMode
        defer {
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
            settings.theaterSessionMode = originalMode
        }
        settings.theaterSessionMode = .translation

        let cases: [(source: String, target: String, first: String, restitch: String)] = [
            ("en", "ko", "Today we trained the model.", "Today we trained the model. Then we applied it"),
            ("ko", "en", "오늘 모델을 학습했습니다.", "오늘 모델을 학습했습니다. 그다음 적용했습니다"),
            ("ja", "en", "今日はモデルを学習しました。", "今日はモデルを学習しました。次に適用しました"),
            ("th", "en", "วันนี้เราฝึกโมเดลแล้วครับ", "วันนี้เราฝึกโมเดลแล้วครับแล้วนำไปใช้ครับ"),
        ]

        for item in cases {
            settings.translationSourceLanguageID = item.source
            settings.translationTargetLanguageID = item.target
            let subscriber = LiveTranslationSubscriber(translator: FakeTranslationEngine())
            subscriber.beginListening()
            subscriber.handlePartial(item.first)
            subscriber.handlePartial(item.restitch)
            let midTalk = TranslationClauseSegmenter.nextCompletedSentence(
                item.restitch,
                languageID: item.source
            )
            if midTalk != nil {
                XCTAssertFalse(
                    subscriber.liveSpokenText.contains(item.first),
                    "\(item.source): finished sentence should peel off the live row"
                )
            } else {
                XCTAssertTrue(
                    subscriber.liveSpokenText.hasPrefix(item.first),
                    item.source
                )
            }
            XCTAssertFalse(subscriber.liveSpokenText.isEmpty, item.source)
            let rows = TheaterCaptionFlow.lines(
                committed: subscriber.committedLines,
                committedIDs: subscriber.committedLineIDs,
                nextCaptionID: subscriber.nextCaptionID,
                committedSources: subscriber.committedSourceLines,
                draft: subscriber.liveCaptionText,
                sourceDraft: subscriber.liveSpokenText,
                pendingSources: subscriber.pendingSpokenLines,
                spokenDisplay: .paired
            )
            if midTalk != nil {
                // Finished speech may be pending or in flight, but the board
                // only paints accepted captions — unread stays invisible.
                XCTAssertFalse(
                    rows.contains { $0.isDraft },
                    item.source
                )
                XCTAssertFalse(
                    rows.contains { $0.source.contains(item.first) && $0.isDraft },
                    item.source
                )
            }
        }
    }

    func testCommittedKoreanIsDroppedFromTheNextLiveLine() {
        let subscriber = LiveTranslationSubscriber(translator: FakeTranslationEngine())
        subscriber.seedCommittedForTesting(
            source: "저는 모델을 학습했습니다",
            translated: "I trained the model."
        )
        XCTAssertTrue(subscriber.liveCaptionText.isEmpty)
        XCTAssertTrue(subscriber.liveSpokenText.isEmpty)

        // Two decodes must agree before a mid-talk commit: the first tick
        // of a Listen confirms nothing.
        subscriber.handlePartial("저는 모델을 학습했습니다그걸 적용하면")
        subscriber.handlePartial("저는 모델을 학습했습니다그걸 적용하면")
        XCTAssertEqual(subscriber.sourceDraft, "그걸 적용하면")
        XCTAssertEqual(subscriber.liveSpokenText, "그걸 적용하면")
        XCTAssertTrue(subscriber.liveCaptionText.isEmpty)
    }

    func testMidTalkPeriodDoesNotClearTheLiveLine() async {
        let subscriber = LiveTranslationSubscriber(translator: FakeTranslationEngine())
        subscriber.beginListening()
        subscriber.handlePartial("Today we trained the model.")
        XCTAssertEqual(subscriber.liveSpokenText, "Today we trained the model.")
        try? await Task.sleep(
            nanoseconds: LiveTranslationTiming.completeSettleNanoseconds(languageID: "en") + 200_000_000
        )
        await subscriber.waitForIdleForTesting()
        XCTAssertEqual(subscriber.liveSpokenText, "Today we trained the model.")
        XCTAssertTrue(subscriber.committedLines.isEmpty)
    }

    func testCaptionEnterPathGrowsOnePairWithoutBlanking() {
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

        let ticks = [
            "Today we",
            "Today we trained",
            "Today we trained the model.",
        ]
        for tick in ticks {
            subscriber.handlePartial(tick)
            XCTAssertTrue(subscriber.committedLines.isEmpty, tick)
            XCTAssertEqual(subscriber.pendingSpokenLines, [])

            let rows = TheaterCaptionFlow.lines(
                committed: subscriber.committedLines,
                committedIDs: subscriber.committedLineIDs,
                nextCaptionID: subscriber.nextCaptionID,
                committedSources: subscriber.committedSourceLines,
                draft: subscriber.liveCaptionText,
                sourceDraft: subscriber.liveSpokenText,
                pendingSources: subscriber.pendingSpokenLines,
                spokenDisplay: .isTheCaption
            )
            XCTAssertTrue(rows.isEmpty, tick)
            XCTAssertTrue(
                subscriber.liveSpokenText.hasPrefix("Today we"),
                "Spoken leftover should keep the opening words on \(tick)"
            )
        }

        subscriber.handlePartial("Today we trained the model. Then we applied it")
        XCTAssertEqual(subscriber.liveSpokenText, "Then we applied it")
        // Voice writes the finished sentence now. The live row is only
        // the next sentence — no pending flash while a translation waits.
        XCTAssertTrue(subscriber.pendingSpokenLines.isEmpty)
        XCTAssertEqual(subscriber.committedSourceLines, ["Today we trained the model."])
        XCTAssertEqual(subscriber.committedLines, ["Today we trained the model."])
    }

    func testVoiceWritesEachFinishedSentenceImmediately() {
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
        let spoken = "Today we trained the model. Then we applied it"
        subscriber.handlePartial(spoken)
        subscriber.handlePartial(spoken)
        XCTAssertTrue(engine.calls.isEmpty)
        XCTAssertTrue(subscriber.pendingSpokenLines.isEmpty)
        XCTAssertEqual(subscriber.committedSourceLines, ["Today we trained the model."])
        XCTAssertEqual(subscriber.committedLines, ["Today we trained the model."])
        XCTAssertEqual(subscriber.liveSpokenText, "Then we applied it")

        let rows = TheaterCaptionFlow.lines(
            committed: subscriber.committedLines,
            committedIDs: subscriber.committedLineIDs,
            nextCaptionID: subscriber.nextCaptionID,
            committedSources: subscriber.committedSourceLines,
            draft: subscriber.liveCaptionText,
            sourceDraft: subscriber.liveSpokenText,
            pendingSources: subscriber.pendingSpokenLines,
            spokenDisplay: .isTheCaption
        )
        XCTAssertEqual(rows.map(\.text), ["Today we trained the model."])
        XCTAssertFalse(rows.contains { $0.isDraft })
        XCTAssertEqual(subscriber.liveSpokenText, "Then we applied it")

        let next = "Today we trained the model. Then we applied it. And we shipped it"
        subscriber.handlePartial(next)
        subscriber.handlePartial(next)
        XCTAssertTrue(subscriber.pendingSpokenLines.isEmpty)
        XCTAssertEqual(
            subscriber.committedSourceLines,
            ["Today we trained the model.", "Then we applied it."]
        )
        XCTAssertEqual(subscriber.liveSpokenText, "And we shipped it")
    }

    /// A lagged restitch may accept every finished Voice clause in one tick.
    /// The unread leftover stays off the board until it commits.
    func testVoiceLaggedRestitchAppendsFinishedClausesAndHidesUnread() {
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
        let spoken =
            "Today we trained the model. Then we applied it. And we shipped it. Later the room went quiet"
        subscriber.handlePartial(spoken)
        XCTAssertTrue(subscriber.committedLines.isEmpty)
        XCTAssertEqual(subscriber.liveSpokenText, "Today we trained the model.")
        XCTAssertFalse(subscriber.liveSpokenText.contains("Then we applied"))
        XCTAssertFalse(subscriber.liveSpokenText.contains("And we shipped"))

        subscriber.handlePartial(spoken)
        XCTAssertTrue(subscriber.pendingSpokenLines.isEmpty)
        XCTAssertEqual(
            subscriber.committedSourceLines,
            [
                "Today we trained the model.",
                "Then we applied it.",
                "And we shipped it.",
            ]
        )
        XCTAssertEqual(subscriber.committedLines, subscriber.committedSourceLines)
        XCTAssertEqual(subscriber.liveSpokenText, "Later the room went quiet")

        let rows = TheaterCaptionFlow.lines(
            committed: subscriber.committedLines,
            committedIDs: subscriber.committedLineIDs,
            nextCaptionID: subscriber.nextCaptionID,
            committedSources: subscriber.committedSourceLines,
            draft: subscriber.liveCaptionText,
            sourceDraft: subscriber.liveSpokenText,
            pendingSources: subscriber.pendingSpokenLines,
            spokenDisplay: .isTheCaption
        )
        XCTAssertEqual(rows.map(\.text), subscriber.committedLines)
        XCTAssertFalse(rows.contains { $0.isDraft })
        XCTAssertFalse(rows.contains { $0.text.contains("Later the room") })
    }

    func testVoiceLaggedRestitchCatchUpPrintsTheRestAfterAPause() async {
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
        let spoken = "Today we trained the model. Then we applied it. And we shipped it."
        subscriber.handlePartial(spoken)
        subscriber.handlePartial(spoken)
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
                "And we shipped it.",
            ]
        )
        XCTAssertTrue(subscriber.liveSpokenText.isEmpty)
    }

    func testVoicePairingsWriteFinishedSentenceImmediately() {
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

        let cases: [(id: String, first: String, restitch: String)] = [
            ("en", "Today we trained the model.", "Today we trained the model. Then we applied it"),
            ("ko", "오늘 모델을 학습했습니다.", "오늘 모델을 학습했습니다. 그다음 적용했습니다"),
            ("ja", "今日はモデルを学習しました。", "今日はモデルを学習しました。次に適用しました"),
            ("th", "วันนี้เราฝึกโมเดลแล้วครับ", "วันนี้เราฝึกโมเดลแล้วครับหลังจากนั้นนำไปใช้ครับ"),
        ]

        for item in cases {
            settings.translationSourceLanguageID = item.id
            settings.translationTargetLanguageID = item.id
            let subscriber = LiveTranslationSubscriber(translator: FakeTranslationEngine())
            subscriber.beginListening()
            subscriber.handlePartial(item.first)
            subscriber.handlePartial(item.restitch)
            guard let midTalk = TranslationClauseSegmenter.nextCompletedSentence(
                item.restitch,
                languageID: item.id
            ) else {
                XCTAssertTrue(
                    subscriber.liveSpokenText.hasPrefix(item.first),
                    item.id
                )
                continue
            }
            XCTAssertTrue(subscriber.pendingSpokenLines.isEmpty, item.id)
            XCTAssertEqual(subscriber.committedSourceLines, [midTalk.unit], item.id)
            XCTAssertEqual(subscriber.committedLines, [midTalk.unit], item.id)
            XCTAssertEqual(subscriber.liveSpokenText, midTalk.rest, item.id)
        }
    }

    func testEmptyStopStillCommitsLeftoverSpeech() async {
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
        subscriber.handlePartial("Today we trained the model and then we measured it carefully.")
        let text = await subscriber.translateFinal("")
        XCTAssertFalse(
            subscriber.committedLines.isEmpty,
            "Empty ASR Stop must still print leftover speech"
        )
        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testSpokenLeftoverGrowsBeforeTheClauseCommits() {
        let subscriber = LiveTranslationSubscriber(translator: FakeTranslationEngine())
        subscriber.beginListening()
        subscriber.handlePartial("Hello")
        XCTAssertEqual(subscriber.sourceDraft, "Hello")
        XCTAssertEqual(subscriber.liveSpokenText, "Hello")
        subscriber.handlePartial("Hello we trained")
        XCTAssertEqual(subscriber.sourceDraft, "Hello we trained")
        XCTAssertEqual(subscriber.liveSpokenText, "Hello we trained")
        subscriber.handlePartial("")
        XCTAssertEqual(subscriber.sourceDraft, "Hello we trained")
        XCTAssertTrue(subscriber.committedLines.isEmpty)
        XCTAssertTrue(subscriber.liveCaptionText.isEmpty)
        XCTAssertEqual(subscriber.statusText, "Listening…")
    }

    func testLiveSpokenTextPrintsBeforeTheCommitGate() {
        let subscriber = LiveTranslationSubscriber(translator: FakeTranslationEngine())
        subscriber.beginListening()
        subscriber.handlePartial("It was")
        XCTAssertEqual(subscriber.liveSpokenText, "It was")
        XCTAssertTrue(TranslationClauseSegmenter.isTooThinToCommit("It was", languageID: "en"))
        XCTAssertTrue(subscriber.committedLines.isEmpty)
        subscriber.handlePartial("It.")
        XCTAssertTrue(TranslationClauseSegmenter.isTooThinToCommit("It.", languageID: "en"))
        XCTAssertTrue(subscriber.committedLines.isEmpty)
    }

    func testJammedSentencesPinTheFirstClauseAndShowTheNextWhileTalking() async {
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
        let jammed =
            "Today we trained the model.Then we applied it.And we shipped it to production."
        subscriber.handlePartial(jammed)
        subscriber.handlePartial(jammed)
        XCTAssertEqual(subscriber.liveSpokenText, "And we shipped it to production.")
        // Both finished sentences are enqueued and must stay visible while
        // their translations resolve.
        XCTAssertEqual(
            subscriber.pendingSpokenLines,
            ["Today we trained the model.", "Then we applied it."]
        )
        await subscriber.waitForIdleForTesting()
        XCTAssertEqual(
            subscriber.committedSourceLines,
            ["Today we trained the model.", "Then we applied it."]
        )
        XCTAssertEqual(subscriber.committedLines, ["번역", "번역"])

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
    }

    /// Fast speech used to wait for each title to land before the next
    /// sentence even entered Apple Translation. Four spoken lines then sat
    /// until the speaker paused.
    func testFastSpeechStartsTheNextTranslationBeforeTheLastCaptionLands() async {
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
        engine.delayNanoseconds = 180_000_000
        engine.result = .success("번역")
        let subscriber = LiveTranslationSubscriber(translator: engine)
        subscriber.beginListening()
        let spoken =
            "Today we trained the model. Then we applied it. And we shipped it. Later the room went quiet"
        subscriber.handlePartial(spoken)
        subscriber.handlePartial(spoken)
        XCTAssertGreaterThanOrEqual(subscriber.pendingSpokenLines.count, 2)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.3
        while engine.maxInFlight < 2, ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThanOrEqual(
            engine.maxInFlight,
            2,
            "the next sentence must start translating before the last caption lands"
        )
        await subscriber.waitForIdleForTesting()
        XCTAssertEqual(
            subscriber.committedSourceLines,
            [
                "Today we trained the model.",
                "Then we applied it.",
                "And we shipped it.",
            ]
        )
        XCTAssertEqual(subscriber.liveSpokenText, "Later the room went quiet")

        let rows = TheaterCaptionFlow.lines(
            committed: subscriber.committedLines,
            committedIDs: subscriber.committedLineIDs,
            nextCaptionID: subscriber.nextCaptionID,
            committedSources: subscriber.committedSourceLines,
            draft: subscriber.liveCaptionText,
            sourceDraft: subscriber.liveSpokenText,
            pendingSources: subscriber.pendingSpokenLines,
            spokenDisplay: .paired
        )
        XCTAssertFalse(rows.contains { $0.isDraft })
        XCTAssertEqual(rows.map(\.text), subscriber.committedLines)
        XCTAssertEqual(subscriber.liveSpokenText, "Later the room went quiet")
    }

    func testRestitchAfterACommitDoesNotPrintTheWholeTalk() async {
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
        subscriber.seedCommittedForTesting(
            source: "Today we trained the model.",
            translated: "오늘 모델을 학습했습니다."
        )
        // Two decodes must agree before a mid-talk commit: the first tick
        // of a Listen confirms nothing.
        subscriber.handlePartial(
            "Today we trained the model. Then we applied it. And we shipped it to production."
        )
        subscriber.handlePartial(
            "Today we trained the model. Then we applied it. And we shipped it to production."
        )
        XCTAssertEqual(subscriber.liveSpokenText, "And we shipped it to production.")
        // The already-committed sentence is peeled off, but the newly
        // finished "Then we applied it." is enqueued and must stay visible.
        XCTAssertEqual(subscriber.pendingSpokenLines, ["Then we applied it."])
        XCTAssertEqual(subscriber.sourceDraft, "And we shipped it to production.")
        XCTAssertFalse(subscriber.sourceDraft.contains("Today we trained"))
        XCTAssertFalse(subscriber.liveSpokenText.contains("Today we trained the model."))
        XCTAssertFalse(subscriber.liveSpokenText.contains("Then we applied"))
    }

    func testSharedLastWordDoesNotEraseTheNextClause() {
        let subscriber = LiveTranslationSubscriber(translator: FakeTranslationEngine())
        subscriber.seedCommittedForTesting(
            source: "Today we trained the model.",
            translated: "오늘 모델을 학습했습니다."
        )
        // Two decodes must agree before a mid-talk commit: the first tick
        // of a Listen confirms nothing.
        subscriber.handlePartial("The model is ready for production use today")
        subscriber.handlePartial("The model is ready for production use today")
        XCTAssertEqual(
            subscriber.sourceDraft,
            "The model is ready for production use today"
        )
        XCTAssertEqual(subscriber.liveSpokenText, "The model is ready for production use today")
        XCTAssertEqual(subscriber.committedLines.count, 1)
    }

    func testThreeSentenceRestitchCommitsOneClauseAtATime() async {
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
        let spoken = "Today we trained the model. Then we applied it. And we shipped it."
        // Two decodes must agree before a mid-talk commit: the first tick
        // of a Listen confirms nothing.
        subscriber.handlePartial(spoken)
        subscriber.handlePartial(spoken)
        XCTAssertEqual(subscriber.liveSpokenText, "And we shipped it.")
        XCTAssertEqual(
            subscriber.pendingSpokenLines,
            ["Today we trained the model.", "Then we applied it."]
        )
        await subscriber.waitForIdleForTesting()
        XCTAssertEqual(
            subscriber.committedSourceLines,
            ["Today we trained the model.", "Then we applied it."]
        )
        XCTAssertEqual(subscriber.liveSpokenText, "And we shipped it.")

        subscriber.handleEndOfUtterance()
        await subscriber.waitForIdleForTesting()
        XCTAssertEqual(
            subscriber.committedSourceLines,
            [
                "Today we trained the model.",
                "Then we applied it.",
                "And we shipped it.",
            ]
        )
        XCTAssertTrue(subscriber.liveSpokenText.isEmpty)
    }

    func testStopConfirmRevisesTheLastClauseAfterTheBoardHasLines() async {
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
        subscriber.seedCommittedForTesting(
            source: "Today we trained the model.",
            translated: "오늘 모델을 학습했습니다."
        )
        subscriber.markAllPosted()
        subscriber.confirmTranscript = {
            "Today we trained the model. Then we applied it to production."
        }
        _ = await subscriber.translateFinal(
            "Today we trained the model. Then we applied it."
        )
        XCTAssertEqual(
            subscriber.committedSourceLines.first,
            "Today we trained the model."
        )
        XCTAssertFalse(
            subscriber.committedSourceLines.contains("Today we trained the model. Then we applied it to production.")
        )
    }

    func testStopConfirmKeepsTheStreamingLeftoverWhenTheFullerPassIsShorter() async {
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
        subscriber.seedCommittedForTesting(
            source: "Today we trained the model.",
            translated: "오늘 모델을 학습했습니다."
        )
        subscriber.markAllPosted()
        subscriber.confirmTranscript = {
            "Today we trained"
        }
        let output = await subscriber.translateFinal(
            "Today we trained the model. Then we applied it."
        )
        let current = "Then we applied it."
        let payload = TranslationClauseSegmenter.joinTranslatedLines(
            ["Today we trained the model.", current],
            languageID: "en"
        )
        XCTAssertEqual(engine.calls, [payload, current])
        XCTAssertEqual(output, "번역")
    }

    func testPauseConfirmLeavesTheLastCommittedLine() async {
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
        engine.result = .success("고친 번역")
        let subscriber = LiveTranslationSubscriber(translator: engine)
        subscriber.seedCommittedForTesting(
            source: "Today we trained the modal.",
            translated: "오늘 모델을 학습했습니다."
        )
        subscriber.beginListening()
        subscriber.handlePartial("Today we trained the modal.")
        subscriber.confirmTranscript = {
            "Today we trained the model."
        }
        subscriber.noteSilenceHold()
        subscriber.noteSilenceHold()
        await subscriber.waitForIdleForTesting()
        XCTAssertEqual(subscriber.committedSourceLines.last, "Today we trained the modal.")
        XCTAssertEqual(subscriber.committedLines.last, "오늘 모델을 학습했습니다.")
        XCTAssertTrue(engine.calls.isEmpty)

        subscriber.confirmTranscript = {
            "Today we trained the model. Then we applied it."
        }
        subscriber.handlePartial("Today we trained the modal. Then we applied it.")
        XCTAssertEqual(subscriber.liveSpokenText, "Then we applied it.")
        XCTAssertFalse(subscriber.sourceDraft.contains("Today we trained"))
        subscriber.noteSilenceHold()
        await subscriber.waitForIdleForTesting()
        XCTAssertEqual(
            subscriber.committedSourceLines,
            ["Today we trained the modal.", "Then we applied it."]
        )
    }

    func testStageFixturesCommitOneCaptionPerLanguage() async {
        let settings = SettingsStore.shared
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        defer {
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
        }

        for fixture in TheaterQualityScore.stageLanguages {
            settings.translationSourceLanguageID = fixture.languageID
            settings.translationTargetLanguageID = fixture.languageID
            let split = TranslationClauseSegmenter.split(fixture.spoken, languageID: fixture.languageID)
            XCTAssertEqual(
                split.completed.first ?? split.tail,
                fixture.expectedUnit,
                "\(fixture.languageID) should be one finished clause"
            )

            let engine = FakeTranslationEngine()
            engine.result = .success("should-not-run")
            let subscriber = LiveTranslationSubscriber(translator: engine)
            subscriber.beginListening()
            let output = await subscriber.translateFinal(fixture.spoken)
            XCTAssertTrue(engine.calls.isEmpty)
            XCTAssertEqual(output, fixture.expectedUnit)
            XCTAssertEqual(subscriber.committedLines, [fixture.expectedUnit])
            XCTAssertTrue(
                TheaterQualityScore.isStageAcceptable(
                    reference: fixture.expectedUnit,
                    hypothesis: subscriber.committedLines.last ?? "",
                    languageID: fixture.languageID
                )
            )
        }
    }

    func testSameLanguagePrintsTheSpokenSentenceWithoutMT() async {
        let settings = SettingsStore.shared
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        defer {
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
        }
        settings.translationSourceLanguageID = "en"
        settings.translationTargetLanguageID = "en"

        let engine = FakeTranslationEngine()
        engine.result = .success("translated")
        let subscriber = LiveTranslationSubscriber(translator: engine)
        subscriber.beginListening()
        let output = await subscriber.translateFinal("Today we trained the model.")
        XCTAssertTrue(engine.calls.isEmpty)
        XCTAssertEqual(output, "Today we trained the model.")
        XCTAssertEqual(subscriber.committedLines, ["Today we trained the model."])
        XCTAssertFalse(subscriber.statusText.contains("Translating"))
        XCTAssertEqual(
            TheaterCaptionExport.bilingualText(pairs: subscriber.captionPairs),
            "Today we trained the model."
        )
    }

    func testIsolatedFirstClauseTranslatesWithoutPriorContext() async {
        let settings = SettingsStore.shared
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        defer {
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
        }
        settings.translationSourceLanguageID = "ko"
        settings.translationTargetLanguageID = "en"

        let engine = FakeTranslationEngine()
        engine.result = .success("I trained the model.")
        let subscriber = LiveTranslationSubscriber(translator: engine)
        subscriber.beginListening()
        let source = "저는 모델을 학습했습니다."
        let output = await subscriber.translateFinal(source)
        XCTAssertEqual(engine.calls, [source])
        XCTAssertEqual(output, "I trained the model.")
        XCTAssertEqual(subscriber.committedLines, ["I trained the model."])
    }

    func testSecondKoreanEnglishClauseSendsPriorSourceThenPeelsTheNewCaption() async {
        let settings = SettingsStore.shared
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        defer {
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
        }
        settings.translationSourceLanguageID = "ko"
        settings.translationTargetLanguageID = "en"

        let priorSource = "저는 모델을 학습했습니다."
        let currentSource = "그걸 적용했습니다."
        let payload = TranslationClauseSegmenter.joinTranslatedLines(
            [priorSource, currentSource],
            languageID: "ko"
        )
        XCTAssertEqual(payload, "저는 모델을 학습했습니다.그걸 적용했습니다.")

        let engine = FakeTranslationEngine()
        engine.resultsByText[payload] = "I trained the model. I applied it."
        engine.result = .success("should-not-fallback")
        let subscriber = LiveTranslationSubscriber(translator: engine)
        subscriber.beginListening()
        subscriber.seedCommittedForTesting(
            source: priorSource,
            translated: "I trained the model."
        )
        subscriber.markAllPosted()
        let output = await subscriber.translateFinal(currentSource)
        XCTAssertEqual(engine.calls, [payload])
        XCTAssertEqual(output, "I applied it.")
        XCTAssertEqual(subscriber.committedLines, ["I trained the model.", "I applied it."])
        XCTAssertFalse(subscriber.committedLines.last?.contains("I trained") ?? true)
        XCTAssertEqual(subscriber.exportCaptionPairs.map(\.source), [priorSource, currentSource])
        XCTAssertEqual(
            subscriber.exportCaptionPairs.map(\.translated),
            ["I trained the model.", "I applied it."]
        )
        XCTAssertEqual(subscriber.exportCaptionPairs.map(\.wasPolished), [false, false])
    }

    func testUnpeelableContextualBlobFallsBackToIsolatedTranslate() async {
        let settings = SettingsStore.shared
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        defer {
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
        }
        settings.translationSourceLanguageID = "ko"
        settings.translationTargetLanguageID = "en"

        let priorSource = "저는 모델을 학습했습니다."
        let currentSource = "그걸 적용했습니다."
        let payload = TranslationClauseSegmenter.joinTranslatedLines(
            [priorSource, currentSource],
            languageID: "ko"
        )
        let engine = FakeTranslationEngine()
        engine.resultsByText[payload] = "UNPEELABLE BLOB"
        engine.resultsByText[currentSource] = "I applied it."
        let subscriber = LiveTranslationSubscriber(translator: engine)
        subscriber.beginListening()
        subscriber.seedCommittedForTesting(
            source: priorSource,
            translated: "I trained the model."
        )
        subscriber.markAllPosted()
        let output = await subscriber.translateFinal(currentSource)
        XCTAssertEqual(engine.calls, [payload, currentSource])
        XCTAssertEqual(output, "I applied it.")
        XCTAssertEqual(subscriber.committedLines.last, "I applied it.")
        XCTAssertEqual(subscriber.committedLines.count, 2)
    }

    func testPrefetchPicksACompletedClauseAndKeysByPriorContext() {
        XCTAssertTrue(
            TranslationClauseSegmenter.isGrowingClause(
                "Hey, how are you doing?",
                toward: "Hey, how are you doing today?"
            )
        )
        XCTAssertTrue(
            TranslationClauseSegmenter.isLivePrefetchMatch(
                unit: "Hey, how are you doing?",
                leftover: "Hey, how are you doing today?",
                languageID: "en"
            )
        )
        XCTAssertFalse(
            TranslationClauseSegmenter.isLivePrefetchMatch(
                unit: "Hi, man.",
                leftover: "Hi, man. Hi, my name is Chris. How are you doing?",
                languageID: "en"
            )
        )
        XCTAssertEqual(
            LiveTranslationPrefetch.unitToPrefetch(
                leftover: "Today we trained the model. Then we applied it",
                languageID: "en"
            ),
            TranslationClauseSegmenter.liveOpenText(
                "Today we trained the model. Then we applied it",
                languageID: "en"
            )
        )
        XCTAssertEqual(
            LiveTranslationPrefetch.unitToPrefetch(
                leftover: "Hello world today",
                languageID: "en"
            ),
            "Hello world today"
        )
        XCTAssertNil(
            LiveTranslationPrefetch.unitToPrefetch(
                leftover: "Hello",
                languageID: "en"
            )
        )
        XCTAssertEqual(
            LiveTranslationPrefetch.unitToPrefetch(
                leftover: "Hello",
                languageID: "en",
                wordByWord: true
            ),
            "Hello"
        )
        XCTAssertEqual(
            LiveTranslationPrefetch.unitToPrefetch(
                leftover: "안녕",
                languageID: "ko",
                wordByWord: true
            ),
            "안녕"
        )
        let key = LiveTranslationPrefetch.cacheKey(
            unit: "Today we measure it.",
            priorSources: ["Today we trained the model."],
            sourceID: "en",
            targetID: "ko"
        )
        let cache = LiveTranslationPrefetchCache()
        XCTAssertNil(cache.caption(for: key))
        let generation = cache.begin(key)
        XCTAssertNotNil(generation)
        cache.finish(key, caption: "오늘 측정합니다.", generation: generation ?? 0)
        XCTAssertEqual(cache.caption(for: key), "오늘 측정합니다.")
        cache.invalidate()
        XCTAssertNil(cache.caption(for: key))

        let short = LiveTranslationPrefetch.cacheKey(
            unit: "Hello I am talking",
            priorSources: [],
            sourceID: "en",
            targetID: "ko"
        )
        let long = LiveTranslationPrefetch.cacheKey(
            unit: "Hello I am talking today",
            priorSources: [],
            sourceID: "en",
            targetID: "ko"
        )
        XCTAssertTrue(LiveTranslationPrefetch.isPrefixGrowth(from: short, to: long))
        XCTAssertFalse(
            LiveTranslationPrefetch.canPrefetch(
                unit: "Hello I am talking today",
                inFlightSources: ["Hello I am talking today"]
            )
        )
        let growth = LiveTranslationPrefetchCache()
        let shortGeneration = growth.begin(short)
        XCTAssertNotNil(shortGeneration)
        XCTAssertNil(growth.begin(long), "a growing leftover must not cancel the prefix prefetch")
        growth.finish(short, caption: "안녕, 말하는 중이야", generation: shortGeneration ?? 0)
        XCTAssertEqual(growth.caption(for: long), "안녕, 말하는 중이야")
        XCTAssertNotNil(growth.begin(long))
    }

    func testCumulativeASRPrintsOnlyTheNewSentence() async {
        let settings = SettingsStore.shared
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        defer {
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
        }
        settings.translationSourceLanguageID = "en"
        settings.translationTargetLanguageID = "en"

        let subscriber = LiveTranslationSubscriber(translator: FakeTranslationEngine())
        subscriber.beginListening()
        subscriber.handlePartial("First sentence is ready.")
        XCTAssertEqual(subscriber.liveSpokenText, "First sentence is ready.")
        subscriber.handleEndOfUtterance()
        await subscriber.waitForIdleForTesting()
        XCTAssertEqual(subscriber.committedLines, ["First sentence is ready."])
        XCTAssertEqual(subscriber.committedSourceLines, ["First sentence is ready."])

        subscriber.handlePartial("First sentence is ready. Second sentence is next.")
        XCTAssertEqual(subscriber.liveSpokenText, "Second sentence is next.")
        subscriber.handleEndOfUtterance()
        await subscriber.waitForIdleForTesting()
        XCTAssertEqual(
            subscriber.committedSourceLines,
            ["First sentence is ready.", "Second sentence is next."]
        )
        XCTAssertEqual(
            subscriber.committedLines,
            ["First sentence is ready.", "Second sentence is next."]
        )

        subscriber.handlePartial(
            "First sentence is ready. Second sentence is next. Third sentence is last."
        )
        subscriber.handleEndOfUtterance()
        await subscriber.waitForIdleForTesting()
        XCTAssertEqual(subscriber.committedSourceLines.count, 3)
        XCTAssertEqual(subscriber.committedSourceLines.last, "Third sentence is last.")
        XCTAssertFalse(
            subscriber.committedLines.contains {
                $0.contains("First sentence is ready. Second")
            }
        )
    }

    func testLongListenKeepsContextAndDoesNotReprintOffscreenSpeech() async {
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

        let sentences = [
            "First sentence is ready.",
            "Second sentence is next.",
            "Third sentence is last.",
            "Fourth sentence is extra.",
            "Fifth sentence is later.",
        ]
        let subscriber = LiveTranslationSubscriber(translator: FakeTranslationEngine())
        subscriber.startSessionRecord()
        subscriber.beginListening()
        var spoken = ""
        for sentence in sentences {
            spoken = spoken.isEmpty ? sentence : spoken + " " + sentence
            _ = await subscriber.translateFinal(spoken)
        }

        XCTAssertEqual(
            subscriber.committedSourceLines,
            Array(sentences.suffix(LiveTranslationTiming.maxCommittedLines))
        )
        XCTAssertEqual(subscriber.exportCaptionPairs.map(\.source), sentences)
        XCTAssertEqual(
            subscriber.priorClausesForTesting(incoming: "Sixth sentence is new.").sources,
            Array(sentences.suffix(LiveTranslationTiming.contextSentenceCount))
        )

        subscriber.handlePartial(spoken + " Sixth sentence is new.")
        XCTAssertEqual(subscriber.liveSpokenText, "Sixth sentence is new.")
        XCTAssertFalse(subscriber.liveSpokenText.contains("First sentence is ready."))

        _ = await subscriber.translateFinal(spoken + " Sixth sentence is new.")
        XCTAssertEqual(subscriber.committedSourceLines.last, "Sixth sentence is new.")
        XCTAssertEqual(subscriber.committedSourceLines.first, "First sentence is ready.")
        XCTAssertEqual(subscriber.exportCaptionPairs.map(\.source).count, 6)
        XCTAssertEqual(subscriber.exportCaptionPairs.map(\.source).last, "Sixth sentence is new.")
    }

    func testListenHistoryDropsClausesOlderThanTheSlidingWindow() async {
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

        let cap = LiveTranslationTiming.maxListenHistory
        XCTAssertEqual(cap, LiveTranslationTiming.contextSentenceCount + LiveTranslationTiming.peelWindowLines)
        let sentences = [
            "First sentence is ready.",
            "Second sentence is next.",
            "Third sentence is last.",
            "Fourth sentence is extra.",
            "Fifth sentence is later.",
            "Sixth sentence is new.",
            "Seventh sentence is added.",
            "Eighth sentence is spoken.",
            "Ninth sentence is heard.",
            "Tenth sentence is finished.",
            "Eleventh sentence is closed.",
            "Twelfth sentence is later.",
            "Thirteenth sentence is added.",
            "Fourteenth sentence is spoken.",
            "Fifteenth sentence is heard.",
            "Sixteenth sentence is finished.",
            "Seventeenth sentence is closed.",
        ]
        XCTAssertGreaterThan(sentences.count, cap)
        let subscriber = LiveTranslationSubscriber(translator: FakeTranslationEngine())
        subscriber.startSessionRecord()
        subscriber.beginListening()
        var spoken = ""
        for sentence in sentences {
            spoken = spoken.isEmpty ? sentence : spoken + " " + sentence
            _ = await subscriber.translateFinal(spoken)
        }

        XCTAssertEqual(subscriber.listenHistoryCountForTesting, cap)
        XCTAssertEqual(
            subscriber.priorClausesForTesting(incoming: "Eighteenth sentence is leftover.").sources,
            Array(sentences.suffix(LiveTranslationTiming.contextSentenceCount))
        )
        XCTAssertFalse(
            subscriber.priorClausesForTesting(incoming: "Eighteenth sentence is leftover.").sources.contains(sentences[0])
        )
        subscriber.handlePartial(spoken + " Eighteenth sentence is leftover.")
        XCTAssertEqual(subscriber.liveSpokenText, "Eighteenth sentence is leftover.")
        XCTAssertFalse(subscriber.liveSpokenText.contains(sentences[0]))
    }

    func testInFlightSentenceDoesNotRejoinTheLiveRow() async {
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
        engine.delayNanoseconds = 250_000_000
        engine.result = .success("번역")
        let subscriber = LiveTranslationSubscriber(translator: engine)
        subscriber.beginListening()
        subscriber.handlePartial("Today we trained the model. Then we applied it")
        XCTAssertEqual(subscriber.liveSpokenText, "Then we applied it")
        XCTAssertEqual(subscriber.pendingSpokenLines, ["Today we trained the model."])
        subscriber.handlePartial("Today we trained the model. Then we applied it to the new data")
        XCTAssertEqual(subscriber.liveSpokenText, "Then we applied it to the new data")
        XCTAssertFalse(subscriber.liveSpokenText.contains("Today we trained the model."))
        subscriber.handlePartial("Today we trained the model Then we applied it to the new data set")
        XCTAssertEqual(subscriber.liveSpokenText, "Then we applied it to the new data set")
        XCTAssertFalse(subscriber.sourceDraft.contains("Today we trained the model Then"))
        await subscriber.waitForIdleForTesting()
    }

    func testGrowingSentenceStaysOnThisCaption() {
        let settings = SettingsStore.shared
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        defer {
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
        }
        settings.translationSourceLanguageID = "en"
        settings.translationTargetLanguageID = "en"

        let subscriber = LiveTranslationSubscriber(translator: FakeTranslationEngine())
        subscriber.beginListening()
        subscriber.handlePartial("Today we")
        XCTAssertTrue(subscriber.pendingSpokenLines.isEmpty)
        XCTAssertEqual(subscriber.liveSpokenText, "Today we")
        subscriber.handlePartial("Today we trained the model")
        XCTAssertTrue(subscriber.pendingSpokenLines.isEmpty)
        XCTAssertEqual(subscriber.liveSpokenText, "Today we trained the model")
        subscriber.handlePartial("Today we trained the model and then we applied")
        XCTAssertTrue(subscriber.pendingSpokenLines.isEmpty)
        XCTAssertEqual(subscriber.liveSpokenText, "Today we trained the model and then we applied")
    }

    func testLowercaseThenStartsTheNextCaptionWhileTalking() {
        let settings = SettingsStore.shared
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        defer {
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
        }
        settings.translationSourceLanguageID = "en"
        settings.translationTargetLanguageID = "en"

        let subscriber = LiveTranslationSubscriber(translator: FakeTranslationEngine())
        subscriber.beginListening()
        // Two decodes must agree before a mid-talk commit: the first tick
        // of a Listen confirms nothing.
        subscriber.handlePartial("Today we trained the model then we applied it")
        subscriber.handlePartial("Today we trained the model then we applied it")
        XCTAssertTrue(subscriber.pendingSpokenLines.isEmpty)
        XCTAssertEqual(subscriber.committedSourceLines, ["Today we trained the model"])
        XCTAssertEqual(subscriber.committedLines, ["Today we trained the model"])
        XCTAssertEqual(subscriber.liveSpokenText, "then we applied it")
        XCTAssertFalse(subscriber.liveSpokenText.contains("Today we trained the model"))
    }

    func testUnpunctuatedThenStartsTheNextCaptionWhileTalking() {
        let settings = SettingsStore.shared
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        defer {
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
        }
        settings.translationSourceLanguageID = "en"
        settings.translationTargetLanguageID = "en"

        let subscriber = LiveTranslationSubscriber(translator: FakeTranslationEngine())
        subscriber.beginListening()
        // Two decodes must agree before a mid-talk commit: the first tick
        // of a Listen confirms nothing.
        subscriber.handlePartial("Today we trained the model Then we applied it")
        subscriber.handlePartial("Today we trained the model Then we applied it")
        XCTAssertTrue(subscriber.pendingSpokenLines.isEmpty)
        XCTAssertEqual(subscriber.committedSourceLines, ["Today we trained the model"])
        XCTAssertEqual(subscriber.committedLines, ["Today we trained the model"])
        XCTAssertEqual(subscriber.liveSpokenText, "Then we applied it")
        XCTAssertFalse(subscriber.liveSpokenText.contains("Today we trained the model"))
    }

    func testNextSentenceStaysOnThisCaptionWhileTalking() {
        let settings = SettingsStore.shared
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        defer {
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
        }
        settings.translationSourceLanguageID = "en"
        settings.translationTargetLanguageID = "en"

        let subscriber = LiveTranslationSubscriber(translator: FakeTranslationEngine())
        subscriber.beginListening()
        // Two decodes must agree before a mid-talk commit: the first tick
        // of a Listen confirms nothing.
        subscriber.handlePartial("Today we trained the model. Then we applied")
        subscriber.handlePartial("Today we trained the model. Then we applied")
        XCTAssertTrue(subscriber.pendingSpokenLines.isEmpty)
        XCTAssertEqual(subscriber.committedSourceLines, ["Today we trained the model."])
        XCTAssertEqual(subscriber.committedLines, ["Today we trained the model."])
        XCTAssertEqual(subscriber.liveSpokenText, "Then we applied")
        XCTAssertFalse(subscriber.liveSpokenText.contains("Today we trained the model."))
    }

    func testReplaceLastAfterAVisibleTranslationLeavesTheBoardLineAlone() {
        let settings = SettingsStore.shared
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        defer {
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
        }
        settings.translationSourceLanguageID = "en"
        settings.translationTargetLanguageID = "ko"

        let subscriber = LiveTranslationSubscriber(translator: FakeTranslationEngine())
        subscriber.seedCommittedForTesting(
            source: "Then we applied it to the new",
            translated: "그걸 새 데이터에 적용했습니다."
        )
        // Two decodes must agree before a mid-talk commit: the first tick
        // of a Listen confirms nothing.
        subscriber.handlePartial("Then we applied it to the new data set today")
        subscriber.handlePartial("Then we applied it to the new data set today")
        XCTAssertEqual(subscriber.committedSourceLines, ["Then we applied it to the new"])
        XCTAssertEqual(subscriber.committedLines, ["그걸 새 데이터에 적용했습니다."])
        XCTAssertEqual(subscriber.liveSpokenText, "data set today")
        XCTAssertFalse(subscriber.committedSourceLines.contains("Then we applied it to the new data set today"))
    }

    func testUnpunctuatedRestitchAfterCommitIsSentenceTwoOnly() {
        let settings = SettingsStore.shared
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        defer {
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
        }
        settings.translationSourceLanguageID = "en"
        settings.translationTargetLanguageID = "ko"

        let subscriber = LiveTranslationSubscriber(translator: FakeTranslationEngine())
        subscriber.seedCommittedForTesting(
            source: "Today we trained the model",
            translated: "오늘 모델을 학습했습니다."
        )
        // Two decodes must agree before a mid-talk commit: the first tick
        // of a Listen confirms nothing.
        subscriber.handlePartial("Today we trained the model Then we applied it")
        subscriber.handlePartial("Today we trained the model Then we applied it")
        XCTAssertEqual(subscriber.liveSpokenText, "Then we applied it")
        XCTAssertEqual(subscriber.committedSourceLines, ["Today we trained the model"])
        XCTAssertFalse(subscriber.sourceDraft.contains("Today we trained the model Then"))
    }

    func testEndOfUtteranceCommitsARealClauseAndLeavesItWasOpen() async {
        let settings = SettingsStore.shared
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        defer {
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
        }
        settings.translationSourceLanguageID = "en"
        settings.translationTargetLanguageID = "ko"

        let thin = FakeTranslationEngine()
        thin.result = .success("그랬어요")
        let thinSubscriber = LiveTranslationSubscriber(translator: thin)
        thinSubscriber.beginListening()
        thinSubscriber.handlePartial("It was")
        thinSubscriber.handleEndOfUtterance()
        await thinSubscriber.waitForIdleForTesting()
        XCTAssertTrue(thin.calls.isEmpty)
        XCTAssertTrue(thinSubscriber.committedLines.isEmpty)

        let engine = FakeTranslationEngine()
        engine.result = .success("그걸 오늘 적용했습니다.")
        let subscriber = LiveTranslationSubscriber(translator: engine)
        subscriber.beginListening()
        subscriber.handlePartial("Then we applied it today")
        XCTAssertTrue(engine.calls.isEmpty)
        subscriber.handleEndOfUtterance()
        await subscriber.waitForIdleForTesting()
        XCTAssertEqual(engine.calls.first, "Then we applied it today")
        XCTAssertEqual(subscriber.committedLines, ["그걸 오늘 적용했습니다."])
        XCTAssertEqual(subscriber.committedSourceLines, ["Then we applied it today"])
    }

    func testFinishedSentenceCommitsWhileTalkingContinues() async {
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
        let spoken = "Today we trained the model. Then we applied it"
        subscriber.handlePartial(spoken)
        subscriber.handlePartial(spoken)
        XCTAssertEqual(subscriber.liveSpokenText, "Then we applied it")
        XCTAssertEqual(subscriber.pendingSpokenLines, ["Today we trained the model."])
        await subscriber.waitForIdleForTesting()
        XCTAssertEqual(subscriber.committedSourceLines, ["Today we trained the model."])
        XCTAssertEqual(subscriber.committedLines, ["번역"])
        XCTAssertEqual(subscriber.liveSpokenText, "Then we applied it")
    }

    func testContinuousSpeechKeepsEachPairedTranslation() async {
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
        engine.resultsByText = [
            "Today we trained the model.": "오늘 모델을 학습했습니다.",
            "Then we applied it.": "그걸 적용했습니다.",
            "And we shipped it to production.": "그리고 프로덕션에 올렸습니다.",
        ]
        engine.result = .success("번역")
        let subscriber = LiveTranslationSubscriber(translator: engine)
        subscriber.beginListening()
        let spoken =
            "Today we trained the model. Then we applied it. And we shipped it to production."
        subscriber.handlePartial(spoken)
        subscriber.handlePartial(spoken)
        XCTAssertEqual(subscriber.liveSpokenText, "And we shipped it to production.")
        await subscriber.waitForIdleForTesting()
        XCTAssertEqual(
            subscriber.committedSourceLines,
            ["Today we trained the model.", "Then we applied it."]
        )
        XCTAssertEqual(
            subscriber.committedLines,
            ["오늘 모델을 학습했습니다.", "그걸 적용했습니다."]
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

    func testEOUHoldSurvivesTheSameTextPartialHop() async {
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
        subscriber.handlePartial("Today we trained the model")
        subscriber.handleEndOfUtterance()
        subscriber.handlePartial("Today we trained the model")
        await subscriber.waitForIdleForTesting()
        XCTAssertEqual(subscriber.committedSourceLines, ["Today we trained the model"])
    }

    func testUndoWhileListeningDoesNotRecommitTheRemovedLine() async {
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
        subscriber.handlePartial("Welcome to the lecture. Thanks for coming.")
        subscriber.handlePartial("Welcome to the lecture. Thanks for coming.")
        await subscriber.waitForIdleForTesting()
        XCTAssertEqual(subscriber.committedSourceLines, ["Welcome to the lecture."])
        subscriber.removeLastCommittedLine()
        XCTAssertTrue(subscriber.committedSourceLines.isEmpty)
        subscriber.handlePartial("Welcome to the lecture. Thanks for coming.")
        await subscriber.waitForIdleForTesting()
        XCTAssertFalse(subscriber.committedSourceLines.contains("Welcome to the lecture."))
    }

    func testConfirmDoesNotReprintAPrintedSentence() async {
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
        subscriber.handlePartial("The model trained well on the data. Next we measure it.")
        subscriber.handlePartial("The model trained well on the data. Next we measure it.")
        await subscriber.waitForIdleForTesting()
        XCTAssertEqual(subscriber.committedSourceLines, ["The model trained well on the data."])
        subscriber.confirmTranscript = { "A model trained well on the data. Next we measure it." }
        subscriber.handleEndOfUtterance()
        await subscriber.waitForIdleForTesting()
        XCTAssertEqual(subscriber.committedSourceLines.first, "The model trained well on the data.")
        XCTAssertFalse(subscriber.committedSourceLines.contains("A model trained well on the data."))
    }
}
