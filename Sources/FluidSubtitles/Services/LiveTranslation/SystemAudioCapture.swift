import CoreMedia
import CoreAudio
import Foundation
import ScreenCaptureKit

enum SystemAudioCaptureError: LocalizedError {
    case screenRecordingDenied
    case needsReopen
    case noDisplay
    case startFailed(String)

    var errorDescription: String? {
        switch self {
        case .screenRecordingDenied:
            return ScreenRecordingAccess.deniedCopy
        case .needsReopen:
            return ScreenRecordingAccess.reopenCopy
        case .noDisplay:
            return "No display is available to capture audio."
        case .startFailed(let message):
            return message
        }
    }
}

/// ScreenCaptureKit audio tap. Always attaches a 2×2 dummy video output.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    typealias PacketHandler = @Sendable (
        _ samples: UnsafePointer<Float>,
        _ frameCount: Int,
        _ sampleRate: Double,
        _ inputHostTime: UInt64,
        _ inputSampleTime: Int64
    ) -> Void

    private let handlerQueue = DispatchQueue(
        label: "com.fluidsubtitles.systemaudio.capture",
        qos: .userInitiated
    )
    private let lock = NSLock()
    private var stream: SCStream?
    private var packetHandler: PacketHandler?
    private var onStopped: ((String) -> Void)?
    private var nextSampleTime: Int64 = 0
    private var stoppingIntentionally = false
    private var didReportStop = false

    func start(
        source: TheaterCaptureSource,
        appBundleID: String?,
        packetHandler: @escaping PacketHandler,
        onStopped: @escaping (String) -> Void
    ) async throws {
        let content: SCShareableContent
        switch await ScreenRecordingAccess.load() {
        case .success(let loaded):
            content = loaded
        case .failure(let resolution):
            switch resolution {
            case .needsReopen:
                throw SystemAudioCaptureError.needsReopen
            case .noDisplay:
                throw SystemAudioCaptureError.noDisplay
            case .denied, .granted:
                throw SystemAudioCaptureError.screenRecordingDenied
            }
        }
        await self.stop()
        self.lock.withLock {
            self.packetHandler = packetHandler
            self.onStopped = onStopped
            self.nextSampleTime = 0
            self.stoppingIntentionally = false
            self.didReportStop = false
        }

        guard let display = content.displays.first else {
            throw SystemAudioCaptureError.noDisplay
        }
        let filter = self.makeFilter(
            content: content,
            display: display,
            source: source,
            appBundleID: appBundleID
        )
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.handlerQueue)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.handlerQueue)
            try await stream.startCapture()
        } catch {
            throw SystemAudioCaptureError.startFailed(ScreenRecordingAccess.message(forStartError: error))
        }
        self.lock.withLock {
            self.stream = stream
        }
    }

    func resetClock() {
        self.lock.lock()
        self.nextSampleTime = 0
        self.lock.unlock()
    }

    func stop() async {
        let stream = self.lock.withLock { () -> SCStream? in
            self.stoppingIntentionally = true
            let stream = self.stream
            self.stream = nil
            self.packetHandler = nil
            self.onStopped = nil
            return stream
        }
        guard let stream else { return }
        try? await stream.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard sampleBuffer.isValid, CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }

        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
        else { return }

        var sizeNeeded = 0
        _ = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &sizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        if sizeNeeded <= 0 {
            sizeNeeded = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size * 16
        }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded, alignment: MemoryLayout<Int>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: list,
            bufferListSize: sizeNeeded,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        defer { _ = blockBuffer }
        guard status == noErr else { return }

        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard let mono = SystemAudioDownmix.monoSamples(
            asbd: asbd,
            bufferList: UnsafePointer(list),
            frameCount: frames
        ), !mono.isEmpty else { return }
        self.lock.lock()
        let handler = self.packetHandler
        let sampleTime = self.nextSampleTime
        self.nextSampleTime &+= Int64(mono.count)
        self.lock.unlock()
        guard let handler else { return }
        mono.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            handler(
                base,
                mono.count,
                asbd.mSampleRate,
                mach_absolute_time(),
                sampleTime
            )
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.lock.lock()
        let intentional = self.stoppingIntentionally
        let callback = self.onStopped
        let already = self.didReportStop
        if !intentional {
            self.didReportStop = true
            self.stream = nil
            self.packetHandler = nil
        }
        self.lock.unlock()
        guard WatchCaptureStop.shouldNotifyUser(
            intentionalStop: intentional,
            alreadyReported: already
        ), let callback else { return }
        callback(WatchCaptureStop.userFacingStatus(error.localizedDescription))
    }

    private func makeFilter(
        content: SCShareableContent,
        display: SCDisplay,
        source: TheaterCaptureSource,
        appBundleID: String?
    ) -> SCContentFilter {
        let excluded = content.applications.filter {
            $0.processID == ProcessInfo.processInfo.processIdentifier
        }
        if source == .watchApp, let bundleID = appBundleID, !bundleID.isEmpty {
            let included = content.applications.filter { application in
                WatchAppInclusion.matches(
                    candidateBundleID: application.bundleIdentifier,
                    targetBundleID: bundleID
                )
            }
            if !included.isEmpty {
                return SCContentFilter(display: display, including: included, exceptingWindows: [])
            }
        }
        return SCContentFilter(
            display: display,
            excludingApplications: excluded,
            exceptingWindows: []
        )
    }
}
