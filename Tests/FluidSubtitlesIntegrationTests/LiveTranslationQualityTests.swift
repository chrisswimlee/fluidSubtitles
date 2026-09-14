import AppKit
import AVFoundation
import XCTest
@testable import FluidSubtitles_Debug

final class LiveTranslationQualityTests: XCTestCase {
    func testBilingualTextInterleavesTranslationThenSource() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let later = start.addingTimeInterval(3.5)
        let entries = [
            LectureCaptionEntry(id: 1, source: "Hello.", translated: "안녕.", committedAt: start),
            LectureCaptionEntry(id: 2, source: "World.", translated: "세상.", committedAt: later),
        ]
        let text = TheaterCaptionExport.bilingualText(pairs: Self.pairs(from: entries))
        XCTAssertEqual(text, "안녕.\nHello.\n\n세상.\nWorld.")
    }

    func testCaptionCuesFromEntriesThreeAndAHalfSecondsApart() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let later = start.addingTimeInterval(3.5)
        let entries = [
            LectureCaptionEntry(id: 1, source: "Hello.", translated: "안녕.", committedAt: start),
            LectureCaptionEntry(id: 2, source: "World.", translated: "세상.", committedAt: later),
        ]

        let srt = TheaterCaptionExport.srt(entries: entries)
        let vtt = TheaterCaptionExport.vtt(entries: entries)
        XCTAssertFalse(
            srt.contains("00:00:00,000 --> 00:00:04,000")
                && srt.contains("00:00:04,000 --> 00:00:08,000"),
            "Entries 3.5s apart should not be snapped onto adjacent 4s slots."
        )
        XCTAssertFalse(
            vtt.contains("00:00:00.000 --> 00:00:04.000")
                && vtt.contains("00:00:04.000 --> 00:00:08.000"),
            "Entries 3.5s apart should not be snapped onto adjacent 4s slots."
        )
        XCTAssertTrue(srt.contains("00:00:00,000 --> 00:00:03,500"))
        XCTAssertTrue(srt.contains("00:00:03,500 --> 00:00:07,000"))
        XCTAssertTrue(srt.contains("안녕."))
        XCTAssertTrue(srt.contains("Hello."))
        XCTAssertTrue(vtt.hasPrefix("WEBVTT"))
        XCTAssertTrue(vtt.contains("00:00:00.000 --> 00:00:03.500"))
        XCTAssertTrue(vtt.contains("00:00:03.500 --> 00:00:07.000"))
        XCTAssertTrue(vtt.contains("세상."))
        XCTAssertTrue(vtt.contains("World."))
    }

    func testMixedCommitDatesKeepNeighboringCues() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let later = start.addingTimeInterval(3.5)
        let pairs = [
            CaptionHistoryPair(source: "Old.", translated: "옛.", wasPolished: false, committedAt: nil),
            CaptionHistoryPair(source: "Hello.", translated: "안녕.", wasPolished: false, committedAt: start),
            CaptionHistoryPair(source: "World.", translated: "세상.", wasPolished: false, committedAt: later),
        ]
        let srt = TheaterCaptionExport.srt(pairs: pairs)
        XCTAssertTrue(srt.contains("00:00:00,000 --> 00:00:04,000"))
        XCTAssertTrue(srt.contains("00:00:04,000 --> 00:00:07,500"))
        XCTAssertTrue(srt.contains("00:00:07,500 --> 00:00:11,000"))
        XCTAssertFalse(srt.contains("00:00:08,000 --> 00:00:12,000"))
    }

    func testPairsWithoutDatesStillUseFourSecondSlots() {
        let pairs = [
            CaptionHistoryPair(source: "Hello.", translated: "안녕.", wasPolished: false),
            CaptionHistoryPair(source: "World.", translated: "세상.", wasPolished: false),
        ]
        let srt = TheaterCaptionExport.srt(pairs: pairs)
        let vtt = TheaterCaptionExport.vtt(pairs: pairs)
        XCTAssertTrue(srt.contains("00:00:00,000 --> 00:00:04,000"))
        XCTAssertTrue(srt.contains("00:00:04,000 --> 00:00:08,000"))
        XCTAssertTrue(vtt.contains("00:00:00.000 --> 00:00:04.000"))
        XCTAssertTrue(vtt.contains("00:00:04.000 --> 00:00:08.000"))
    }

    func testProductLanguagesAreOnlyEnglishKoreanThai() {
        XCTAssertEqual(VoiceEngineLanguageCatalog.productLanguageIDs, ["en", "ko", "th"])
        XCTAssertEqual(
            Set(VoiceEngineLanguageCatalog.allLanguages().map(\.id)),
            ["en", "ko", "th"]
        )
    }

    func testEnglishRoutesIncludeParakeetAndThaiPreferredRouteDoesNot() {
        let catalogModels = Array(SettingsStore.SpeechModel.allCases)
        let english = VoiceEngineLanguageCatalog.routes(forLanguageID: "en", availableModels: catalogModels)
        XCTAssertFalse(english.isEmpty)
        XCTAssertTrue(
            english.contains { Self.isParakeet($0.model) },
            "English should expose a Parakeet route."
        )

        guard let thaiLanguage = VoiceEngineLanguageCatalog.language(id: "th", availableModels: catalogModels) else {
            XCTFail("Thai should be a product language")
            return
        }
        let thai = VoiceEngineLanguageCatalog.routes(for: thaiLanguage, availableModels: catalogModels)
        XCTAssertFalse(thai.isEmpty)
        XCTAssertFalse(
            thai.contains { Self.isParakeet($0.model) },
            "Thai preferred routes must not include Parakeet."
        )
    }

    @MainActor
    func testApplyPreferredRouteLeavesThaiOffParakeet() {
        let settings = SettingsStore.shared
        let originalModel = settings.selectedSpeechModel
        let originalSource = settings.translationSourceLanguageID
        let originalOnboarding = settings.onboardingSelectedLanguageID
        defer {
            settings.selectedSpeechModel = originalModel
            settings.translationSourceLanguageID = originalSource
            settings.onboardingSelectedLanguageID = originalOnboarding
        }

        settings.selectedSpeechModel = .parakeetRealtime
        VoiceEngineLanguageCatalog.applyPreferredRoute(forLanguageID: "th", to: settings)
        XCTAssertFalse(Self.isParakeet(settings.selectedSpeechModel))
        XCTAssertTrue(VoiceEngineLanguageCatalog.supports(settings.selectedSpeechModel, languageID: "th"))
    }

    func testBilingualWrapPutsSpokenThaiBeforeEnglish() {
        let font = NSFont.systemFont(ofSize: 24, weight: .semibold)
        let rows = TheaterBilingualWrap.rows(
            spoken: "สวัสดี",
            translated: "Hello",
            font: font,
            width: 800
        )
        XCTAssertGreaterThanOrEqual(rows.count, 2)
        XCTAssertEqual(rows[0].text, "สวัสดี")
        XCTAssertTrue(rows[0].isSpoken)
        XCTAssertEqual(rows[1].text, "Hello")
        XCTAssertFalse(rows[1].isSpoken)
    }

    func testBilingualWrapPutsSpokenKoreanBeforeEnglish() {
        let font = NSFont.systemFont(ofSize: 24, weight: .semibold)
        let rows = TheaterBilingualWrap.rows(
            spoken: "안녕하세요",
            translated: "Hello",
            font: font,
            width: 800
        )
        XCTAssertGreaterThanOrEqual(rows.count, 2)
        XCTAssertEqual(rows[0].text, "안녕하세요")
        XCTAssertTrue(rows[0].isSpoken)
        XCTAssertEqual(rows[1].text, "Hello")
        XCTAssertFalse(rows[1].isSpoken)
    }

    func testLastListenLatencyStoreRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LastListenLatency-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        var sample = LiveTranslationLatencySample()
        sample.endToEndMilliseconds = 4200
        sample.asrMilliseconds = 800
        sample.machineTranslationMilliseconds = 120
        sample.thermalState = .nominal
        LastListenLatencyStore.write(sample, to: url)

        let read = LastListenLatencyStore.read(from: url)
        XCTAssertEqual(read?.endToEndMilliseconds, 4200)
        XCTAssertEqual(read?.machineTranslationMilliseconds, 120)
        XCTAssertFalse(TheaterReadiness.captionsPrintAfterSentence.isEmpty)
        XCTAssertTrue(TheaterReadiness.printedLinesStay.contains("stays"))
        XCTAssertTrue(TheaterReadiness.timedExportHonesty.contains("committed"))
    }

    func testTalkReportFlagsALineIWouldNotShow() {
        let report = TheaterQualityScore.report(
            asr: [(
                reference: TheaterQualityScore.english.spoken,
                hypothesis: TheaterQualityScore.english.spoken,
                languageID: "en"
            )],
            translations: [(
                reference: TheaterQualityScore.englishToKorean.referenceCaption,
                hypothesis: "완전히 다른 문장입니다",
                languageID: "ko"
            )]
        )
        XCTAssertEqual(report.asrError, 0)
        XCTAssertTrue(report.wouldShowASR)
        XCTAssertFalse(report.wouldShowTranslation)
        XCTAssertEqual(TheaterQualityScore.stagePairs.count, 3)
        XCTAssertEqual(LiveTranslationTiming.contextSentenceCount, 4)
    }

    func testReadyGateBlocksDeniedMicrophoneAndMissingPack() {
        let blocked = TheaterReadyGate.snapshot(
            engineSupportsSource: true,
            modelInstalled: true,
            sameLanguagePair: false,
            pack: .supported,
            microphone: .denied,
            firstCaptionPrinted: false
        )
        XCTAssertFalse(blocked.canListen)
        XCTAssertTrue(blocked.nextAction.contains("microphone"))

        let sameLanguage = TheaterReadyGate.snapshot(
            engineSupportsSource: true,
            modelInstalled: true,
            sameLanguagePair: true,
            pack: .unknown,
            microphone: .authorized,
            firstCaptionPrinted: true
        )
        XCTAssertTrue(sameLanguage.canListen)
        XCTAssertTrue(sameLanguage.isFullyReady)
        XCTAssertEqual(sameLanguage.nextAction, "Ready.")

        let watchBlocked = TheaterReadyGate.snapshot(
            engineSupportsSource: true,
            modelInstalled: true,
            sameLanguagePair: true,
            pack: .installed,
            microphone: .authorized,
            firstCaptionPrinted: false,
            mode: .watch,
            screenRecordingAllowed: false
        )
        XCTAssertFalse(watchBlocked.canListen)
        XCTAssertTrue(watchBlocked.nextAction.contains("restarting") || watchBlocked.nextAction.contains("reopen"))
    }

    @MainActor
    func testLocalCommitTranslationKeepsTargetScript() {
        XCTAssertEqual(
            LLMTranslationEngine.acceptedCommitTranslation(
                "오늘 모델을 학습했습니다.",
                sourceText: "Today we trained the model.",
                target: TranslationLanguageCatalog.korean
            ),
            "오늘 모델을 학습했습니다."
        )
        XCTAssertNil(
            LLMTranslationEngine.acceptedCommitTranslation(
                "Today we trained the model.",
                sourceText: "Today we trained the model.",
                target: TranslationLanguageCatalog.korean
            )
        )
        let prompt = LLMTranslationPrompt.translateMessages(
            sourceText: "Today we trained the model.",
            priorSource: ["Hello."],
            sourceLanguage: "English",
            targetLanguage: "Korean"
        )
        XCTAssertTrue(prompt[0]["content"]?.contains("Translate") == true)
    }

    @MainActor
    func testLocalCommitRejectsPunctuationStrippedAndLabeledEchoes() {
        let source = "Today we trained the model."
        XCTAssertNil(
            LLMTranslationEngine.acceptedCommitTranslation(
                "Today we trained the model!",
                sourceText: source,
                target: TranslationLanguageCatalog.korean
            )
        )
        XCTAssertNil(
            LLMTranslationEngine.acceptedCommitTranslation(
                "Original: Today we trained the model.",
                sourceText: source,
                target: TranslationLanguageCatalog.korean
            )
        )
        XCTAssertNil(
            LLMTranslationEngine.acceptedCommitTranslation(
                "\"Today we trained the model.\"",
                sourceText: source,
                target: TranslationLanguageCatalog.korean
            )
        )
        XCTAssertEqual(
            LLMTranslationEngine.commitVerdict(
                "Translation: 오늘 모델을 학습했습니다.",
                sourceText: source,
                target: TranslationLanguageCatalog.korean
            ),
            .accept("오늘 모델을 학습했습니다.")
        )
        XCTAssertEqual(
            LLMTranslationEngine.commitVerdict(
                "Ｔｏｄａｙ ｗｅ ｔｒａｉｎｅｄ ｔｈｅ ｍｏｄｅｌ．",
                sourceText: source,
                target: TranslationLanguageCatalog.korean
            ),
            .echo
        )
    }

    @MainActor
    func testLocalCommitRejectsEngineErrorText() {
        let source = "Today we trained the model."
        XCTAssertNil(
            LLMTranslationEngine.acceptedCommitTranslation(
                "Error: quota exceeded",
                sourceText: source,
                target: TranslationLanguageCatalog.korean
            )
        )
        XCTAssertNil(LLMTranslationEngine.captionSafeForBoard("Error: quota exceeded", sourceText: source))
        XCTAssertNil(LLMTranslationEngine.captionSafeForBoard(source, sourceText: source))
        XCTAssertEqual(
            LLMTranslationEngine.captionSafeForBoard("오늘 모델을 학습했습니다.", sourceText: source),
            "오늘 모델을 학습했습니다."
        )
        XCTAssertFalse(
            LLMTranslationEngine.looksLikeEngineError("The API key is stored locally on this Mac.")
        )
    }

    func testLocalEchoTallySkipsAfterMostLinesEcho() {
        var tally = LocalTranslationEchoTally()
        for _ in 0..<4 {
            tally.record(echoed: true)
            XCTAssertFalse(tally.shouldSkipLocal)
        }
        tally.record(echoed: false)
        XCTAssertTrue(tally.shouldSkipLocal)
        XCTAssertEqual(tally.attempts, LiveTranslationTiming.localEchoFailMinimumAttempts)
        XCTAssertEqual(LiveTranslationTiming.localEchoFailRatio, 0.80, accuracy: 0.001)

        var mixed = LocalTranslationEchoTally()
        mixed.record(echoed: true)
        mixed.record(echoed: true)
        mixed.record(echoed: false)
        mixed.record(echoed: false)
        mixed.record(echoed: false)
        XCTAssertFalse(mixed.shouldSkipLocal)
    }

    @MainActor
    func testLocalEngineSkipsCommitAfterListenEchoes() {
        let settings = SettingsStore.shared
        let original = settings.mlxRunnerEnabled
        defer { settings.mlxRunnerEnabled = original }
        settings.mlxRunnerEnabled = true

        let engine = LLMTranslationEngine()
        for _ in 0..<4 {
            engine.noteListenEcho(true)
        }
        engine.noteListenEcho(false)
        XCTAssertTrue(engine.echoTally.shouldSkipLocal)
        XCTAssertFalse(engine.isReadyForCommitTranslation(settings: settings))
        engine.resetListenEchoTally()
        XCTAssertFalse(engine.echoTally.shouldSkipLocal)
    }

    private static func pairs(from entries: [LectureCaptionEntry]) -> [CaptionHistoryPair] {
        entries.map {
            CaptionHistoryPair(source: $0.source, translated: $0.translated, wasPolished: $0.wasPolished)
        }
    }

    private static func isParakeet(_ model: SettingsStore.SpeechModel) -> Bool {
        switch model {
        case .parakeetTDT, .parakeetTDTv2, .parakeetRealtime:
            return true
        default:
            return false
        }
    }

}
