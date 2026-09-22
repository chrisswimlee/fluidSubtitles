import AppKit
import XCTest
@testable import FluidSubtitles_Debug

final class LiveTranslationArchiveTests: XCTestCase {
    func testVisibleWindowStaysCappedAndOverflowLivesOnDisk() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("theater-soak-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let archive = LectureCaptionArchive(url: url)
        var log = LectureCaptionLog()

        for index in 1...3000 {
            guard let committed = log.commit(source: "line \(index).", translated: "caption \(index).") else {
                XCTFail("commit failed at \(index)")
                return
            }
            archive.append(committed.overflow)
        }

        XCTAssertEqual(LiveTranslationTiming.maxCommittedLines, LiveTranslationTiming.visibleTheaterLines)
        XCTAssertEqual(log.entries.count, LiveTranslationTiming.visibleTheaterLines)
        XCTAssertEqual(archive.overflowCount, 3000 - LiveTranslationTiming.visibleTheaterLines)
        XCTAssertEqual(log.translatedLines.first, "caption \(3000 - LiveTranslationTiming.visibleTheaterLines + 1).")
        XCTAssertEqual(log.translatedLines.last, "caption 3000.")
        XCTAssertEqual(archive.loadAll().count, 3000 - LiveTranslationTiming.visibleTheaterLines)
        XCTAssertEqual(archive.loadAll().first?.translated, "caption 1.")

        let counted = LectureCaptionArchive(url: url)
        XCTAssertEqual(counted.overflowCount, 0)
        counted.recount()
        XCTAssertEqual(counted.overflowCount, 3000 - LiveTranslationTiming.visibleTheaterLines)
    }

    func testLegacySnapshotDecodesWithoutCommittedAt() throws {
        let json = """
        {"id":7,"source":"Hello.","translated":"안녕.","wasPolished":false}
        """
        let entry = try JSONDecoder().decode(LectureCaptionEntry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.id, 7)
        XCTAssertEqual(entry.source, "Hello.")
        XCTAssertEqual(entry.translated, "안녕.")
        XCTAssertEqual(entry.committedAt, .distantPast)
    }

    func testAppendLoadAllAndRecountAgreeOnTempURL() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("theater-durable-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let archive = LectureCaptionArchive(url: url)
        archive.append([
            LectureCaptionEntry(id: 1, source: "one.", translated: "하나."),
            LectureCaptionEntry(id: 2, source: "two.", translated: "둘."),
            LectureCaptionEntry(id: 3, source: "three.", translated: "셋.")
        ])

        XCTAssertEqual(archive.overflowCount, 3)
        let loaded = archive.loadAll()
        XCTAssertEqual(loaded.count, 3)
        XCTAssertEqual(loaded.map(\.id), [1, 2, 3])
        XCTAssertEqual(archive.overflowCount, 3)

        let recounted = LectureCaptionArchive(url: url)
        recounted.recount()
        XCTAssertEqual(recounted.overflowCount, 3)
        XCTAssertEqual(recounted.loadAll().map(\.translated), ["하나.", "둘.", "셋."])
    }

    func testEmptyFileRecountsZero() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("theater-empty-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let missing = LectureCaptionArchive(url: url)
        missing.recount()
        XCTAssertEqual(missing.overflowCount, 0)

        FileManager.default.createFile(atPath: url.path, contents: Data())
        let empty = LectureCaptionArchive(url: url)
        empty.recount()
        XCTAssertEqual(empty.overflowCount, 0)
        XCTAssertTrue(empty.loadAll().isEmpty)
        XCTAssertEqual(empty.overflowCount, 0)
    }

    func testLoadAllSkipsCorruptLineWhileRecountCountsPhysicalLines() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("theater-corrupt-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let jsonl = """
        {"id":1,"source":"one.","translated":"하나.","wasPolished":false}
        {not-valid-json
        {"id":2,"source":"two.","translated":"둘.","wasPolished":false}
        """
        try Data(jsonl.utf8).write(to: url)

        let archive = LectureCaptionArchive(url: url)
        let loaded = archive.loadAll()
        XCTAssertEqual(loaded.map(\.id), [1, 2])
        XCTAssertEqual(archive.overflowCount, 2)

        let recounted = LectureCaptionArchive(url: url)
        recounted.recount()
        XCTAssertEqual(recounted.overflowCount, 3)
    }

    func testEnqueueIsVisibleToLoadAllWithoutCallingAppend() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("theater-enqueue-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let archive = LectureCaptionArchive(url: url)
        for index in 1...20 {
            archive.enqueue([
                LectureCaptionEntry(id: UInt64(index), source: "line \(index).", translated: "caption \(index).")
            ])
        }
        XCTAssertEqual(archive.overflowCount, 20)
        let loaded = archive.loadAll()
        XCTAssertEqual(loaded.count, 20)
        XCTAssertEqual(loaded.first?.translated, "caption 1.")
        XCTAssertEqual(loaded.last?.translated, "caption 20.")
        XCTAssertEqual(archive.overflowCount, 20)
    }

    @MainActor
    func testExportUsesArchivedLinesPlusTheVisibleWindow() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("theater-export-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let archive = LectureCaptionArchive(url: url)
        let subscriber = LiveTranslationSubscriber(
            translator: FakeTranslationEngine(),
            archive: archive
        )
        for index in 1...205 {
            subscriber.seedCommittedForTesting(source: "line \(index).", translated: "caption \(index).")
        }
        XCTAssertEqual(subscriber.committedLines.count, 205)
        XCTAssertEqual(subscriber.sessionLineCount, 205)
        // The board keeps the on-screen window; export and history keep the whole talk.
        XCTAssertEqual(subscriber.exportCaptionPairs.count, 205)
        XCTAssertEqual(subscriber.exportCaptionPairs.first?.translated, "caption 1.")
        XCTAssertEqual(subscriber.exportCaptionPairs.last?.translated, "caption 205.")
        XCTAssertNil(subscriber.lineWindowStatus)

        subscriber.reset(clearArchive: true)
        XCTAssertTrue(subscriber.committedLines.isEmpty)
        XCTAssertEqual(subscriber.archivedLineCount, 0)
        XCTAssertTrue(subscriber.exportCaptionPairs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

/// Every I speak → Show as pairing (12 translated + 4 same-language), fed
/// like ASR feeds Theater: a cumulative transcript in the spoken script.
@MainActor
final class TheaterLanguagePairTests: XCTestCase {
    private struct Speech {
        let id: String
        /// How ASR joins sentences in this script (Japanese has no spaces).
        let joiner: String
        let talk: [String]
        /// Two sentences that differ by one word.
        let similar: (String, String)
        /// A finished clause with no ending punctuation, then a pause.
        let paused: String
    }

    private let speech: [Speech] = [
        Speech(
            id: "en", joiner: " ",
            talk: ["Today we trained the model.", "Then we tested it on new data.", "The results were very good."],
            similar: ("We tested it on English data.", "We tested it on Korean data."),
            paused: "so this is how the attention layer works"
        ),
        Speech(
            id: "ko", joiner: " ",
            talk: ["오늘 모델을 학습했습니다.", "그다음 새 데이터로 테스트했습니다.", "결과가 아주 좋았습니다."],
            similar: ("영어 데이터로 모델을 테스트했습니다.", "한국어 데이터로 모델을 테스트했습니다."),
            paused: "그래서 이 어텐션 층이 이렇게 동작하는데 이것을 오늘 자세히 보여드리겠습니다"
        ),
        Speech(
            id: "ja", joiner: "",
            talk: ["今日はモデルを学習しました。", "次に新しいデータでテストしました。", "結果はとても良かったです。"],
            similar: ("英語のデータでモデルをテストしました。", "韓国語のデータでモデルをテストしました。"),
            paused: "それでこのアテンション層がこのように動くのを今日は詳しく説明しようと思います"
        ),
        Speech(
            id: "th", joiner: " ",
            talk: ["วันนี้เราฝึกโมเดลครับ", "จากนั้นเราทดสอบกับข้อมูลใหม่ครับ", "ผลลัพธ์ดีมากครับ"],
            similar: ("เราทดสอบโมเดลกับข้อมูลภาษาอังกฤษครับ", "เราทดสอบโมเดลกับข้อมูลภาษาเกาหลีครับ"),
            paused: "ดังนั้นชั้นแอทเทนชันนี้ทำงานแบบนี้และวันนี้ผมจะอธิบายรายละเอียดทั้งหมดให้ฟัง"
        ),
    ]

    private var originalSource = ""
    private var originalTarget = ""
    private var originalSpokenLine: TheaterSpokenLineMode = .afterPause

    override func setUp() async throws {
        self.originalSource = SettingsStore.shared.translationSourceLanguageID
        self.originalTarget = SettingsStore.shared.translationTargetLanguageID
        self.originalSpokenLine = SettingsStore.shared.theaterSpokenLineMode
        SettingsStore.shared.theaterSpokenLineMode = .afterPause
    }

    override func tearDown() async throws {
        SettingsStore.shared.translationSourceLanguageID = self.originalSource
        SettingsStore.shared.translationTargetLanguageID = self.originalTarget
        SettingsStore.shared.theaterSpokenLineMode = self.originalSpokenLine
    }

    private func subscriber(source: String, target: String) -> (LiveTranslationSubscriber, FakeTranslationEngine) {
        SettingsStore.shared.translationSourceLanguageID = source
        SettingsStore.shared.translationTargetLanguageID = target
        let engine = FakeTranslationEngine()
        engine.result = .success(target == "en" ? "Translated line." : "번역 [\(target)]")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let subscriber = LiveTranslationSubscriber(translator: engine, archive: LectureCaptionArchive(url: url))
        subscriber.beginListening()
        return (subscriber, engine)
    }

    private func pairs() -> [(Speech, String)] {
        self.speech.flatMap { spoken in self.speech.map { (spoken, $0.id) } }
    }

    private func settle() async {
        try? await Task.sleep(nanoseconds: 30_000_000)
    }

    /// Feed a sentence the way ASR grows it: half, full, full again.
    private func speak(_ sentence: String, after transcript: String, joiner: String, into subscriber: LiveTranslationSubscriber) async -> String {
        let characters = Array(sentence)
        let half = String(characters.prefix(characters.count / 2))
        let lead = transcript.isEmpty ? "" : transcript + joiner
        for partial in [lead + half, lead + sentence, lead + sentence] {
            subscriber.handlePartial(partial)
            await self.settle()
        }
        return lead + sentence
    }

    func testContinuousTalkPrintsEverySentenceOnceForEveryPair() async {
        var failures: [String] = []
        for (spoken, target) in self.pairs() {
            let (subscriber, _) = self.subscriber(source: spoken.id, target: target)
            var transcript = ""
            for sentence in spoken.talk {
                transcript = await self.speak(sentence, after: transcript, joiner: spoken.joiner, into: subscriber)
            }
            subscriber.handleEndOfUtterance()
            await subscriber.waitForIdleForTesting()
            if subscriber.committedSourceLines != spoken.talk {
                failures.append("\(spoken.id)→\(target): \(subscriber.committedSourceLines) draft=\"\(subscriber.sourceDraft)\"")
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testSimilarSentencesBothPrintForEveryPair() async {
        var failures: [String] = []
        for (spoken, target) in self.pairs() {
            let (subscriber, _) = self.subscriber(source: spoken.id, target: target)
            var transcript = await self.speak(spoken.similar.0, after: "", joiner: spoken.joiner, into: subscriber)
            transcript = await self.speak(spoken.similar.1, after: transcript, joiner: spoken.joiner, into: subscriber)
            subscriber.handleEndOfUtterance()
            await subscriber.waitForIdleForTesting()
            let expected = [spoken.similar.0, spoken.similar.1]
            if subscriber.committedSourceLines != expected {
                failures.append("\(spoken.id)→\(target): \(subscriber.committedSourceLines)")
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testPausedClausePrintsForEveryPair() async {
        var failures: [String] = []
        for (spoken, target) in self.pairs() {
            let (subscriber, _) = self.subscriber(source: spoken.id, target: target)
            subscriber.handlePartial(spoken.paused)
            await self.settle()
            subscriber.handlePartial(spoken.paused)
            await self.settle()
            subscriber.noteSilenceHold()
            await subscriber.waitForIdleForTesting()
            if subscriber.committedSourceLines.joined(separator: spoken.joiner) != spoken.paused {
                failures.append("\(spoken.id)→\(target): \(subscriber.committedSourceLines) draft=\"\(subscriber.sourceDraft)\"")
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testStopPrintsLeftoverForEveryPair() async {
        var failures: [String] = []
        for (spoken, target) in self.pairs() {
            let (subscriber, _) = self.subscriber(source: spoken.id, target: target)
            let transcript = await self.speak(spoken.talk[0], after: "", joiner: spoken.joiner, into: subscriber)
            let unfinished = String(spoken.talk[1].dropLast(spoken.id == "th" ? 4 : 1))
            let full = transcript + spoken.joiner + unfinished
            subscriber.handlePartial(full)
            _ = await subscriber.translateFinal(full)
            let printed = subscriber.committedSourceLines
            if printed.first != spoken.talk[0] || printed.count != 2 || printed.last != unfinished {
                failures.append("\(spoken.id)→\(target): \(printed)")
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    /// ASR drops a printed sentence's period and runs on: the newest line is
    /// fixed in place, never left behind as a fragment row.
    func testRestitchFixesNewestLineForEveryPair() async {
        let continuations = [
            "en": "on new data.",
            "ko": "새 데이터로 다시 했습니다.",
            "ja": "新しいデータで。",
            "th": "กับข้อมูลใหม่ครับ",
        ]
        var failures: [String] = []
        for (spoken, target) in self.pairs() {
            guard let tail = continuations[spoken.id] else { continue }
            let (subscriber, _) = self.subscriber(source: spoken.id, target: target)
            // Thai lecture lines in this fixture end in ครับ, not a period.
            // The Whisper bug is a dropped terminator; give Thai the same mark.
            let first = spoken.id == "th" ? "\(spoken.talk[0])." : spoken.talk[0]
            _ = await self.speak(first, after: "", joiner: spoken.joiner, into: subscriber)
            subscriber.handleEndOfUtterance()
            await subscriber.waitForIdleForTesting()
            var stem = first
            while let last = stem.last, ".。".contains(last) { stem.removeLast() }
            let revised = stem + spoken.joiner + tail
            let next = spoken.talk[2]
            for partial in [revised, revised + spoken.joiner + next, revised + spoken.joiner + next] {
                subscriber.handlePartial(partial)
                await self.settle()
            }
            subscriber.handleEndOfUtterance()
            await subscriber.waitForIdleForTesting()
            if subscriber.committedSourceLines != [revised, next] {
                failures.append("\(spoken.id)→\(target): \(subscriber.committedSourceLines)")
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testBoardPutsSpokenLineFirstForEveryPair() {
        let font = NSFont.systemFont(ofSize: 40, weight: .semibold)
        for (spoken, target) in self.pairs() {
            let translated = self.speech.first { $0.id == target }?.talk[0] ?? ""
            let rows = TheaterBilingualWrap.rows(spoken: spoken.talk[1], translated: translated, font: font, width: 420)
            XCTAssertTrue(rows.first?.isSpoken ?? false, "\(spoken.id)→\(target)")
            let spokenIndexes = rows.indices.filter { rows[$0].isSpoken }
            XCTAssertEqual(spokenIndexes, Array(0..<spokenIndexes.count), "\(spoken.id)→\(target)")
            XCTAssertFalse(rows.map(\.text).joined().isEmpty)
        }
    }
}

@MainActor
final class TheaterInsertPasteScopeTests: XCTestCase {
    func testCaptionLanguageNoLongerForcesPasteForDictation() {
        let settings = SettingsStore.shared
        let originalTarget = settings.translationTargetLanguageID
        let originalUsed = settings.theaterListenUsed
        defer {
            settings.translationTargetLanguageID = originalTarget
            settings.theaterListenUsed = originalUsed
        }
        settings.translationTargetLanguageID = "ko"
        settings.theaterListenUsed = true
        let english = InsertIMEGuard.Snapshot(identifier: "com.apple.keylayout.US", isASCIICapable: true)
        // Dictation follows the live input source, not the caption language.
        XCTAssertFalse(InsertIMEGuard.shouldAvoidUnicodeInjection(snapshot: english))
        // Caption inserts still ask for paste at their own call site.
        XCTAssertTrue(InsertIMEGuard.shouldPreferPasteForTheaterCaption())
        settings.translationTargetLanguageID = "en"
        XCTAssertFalse(InsertIMEGuard.shouldPreferPasteForTheaterCaption())
    }
}

@MainActor
final class TheaterTalkPackInspectorTests: XCTestCase {
    func testAddAndRemoveOneName() {
        let settings = SettingsStore.shared
        let originalTerms = settings.theaterTalkPackTerms
        let originalName = settings.theaterTalkPackFileName
        defer {
            settings.theaterTalkPackTerms = originalTerms
            settings.theaterTalkPackFileName = originalName
        }
        settings.clearTheaterTalkPack()
        XCTAssertTrue(settings.addTheaterTalkPackTerm("  PyTorch  "))
        XCTAssertFalse(settings.addTheaterTalkPackTerm("pytorch"), "case-insensitive duplicate")
        XCTAssertFalse(settings.addTheaterTalkPackTerm("   "))
        XCTAssertTrue(settings.addTheaterTalkPackTerm("김서연"))
        XCTAssertEqual(settings.theaterTalkPackTerms, ["PyTorch", "김서연"])
        XCTAssertTrue(settings.hasTheaterTalkPack)
        settings.removeTheaterTalkPackTerm("PyTorch")
        XCTAssertEqual(settings.theaterTalkPackTerms, ["김서연"])
    }

    func testAddStopsAtTheCap() {
        let settings = SettingsStore.shared
        let originalTerms = settings.theaterTalkPackTerms
        defer { settings.theaterTalkPackTerms = originalTerms }
        settings.theaterTalkPackTerms = (0..<TheaterTalkPack.maxTerms).map { "Name\($0)" }
        XCTAssertFalse(settings.addTheaterTalkPackTerm("OneMore"))
        XCTAssertEqual(settings.theaterTalkPackTerms.count, TheaterTalkPack.maxTerms)
    }
}
