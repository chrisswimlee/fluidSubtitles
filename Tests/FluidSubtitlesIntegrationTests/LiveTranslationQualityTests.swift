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

    func testProductLanguagesAreTheAppleAndVoiceOverlap() {
        XCTAssertEqual(
            VoiceEngineLanguageCatalog.productLanguageIDs,
            TranslationLanguageCatalog.supportedIDs
        )
        XCTAssertEqual(
            Set(VoiceEngineLanguageCatalog.allLanguages().map(\.id)),
            TranslationLanguageCatalog.supportedIDs
        )
        XCTAssertEqual(TranslationLanguageCatalog.language(id: "nb")?.id, "no")
        XCTAssertEqual(TranslationLanguageCatalog.language(id: "zh-TW")?.id, "zh")
        XCTAssertEqual(TranslationLanguageCatalog.language(id: "pt-PT")?.id, "pt")
        XCTAssertNil(TranslationLanguageCatalog.language(id: "el"))
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

        guard let japaneseLanguage = VoiceEngineLanguageCatalog.language(id: "ja", availableModels: catalogModels) else {
            XCTFail("Japanese should be a product language")
            return
        }
        let japanese = VoiceEngineLanguageCatalog.routes(for: japaneseLanguage, availableModels: catalogModels)
        XCTAssertFalse(japanese.isEmpty)
        XCTAssertFalse(
            japanese.contains { Self.isParakeet($0.model) },
            "Japanese preferred routes must not include Parakeet."
        )
        XCTAssertTrue(
            japanese.contains { $0.model == .cohereTranscribeSixBit },
            "Japanese should expose Cohere."
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

    func testBilingualWrapPutsSpokenJapaneseBeforeEnglish() {
        let font = NSFont.systemFont(ofSize: 24, weight: .semibold)
        let rows = TheaterBilingualWrap.rows(
            spoken: "こんにちは",
            translated: "Hello",
            font: font,
            width: 800
        )
        XCTAssertGreaterThanOrEqual(rows.count, 2)
        XCTAssertEqual(rows[0].text, "こんにちは")
        XCTAssertTrue(rows[0].isSpoken)
        XCTAssertEqual(rows[1].text, "Hello")
        XCTAssertFalse(rows[1].isSpoken)
    }



    func testLeftoverTailPeelsAfterCommittedSentence() {
        XCTAssertEqual(
            TranslationClauseSegmenter.leftoverTail(
                "오늘 모델을 학습했습니다. 그걸 적용했습니다.",
                already: ["오늘 모델을 학습했습니다."],
                languageID: "ko"
            ),
            "그걸 적용했습니다."
        )
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

    func testBilingualWrapFillsAWideBoardInsteadOfTwelveWords() {
        let font = NSFont.systemFont(ofSize: 32, weight: .semibold)
        let short = "Hello there friends"
        XCTAssertEqual(TheaterBilingualWrap.visualLines(short, font: font, width: 2000), [short])
        let text = "Today we trained the model then we applied it together now please everyone"
        let target = TheaterBilingualWrap.targetLineUnits(for: text, font: font, width: 2000)
        XCTAssertGreaterThan(target, 12)
        let lines = TheaterBilingualWrap.visualLines(text, font: font, width: 2000)
        XCTAssertEqual(lines, [text])
        let grown = TheaterBilingualWrap.visualLines(text + " later", font: font, width: 2000)
        XCTAssertEqual(grown, [text + " later"])
    }

    func testBilingualWrapUsesFewerWordsOnANarrowBoard() {
        let font = NSFont.systemFont(ofSize: 32, weight: .semibold)
        let text = "Today we trained the model then we applied it together"
        let lines = TheaterBilingualWrap.visualLines(text, font: font, width: 220)
        XCTAssertGreaterThan(lines.count, 1)
        XCTAssertTrue(text.hasPrefix(lines[0]))
        XCTAssertFalse(lines[0].contains("together"))
    }

    func testBilingualWrapFillsAWideCompactTitle() {
        let font = NSFont.systemFont(ofSize: 32, weight: .semibold)
        let text = "오늘우리는그모델을함께학습하고적용했습니다지금바로여기서확인합니다"
        let target = TheaterBilingualWrap.targetLineUnits(for: text, font: font, width: 2000)
        XCTAssertGreaterThan(target, 22)
        let lines = TheaterBilingualWrap.visualLines(text, font: font, width: 2000)
        XCTAssertEqual(lines, [text])
    }

    func testTranslateStackFillsAWideShowAsTitle() {
        let spokenFont = NSFont.systemFont(ofSize: 24, weight: .semibold)
        let titleFont = NSFont.systemFont(ofSize: 32, weight: .semibold)
        let spoken = "Today we trained the model then we applied it together now"
        let title = "오늘 우리는 그 모델을 학습한 다음 함께 적용했습니다"
        let rows = TheaterBilingualWrap.rows(
            spoken: spoken,
            translated: title,
            spokenFont: spokenFont,
            translatedFont: titleFont,
            width: 2000
        )
        XCTAssertEqual(rows.filter(\.isSpoken).map(\.text), [spoken])
        XCTAssertEqual(rows.filter { !$0.isSpoken }.map(\.text), [title])
    }

    func testBilingualWrapKeepsOpeningQuotesWithTheNextWord() {
        let font = NSFont.systemFont(ofSize: 32, weight: .semibold)
        let text = "He said \"Hello there friends today\""
        let lines = Self.wrappingLines(text, font: font)
        XCTAssertGreaterThan(lines.count, 1)
        XCTAssertFalse(
            lines.contains { $0.hasSuffix(" \"") || $0.hasSuffix("「") },
            "Opening quote must not sit alone at the end of a line: \(lines)"
        )
        XCTAssertTrue(
            lines.contains { $0.contains("\"Hello") || $0.hasPrefix("\"") },
            "Quote should travel with Hello: \(lines)"
        )
    }

    func testBilingualWrapKeepsJapaneseQuotesAndSmallKanaTogether() {
        let font = NSFont.systemFont(ofSize: 32, weight: .semibold)
        let text = "彼は「よろしくお願いします」と言いました"
        let lines = Self.wrappingLines(text, font: font)
        XCTAssertGreaterThan(lines.count, 1)
        XCTAssertFalse(
            lines.contains { line in
                guard let last = line.last else { return false }
                return "「『".contains(last)
            },
            "Opening bracket must not end a line: \(lines)"
        )
        XCTAssertFalse(
            lines.contains { line in
                guard let first = line.first else { return false }
                return "」』。、ょっゃゅー".contains(first)
            },
            "Closing mark or small kana must not start a line: \(lines)"
        )
    }

    func testBilingualWrapKeepsHyphenatedWordsTogether() {
        let font = NSFont.systemFont(ofSize: 32, weight: .semibold)
        let text = "Use a well-known model today please everyone"
        let lines = Self.wrappingLines(text, font: font)
        XCTAssertGreaterThan(lines.count, 1)
        XCTAssertFalse(
            lines.contains { $0.hasPrefix("-") || $0.contains("well-") && !$0.contains("well-known") },
            "Hyphen must not start the next line: \(lines)"
        )
        XCTAssertEqual(lines.joined().replacingOccurrences(of: " ", with: ""), "Useawell-knownmodeltodaypleaseeveryone")
    }

    func testBilingualWrapSplitsAWordThatCannotFitTheBoard() {
        let font = NSFont.systemFont(ofSize: 48, weight: .semibold)
        let text = "internationalization"
        let lines = TheaterBilingualWrap.visualLines(text, font: font, width: 80)
        XCTAssertGreaterThan(lines.count, 1)
        XCTAssertEqual(lines.joined(), text)
        for line in lines {
            let width = ceil((line as NSString).size(withAttributes: [.font: font]).width)
            XCTAssertLessThanOrEqual(width, 120, "Overflow split left a clipped chunk: \(line)")
        }
    }

    private static func wrappingLines(_ text: String, font: NSFont) -> [String] {
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
        return TheaterBilingualWrap.visualLines(text, font: font, width: width)
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

    func testEngineCopyKeepsVoiceAndTranslationSeparate() {
        XCTAssertTrue(TheaterEngineCopy.voicePurpose.contains("speech into text"))
        XCTAssertEqual(TheaterEngineCopy.translationName(), "Apple Translation")
        XCTAssertTrue(TheaterEngineCopy.translationPurpose.lowercased().contains("not a chat model"))
        XCTAssertEqual(TheaterTranslationEngineKind.apple.displayName, "Apple Translation")
        XCTAssertEqual(TheaterTranslationEngineKind.localLLM.displayName, "Local small LLM (experimental)")
        XCTAssertEqual(
            TheaterEngineCopy.translationRunningLine(
                mode: .transcription,
                sameLanguage: false,
                pack: .installed
            ),
            "Voice writes what you say. Translation Engine stays off."
        )
        XCTAssertEqual(
            TheaterEngineCopy.translationRunningLine(
                mode: .translation,
                sameLanguage: true,
                pack: .unknown
            ),
            "Same language — Apple Translation is not needed."
        )
        XCTAssertEqual(
            TheaterEngineCopy.translationRunningLine(
                mode: .translation,
                sameLanguage: false,
                pack: .installed
            ),
            "Running Apple Translation on this Mac."
        )
        XCTAssertEqual(
            TheaterEngineCopy.translationRunningLine(
                mode: .translation,
                sameLanguage: false,
                pack: .supported
            ),
            "Apple Translation needs this language pack once."
        )
        XCTAssertEqual(
            TheaterEngineCopy.translationRunningLine(
                mode: .translation,
                sameLanguage: false,
                pack: .installed,
                engine: .localLLM
            ),
            "Experimental local LLM can sharpen the first print. Apple Translation stays the fallback."
        )
        let settings = SettingsStore.shared
        let previous = settings.mlxRunnerEnabled
        settings.theaterTranslationEngine = .localLLM
        XCTAssertTrue(settings.mlxRunnerEnabled)
        XCTAssertEqual(TheaterEngineCopy.translationName(settings: settings), "Local small LLM (experimental)")
        settings.theaterTranslationEngine = .apple
        XCTAssertFalse(settings.mlxRunnerEnabled)
        settings.mlxRunnerEnabled = previous
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
        XCTAssertEqual(TheaterQualityScore.stagePairs.count, 5)
        XCTAssertEqual(LiveTranslationTiming.contextSentenceCount, 4)
    }

    func testCharacterErrorRateIsZeroForIdenticalKoreanStrings() {
        XCTAssertEqual(
            TheaterQualityScore.characterErrorRate(
                reference: TheaterQualityScore.korean.spoken,
                hypothesis: TheaterQualityScore.korean.spoken
            ),
            0
        )
    }

    func testCharacterErrorRateIgnoresPunctuationAndWhitespace() {
        XCTAssertEqual(
            TheaterQualityScore.characterErrorRate(
                reference: "Hello, World!",
                hypothesis: "hello world"
            ),
            0
        )
    }

    func testCharacterErrorRateComputesEditDistanceOverReferenceLength() {
        XCTAssertEqual(
            TheaterQualityScore.characterErrorRate(
                reference: "안녕",
                hypothesis: "안녕하세요"
            ),
            1.5,
            accuracy: 0.0001
        )
    }

    func testCharacterErrorRateIsOneWhenReferenceEmptyAndHypothesisNonEmpty() {
        XCTAssertEqual(
            TheaterQualityScore.characterErrorRate(
                reference: "",
                hypothesis: "안녕"
            ),
            1
        )
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
        XCTAssertEqual(blocked.nextAction, MicrophoneAccess.deniedCopy)

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

        let voiceNeedsSpeech = TheaterReadyGate.snapshot(
            engineSupportsSource: true,
            modelInstalled: true,
            sameLanguagePair: true,
            pack: .installed,
            microphone: .authorized,
            firstCaptionPrinted: false,
            mode: .transcription
        )
        XCTAssertTrue(voiceNeedsSpeech.canListen)
        XCTAssertTrue(voiceNeedsSpeech.nextAction.contains("Listen"))

        let coldPackStillAllowsListen = TheaterReadyGate.snapshot(
            engineSupportsSource: true,
            modelInstalled: true,
            sameLanguagePair: false,
            pack: .unknown,
            microphone: .authorized,
            firstCaptionPrinted: true
        )
        XCTAssertTrue(coldPackStillAllowsListen.canListen)
        XCTAssertTrue(coldPackStillAllowsListen.languagePackReady)
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
        XCTAssertEqual(
            LLMTranslationEngine.acceptedCommitTranslation(
                "今日はモデルを学習しました。",
                sourceText: "Today we trained the model.",
                target: TranslationLanguageCatalog.japanese
            ),
            "今日はモデルを学習しました。"
        )
        XCTAssertNil(
            LLMTranslationEngine.acceptedCommitTranslation(
                "Today we trained the model.",
                sourceText: "Today we trained the model.",
                target: TranslationLanguageCatalog.japanese
            )
        )
        let prompt = LLMTranslationPrompt.translateMessages(
            sourceText: "Today we trained the model.",
            priorSource: ["Hello."],
            sourceLanguage: "English",
            targetLanguage: "Korean"
        )
        XCTAssertTrue(prompt[0]["content"]?.contains("Translate") == true)
        let withTerms = LLMTranslationPrompt.translateMessages(
            sourceText: "Today we trained the model.",
            priorSource: ["Hello."],
            sourceLanguage: "English",
            targetLanguage: "Korean",
            terms: ["Nemotron", "fluidSubtitles"]
        )
        XCTAssertTrue(withTerms[0]["content"]?.contains("Nemotron") == true)
        XCTAssertTrue(withTerms[0]["content"]?.contains("fluidSubtitles") == true)
        XCTAssertTrue(
            LLMTranslationPrompt.termGuidance([]).contains("Keep names and glossary tokens unchanged.")
        )
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

    @MainActor
    func testLocalEngineIgnoresLegacyPolishFlag() {
        let settings = SettingsStore.shared
        let originalMLX = settings.mlxRunnerEnabled
        let originalPolish = settings.llmTranslationPolishEnabled
        defer {
            settings.mlxRunnerEnabled = originalMLX
            settings.llmTranslationPolishEnabled = originalPolish
        }
        settings.mlxRunnerEnabled = false
        settings.llmTranslationPolishEnabled = true
        XCTAssertFalse(LLMTranslationEngine().isAvailable(settings: settings))
        XCTAssertFalse(LLMTranslationEngine().isReadyForCommitTranslation(settings: settings))
    }

    @MainActor
    func testLocalFirstPrintStaysNilWhenLocalEngineIsOff() async {
        let settings = SettingsStore.shared
        let original = settings.mlxRunnerEnabled
        defer { settings.mlxRunnerEnabled = original }
        settings.mlxRunnerEnabled = false
        let llm = LLMTranslationEngine()
        let sharpened = await LiveTranslationMT.localFirstPrint(
            "Today we trained the model.",
            draft: "오늘 모델을 학습했습니다.",
            prior: (sources: [], translations: []),
            source: TranslationLanguageCatalog.english,
            target: TranslationLanguageCatalog.korean,
            terms: [],
            llmEngine: llm
        )
        XCTAssertNil(sharpened)
        XCTAssertFalse(llm.isReadyForCommitTranslation(settings: settings))
    }

    @MainActor
    func testAppleClauseWinsWhenLocalIsNotReady() async throws {
        let engine = FakeTranslationEngine()
        engine.result = .success("오늘 모델을 학습했습니다.")
        let llm = LLMTranslationEngine()
        let caption = try await LiveTranslationMT.translateClause(
            "Today we trained the model.",
            source: TranslationLanguageCatalog.english,
            target: TranslationLanguageCatalog.korean,
            terms: [],
            kind: .commit,
            prior: (sources: [], translations: []),
            translator: engine,
            llmEngine: llm
        )
        XCTAssertEqual(caption, "오늘 모델을 학습했습니다.")
        XCTAssertEqual(engine.calls, ["Today we trained the model."])
    }

    @MainActor
    func testTranslateWithRetrySucceedsOnSecondAttemptAfterTransientFailure() async throws {
        let engine = FakeTranslationEngine()
        engine.resultQueue = [
            .failure(TranslationEngineError(message: "network blip")),
            .success("오늘 모델을 학습했습니다."),
        ]
        let result = try await LiveTranslationMT.translateWithRetry(
            "Today we trained the model.",
            source: TranslationLanguageCatalog.english,
            target: TranslationLanguageCatalog.korean,
            engine: engine,
            kind: .commit
        )
        XCTAssertEqual(result, "오늘 모델을 학습했습니다.")
        XCTAssertEqual(engine.calls.count, 2)
    }

    @MainActor
    func testTranslateWithRetryThrowsSupersededWithoutRetrying() async {
        let engine = FakeTranslationEngine()
        engine.resultQueue = [
            .failure(TranslationEngineError.superseded),
            .success("should never be returned"),
        ]
        do {
            _ = try await LiveTranslationMT.translateWithRetry(
                "Today we trained the model.",
                source: TranslationLanguageCatalog.english,
                target: TranslationLanguageCatalog.korean,
                engine: engine,
                kind: .commit
            )
            XCTFail("expected translateWithRetry to throw")
        } catch let error as TranslationEngineError {
            XCTAssertTrue(error.isSuperseded)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
        XCTAssertEqual(engine.calls.count, 1)
    }

    @MainActor
    func testTranslateWithRetryThrowsAfterBothAttemptsFail() async {
        let engine = FakeTranslationEngine()
        engine.resultQueue = [
            .failure(TranslationEngineError(message: "first fail")),
            .failure(TranslationEngineError(message: "second fail")),
        ]
        do {
            _ = try await LiveTranslationMT.translateWithRetry(
                "Today we trained the model.",
                source: TranslationLanguageCatalog.english,
                target: TranslationLanguageCatalog.korean,
                engine: engine,
                kind: .commit
            )
            XCTFail("expected translateWithRetry to throw")
        } catch let error as TranslationEngineError {
            XCTAssertEqual(error.message, "second fail")
        } catch {
            XCTFail("wrong error type: \(error)")
        }
        XCTAssertEqual(engine.calls.count, 2)
    }

    @MainActor
    func testTranslateWithRetrySucceedsOnFirstAttemptWithoutRetry() async throws {
        let engine = FakeTranslationEngine()
        engine.resultQueue = [.success("바로 성공")]
        let result = try await LiveTranslationMT.translateWithRetry(
            "Today we trained the model.",
            source: TranslationLanguageCatalog.english,
            target: TranslationLanguageCatalog.korean,
            engine: engine,
            kind: .commit
        )
        XCTAssertEqual(result, "바로 성공")
        XCTAssertEqual(engine.calls.count, 1)
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

        for _ in 0..<4 {
            engine.noteListenFailure()
        }
        engine.noteListenEcho(false)
        XCTAssertTrue(engine.echoTally.shouldSkipLocal)
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

    func testConfirmedPrefixHoldsARestitchUntilTheSharedRun() {
        let previous = "I just woke up from my dream But you and I had to say goodbye And I don't know what it on me."
        let incoming = "I just woke up from my dream But you and I had to say goodbye And I don't know what it all means. But since I"
        let result = StreamingTranscriptStitcher.stitchResult(committed: previous, incoming: incoming)
        XCTAssertTrue(incoming.hasPrefix(result.confirmedPrefix) || result.text.hasPrefix(result.confirmedPrefix))
        XCTAssertFalse(result.confirmedPrefix.contains("all means"))
        XCTAssertEqual(
            StreamingTranscriptStitcher.monotonicTarget(
                printed: "what it on me",
                incoming: "what it all means"
            ),
            "what it on me"
        )
        XCTAssertEqual(
            StreamingTranscriptStitcher.monotonicTarget(
                printed: "What if discipline could...",
                incoming: "What if discipline could feel as good as scrolling?"
            ),
            "What if discipline could feel as good as scrolling?"
        )
        XCTAssertTrue(
            StreamingTranscriptStitcher.confirmedClauseContains(
                unit: "Today we trained the model.",
                confirmed: "Today we trained the model."
            )
        )
        XCTAssertFalse(
            StreamingTranscriptStitcher.confirmedClauseContains(
                unit: "Today we trained the model.",
                confirmed: "Today we trained the model then we applied it"
            )
        )
    }

    func testUnpunctuatedPauseCutDoesNotPeelItsOwnGrowth() {
        XCTAssertEqual(
            TranslationClauseSegmenter.leftoverTail(
                "so this is how the attention layer works in practice",
                already: ["so this is how the attention layer works"],
                languageID: "en"
            ),
            "in practice"
        )
        XCTAssertTrue(
            TranslationClauseSegmenter.isInPlaceGrowth(
                previous: "so this is how the attention layer works",
                incoming: "so this is how the attention layer works in practice"
            )
        )
        XCTAssertEqual(
            TranslationClauseSegmenter.leftoverTail(
                "Today we trained the model Then we applied it",
                already: ["Today we trained the model"],
                languageID: "en"
            ),
            "Then we applied it"
        )
    }

    func testUnspacedKoreanAlignsOnASharedRun() {
        let committed = "오늘우리는그모델을학습했습니다다음적용합"
        let incoming = "우리는그모델을학습했습니다다음적용했습니다"
        let stitched = StreamingTranscriptStitcher.stitch(committed: committed, incoming: incoming)
        XCTAssertEqual(stitched, "오늘우리는그모델을학습했습니다다음적용했습니다")
        XCTAssertTrue(TranslationClauseSegmenter.hasUnspacedScript("오늘모델을학습했습니다"))
    }

    func testUnreadPendingStaysOffTheBoard() {
        let pending = TheaterCaptionFlow.lines(
            committed: [],
            nextCaptionID: 1,
            draft: "",
            sourceDraft: "Then we applied it",
            pendingSources: ["Today we trained the model."],
            liveRowID: 2,
            spokenDisplay: .paired
        )
        XCTAssertTrue(pending.isEmpty)
        let afterFail = TheaterCaptionFlow.lines(
            committed: [],
            nextCaptionID: 1,
            draft: "",
            sourceDraft: "Then we applied it",
            pendingSources: [],
            liveRowID: 2,
            spokenDisplay: .paired
        )
        XCTAssertTrue(afterFail.isEmpty)
        XCTAssertEqual(
            TheaterCaptionFlow.liveID(after: [], nextID: 1, pendingCount: 0),
            "c-1"
        )
        XCTAssertEqual(
            TheaterCaptionFlow.liveID(after: [], nextID: 2, pendingCount: 0),
            "c-2"
        )
    }

    func testPendingDraftRowsDoNotReserveAShowAsSlotOnTheBoard() {
        let pending = TheaterCaptionFlow.lines(
            committed: [],
            nextCaptionID: 1,
            draft: "",
            sourceDraft: "Then we applied it",
            pendingSources: ["Today we trained the model."],
            liveRowID: 2,
            spokenDisplay: .paired
        )
        XCTAssertTrue(pending.isEmpty)
        let spokenFont = NSFont.systemFont(ofSize: 16)
        let titleFont = NSFont.systemFont(ofSize: 36)
        let rows = TheaterBilingualWrap.rows(
            spoken: "Today we trained the model.",
            translated: "",
            spokenFont: spokenFont,
            translatedFont: titleFont,
            width: 900
        )
        let reserved = TheaterBilingualWrap.reservedDisplayHeight(
            rows: rows,
            spokenFont: spokenFont,
            translatedFont: titleFont,
            width: 900
        )
        let tight = TheaterBilingualWrap.displayHeight(
            rows: rows,
            spokenFont: spokenFont,
            translatedFont: titleFont
        )
        XCTAssertGreaterThan(reserved, tight)
    }

    func testWrapWidthFollowsTheBoardLockWithoutASecondHysteresis() {
        let locked = TheaterBilingualWrap.layoutWrapWidth(proposed: 900, locked: 0)
        XCTAssertEqual(locked, 900)
        let smallWiden = TheaterBilingualWrap.layoutWrapWidth(proposed: 910, locked: 900)
        XCTAssertEqual(smallWiden, 900)
    }

    func testTornCommittedIDsDoNotCollideAcrossHistorySlots() {
        let rows = TheaterCaptionFlow.lines(
            committed: ["Hello.", "World."],
            committedIDs: [5],
            nextCaptionID: 6,
            draft: "",
            sourceDraft: "Then we applied it",
            liveRowID: 6,
            spokenDisplay: .paired
        )
        XCTAssertEqual(rows.map(\.id), ["c-5", "c-h-2"])
        XCTAssertFalse(rows.contains { $0.isDraft })
    }


    @MainActor
    func testHandlePartialHoldsARestitchThatRewritesAPrintedWord() {
        let settings = SettingsStore.shared
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        let originalMode = settings.theaterSessionMode
        let originalSpoken = settings.theaterSpokenLineMode
        defer {
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
            settings.theaterSessionMode = originalMode
            settings.theaterSpokenLineMode = originalSpoken
        }
        settings.theaterSessionMode = .translation
        settings.theaterSpokenLineMode = .afterPause
        settings.translationSourceLanguageID = "en"
        settings.translationTargetLanguageID = "ko"
        let subscriber = LiveTranslationSubscriber(translator: FakeTranslationEngine())
        subscriber.beginListening()
        subscriber.handlePartial("I don't know what it on me.")
        XCTAssertTrue(subscriber.liveSpokenText.contains("on me"))
        subscriber.handlePartial("I don't know what it all means. But since I")
        XCTAssertTrue(
            subscriber.liveSpokenText.contains("on me"),
            subscriber.liveSpokenText
        )
        XCTAssertFalse(subscriber.liveSpokenText.contains("all means"))
    }

    @MainActor
    func testFirstClauseUsesTheColdTranslateFloor() {
        let subscriber = LiveTranslationSubscriber(translator: FakeTranslationEngine())
        subscriber.beginListening()
        XCTAssertEqual(
            subscriber.translateTimeoutNsForTesting,
            LiveTranslationTiming.translateClauseTimeoutNanoseconds
        )
        subscriber.seedCommittedForTesting(source: "Yesterday.", translated: "어제.")
        XCTAssertEqual(
            subscriber.translateTimeoutNsForTesting,
            LiveTranslationTiming.commitMailboxTimeoutNanoseconds
        )
    }

    @MainActor
    func testHypothesisReplayNeverRewritesAPrintedWord() {
        let settings = SettingsStore.shared
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        let originalMode = settings.theaterSessionMode
        let originalSpoken = settings.theaterSpokenLineMode
        defer {
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
            settings.theaterSessionMode = originalMode
            settings.theaterSpokenLineMode = originalSpoken
        }
        settings.theaterSessionMode = .translation
        settings.theaterSpokenLineMode = .afterPause
        settings.translationSourceLanguageID = "en"
        settings.translationTargetLanguageID = "ko"
        let engine = FakeTranslationEngine()
        let subscriber = LiveTranslationSubscriber(translator: engine)
        subscriber.beginListening()
        let ticks = [
            "I feel fine.",
            "I feel the fine about it.",
            "I feel the fine about it.  Clear.",
            "I really fine about it.  Clear.",
            "I really fine about it.  Cle.  Exactly.",
        ]
        var printed = ""
        for tick in ticks {
            subscriber.handlePartial(tick)
            let target = subscriber.liveSpokenText
            if !printed.isEmpty, !target.isEmpty {
                let grew = target.hasPrefix(printed)
                let held = printed.hasPrefix(target)
                let peeled = !target.hasPrefix(printed) && !printed.hasPrefix(target)
                XCTAssertTrue(
                    grew || held || peeled || target == printed,
                    "printed=\(printed) target=\(target)"
                )
            }
            printed = target
        }
    }

    @MainActor
    func testLiveCaptionIDSurvivesAFailedCommit() async {
        let settings = SettingsStore.shared
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        let originalMode = settings.theaterSessionMode
        let originalSpoken = settings.theaterSpokenLineMode
        defer {
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
            settings.theaterSessionMode = originalMode
            settings.theaterSpokenLineMode = originalSpoken
        }
        settings.theaterSessionMode = .translation
        settings.theaterSpokenLineMode = .afterPause
        settings.translationSourceLanguageID = "en"
        settings.translationTargetLanguageID = "ko"
        let engine = FakeTranslationEngine()
        engine.result = .failure(TranslationEngineError(message: "pack missing"))
        let subscriber = LiveTranslationSubscriber(translator: engine)
        subscriber.beginListening()
        subscriber.handlePartial("Today we trained the model. Then we applied it.")
        subscriber.handlePartial("Today we trained the model. Then we applied it.")
        let before = subscriber.liveCaptionID
        XCTAssertGreaterThan(before, 0)
        await subscriber.waitForIdleForTesting()
        XCTAssertEqual(subscriber.liveCaptionID, before)
    }

}
