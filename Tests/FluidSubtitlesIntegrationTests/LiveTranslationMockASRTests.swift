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

        XCTAssertEqual(subscriber.liveSpokenText, "And we shipped it to production.")
        XCTAssertGreaterThanOrEqual(subscriber.inFlightCaptionCount, 1)
        let liveRows = TheaterCaptionFlow.lines(
            committed: subscriber.committedLines,
            committedIDs: subscriber.committedLineIDs,
            nextCaptionID: subscriber.nextCaptionID,
            committedSources: subscriber.committedSourceLines,
            draft: subscriber.liveCaptionText,
            sourceDraft: subscriber.liveSpokenText,
            pendingSources: subscriber.pendingSpokenLines,
            inFlightCount: subscriber.inFlightCaptionCount,
            spokenDisplay: .paired
        )
        XCTAssertEqual(
            liveRows.last?.id,
            TheaterCaptionFlow.liveID(
                after: subscriber.committedLineIDs,
                nextID: subscriber.nextCaptionID,
                pendingCount: subscriber.pendingSpokenLines.count
            )
        )
        XCTAssertNotEqual(liveRows.last?.id, "c-1")

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
}
