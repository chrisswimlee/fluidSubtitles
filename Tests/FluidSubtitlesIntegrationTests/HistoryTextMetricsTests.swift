import XCTest
@testable import FluidSubtitles_Debug

final class HistoryTextMetricsTests: XCTestCase {
    func testEnglishWhitespaceCountUnchanged() {
        XCTAssertEqual(HistoryTextMetrics.wordCount(in: ""), 0)
        XCTAssertEqual(HistoryTextMetrics.wordCount(in: " \n "), 0)
        XCTAssertEqual(HistoryTextMetrics.wordCount(in: "  one\t two\nthree  "), 3)
        XCTAssertEqual(HistoryTextMetrics.wordCount(in: "New dictation"), 2)
        XCTAssertEqual(HistoryTextMetrics.wordCount(in: "Unsaved"), 1)
    }

    func testKoreanJapaneseAndThaiAreNotOneWord() {
        XCTAssertEqual(HistoryTextMetrics.wordCount(in: "안녕하세요"), 5)
        XCTAssertEqual(HistoryTextMetrics.wordCount(in: "こんにちは"), 5)
        XCTAssertGreaterThan(HistoryTextMetrics.wordCount(in: "สวัสดีครับ"), 1)
    }

    func testFTSQueryStripsOperators() {
        XCTAssertEqual(TranscriptionHistoryDatabase.ftsQuery(from: "hello world"), "\"hello\" AND \"world\"")
        XCTAssertEqual(TranscriptionHistoryDatabase.ftsQuery(from: "hello* OR world"), "\"hello\" AND \"OR\" AND \"world\"")
        XCTAssertNil(TranscriptionHistoryDatabase.ftsQuery(from: "   "))
    }
}

final class HistoryRetentionAndSearchTests: XCTestCase {
    func testPruneDropsOldRowsAndKeepsNewest() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-retention-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let database = try TranscriptionHistoryDatabase(url: url)
        let old = Self.entry(text: "old row", timestamp: Date(timeIntervalSince1970: 10))
        let kept = Self.entry(text: "kept row", timestamp: Date())
        try database.write(
            upserts: [try Self.record(old), try Self.record(kept)],
            deletes: [],
            replacing: true
        )
        let result = try database.prune(
            policy: HistoryRetentionPolicy(maxAgeSeconds: 86_400, maxRows: 20_000)
        )
        XCTAssertEqual(Set(result.deletedIDs), [old.id])
        XCTAssertEqual(try database.read().map(\.id), [kept.id])
    }

    func testSearchFindsIndexedBody() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-fts-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let database = try TranscriptionHistoryDatabase(url: url)
        let match = Self.entry(text: "unique caption zebra", timestamp: Date())
        let other = Self.entry(text: "unrelated note", timestamp: Date().addingTimeInterval(-1))
        try database.write(
            upserts: [try Self.record(match), try Self.record(other)],
            deletes: [],
            replacing: true
        )
        let page = try database.readPage(limit: 10, query: "zebra")
        XCTAssertEqual(page.map(\.id), [match.id])
    }

    func testFeedbackMarkdownStaysLocal() {
        let markdown = TranscriptionFeedbackReporter.markdown(
            for: .init(
                rawText: "raw",
                processedText: "processed",
                processingModel: "test",
                comments: "note"
            )
        )
        XCTAssertTrue(markdown.contains("Speech stays on this Mac"))
        XCTAssertTrue(markdown.contains("raw"))
        XCTAssertTrue(markdown.contains("processed"))
    }

    func testLocalDraftWritesMarkdown() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("feedback-draft-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let draft = try LocalFeedbackDraft.write(
            title: "Test",
            body: "hello",
            fileManager: FileManager.default,
            now: Date(timeIntervalSince1970: 1_700_000_000),
            directory: root
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: draft.fileURL.path))
        XCTAssertTrue(draft.body.contains("hello"))
    }

    private static func entry(text: String, timestamp: Date) -> TranscriptionHistoryEntry {
        TranscriptionHistoryEntry(
            timestamp: timestamp,
            rawText: text,
            processedText: text,
            appName: "Test",
            windowTitle: "Test",
            wasAIProcessed: false
        )
    }

    private static func record(_ entry: TranscriptionHistoryEntry) throws -> TranscriptionHistoryDatabase.Record {
        TranscriptionHistoryDatabase.Record(id: entry.id, payload: try JSONEncoder().encode(entry))
    }
}
