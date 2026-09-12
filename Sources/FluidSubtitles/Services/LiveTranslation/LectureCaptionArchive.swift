import Foundation

/// Overflow from the 200-line Theater window. JSONL on disk so a 3-hour talk
/// does not grow the in-memory SwiftUI board or UserDefaults snapshot.
final class LectureCaptionArchive: @unchecked Sendable {
    private let url: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private(set) var overflowCount = 0

    init(url: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.url = url ?? AppSupportDirectory.url(fileManager: fileManager)
            .appendingPathComponent("TheaterSession.jsonl")
    }

    func append(_ entries: [LectureCaptionEntry]) {
        guard !entries.isEmpty else { return }
        self.lock.lock()
        defer { self.lock.unlock() }
        do {
            try self.fileManager.createDirectory(
                at: self.url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !self.fileManager.fileExists(atPath: self.url.path) {
                self.fileManager.createFile(atPath: self.url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: self.url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            for entry in entries {
                let data = try encoder.encode(entry)
                try handle.write(contentsOf: data)
                try handle.write(contentsOf: Data([0x0A]))
                self.overflowCount += 1
            }
            try handle.synchronize()
        } catch {
            DebugLogger.shared.error(
                "Theater archive append failed: \(error.localizedDescription)",
                source: "LiveTranslation"
            )
        }
    }

    func loadAll() -> [LectureCaptionEntry] {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let data = try? Data(contentsOf: self.url), !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var entries: [LectureCaptionEntry] = []
        entries.reserveCapacity(self.overflowCount)
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let entry = try? decoder.decode(LectureCaptionEntry.self, from: Data(line)) {
                entries.append(entry)
            }
        }
        self.overflowCount = entries.count
        return entries
    }

    func reset() {
        self.lock.lock()
        defer { self.lock.unlock() }
        try? self.fileManager.removeItem(at: self.url)
        self.overflowCount = 0
    }

    /// Count overflow lines without decoding captions into RAM.
    func recount() {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.overflowCount = Self.lineCount(at: self.url, fileManager: self.fileManager)
    }

    private static func lineCount(at url: URL, fileManager: FileManager) -> Int {
        guard fileManager.fileExists(atPath: url.path),
              let handle = try? FileHandle(forReadingFrom: url)
        else { return 0 }
        defer { try? handle.close() }
        var count = 0
        var remainder = false
        while true {
            let chunk = (try? handle.read(upToCount: 65_536)) ?? Data()
            if chunk.isEmpty { break }
            for byte in chunk {
                if byte == 0x0A {
                    count += 1
                    remainder = false
                } else {
                    remainder = true
                }
            }
        }
        if remainder { count += 1 }
        return count
    }
}
