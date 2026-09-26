import Darwin
import Foundation

/// Device-rate copies of HAL packets. The drain thread writes and releases the
/// 64-slot ring before resample, the 30-second buffer, or WAV run on the commit queue.
final class CapturePacketHandoff: @unchecked Sendable {
    struct StoredPacket {
        let frameCount: Int
        let sampleRate: Double
        let inputHostTime: UInt64
        let inputSampleTime: Int64
    }

    private struct Descriptor {
        var frameOffset: Int
        var frameCount: Int
        var sampleRate: Double
        var inputHostTime: UInt64
        var inputSampleTime: Int64

        static let empty = Descriptor(
            frameOffset: 0,
            frameCount: 0,
            sampleRate: 0,
            inputHostTime: 0,
            inputSampleTime: 0
        )
    }

    private let frameStorage: UnsafeMutableRawPointer
    private let frameStorageBytes: Int
    private let frames: UnsafeMutablePointer<Float>
    private let frameCapacity: Int
    private let descriptorStorage: UnsafeMutableRawPointer
    private let descriptorStorageBytes: Int
    private let descriptors: UnsafeMutablePointer<Descriptor>
    private let descriptorCapacity: Int
    private let lock = NSLock()
    private var writeFrame = 0
    private var occupiedFrames = 0
    private var writeDesc = 0
    private var readDesc = 0
    private var occupiedDesc = 0
    private var droppedPackets: UInt64 = 0
    private var didNoticeDrop = false
    private var wired = false

    convenience init(sampleRate: Double, retainedSeconds: Int = LiveAudioRetention.maximumRetainedSeconds) {
        let rate = max(Int(sampleRate.rounded()), LiveAudioRetention.sampleRate)
        let frames = max(rate * max(retainedSeconds, 1), Int(FV_CORE_AUDIO_MAX_FRAMES_PER_PACKET))
        let descriptors = max(4_096, frames / 32)
        self.init(frameCapacity: frames, descriptorCapacity: descriptors)
    }

    init(frameCapacity: Int, descriptorCapacity: Int) {
        let frames = max(frameCapacity, 1)
        let descriptors = max(descriptorCapacity, 1)
        let frameBytes = frames * MemoryLayout<Float>.stride
        let descriptorBytes = descriptors * MemoryLayout<Descriptor>.stride
        let frameAllocation = Self.allocateWired(byteCount: frameBytes)
        let descriptorAllocation = Self.allocateWired(byteCount: descriptorBytes)
        self.frameStorage = frameAllocation.storage
        self.frameStorageBytes = frameAllocation.bytes
        self.frames = frameAllocation.storage.bindMemory(to: Float.self, capacity: frames)
        self.frameCapacity = frames
        self.descriptorStorage = descriptorAllocation.storage
        self.descriptorStorageBytes = descriptorAllocation.bytes
        self.descriptors = descriptorAllocation.storage.bindMemory(to: Descriptor.self, capacity: descriptors)
        self.descriptorCapacity = descriptors
        if mlock(frameAllocation.storage, frameAllocation.bytes) == 0,
           mlock(descriptorAllocation.storage, descriptorAllocation.bytes) == 0
        {
            self.wired = true
        } else {
            munlock(frameAllocation.storage, frameAllocation.bytes)
            munlock(descriptorAllocation.storage, descriptorAllocation.bytes)
        }
    }

    deinit {
        if self.wired {
            munlock(self.frameStorage, self.frameStorageBytes)
            munlock(self.descriptorStorage, self.descriptorStorageBytes)
        }
        self.frameStorage.deallocate()
        self.descriptorStorage.deallocate()
    }

    private static func allocateWired(byteCount: Int) -> (storage: UnsafeMutableRawPointer, bytes: Int) {
        let page = max(Int(sysconf(_SC_PAGESIZE)), MemoryLayout<Float>.alignment)
        let span = max((byteCount + page - 1) & ~(page - 1), page)
        let storage = UnsafeMutableRawPointer.allocate(byteCount: span, alignment: page)
        memset(storage, 0, span)
        return (storage, span)
    }

    /// Copies one packet. Returns false when the handoff is full; the caller
    /// still consumes the HAL slot so the 64-deep ring can turn over.
    func write(
        samples: UnsafePointer<Float>,
        frameCount: Int,
        sampleRate: Double,
        inputHostTime: UInt64,
        inputSampleTime: Int64
    ) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard frameCount > 0,
              frameCount <= self.frameCapacity,
              self.occupiedDesc < self.descriptorCapacity,
              self.occupiedFrames + frameCount <= self.frameCapacity
        else {
            self.droppedPackets += 1
            return false
        }

        let start = self.writeFrame
        self.copyInLocked(from: samples, count: frameCount)
        self.descriptors[self.writeDesc] = Descriptor(
            frameOffset: start,
            frameCount: frameCount,
            sampleRate: sampleRate,
            inputHostTime: inputHostTime,
            inputSampleTime: inputSampleTime
        )
        self.writeDesc = (self.writeDesc + 1) % self.descriptorCapacity
        self.occupiedFrames += frameCount
        self.occupiedDesc += 1
        return true
    }

    /// True the first time a write is rejected.
    func consumeDropNotice() -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.droppedPackets > 0, self.didNoticeDrop == false else { return false }
        self.didNoticeDrop = true
        return true
    }

    var droppedPacketCount: UInt64 {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.droppedPackets
    }

    func copyNext(into destination: UnsafeMutablePointer<Float>, capacity: Int) -> StoredPacket? {
        self.lock.lock()
        defer { self.lock.unlock() }
        while self.occupiedDesc > 0 {
            let descriptor = self.descriptors[self.readDesc]
            self.retireHeadLocked(descriptor)
            guard descriptor.frameCount > 0, descriptor.frameCount <= capacity else {
                self.droppedPackets += 1
                continue
            }
            self.copyOutLocked(
                from: descriptor.frameOffset,
                count: descriptor.frameCount,
                into: destination
            )
            return StoredPacket(
                frameCount: descriptor.frameCount,
                sampleRate: descriptor.sampleRate,
                inputHostTime: descriptor.inputHostTime,
                inputSampleTime: descriptor.inputSampleTime
            )
        }
        return nil
    }

    func deliver(
        using scratch: CaptureScratch,
        to packetHandler: DirectCoreAudioPacketHandler
    ) {
        while let stored = self.copyNext(into: scratch.samples, capacity: scratch.capacity) {
            packetHandler(
                scratch.samples,
                stored.frameCount,
                stored.sampleRate,
                stored.inputHostTime,
                stored.inputSampleTime
            )
        }
    }

    func pop() -> (frames: [Float], sampleRate: Double, inputHostTime: UInt64, inputSampleTime: Int64)? {
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: self.frameCapacity)
        defer { scratch.deallocate() }
        guard let stored = self.copyNext(into: scratch, capacity: self.frameCapacity) else { return nil }
        return (
            Array(UnsafeBufferPointer(start: scratch, count: stored.frameCount)),
            stored.sampleRate,
            stored.inputHostTime,
            stored.inputSampleTime
        )
    }

    private func copyInLocked(from samples: UnsafePointer<Float>, count: Int) {
        var remaining = count
        var source = 0
        var dest = self.writeFrame
        while remaining > 0 {
            let run = min(remaining, self.frameCapacity - dest)
            self.frames.advanced(by: dest).update(from: samples.advanced(by: source), count: run)
            source += run
            remaining -= run
            dest += run
            if dest == self.frameCapacity {
                dest = 0
            }
        }
        self.writeFrame = dest
    }

    private func copyOutLocked(from offset: Int, count: Int, into destination: UnsafeMutablePointer<Float>) {
        var remaining = count
        var source = offset
        var dest = 0
        while remaining > 0 {
            let run = min(remaining, self.frameCapacity - source)
            destination.advanced(by: dest).update(from: self.frames.advanced(by: source), count: run)
            dest += run
            remaining -= run
            source += run
            if source == self.frameCapacity {
                source = 0
            }
        }
    }

    private func retireHeadLocked(_ descriptor: Descriptor) {
        self.occupiedFrames -= descriptor.frameCount
        self.occupiedDesc -= 1
        self.readDesc = (self.readDesc + 1) % self.descriptorCapacity
    }
}

final class CaptureScratch: @unchecked Sendable {
    let samples: UnsafeMutablePointer<Float>
    let capacity: Int

    init(capacity: Int) {
        let count = max(capacity, 1)
        let samples = UnsafeMutablePointer<Float>.allocate(capacity: count)
        samples.initialize(repeating: 0, count: count)
        self.samples = samples
        self.capacity = count
    }

    deinit {
        self.samples.deinitialize(count: self.capacity)
        self.samples.deallocate()
    }
}
