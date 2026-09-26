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
        let repeated = TheaterCaptionFlow.lines(board: .make(translated: ["Hello."], sources: ["Hello."], ids: [1]))
        XCTAssertEqual(repeated.map(\.text), ["Hello."])
        XCTAssertEqual(repeated.last?.id, "c-1")
        XCTAssertFalse(repeated.contains { $0.isDraft })

        let midTalk = TheaterCaptionFlow.lines(board: .make(translated: []))
        XCTAssertTrue(midTalk.isEmpty)

        let pairedSame = TheaterCaptionFlow.lines(board: .make(translated: []))
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
        let lines = TheaterCaptionFlow.lines(board: .make(translated: ["안녕."], sources: ["Hello."], ids: [1]))
        XCTAssertEqual(lines.map(\.text), ["안녕."])
        XCTAssertEqual(lines.map(\.source), ["Hello."])
        XCTAssertEqual(lines.last?.id, "c-1")
        XCTAssertFalse(lines.contains { $0.isDraft })
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

    /// A printed clause grows twice. The shorter retranslation is held until
    /// the longer one has already painted, then released. The late result
    /// must not replace the caption that belongs to the current source.
    func testSlowerRetranslationCannotOverwriteALaterInPlaceGrowth() async {
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
        settings.translationSourceLanguageID = "en"
        settings.translationTargetLanguageID = "ko"

        let engine = HeldTranslationEngine()
        engine.holdIf = { $0.contains("on Korean data") && !$0.contains("too") }
        engine.translation = { text in
            if text.contains("on Korean data too") { return "긴 번역" }
            if text.contains("on Korean data") { return "중간 번역" }
            return "짧은 번역"
        }
        defer { engine.release() }

        let subscriber = LiveTranslationSubscriber(translator: engine)
        subscriber.beginListening()
        let short = "We trained the model."
        subscriber.handlePartial(short)
        subscriber.handlePartial(short)
        await subscriber.waitForIdleForTesting()
        XCTAssertEqual(subscriber.committedSourceLines, [short])
        XCTAssertEqual(subscriber.committedLines, ["짧은 번역"])

        let medium = "We trained the model on Korean data."
        subscriber.handlePartial(medium)
        let held = await Self.waitUntil { engine.heldCalls > 0 }
        XCTAssertTrue(held, "the shorter retranslation never started: \(engine.calls)")
        XCTAssertEqual(subscriber.committedSourceLines, [short])
        XCTAssertEqual(subscriber.committedLines, ["짧은 번역"])

        let long = "We trained the model on Korean data too."
        subscriber.handlePartial(long)
        XCTAssertEqual(
            subscriber.committedSourceLines,
            [short],
            "the longer source painted before its translation. calls=\(engine.calls)"
        )
        XCTAssertEqual(subscriber.committedLines, ["짧은 번역"])
        var mismatched = false
        let painted = await Self.waitUntil {
            let sources = subscriber.committedSourceLines
            let lines = subscriber.committedLines
            if sources == [long], lines != ["긴 번역"] { mismatched = true }
            return sources == [long] && lines == ["긴 번역"]
        }
        XCTAssertFalse(mismatched, "source and Show-as changed apart. lines=\(subscriber.committedLines) sources=\(subscriber.committedSourceLines)")
        XCTAssertTrue(
            painted,
            "longer growth did not paint before the held translation returned. lines=\(subscriber.committedLines) sources=\(subscriber.committedSourceLines) calls=\(engine.calls)"
        )
        XCTAssertTrue(
            engine.calls.contains(long),
            "the longer clause was not sent for translation. calls=\(engine.calls)"
        )
        XCTAssertFalse(engine.staleReturned)
        engine.release()
        await subscriber.waitForIdleForTesting()

        XCTAssertTrue(engine.staleReturned, "the held retranslation never finished, so the race did not run")
        XCTAssertEqual(subscriber.committedSourceLines, [long])
        XCTAssertEqual(subscriber.committedLines, ["긴 번역"])
        XCTAssertEqual(subscriber.captionPairs.map(\.source), [long])
        XCTAssertEqual(subscriber.captionPairs.map(\.translated), ["긴 번역"])
    }

    /// The first sentence is still translating when recognition grows it.
    /// Releasing that original call after the grown caption has printed must
    /// not add the short line back or replace the grown translation.
    func testSlowerOriginalCommitCannotLandAfterPendingGrowth() async {
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
        settings.translationSourceLanguageID = "en"
        settings.translationTargetLanguageID = "ko"

        let engine = HeldTranslationEngine()
        engine.holdIf = { !$0.contains("on Korean data") }
        engine.translation = { text in
            text.contains("on Korean data") ? "긴 번역" : "짧은 번역"
        }
        defer { engine.release() }

        let subscriber = LiveTranslationSubscriber(translator: engine)
        subscriber.beginListening()
        let short = "We trained the model."
        subscriber.handlePartial(short)
        subscriber.handlePartial(short)
        let held = await Self.waitUntil { engine.heldCalls > 0 }
        XCTAssertTrue(held, "the original commit never started: \(engine.calls)")
        XCTAssertTrue(subscriber.committedLines.isEmpty)

        let grown = "We trained the model on Korean data."
        subscriber.handlePartial(grown)
        var mismatched = false
        let painted = await Self.waitUntil {
            let sources = subscriber.committedSourceLines
            let lines = subscriber.committedLines
            if sources == [grown], lines != ["긴 번역"] { mismatched = true }
            return sources == [grown] && lines == ["긴 번역"]
        }
        XCTAssertFalse(mismatched, "grown source appeared under the short translation")
        XCTAssertTrue(
            painted,
            "grown caption did not print while the original translation was held. lines=\(subscriber.committedLines) sources=\(subscriber.committedSourceLines) calls=\(engine.calls)"
        )
        XCTAssertFalse(engine.staleReturned)
        engine.release()
        await subscriber.waitForIdleForTesting()

        XCTAssertTrue(engine.staleReturned)
        XCTAssertEqual(subscriber.committedSourceLines, [grown])
        XCTAssertEqual(subscriber.committedLines, ["긴 번역"])
        XCTAssertEqual(subscriber.captionPairs.map(\.source), [grown])
        XCTAssertEqual(subscriber.captionPairs.map(\.translated), ["긴 번역"])
    }

    /// The sentence after a period-insertion stays its own caption, and the
    /// held retranslation of the grown row still lands after that sentence prints.
    func testGrowthRetranslationLandsAfterTheNextSentencePrints() async {
        let restore = self.englishToKorean()
        defer { restore() }

        let engine = HeldTranslationEngine()
        engine.holdIf = { $0.contains("on Korean data") && !$0.contains("worked") }
        engine.translation = { text in
            if text.contains("worked") { return "잘 됐다" }
            if text.contains("on Korean data") { return "중간 번역" }
            return "짧은 번역"
        }
        defer { engine.release() }

        let subscriber = LiveTranslationSubscriber(translator: engine)
        subscriber.beginListening()
        let short = "We trained the model."
        subscriber.handlePartial(short)
        subscriber.handlePartial(short)
        await subscriber.waitForIdleForTesting()

        let medium = "We trained the model on Korean data."
        subscriber.handlePartial(medium)
        let held = await Self.waitUntil { engine.heldCalls > 0 }
        XCTAssertTrue(held, "growth retranslation never started: \(engine.calls)")

        let spoken = "\(medium) It worked well."
        subscriber.handlePartial(spoken)
        subscriber.handlePartial(spoken)
        let printed = await Self.waitUntil {
            subscriber.committedSourceLines == [short, "It worked well."]
                && subscriber.committedLines == ["짧은 번역", "잘 됐다"]
        }
        XCTAssertTrue(
            printed,
            "the next sentence did not print on its own. sources=\(subscriber.committedSourceLines) lines=\(subscriber.committedLines)"
        )
        engine.release()
        await subscriber.waitForIdleForTesting()

        XCTAssertTrue(engine.staleReturned)
        XCTAssertEqual(subscriber.committedSourceLines, [medium, "It worked well."])
        XCTAssertEqual(subscriber.committedLines, ["중간 번역", "잘 됐다"])
        XCTAssertEqual(subscriber.captionPairs.map(\.translated), ["중간 번역", "잘 됐다"])
    }

    /// Apple Speech often resends the shorter sentence in front of the growth.
    func testCumulativeRestitchStillRetargetsAPeriodInsertion() async {
        let restore = self.englishToKorean()
        defer { restore() }
        let engine = FakeTranslationEngine()
        engine.result = .success("번역")
        let subscriber = LiveTranslationSubscriber(translator: engine)
        subscriber.beginListening()
        let short = "We trained the model."
        subscriber.handlePartial(short)
        subscriber.handlePartial(short)
        await subscriber.waitForIdleForTesting()

        let medium = "We trained the model on Korean data."
        subscriber.handlePartial(medium)
        await subscriber.waitForIdleForTesting()
        XCTAssertEqual(subscriber.committedSourceLines, [medium])

        let long = "We trained the model on Korean data too."
        subscriber.handlePartial("\(short) \(long)")
        await subscriber.waitForIdleForTesting()
        XCTAssertEqual(subscriber.committedSourceLines, [long])
        XCTAssertEqual(subscriber.committedLines, ["번역"])
        XCTAssertEqual(subscriber.captionPairs.map(\.source), [long])
        XCTAssertEqual(subscriber.captionPairs.map(\.translated), ["번역"])
    }

    /// One decode of a finished sentence, then the same clause with words
    /// inserted before the period. The open row keeps the longer clause.
    func testOpenRowKeepsAPeriodInsertionBeforeCommit() {
        let restore = self.englishToKorean()
        defer { restore() }
        let subscriber = LiveTranslationSubscriber(translator: FakeTranslationEngine())
        subscriber.beginListening()
        subscriber.handlePartial("We trained the model.")
        subscriber.handlePartial("We trained the model on Korean data.")
        let kept = subscriber.committedSourceLines + [subscriber.sourceDraft]
        XCTAssertTrue(
            kept.contains("We trained the model on Korean data."),
            "sources=\(subscriber.committedSourceLines) draft=\(subscriber.sourceDraft)"
        )
        XCTAssertFalse(subscriber.committedSourceLines.contains("on Korean data."))
        XCTAssertNotEqual(subscriber.sourceDraft, "on Korean data.")
    }

    /// A printed word that was rewritten is not in-place growth.
    func testPrintedWordRewriteDoesNotRetargetTheRow() async {
        let restore = self.englishToKorean()
        defer { restore() }
        let engine = FakeTranslationEngine()
        engine.result = .success("번역")
        let subscriber = LiveTranslationSubscriber(translator: engine)
        subscriber.beginListening()
        let printed = "I don't know what it on me."
        subscriber.handlePartial(printed)
        subscriber.handlePartial(printed)
        await subscriber.waitForIdleForTesting()
        XCTAssertEqual(subscriber.committedSourceLines, [printed])

        subscriber.handlePartial("I don't know what it all means.")
        XCTAssertEqual(subscriber.committedSourceLines, [printed])
        XCTAssertEqual(subscriber.committedLines.count, 1)
    }

    /// Stop bumps the generation. The retranslation that was already in flight
    /// must not paint after the listen has ended.
    func testEndedListenDropsAnInFlightGrowthRetranslation() async {
        let restore = self.englishToKorean()
        defer { restore() }
        let engine = HeldTranslationEngine()
        engine.holdIf = { $0.contains("on Korean data") }
        engine.translation = { text in
            text.contains("on Korean data") ? "중간 번역" : "짧은 번역"
        }
        defer { engine.release() }

        let subscriber = LiveTranslationSubscriber(translator: engine)
        subscriber.beginListening()
        let short = "We trained the model."
        subscriber.handlePartial(short)
        subscriber.handlePartial(short)
        await subscriber.waitForIdleForTesting()

        subscriber.handlePartial("We trained the model on Korean data.")
        let held = await Self.waitUntil { engine.heldCalls > 0 }
        XCTAssertTrue(held, "growth retranslation never started: \(engine.calls)")
        XCTAssertEqual(subscriber.committedLines, ["짧은 번역"])

        subscriber.endListening()
        engine.release()
        await subscriber.waitForIdleForTesting()
        XCTAssertEqual(subscriber.committedSourceLines, [short])
        XCTAssertEqual(subscriber.committedLines, ["짧은 번역"])
        XCTAssertEqual(subscriber.captionPairs.map(\.source), [short])
        XCTAssertEqual(subscriber.captionPairs.map(\.translated), ["짧은 번역"])
    }

    private func englishToKorean() -> () -> Void {
        let settings = SettingsStore.shared
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        let originalMode = settings.theaterSessionMode
        settings.theaterSessionMode = .translation
        settings.translationSourceLanguageID = "en"
        settings.translationTargetLanguageID = "ko"
        return {
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
            settings.theaterSessionMode = originalMode
        }
    }

    private static func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    /// A close sentence that resembles an older line is the next caption.
    /// It must not rewrite that older line or the newest one.
    func testCloseSentenceOfAnOlderLinePrintsAsItsOwnRow() async {
        let restore = self.englishToKorean()
        defer { restore() }
        let engine = FakeTranslationEngine()
        engine.result = .success("번역")
        let subscriber = LiveTranslationSubscriber(translator: engine)
        subscriber.beginListening()
        let older = "Today we trained the model."
        let newest = "Please sit down now."
        subscriber.handlePartial(older)
        subscriber.handlePartial(older)
        await subscriber.waitForIdleForTesting()
        let both = "\(older) \(newest)"
        subscriber.handlePartial(both)
        subscriber.handlePartial(both)
        await subscriber.waitForIdleForTesting()
        XCTAssertEqual(subscriber.committedSourceLines, [older, newest])

        let close = "Today we trained the modal."
        subscriber.handlePartial(close)
        subscriber.handlePartial(close)
        await subscriber.waitForIdleForTesting()
        XCTAssertEqual(subscriber.committedSourceLines, [older, newest, close])
        XCTAssertEqual(subscriber.committedLines.count, 3)
    }

    func testCloseSentenceAgainstAnOlderLineStaysUnpeeled() {
        let older = "Today we trained the model."
        let newest = "Please sit down now."
        let incoming = "Today we trained the modal."
        XCTAssertTrue(
            TranslationClauseSegmenter.shouldReviseCommitted(
                previous: older,
                incoming: incoming,
                languageID: "en"
            )
        )
        XCTAssertEqual(
            TranslationClauseSegmenter.leftoverTail(
                incoming,
                already: [older, newest],
                languageID: "en"
            ),
            incoming
        )
    }
}

/// Blocks chosen translations on a continuation so a test can let a later
/// call paint first, then release the earlier one.
@MainActor
final class HeldTranslationEngine: TranslationEngine {
    let name = "Held"
    var holdIf: (String) -> Bool = { _ in false }
    var translation: (String) -> String = { _ in "번역" }
    private(set) var calls: [String] = []
    private(set) var heldCalls = 0
    private(set) var staleReturned = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func release() {
        self.released = true
        let pending = self.waiters
        self.waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func translate(
        _ text: String,
        source _: TranslationLanguage,
        target _: TranslationLanguage
    ) async throws -> String {
        self.calls.append(text)
        let held = self.holdIf(text)
        if held, !self.released {
            self.heldCalls += 1
            await withCheckedContinuation { continuation in
                if self.released {
                    continuation.resume()
                } else {
                    self.waiters.append(continuation)
                }
            }
            self.staleReturned = true
        }
        return self.translation(text)
    }
}
