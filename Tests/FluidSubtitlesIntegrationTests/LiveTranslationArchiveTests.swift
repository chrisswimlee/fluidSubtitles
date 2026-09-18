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
        XCTAssertEqual(subscriber.committedLines.count, LiveTranslationTiming.visibleTheaterLines)
        XCTAssertEqual(subscriber.sessionLineCount, LiveTranslationTiming.visibleTheaterLines)
        XCTAssertEqual(subscriber.exportCaptionPairs.count, LiveTranslationTiming.visibleTheaterLines)
        XCTAssertEqual(
            subscriber.exportCaptionPairs.first?.translated,
            "caption \(205 - LiveTranslationTiming.visibleTheaterLines + 1)."
        )
        XCTAssertNil(subscriber.lineWindowStatus)

        subscriber.reset(clearArchive: true)
        XCTAssertTrue(subscriber.committedLines.isEmpty)
        XCTAssertEqual(subscriber.archivedLineCount, 0)
        XCTAssertTrue(subscriber.exportCaptionPairs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
