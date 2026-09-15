import XCTest
@testable import FluidSubtitles_Debug

@MainActor
final class FakeTranslationEngine: TranslationEngine {
    let name = "Fake"
    var result: Result<String, Error> = .success("translated")
    var delayNanoseconds: UInt64 = 0
    var calls: [String] = []
    var resultsByText: [String: String] = [:]

    func translate(
        _ text: String,
        source: TranslationLanguage,
        target: TranslationLanguage
    ) async throws -> String {
        self.calls.append(text)
        if self.delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: self.delayNanoseconds)
        }
        if let mapped = self.resultsByText[text] {
            return mapped
        }
        return try self.result.get()
    }
}

@MainActor
final class LiveTranslationSubscriberTests: XCTestCase {
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

    func testHandlePartialHoldsTheLineUntilCommit() async {
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
        XCTAssertTrue(subscriber.liveCaptionText.isEmpty)
        XCTAssertTrue(engine.calls.isEmpty)

        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(engine.calls.isEmpty)
        XCTAssertTrue(subscriber.liveCaptionText.isEmpty)
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
        XCTAssertTrue(engine.calls.isEmpty)
        let output = await subscriber.translateFinal("Hello world today.")
        XCTAssertEqual(engine.calls, ["Hello world today."])
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

    func testCommittedKoreanIsDroppedFromTheNextLiveLine() {
        let subscriber = LiveTranslationSubscriber(translator: FakeTranslationEngine())
        subscriber.seedCommittedForTesting(
            source: "저는 모델을 학습했습니다",
            translated: "I trained the model."
        )
        XCTAssertTrue(subscriber.liveCaptionText.isEmpty)
        XCTAssertTrue(subscriber.liveSpokenText.isEmpty)

        subscriber.handlePartial("저는 모델을 학습했습니다그걸 적용하면")
        XCTAssertEqual(subscriber.sourceDraft, "그걸 적용하면")
        XCTAssertEqual(subscriber.liveSpokenText, "그걸 적용하면")
        XCTAssertTrue(subscriber.liveCaptionText.isEmpty)
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
        subscriber.handlePartial(
            "Today we trained the model.Then we applied it.And we shipped it to production."
        )
        XCTAssertEqual(subscriber.liveSpokenText, "And we shipped it to production.")
        XCTAssertEqual(
            subscriber.pendingSpokenLines,
            ["Today we trained the model.", "Then we applied it."]
        )
        XCTAssertTrue(subscriber.sourceDraft.contains("Then we applied it."))
        XCTAssertTrue(subscriber.sourceDraft.contains("And we shipped it to production."))
        XCTAssertFalse(subscriber.sourceDraft.contains("Today we trained the model."))

        subscriber.handleEndOfUtterance()
        await subscriber.waitForIdleForTesting()
        XCTAssertEqual(engine.calls.first, "Today we trained the model.")
        XCTAssertEqual(
            subscriber.committedSourceLines,
            [
                "Today we trained the model.",
                "Then we applied it.",
                "And we shipped it to production.",
            ]
        )
        XCTAssertFalse(subscriber.sourceDraft.contains("Today we trained the model."))
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
        subscriber.handlePartial(
            "Today we trained the model. Then we applied it. And we shipped it to production."
        )
        XCTAssertEqual(subscriber.liveSpokenText, "And we shipped it to production.")
        XCTAssertEqual(subscriber.pendingSpokenLines, ["Then we applied it."])
        XCTAssertTrue(subscriber.sourceDraft.contains("And we shipped it"))
        XCTAssertFalse(subscriber.sourceDraft.contains("Today we trained"))
        XCTAssertFalse(subscriber.sourceDraft.contains("Then we applied it."))

        try? await Task.sleep(nanoseconds: 200_000_000)
        let current = "Then we applied it."
        let payload = TranslationClauseSegmenter.joinTranslatedLines(
            ["Today we trained the model.", current],
            languageID: "en"
        )
        XCTAssertEqual(engine.calls.first, payload)
        XCTAssertTrue(engine.calls.contains(current))
        XCTAssertEqual(subscriber.committedLines.last, "번역")
        XCTAssertTrue(subscriber.sourceDraft.contains("And we shipped it"))
    }

    func testSharedLastWordDoesNotEraseTheNextClause() {
        let subscriber = LiveTranslationSubscriber(translator: FakeTranslationEngine())
        subscriber.seedCommittedForTesting(
            source: "Today we trained the model.",
            translated: "오늘 모델을 학습했습니다."
        )
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
        subscriber.handlePartial(
            "Today we trained the model. Then we applied it. And we shipped it."
        )
        XCTAssertEqual(subscriber.liveSpokenText, "And we shipped it.")
        XCTAssertEqual(
            subscriber.pendingSpokenLines,
            ["Today we trained the model.", "Then we applied it."]
        )
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(engine.calls, ["Today we trained the model."])
        XCTAssertTrue(subscriber.sourceDraft.contains("Then we applied it."))
        XCTAssertTrue(subscriber.sourceDraft.contains("And we shipped it."))

        try? await Task.sleep(nanoseconds: LiveTranslationTiming.completeSettleNanoseconds(languageID: "en") + 200_000_000)
        let first = "Today we trained the model."
        let second = "Then we applied it."
        let payload = TranslationClauseSegmenter.joinTranslatedLines(
            [first, second],
            languageID: "en"
        )
        XCTAssertEqual(engine.calls, [first, payload, second])
        XCTAssertTrue(subscriber.sourceDraft.contains("And we shipped it."))
        XCTAssertFalse(subscriber.sourceDraft.contains("Today we trained"))
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
        let output = await subscriber.translateFinal(
            "Today we trained the model. Then we applied it."
        )
        let current = "Then we applied it to production."
        let payload = TranslationClauseSegmenter.joinTranslatedLines(
            ["Today we trained the model.", current],
            languageID: "en"
        )
        XCTAssertEqual(engine.calls, [payload, current])
        XCTAssertEqual(output, "번역")
        XCTAssertEqual(subscriber.committedLines.last, "번역")
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
        XCTAssertEqual(
            LiveTranslationPrefetch.unitToPrefetch(
                leftover: "Today we trained the model. Then we applied it",
                languageID: "en"
            ),
            "Today we trained the model."
        )
        XCTAssertNil(
            LiveTranslationPrefetch.unitToPrefetch(
                leftover: "Hello world today",
                languageID: "en"
            )
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
        await subscriber.waitForIdleForTesting()
        XCTAssertEqual(subscriber.committedLines, ["First sentence is ready."])
        XCTAssertEqual(subscriber.committedSourceLines, ["First sentence is ready."])

        subscriber.handlePartial("First sentence is ready. Second sentence is next.")
        XCTAssertEqual(subscriber.liveSpokenText, "Second sentence is next.")
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
        await subscriber.waitForIdleForTesting()
        XCTAssertEqual(subscriber.committedSourceLines.count, 3)
        XCTAssertEqual(subscriber.committedSourceLines.last, "Third sentence is last.")
        XCTAssertFalse(
            subscriber.committedLines.contains {
                $0.contains("First sentence is ready. Second")
            }
        )
    }

    func testNextSentenceTypesOnANewLineWhileTalking() {
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
        subscriber.handlePartial("Today we trained the model. Then we applied")
        XCTAssertEqual(subscriber.pendingSpokenLines, ["Today we trained the model."])
        XCTAssertEqual(subscriber.liveSpokenText, "Then we applied")
        XCTAssertTrue(subscriber.committedLines.isEmpty)

        let rows = TheaterCaptionFlow.lines(
            committed: subscriber.committedLines,
            committedIDs: subscriber.committedLineIDs,
            nextCaptionID: subscriber.nextCaptionID,
            committedSources: subscriber.committedSourceLines,
            draft: subscriber.liveCaptionText,
            sourceDraft: subscriber.liveSpokenText,
            pendingSources: subscriber.pendingSpokenLines
        )
        XCTAssertEqual(rows.map(\.text), ["Today we trained the model.", "Then we applied"])
        XCTAssertEqual(rows.first?.isDraft, true)
        XCTAssertEqual(rows.last?.isDraft, true)
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
        subscriber.handlePartial("Today we trained the model. Then we applied it")
        XCTAssertEqual(subscriber.liveSpokenText, "Then we applied it")
        XCTAssertEqual(subscriber.pendingSpokenLines, ["Today we trained the model."])
        try? await Task.sleep(
            nanoseconds: LiveTranslationTiming.completeSettleNanoseconds(languageID: "en") + 200_000_000
        )
        await subscriber.waitForIdleForTesting()
        XCTAssertEqual(engine.calls.first, "Today we trained the model.")
        XCTAssertEqual(subscriber.committedSourceLines, ["Today we trained the model."])
        XCTAssertEqual(subscriber.liveSpokenText, "Then we applied it")
        XCTAssertFalse(subscriber.committedSourceLines.contains("Today we trained the model. Then we applied it"))
    }
}
