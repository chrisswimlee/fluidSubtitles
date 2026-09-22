import Foundation
import SQLite3

// swiftlint:disable type_body_length function_body_length file_length

struct HistoryRetentionPolicy: Equatable, Sendable {
    var maxAgeSeconds: TimeInterval?
    var maxRows: Int?

    static let unlimited = HistoryRetentionPolicy(maxAgeSeconds: nil, maxRows: nil)

    var isUnlimited: Bool {
        self.maxAgeSeconds == nil && self.maxRows == nil
    }
}

struct HistoryPruneResult: Equatable, Sendable {
    var deletedIDs: [UUID]
    var audioFileNames: [String]

    static let empty = HistoryPruneResult(deletedIDs: [], audioFileNames: [])
}

nonisolated enum HistoryTextMetrics {
    static func wordCount(in text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        var total = 0
        for token in trimmed.components(separatedBy: .whitespacesAndNewlines) where !token.isEmpty {
            total += self.tokenWeight(token)
        }
        return total
    }

    /// Latin and Thai phrase tokens stay 1. A Korean, Japanese, or Chinese
    /// run without spaces counts letters so Stats is not stuck at 1.
    static func tokenWeight(_ token: String) -> Int {
        var ideographs = 0
        var hasThai = false
        var hasWesternLetters = false
        for scalar in token.unicodeScalars {
            if self.isIdeographOrHangulOrKana(scalar) {
                ideographs += 1
            } else if (0x0E00...0x0E7F).contains(scalar.value) {
                hasThai = true
            } else if CharacterSet.letters.contains(scalar) {
                hasWesternLetters = true
            }
        }
        if hasThai {
            return max(token.count, 1)
        }
        if ideographs == 0 {
            return 1
        }
        return ideographs + (hasWesternLetters ? 1 : 0)
    }

    private static func isIdeographOrHangulOrKana(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (0x1100...0x11FF).contains(value)
            || (0x3040...0x30FF).contains(value)
            || (0x3130...0x318F).contains(value)
            || (0x4E00...0x9FFF).contains(value)
            || (0xAC00...0xD7AF).contains(value)
            || (0xF900...0xFAFF).contains(value)
    }

    static func summaryRecord(for entry: TranscriptionHistoryEntry) -> HistorySummaryRecord {
        HistorySummaryRecord(
            id: entry.id,
            timestamp: entry.timestamp,
            words: self.wordCount(in: entry.processedText),
            appName: entry.appName.isEmpty ? "Unknown" : entry.appName,
            wasAIProcessed: entry.wasAIProcessed
        )
    }
}

struct HistorySummaryRecord: Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let words: Int
    let appName: String
    let wasAIProcessed: Bool
}

struct HistoryStatsSnapshot: Sendable {
    var totalEntries: Int
    var totalWords: Int
    var aiProcessedCount: Int
    var todayWords: Int
    var todayTranscriptions: Int
    var longestWords: Int
    var topApps: [(app: String, count: Int)]
    var peakHour: Int?
    var mostWordsInDay: Int
    var mostTranscriptionsInDay: Int
    var activeDayStarts: [Date]

    static let empty = HistoryStatsSnapshot(
        totalEntries: 0,
        totalWords: 0,
        aiProcessedCount: 0,
        todayWords: 0,
        todayTranscriptions: 0,
        longestWords: 0,
        topApps: [],
        peakHour: nil,
        mostWordsInDay: 0,
        mostTranscriptionsInDay: 0,
        activeDayStarts: []
    )
}

/// Owned by the history writer's serial queue. One JSON payload per entry, not per history.
final class TranscriptionHistoryDatabase {
    private var ftsEnabled = false

    struct Record: Equatable {
        let id: UUID
        let payload: Data
    }

    private let connection: OpaquePointer

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open history."
            if let handle { sqlite3_close(handle) }
            throw NSError(domain: "HistoryDatabase", code: Int(status), userInfo: [NSLocalizedDescriptionKey: message])
        }
        self.connection = handle
        do {
            try self.execute("PRAGMA busy_timeout=2000")
            try self.execute("PRAGMA journal_mode=WAL")
            try self.execute("PRAGMA synchronous=FULL")
            try self.execute("PRAGMA secure_delete=ON")
            try self.execute("CREATE TABLE IF NOT EXISTS history (id TEXT PRIMARY KEY, payload BLOB NOT NULL)")
            try self.execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY)")
            try self.ensureIndexedColumns()
            try self.backfillIndexedColumnsIfNeeded()
            try self.ensureSearchIndex()
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    deinit { sqlite3_close(self.connection) }

    var isMigrated: Bool {
        get throws {
            let statement = try self.prepare("SELECT 1 FROM metadata WHERE key='legacy_imported'")
            defer { sqlite3_finalize(statement) }
            let result = sqlite3_step(statement)
            guard result == SQLITE_ROW || result == SQLITE_DONE else { throw self.error() }
            return result == SQLITE_ROW
        }
    }

    func migrate(_ records: [Record]) throws {
        guard try !self.isMigrated else { return }
        try self.transaction {
            for record in records {
                try self.upsert(record)
            }
            try self.execute("INSERT INTO metadata(key) VALUES ('legacy_imported')")
        }
    }

    func read() throws -> [Record] {
        try self.readRecords(sql: "SELECT id, payload FROM history ORDER BY timestamp DESC, id DESC")
    }

    func readPage(limit: Int, query: String?) throws -> [Record] {
        let clamped = max(1, limit)
        if let query {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return try self.searchRecords(query: trimmed, limit: clamped)
            }
        }
        return try self.readRecords(
            sql: "SELECT id, payload FROM history ORDER BY timestamp DESC, id DESC LIMIT \(clamped)"
        )
    }

    func readSummaryRecords() throws -> [HistorySummaryRecord] {
        let statement = try self.prepare(
            "SELECT id, timestamp, word_count, app_name, was_ai FROM history ORDER BY timestamp DESC, id DESC"
        )
        defer { sqlite3_finalize(statement) }
        var records: [HistorySummaryRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0),
                  let id = UUID(uuidString: String(cString: text))
            else { continue }
            let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
            let words = Int(sqlite3_column_int(statement, 2))
            let appName = sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? "Unknown"
            records.append(
                HistorySummaryRecord(
                    id: id,
                    timestamp: timestamp,
                    words: words,
                    appName: appName.isEmpty ? "Unknown" : appName,
                    wasAIProcessed: sqlite3_column_int(statement, 4) != 0
                )
            )
        }
        return records
    }

    func readEntriesWithAudio() throws -> [Record] {
        try self.readRecords(
            sql: "SELECT id, payload FROM history WHERE audio_file != '' ORDER BY timestamp ASC"
        )
    }

    func readEntry(id: UUID) throws -> Record? {
        try self.readRecords(sql: "SELECT id, payload FROM history WHERE id='\(id.uuidString)' LIMIT 1").first
    }

    func stats(dayStart: Date?, dayEnd: Date?) throws -> HistoryStatsSnapshot {
        let totals = try self.prepare("SELECT COUNT(*), COALESCE(SUM(word_count),0), COALESCE(SUM(was_ai),0), COALESCE(MAX(word_count),0) FROM history")
        defer { sqlite3_finalize(totals) }
        guard sqlite3_step(totals) == SQLITE_ROW else { throw self.error() }
        let totalEntries = Int(sqlite3_column_int(totals, 0))
        let totalWords = Int(sqlite3_column_int(totals, 1))
        let aiProcessed = Int(sqlite3_column_int(totals, 2))
        let longestWords = Int(sqlite3_column_int(totals, 3))

        var todayWords = 0
        var todayTranscriptions = 0
        if let dayStart, let dayEnd {
            let statement = try self.prepare(
                """
                SELECT COALESCE(SUM(word_count),0), COUNT(*) FROM history
                WHERE timestamp >= \(dayStart.timeIntervalSince1970)
                  AND timestamp < \(dayEnd.timeIntervalSince1970)
                """
            )
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw self.error() }
            todayWords = Int(sqlite3_column_int(statement, 0))
            todayTranscriptions = Int(sqlite3_column_int(statement, 1))
        }

        return HistoryStatsSnapshot(
            totalEntries: totalEntries,
            totalWords: totalWords,
            aiProcessedCount: aiProcessed,
            todayWords: todayWords,
            todayTranscriptions: todayTranscriptions,
            longestWords: longestWords,
            topApps: try self.topApps(limit: 8),
            peakHour: try self.peakHour(),
            mostWordsInDay: try self.extremeDayAggregate(words: true),
            mostTranscriptionsInDay: try self.extremeDayAggregate(words: false),
            activeDayStarts: try self.activeDayStarts()
        )
    }

    func write(upserts: [Record], deletes: [UUID], replacing: Bool) throws {
        try self.transaction {
            if replacing {
                try self.execute("DELETE FROM history")
                try self.clearSearchIndex()
            }
            for id in deletes {
                // UUID's canonical representation contains no SQL metacharacters.
                try self.execute("DELETE FROM history WHERE id='\(id.uuidString)'")
                try self.removeFromSearchIndex(id: id)
            }
            for record in upserts {
                try self.upsert(record)
            }
        }
    }

    func prune(policy: HistoryRetentionPolicy) throws -> HistoryPruneResult {
        guard !policy.isUnlimited else { return .empty }
        var deletedIDs: [UUID] = []
        var audioFileNames: [String] = []
        try self.transaction {
            var doomed = Set<UUID>()
            if let maxAge = policy.maxAgeSeconds {
                let cutoff = Date().timeIntervalSince1970 - maxAge
                let rows = try self.readPruneCandidates(
                    sql: "SELECT id, audio_file FROM history WHERE timestamp < \(cutoff)"
                )
                for row in rows {
                    doomed.insert(row.id)
                    if !row.audioFile.isEmpty { audioFileNames.append(row.audioFile) }
                }
            }
            if let maxRows = policy.maxRows, maxRows > 0 {
                let overflow = try self.readPruneCandidates(
                    sql: """
                    SELECT id, audio_file FROM history
                    WHERE id NOT IN (
                        SELECT id FROM history ORDER BY timestamp DESC, id DESC LIMIT \(maxRows)
                    )
                    """
                )
                for row in overflow {
                    doomed.insert(row.id)
                    if !row.audioFile.isEmpty { audioFileNames.append(row.audioFile) }
                }
            }
            for id in doomed {
                try self.execute("DELETE FROM history WHERE id='\(id.uuidString)'")
                try self.removeFromSearchIndex(id: id)
                deletedIDs.append(id)
            }
        }
        return HistoryPruneResult(deletedIDs: deletedIDs, audioFileNames: audioFileNames)
    }

    private func upsert(_ record: Record) throws {
        let entry = try JSONDecoder().decode(TranscriptionHistoryEntry.self, from: record.payload)
        let preview = String(entry.processedText.prefix(80))
        let wordCount = HistoryTextMetrics.wordCount(in: entry.processedText)
        let body = String((entry.processedText + "\n" + entry.rawText + "\n" + entry.windowTitle).prefix(8_000))
        let statement = try self.prepare(
            """
            INSERT OR REPLACE INTO history(id,payload,timestamp,preview,app_name,word_count,was_ai,body,audio_file)
            VALUES (?,?,?,?,?,?,?,?,?)
            """
        )
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = record.id.uuidString.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
        let blobStatus = record.payload.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(bytes.count), transient)
        }
        sqlite3_bind_double(statement, 3, entry.timestamp.timeIntervalSince1970)
        _ = preview.withCString { sqlite3_bind_text(statement, 4, $0, -1, transient) }
        _ = entry.appName.withCString { sqlite3_bind_text(statement, 5, $0, -1, transient) }
        sqlite3_bind_int(statement, 6, Int32(wordCount))
        sqlite3_bind_int(statement, 7, entry.wasAIProcessed ? 1 : 0)
        _ = body.withCString { sqlite3_bind_text(statement, 8, $0, -1, transient) }
        _ = (entry.audio?.fileName ?? "").withCString { sqlite3_bind_text(statement, 9, $0, -1, transient) }
        guard blobStatus == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw self.error() }
        try self.upsertSearchIndex(id: record.id, preview: preview, appName: entry.appName, body: body)
    }

    private func ensureIndexedColumns() throws {
        let columns = try self.tableColumns()
        if !columns.contains("timestamp") {
            try self.execute("ALTER TABLE history ADD COLUMN timestamp REAL NOT NULL DEFAULT 0")
        }
        if !columns.contains("preview") {
            try self.execute("ALTER TABLE history ADD COLUMN preview TEXT NOT NULL DEFAULT ''")
        }
        if !columns.contains("app_name") {
            try self.execute("ALTER TABLE history ADD COLUMN app_name TEXT NOT NULL DEFAULT ''")
        }
        if !columns.contains("word_count") {
            try self.execute("ALTER TABLE history ADD COLUMN word_count INTEGER NOT NULL DEFAULT 0")
        }
        if !columns.contains("was_ai") {
            try self.execute("ALTER TABLE history ADD COLUMN was_ai INTEGER NOT NULL DEFAULT 0")
        }
        if !columns.contains("body") {
            try self.execute("ALTER TABLE history ADD COLUMN body TEXT NOT NULL DEFAULT ''")
        }
        if !columns.contains("audio_file") {
            try self.execute("ALTER TABLE history ADD COLUMN audio_file TEXT NOT NULL DEFAULT ''")
        }
        try self.execute("CREATE INDEX IF NOT EXISTS history_timestamp_idx ON history(timestamp DESC)")
    }

    private func backfillIndexedColumnsIfNeeded() throws {
        guard try !self.hasMetadata("indexed_columns_backfilled") else { return }
        let records = try self.readRecords(sql: "SELECT id, payload FROM history")
        for record in records {
            try self.upsert(record)
        }
        try self.execute("INSERT OR IGNORE INTO metadata(key) VALUES ('indexed_columns_backfilled')")
    }

    private func ensureSearchIndex() throws {
        do {
            try self.execute(
                """
                CREATE VIRTUAL TABLE IF NOT EXISTS history_fts USING fts5(
                    id UNINDEXED,
                    preview,
                    app_name,
                    body,
                    tokenize = 'unicode61'
                )
                """
            )
            self.ftsEnabled = true
            try self.backfillSearchIndexIfNeeded()
        } catch {
            self.ftsEnabled = false
            DebugLogger.shared.debug(
                "History FTS unavailable: \(error.localizedDescription)",
                source: "TranscriptionHistoryStore"
            )
        }
    }

    private func backfillSearchIndexIfNeeded() throws {
        guard self.ftsEnabled, try !self.hasMetadata("history_fts_backfilled") else { return }
        try self.execute("DELETE FROM history_fts")
        let records = try self.readRecords(sql: "SELECT id, payload FROM history")
        for record in records {
            let entry = try JSONDecoder().decode(TranscriptionHistoryEntry.self, from: record.payload)
            let preview = String(entry.processedText.prefix(80))
            let body = String((entry.processedText + "\n" + entry.rawText + "\n" + entry.windowTitle).prefix(8_000))
            try self.upsertSearchIndex(id: record.id, preview: preview, appName: entry.appName, body: body)
        }
        try self.execute("INSERT OR IGNORE INTO metadata(key) VALUES ('history_fts_backfilled')")
    }

    private func upsertSearchIndex(id: UUID, preview: String, appName: String, body: String) throws {
        guard self.ftsEnabled else { return }
        try self.removeFromSearchIndex(id: id)
        let statement = try self.prepare(
            "INSERT INTO history_fts(id, preview, app_name, body) VALUES (?, ?, ?, ?)"
        )
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = id.uuidString.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
        _ = preview.withCString { sqlite3_bind_text(statement, 2, $0, -1, transient) }
        _ = appName.withCString { sqlite3_bind_text(statement, 3, $0, -1, transient) }
        _ = body.withCString { sqlite3_bind_text(statement, 4, $0, -1, transient) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw self.error() }
    }

    private func removeFromSearchIndex(id: UUID) throws {
        guard self.ftsEnabled else { return }
        try self.execute("DELETE FROM history_fts WHERE id='\(id.uuidString)'")
    }

    private func clearSearchIndex() throws {
        guard self.ftsEnabled else { return }
        try self.execute("DELETE FROM history_fts")
    }

    private func readPruneCandidates(sql: String) throws -> [(id: UUID, audioFile: String)] {
        let statement = try self.prepare(sql)
        defer { sqlite3_finalize(statement) }
        var rows: [(id: UUID, audioFile: String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0),
                  let id = UUID(uuidString: String(cString: text))
            else { continue }
            let audio = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            rows.append((id: id, audioFile: audio))
        }
        return rows
    }

    private func hasMetadata(_ key: String) throws -> Bool {
        let escaped = key.replacingOccurrences(of: "'", with: "''")
        let statement = try self.prepare("SELECT 1 FROM metadata WHERE key='\(escaped)'")
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw self.error() }
        return result == SQLITE_ROW
    }

    private func tableColumns() throws -> Set<String> {
        let statement = try self.prepare("PRAGMA table_info(history)")
        defer { sqlite3_finalize(statement) }
        var columns: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) {
                columns.insert(String(cString: name))
            }
        }
        return columns
    }

    private func searchRecords(query: String, limit: Int) throws -> [Record] {
        if self.ftsEnabled, let match = Self.ftsQuery(from: query) {
            do {
                return try self.searchRecordsFTS(match: match, limit: limit)
            } catch {
                DebugLogger.shared.debug(
                    "History FTS search fell back to LIKE: \(error.localizedDescription)",
                    source: "TranscriptionHistoryStore"
                )
            }
        }
        return try self.searchRecordsLike(query: query, limit: limit)
    }

    private func searchRecordsFTS(match: String, limit: Int) throws -> [Record] {
        let statement = try self.prepare(
            """
            SELECT history.id, history.payload FROM history
            JOIN history_fts ON history.id = history_fts.id
            WHERE history_fts MATCH ?
            ORDER BY history.timestamp DESC, history.id DESC
            LIMIT \(limit)
            """
        )
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = match.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
        return try self.stepRecords(statement)
    }

    private func searchRecordsLike(query: String, limit: Int) throws -> [Record] {
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let like = "%\(escaped)%"
        let statement = try self.prepare(
            """
            SELECT id, payload FROM history
            WHERE preview LIKE ? ESCAPE '\\'
               OR app_name LIKE ? ESCAPE '\\'
               OR body LIKE ? ESCAPE '\\'
            ORDER BY timestamp DESC, id DESC
            LIMIT \(limit)
            """
        )
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = like.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
        _ = like.withCString { sqlite3_bind_text(statement, 2, $0, -1, transient) }
        _ = like.withCString { sqlite3_bind_text(statement, 3, $0, -1, transient) }
        return try self.stepRecords(statement)
    }

    static func ftsQuery(from raw: String) -> String? {
        let tokens = raw.split(whereSeparator: \.isWhitespace).compactMap { token -> String? in
            let cleaned = token.filter { $0.isLetter || $0.isNumber || $0 == "'" }
            guard !cleaned.isEmpty else { return nil }
            return "\"\(cleaned)\""
        }
        guard !tokens.isEmpty else { return nil }
        return tokens.joined(separator: " AND ")
    }

    private func readRecords(sql: String) throws -> [Record] {
        let statement = try self.prepare(sql)
        defer { sqlite3_finalize(statement) }
        return try self.stepRecords(statement)
    }

    private func stepRecords(_ statement: OpaquePointer) throws -> [Record] {
        var records: [Record] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return records }
            guard result == SQLITE_ROW,
                  let text = sqlite3_column_text(statement, 0),
                  let id = UUID(uuidString: String(cString: text)),
                  let bytes = sqlite3_column_blob(statement, 1)
            else { throw self.error() }
            records.append(Record(id: id, payload: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))))
        }
    }

    private func topApps(limit: Int) throws -> [(app: String, count: Int)] {
        let statement = try self.prepare(
            "SELECT app_name, COUNT(*) FROM history GROUP BY app_name ORDER BY COUNT(*) DESC LIMIT \(limit)"
        )
        defer { sqlite3_finalize(statement) }
        var rows: [(app: String, count: Int)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let name = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "Unknown"
            rows.append((app: name.isEmpty ? "Unknown" : name, count: Int(sqlite3_column_int(statement, 1))))
        }
        return rows
    }

    private func peakHour() throws -> Int? {
        let statement = try self.prepare(
            """
            SELECT CAST(strftime('%H', timestamp, 'unixepoch', 'localtime') AS INTEGER) AS hour, COUNT(*)
            FROM history GROUP BY hour ORDER BY COUNT(*) DESC LIMIT 1
            """
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func extremeDayAggregate(words: Bool) throws -> Int {
        let value = words ? "SUM(word_count)" : "COUNT(*)"
        let statement = try self.prepare(
            """
            SELECT COALESCE(MAX(total),0) FROM (
                SELECT \(value) AS total FROM history
                GROUP BY date(timestamp, 'unixepoch', 'localtime')
            )
            """
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func activeDayStarts() throws -> [Date] {
        let statement = try self.prepare(
            "SELECT DISTINCT date(timestamp, 'unixepoch', 'localtime') FROM history ORDER BY 1 DESC"
        )
        defer { sqlite3_finalize(statement) }
        var days: [Date] = []
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0),
                  let date = formatter.date(from: String(cString: text))
            else { continue }
            days.append(date)
        }
        return days
    }

    private func transaction(_ body: () throws -> Void) throws {
        try self.execute("BEGIN IMMEDIATE")
        do {
            try body()
            try self.execute("COMMIT")
        } catch {
            try? self.execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(self.connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw self.error()
        }
        return statement
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(self.connection, sql, nil, nil, nil) == SQLITE_OK else { throw self.error() }
    }

    private func error() -> Error {
        NSError(domain: "HistoryDatabase", code: Int(sqlite3_errcode(self.connection)), userInfo: [
            NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(self.connection)),
        ])
    }
}

/// All disk queries and Codable work happen here, including the one-time legacy import.
final nonisolated class TranscriptionHistoryWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fluid.history.persistence", qos: .utility)
    private var database: TranscriptionHistoryDatabase?
    private var writeError: Error?
    private let defaults: UserDefaults
    private let url: URL
    private let legacyKey = "TranscriptionHistoryEntries"

    init(defaults: UserDefaults = .standard, url: URL? = nil) {
        self.defaults = defaults
        self.url = url ?? AppSupportDirectory.url().appendingPathComponent("TranscriptionHistory.sqlite3")
    }

    func load(retention: HistoryRetentionPolicy = .unlimited) async throws -> [TranscriptionHistoryEntry] {
        try await self.onQueue {
            let database = try self.openDatabase()
            self.applyPrune(try database.prune(policy: retention))
            let entries = try database.read().map {
                try JSONDecoder().decode(TranscriptionHistoryEntry.self, from: $0.payload)
            }.sorted { $0.timestamp > $1.timestamp }
            DebugLogger.shared.info("HISTORY_BENCH loaded entries=\(entries.count) storage=sqlite", source: "TranscriptionHistoryStore")
            return entries
        }
    }

    func loadPublishedState(
        pageLimit: Int,
        query: String? = nil,
        retention: HistoryRetentionPolicy = .unlimited
    ) async throws -> (
        page: [TranscriptionHistoryEntry],
        summaries: [HistorySummaryRecord]
    ) {
        try await self.onQueue {
            let database = try self.openDatabase()
            self.applyPrune(try database.prune(policy: retention))
            let page = try database.readPage(limit: pageLimit, query: query).map {
                try JSONDecoder().decode(TranscriptionHistoryEntry.self, from: $0.payload)
            }
            let summaries = try database.readSummaryRecords()
            DebugLogger.shared.info(
                "HISTORY_BENCH loaded page=\(page.count) summaries=\(summaries.count) storage=sqlite",
                source: "TranscriptionHistoryStore"
            )
            return (page, summaries)
        }
    }

    func loadEntry(id: UUID) async throws -> TranscriptionHistoryEntry? {
        try await self.onQueue {
            let database = try self.openDatabase()
            guard let record = try database.readEntry(id: id) else { return nil }
            return try JSONDecoder().decode(TranscriptionHistoryEntry.self, from: record.payload)
        }
    }

    func loadEntriesWithAudio() async throws -> [TranscriptionHistoryEntry] {
        try await self.onQueue {
            let database = try self.openDatabase()
            return try database.readEntriesWithAudio().map {
                try JSONDecoder().decode(TranscriptionHistoryEntry.self, from: $0.payload)
            }
        }
    }

    func write(
        upserts: [TranscriptionHistoryEntry],
        deletes: [UUID] = [],
        replacing: Bool = false,
        retention: HistoryRetentionPolicy = .unlimited,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        self.queue.async {
            let startedAt = ProcessInfo.processInfo.systemUptime
            do {
                guard let database = self.database else {
                    throw NSError(domain: "HistoryDatabase", code: 1, userInfo: [NSLocalizedDescriptionKey: "History is not loaded."])
                }
                let records = try upserts.map { try self.record($0) }
                try database.write(upserts: records, deletes: deletes, replacing: replacing)
                if !replacing {
                    self.applyPrune(try database.prune(policy: retention))
                }
                self.writeError = nil
                let finishedAt = ProcessInfo.processInfo.systemUptime
                DebugLogger.shared.info(
                    "HISTORY_BENCH t=\(finishedAt) background=true upserts=\(upserts.count) deletes=\(deletes.count) " +
                        "replace=\(replacing) bytes=\(records.reduce(0) { $0 + $1.payload.count }) totalMs=\((finishedAt - startedAt) * 1000)",
                    source: "TranscriptionHistoryStore"
                )
                completion(nil)
            } catch {
                self.writeError = error
                completion(error)
            }
        }
    }

    private func applyPrune(_ result: HistoryPruneResult) {
        for fileName in result.audioFileNames where !fileName.isEmpty {
            _ = DictationAudioHistoryStore.shared.deleteAudio(fileName: fileName)
        }
    }

    func drain() async -> Error? {
        await withCheckedContinuation { continuation in
            self.queue.async { continuation.resume(returning: self.writeError) }
        }
    }

    private func openDatabase() throws -> TranscriptionHistoryDatabase {
        let database = try self.database ?? TranscriptionHistoryDatabase(url: self.url)
        self.database = database
        if try !database.isMigrated {
            let legacy = try self.defaults.data(forKey: self.legacyKey).map {
                try JSONDecoder().decode([TranscriptionHistoryEntry].self, from: $0)
            } ?? []
            try database.migrate(legacy.map { try self.record($0) })
        }
        // The transaction is committed and every payload decoded before retiring legacy storage.
        self.defaults.removeObject(forKey: self.legacyKey)
        return database
    }

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            self.queue.async {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func record(_ entry: TranscriptionHistoryEntry) throws -> TranscriptionHistoryDatabase.Record {
        try TranscriptionHistoryDatabase.Record(id: entry.id, payload: JSONEncoder().encode(entry))
    }
}
