import Foundation

/// Optional JSONL helper for leftover session files. Live Theater drops
/// off-screen captions instead of writing overflow.
/// Writes run on a dedicated serial queue with a batched flush so clause
/// commits do not fsync on the MainActor.
final class LectureCaptionArchive: @unchecked Sendable {
    static let flushLineThreshold = 16
    static let flushDelay: TimeInterval = 0.35

    private let url: URL
    private let fileManager: FileManager
    private let queue: DispatchQueue
    private static let queueKey = DispatchSpecificKey<UInt8>()
    private var pending: [LectureCaptionEntry] = []
    private var flushedCount = 0
    private var flushWorkItem: DispatchWorkItem?

    init(url: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.url = url ?? AppSupportDirectory.url(fileManager: fileManager)
            .appendingPathComponent("TheaterSession.jsonl")
        let queue = DispatchQueue(label: "com.fluidsubtitles.theater.archive")
        queue.setSpecific(key: Self.queueKey, value: 1)
        self.queue = queue
    }

    /// Flushed lines plus anything still in the write buffer.
    var overflowCount: Int {
        self.sync { self.flushedCount + self.pending.count }
    }

    /// Buffer overflow lines and return immediately. Disk write + fsync happen
    /// on the archive queue after a short batch or an explicit barrier.
    func enqueue(_ entries: [LectureCaptionEntry]) {
        guard !entries.isEmpty else { return }
        self.sync {
            self.pending.append(contentsOf: entries)
            if self.pending.count >= Self.flushLineThreshold {
                self.scheduleFlushLocked(deadline: .now())
            } else {
                self.scheduleFlushLocked(deadline: .now() + Self.flushDelay)
            }
        }
    }

    /// Enqueue and flush before returning. Used by tests and restore barriers.
    func append(_ entries: [LectureCaptionEntry]) {
        guard !entries.isEmpty else { return }
        self.sync {
            self.pending.append(contentsOf: entries)
            self.flushLocked()
        }
    }

    func flush() {
        self.sync { self.flushLocked() }
    }

    func loadAll() -> [LectureCaptionEntry] {
        self.sync {
            self.flushLocked()
            guard let data = try? Data(contentsOf: self.url), !data.isEmpty else {
                self.flushedCount = 0
                return []
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var entries: [LectureCaptionEntry] = []
            entries.reserveCapacity(self.flushedCount)
            for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                if let entry = try? decoder.decode(LectureCaptionEntry.self, from: Data(line)) {
                    entries.append(entry)
                }
            }
            self.flushedCount = entries.count
            return entries
        }
    }

    func reset() {
        self.sync {
            self.flushWorkItem?.cancel()
            self.flushWorkItem = nil
            self.pending.removeAll()
            try? self.fileManager.removeItem(at: self.url)
            self.flushedCount = 0
        }
    }

    /// Count overflow lines without decoding captions into RAM.
    func recount() {
        self.sync {
            self.flushLocked()
            self.flushedCount = Self.lineCount(at: self.url, fileManager: self.fileManager)
        }
    }

    private func sync<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            return body()
        }
        return self.queue.sync(execute: body)
    }

    private func scheduleFlushLocked(deadline: DispatchTime) {
        self.flushWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flushLocked()
        }
        self.flushWorkItem = work
        self.queue.asyncAfter(deadline: deadline, execute: work)
    }

    private func flushLocked() {
        self.flushWorkItem?.cancel()
        self.flushWorkItem = nil
        let entries = self.pending
        self.pending.removeAll()
        guard !entries.isEmpty else { return }
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
            var written = 0
            do {
                for entry in entries {
                    let data = try encoder.encode(entry)
                    try handle.write(contentsOf: data)
                    try handle.write(contentsOf: Data([0x0A]))
                    written += 1
                }
                try handle.synchronize()
                self.flushedCount += written
            } catch {
                // Only the entries that never made it to disk are retried.
                // Reinserting already-written ones would double-write them
                // and inflate flushedCount/overflowCount on the next flush.
                self.flushedCount += written
                self.pending.insert(contentsOf: entries[written...], at: 0)
                throw error
            }
        } catch {
            DebugLogger.shared.error(
                "Theater archive append failed: \(error.localizedDescription)",
                source: "LiveTranslation"
            )
        }
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
