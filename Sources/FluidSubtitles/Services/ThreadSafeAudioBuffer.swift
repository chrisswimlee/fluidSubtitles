import Foundation

enum LiveAudioRetention {
    static let sampleRate = 16_000
    static let maximumRetainedSeconds = 30
    static let maximumRetainedSamples = sampleRate * maximumRetainedSeconds
    static let incrementalOverlapSeconds = 1
    static let incrementalOverlapSamples = sampleRate * incrementalOverlapSeconds
}

/// Thread-safe PCM ring. `count` is the logical session length; only the newest
/// retained window stays in RAM.
final nonisolated class ThreadSafeAudioBuffer {
    private var buffer: [Float] = []
    private var droppedSampleCount = 0
    private let lock = NSLock()
    private let maximumRetainedSamples: Int

    init(maximumRetainedSamples: Int = LiveAudioRetention.maximumRetainedSamples) {
        self.maximumRetainedSamples = max(1, maximumRetainedSamples)
    }

    /// Appends new samples and drops anything older than the retention cap.
    func append(_ newSamples: [Float]) {
        guard !newSamples.isEmpty else { return }
        self.lock.lock()
        defer { self.lock.unlock() }
        self.buffer.append(contentsOf: newSamples)
        self.dropOverflowLocked()
    }

    func clear(keepingCapacity: Bool = false) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.buffer.removeAll(keepingCapacity: keepingCapacity)
        self.droppedSampleCount = 0
    }

    /// Logical samples captured this session, including already-dropped audio.
    var count: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.droppedSampleCount + self.buffer.count
    }

    var retainedCount: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.buffer.count
    }

    var logicalStart: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.droppedSampleCount
    }

    /// Drops retained samples whose logical index is below `logicalIndex`.
    func dropSamples(before logicalIndex: Int) {
        self.lock.lock()
        defer { self.lock.unlock() }
        let clamped = min(max(logicalIndex, self.droppedSampleCount), self.droppedSampleCount + self.buffer.count)
        let removeCount = clamped - self.droppedSampleCount
        guard removeCount > 0 else { return }
        self.buffer.removeFirst(removeCount)
        self.droppedSampleCount += removeCount
    }

    /// First `length` retained samples. Never returns dropped audio.
    func getPrefix(_ length: Int) -> [Float] {
        self.lock.lock()
        defer { self.lock.unlock() }
        let safeLength = min(max(0, length), self.buffer.count)
        return Array(self.buffer[0..<safeLength])
    }

    /// Exact logical range when every requested sample is still retained.
    func getRange(startingAt start: Int, count: Int) -> [Float] {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard start >= 0,
              count > 0,
              start >= self.droppedSampleCount,
              start <= self.droppedSampleCount + self.buffer.count,
              count <= self.droppedSampleCount + self.buffer.count - start
        else {
            return []
        }
        let localStart = start - self.droppedSampleCount
        return Array(self.buffer[localStart..<(localStart + count)])
    }

    func getRetained() -> [Float] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.buffer
    }

    /// Retained window only. Long sessions do not materialize dropped PCM.
    func getAll() -> [Float] {
        self.getRetained()
    }

    private func dropOverflowLocked() {
        guard self.buffer.count > self.maximumRetainedSamples else { return }
        let overflow = self.buffer.count - self.maximumRetainedSamples
        self.buffer.removeFirst(overflow)
        self.droppedSampleCount += overflow
    }
}
