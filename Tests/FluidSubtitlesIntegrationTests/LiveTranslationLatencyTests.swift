import XCTest
@testable import FluidSubtitles_Debug

@MainActor
final class LiveTranslationLatencyTests: XCTestCase {
    func testHostClockConvertsHostTicksToUptime() {
        let delay: TimeInterval = 0.25
        let delayTicks = LiveTranslationHostClock.ticks(forSeconds: delay)
        XCTAssertGreaterThan(delayTicks, 0)

        let nowUptime: TimeInterval = 12.5
        let nowHost = delayTicks &+ delayTicks &+ 1
        let speechHost = nowHost &- delayTicks
        let start = LiveTranslationHostClock.uptime(
            fromHostTime: speechHost,
            nowUptime: nowUptime,
            nowHostTime: nowHost
        )
        XCTAssertEqual(start, nowUptime - delay, accuracy: 0.02)
    }

    func testHostClockDoesNotTrapWhenHostTimeIsInTheFuture() {
        let start = LiveTranslationHostClock.uptime(
            fromHostTime: 100,
            nowUptime: 12.5,
            nowHostTime: 50
        )
        XCTAssertEqual(start, 12.5)
    }

    func testTrackerReportsRequestToFirstBufferAsMic() {
        var tracker = LiveTranslationLatencyTracker()
        tracker.markListenStart(10.0)
        tracker.markFirstBuffer(10.08)
        tracker.markSpeechStart(10.1)
        tracker.markASRReady(10.3)
        let sample = tracker.markTranslated(at: 10.74, mtMilliseconds: 80, thermal: .nominal)
        XCTAssertEqual(sample.micMilliseconds, 80)
        XCTAssertEqual(sample.endToEndMilliseconds, 640)
        XCTAssertEqual(
            sample.displayText,
            "mic 80 · 640ms e2e · ASR 200 · MT 80 · thermal nominal"
        )
    }

    func testTrackerComputesEndToEndAndASRFromFakeTimes() {
        var tracker = LiveTranslationLatencyTracker()
        tracker.markSpeechStart(10.0)
        tracker.markASRReady(10.2)
        let sample = tracker.markTranslated(at: 10.64, mtMilliseconds: 95, thermal: .nominal)
        XCTAssertEqual(sample.endToEndMilliseconds, 640)
        XCTAssertEqual(sample.asrMilliseconds, 200)
        XCTAssertEqual(sample.machineTranslationMilliseconds, 95)
        XCTAssertEqual(
            sample.displayText,
            "640ms e2e · ASR 200 · MT 95 · thermal nominal"
        )
        XCTAssertEqual(sample.compactText, "640ms")
    }

    func testTrackerDoesNotRelabelMTAsEndToEndWithoutSpeechStart() {
        var tracker = LiveTranslationLatencyTracker()
        let sample = tracker.markTranslated(at: 4.0, mtMilliseconds: 140, thermal: .fair)
        XCTAssertNil(sample.endToEndMilliseconds)
        XCTAssertEqual(sample.displayText, "MT 140ms · thermal fair")
        XCTAssertEqual(sample.compactText, "MT 140ms")
    }

    func testSilenceGateKeepsTheFirstTickAndSkipsAfterHold() {
        XCTAssertFalse(
            LiveTranslationSilenceGate.shouldSkipASRTick(
                hadFirstTick: false,
                lastVoicedUptime: nil,
                now: 1.0
            )
        )
        XCTAssertFalse(
            LiveTranslationSilenceGate.shouldSkipASRTick(
                hadFirstTick: true,
                lastVoicedUptime: 0.9,
                now: 1.0
            )
        )
        XCTAssertFalse(
            LiveTranslationSilenceGate.shouldSkipASRTick(
                hadFirstTick: true,
                lastVoicedUptime: 0.4,
                now: 1.0
            )
        )
        XCTAssertTrue(
            LiveTranslationSilenceGate.shouldSkipASRTick(
                hadFirstTick: true,
                lastVoicedUptime: 0.4,
                now: 1.0,
                consumedSilenceEdgeTick: true
            )
        )
        XCTAssertFalse(
            LiveTranslationSilenceGate.shouldSkipASRTick(
                hadFirstTick: true,
                lastVoicedUptime: nil,
                now: 1.0
            )
        )
        XCTAssertTrue(
            LiveTranslationSilenceGate.shouldSkipASRTick(
                hadFirstTick: true,
                lastVoicedUptime: nil,
                now: 1.0,
                consumedSilenceEdgeTick: true
            )
        )
    }

    func testSilenceGateLeavesNominalAndFairTicksUnchanged() {
        XCTAssertFalse(
            LiveTranslationSilenceGate.shouldSkipASRTick(
                hadFirstTick: true,
                lastVoicedUptime: 0.4,
                now: 1.0,
                thermal: .nominal
            )
        )
        XCTAssertFalse(
            LiveTranslationSilenceGate.shouldSkipASRTick(
                hadFirstTick: true,
                lastVoicedUptime: 0.4,
                now: 1.0,
                thermal: .fair
            )
        )
        XCTAssertTrue(
            LiveTranslationSilenceGate.shouldSkipASRTick(
                hadFirstTick: true,
                lastVoicedUptime: 0.4,
                now: 1.0,
                consumedSilenceEdgeTick: true,
                thermal: .fair
            )
        )
    }

    func testSilenceGateTreatsSilenceEdgeAsConsumedWhenThermalIsSerious() {
        XCTAssertFalse(
            LiveTranslationSilenceGate.treatsSilenceEdgeAsConsumed(.nominal)
        )
        XCTAssertFalse(
            LiveTranslationSilenceGate.treatsSilenceEdgeAsConsumed(.fair)
        )
        XCTAssertTrue(
            LiveTranslationSilenceGate.treatsSilenceEdgeAsConsumed(.serious)
        )
        XCTAssertTrue(
            LiveTranslationSilenceGate.treatsSilenceEdgeAsConsumed(.critical)
        )
        XCTAssertTrue(
            LiveTranslationSilenceGate.shouldSkipASRTick(
                hadFirstTick: true,
                lastVoicedUptime: 0.4,
                now: 1.0,
                thermal: .serious
            )
        )
        XCTAssertTrue(
            LiveTranslationSilenceGate.shouldSkipASRTick(
                hadFirstTick: true,
                lastVoicedUptime: nil,
                now: 1.0,
                thermal: .critical
            )
        )
    }

    func testSilenceGateDoesNotSkipFirstTickWhenThermalIsSerious() {
        XCTAssertFalse(
            LiveTranslationSilenceGate.shouldSkipASRTick(
                hadFirstTick: false,
                lastVoicedUptime: nil,
                now: 1.0,
                thermal: .serious
            )
        )
        XCTAssertFalse(
            LiveTranslationSilenceGate.shouldSkipASRTick(
                hadFirstTick: false,
                lastVoicedUptime: 0.4,
                now: 1.0,
                thermal: .critical
            )
        )
    }

    func testSilenceGateDowngradesEngineOnlyWhenThermalIsCritical() {
        XCTAssertFalse(LiveTranslationSilenceGate.shouldDowngradeEngine(.nominal))
        XCTAssertFalse(LiveTranslationSilenceGate.shouldDowngradeEngine(.fair))
        XCTAssertFalse(LiveTranslationSilenceGate.shouldDowngradeEngine(.serious))
        XCTAssertTrue(LiveTranslationSilenceGate.shouldDowngradeEngine(.critical))
        XCTAssertFalse(
            LiveTranslationThermalEngine.shouldApply(
                current: .appleSpeechAnalyzer,
                thermal: .critical,
                alreadyOverridden: false
            )
        )
        XCTAssertFalse(
            LiveTranslationThermalEngine.shouldApply(
                current: .nemotronStreaming,
                thermal: .serious,
                alreadyOverridden: false
            )
        )
        XCTAssertTrue(
            LiveTranslationThermalEngine.shouldApply(
                current: .nemotronStreaming,
                thermal: .critical,
                alreadyOverridden: false
            )
        )
        XCTAssertFalse(
            LiveTranslationThermalEngine.shouldApply(
                current: .nemotronStreaming,
                thermal: .critical,
                alreadyOverridden: true
            )
        )
        XCTAssertEqual(
            LiveTranslationThermalEngine.fallbackModel(isAppleSpeechAnalyzerAvailable: true),
            .appleSpeechAnalyzer
        )
        XCTAssertEqual(
            LiveTranslationThermalEngine.fallbackModel(isAppleSpeechAnalyzerAvailable: false),
            .appleSpeech
        )
    }

    func testSilenceGateDoesNotSkipVoicedWindowWhenThermalIsSerious() {
        XCTAssertFalse(
            LiveTranslationSilenceGate.shouldSkipASRTick(
                hadFirstTick: true,
                lastVoicedUptime: 0.9,
                now: 1.0,
                thermal: .serious
            )
        )
        XCTAssertFalse(
            LiveTranslationSilenceGate.shouldSkipASRTick(
                hadFirstTick: true,
                lastVoicedUptime: 0.7,
                now: 1.0,
                thermal: .critical
            )
        )
    }

    func testOpenLinePublishesLiveShowAsWithoutCommitting() async {
        let settings = SettingsStore.shared
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        defer {
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
        }
        settings.translationSourceLanguageID = "en"
        settings.translationTargetLanguageID = "ko"
        let originalSpoken = settings.theaterSpokenLineMode
        defer { settings.theaterSpokenLineMode = originalSpoken }
        settings.theaterSpokenLineMode = .afterPause

        let engine = FakeTranslationEngine()
        engine.result = .success("안녕 세상")
        let subscriber = LiveTranslationSubscriber(
            translator: engine,
            archive: LectureCaptionArchive(url: self.temporaryArchiveURL())
        )
        subscriber.beginListening()
        subscriber.handlePartial("Hello world today")
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(engine.calls, ["Hello world today"])
        XCTAssertEqual(subscriber.liveCaptionText, "안녕 세상")
        XCTAssertTrue(subscriber.committedLines.isEmpty)
    }

    func testEnglishEOUDoesNotCommitAThinOpenTail() async {
        let settings = SettingsStore.shared
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        defer {
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
        }
        settings.translationSourceLanguageID = "en"
        settings.translationTargetLanguageID = "ko"
        let originalSpoken = settings.theaterSpokenLineMode
        defer { settings.theaterSpokenLineMode = originalSpoken }
        settings.theaterSpokenLineMode = .afterPause

        let engine = FakeTranslationEngine()
        engine.result = .success("안녕 세상")
        let subscriber = LiveTranslationSubscriber(
            translator: engine,
            archive: LectureCaptionArchive(url: self.temporaryArchiveURL())
        )
        subscriber.beginListening()
        subscriber.handlePartial("Hello world today")
        subscriber.handleEndOfUtterance()
        // A brief pause keeps the thin tail open in case the thought goes on.
        // Show-as may already be the live prefetch of that tail.
        try? await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertTrue(subscriber.committedLines.isEmpty)
        XCTAssertEqual(engine.calls, ["Hello world today"])
        XCTAssertEqual(subscriber.sourceDraft, "Hello world today")
        // Sustained silence prints it instead of holding it until Stop.
        await subscriber.waitForIdleForTesting()
        XCTAssertEqual(engine.calls.count, 1)
    }

    func testSessionTraceRecordsTheListenWithoutTheWords() {
        var trace = LiveTranslationSessionTrace(token: 4, kind: "captions", startedUptime: 10)
        XCTAssertEqual(
            trace.beginLine(mode: "translation", pair: "ko>en", model: "apple-speech", thermal: "nominal"),
            "session begin kind=captions token=4 mode=translation pair=ko>en model=apple-speech thermal=nominal"
        )
        trace.partials = 12
        trace.silenceHolds = 2
        trace.utteranceEnds = 1
        XCTAssertEqual(
            trace.endLine(outcome: "finished chars=40", now: 12.5, lines: 3),
            "session finished chars=40 kind=captions token=4 elapsedMs=2500 partials=12 silenceHolds=2 utteranceEnds=1 lines=3"
        )
        XCTAssertFalse(trace.endLine(outcome: "abandoned", now: 11, lines: 0).contains("hello"))
        XCTAssertEqual(LiveTranslationTrace.packLabel(.supported), "supported")
        XCTAssertEqual(
            LiveTranslationTrace.event("listen blocked", token: 4, "gate=needDownload pair=ko>en"),
            "listen blocked token=4 gate=needDownload pair=ko>en"
        )
    }

    func testThermalReadoutLabels() {
        XCTAssertEqual(LiveTranslationThermalReadout.label(.nominal), "nominal")
        XCTAssertEqual(LiveTranslationThermalReadout.label(.serious), "serious")
    }

    @MainActor
    func testPolishYieldsWhileAnASRChunkIsStillRunning() async {
        let asr = AppServices.shared.asr
        let wasBusy = asr.isProcessingChunk
        asr.isProcessingChunk = false
        defer { asr.isProcessingChunk = wasBusy }
        let idle = await LiveTranslationMT.polishYieldsToASRChunk(maxWait: 0)
        XCTAssertFalse(idle)
        asr.isProcessingChunk = true
        let busy = await LiveTranslationMT.polishYieldsToASRChunk(maxWait: 0)
        XCTAssertTrue(busy)
    }

    func testSpeechTickDefersWhileAppleTranslationIsRunning() {
        XCTAssertFalse(LiveTranslationModelGate.isTranslationRunning)
        XCTAssertFalse(LiveTranslationModelGate.shouldDeferSpeechTick(translationRunning: false))
        LiveTranslationModelGate.beginTranslation()
        XCTAssertTrue(LiveTranslationModelGate.shouldDeferSpeechTick(
            translationRunning: LiveTranslationModelGate.isTranslationRunning
        ))
        LiveTranslationModelGate.endTranslation()
        XCTAssertFalse(LiveTranslationModelGate.isTranslationRunning)
    }

    func testSharpenAdmissionYieldsWhenHotOrUnderMemoryPressure() {
        XCTAssertTrue(TheaterSharpenAdmission.allows(thermal: .nominal, memoryPressure: .normal))
        XCTAssertTrue(TheaterSharpenAdmission.allows(thermal: .fair, memoryPressure: .normal))
        XCTAssertFalse(TheaterSharpenAdmission.allows(thermal: .serious, memoryPressure: .normal))
        XCTAssertFalse(TheaterSharpenAdmission.allows(thermal: .critical, memoryPressure: .normal))
        XCTAssertFalse(TheaterSharpenAdmission.allows(thermal: .nominal, memoryPressure: .warning))
        XCTAssertFalse(TheaterSharpenAdmission.allows(thermal: .fair, memoryPressure: .critical))
        XCTAssertTrue(TheaterSharpenAdmission.isWithdrawal(TranslationEngineError.sharpenWithdrawn))
        XCTAssertTrue(TheaterSharpenAdmission.isWithdrawal(CancellationError()))
        XCTAssertFalse(TheaterSharpenAdmission.isWithdrawal(TranslationEngineError.timeout))
    }

    func testAcceleratorGateCancelsInFlightSharpen() async {
        let gate = TheaterAcceleratorGate(observingSystem: false)
        let entered = expectation(description: "sharpen entered")
        let work = Task {
            try await gate.track {
                entered.fulfill()
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return true
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        gate.cancelInFlight()
        do {
            _ = try await work.value
            XCTFail("in-flight sharpen should cancel")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    private func temporaryArchiveURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("theater-archive-\(UUID().uuidString).jsonl")
    }
}
