//
//  ASRService+AudioCapture.swift
//  fluid
//
//  Realtime audio callbacks and the capture pipeline.
//

import Accelerate
import AVFoundation
import CoreAudio
import Foundation

// MARK: - Audio capture pipeline

//
// Audio callbacks are not main-actor isolated. Direct Core Audio arrives through
// a lock-free C ring. The AVAudioEngine implementation remains as legacy code but
// is no longer user-selectable. This pipeline owns timestamp trimming, 16 kHz
// conversion, levels, and session-safe delivery without touching ASRService from
// a realtime callback.

final nonisolated class AudioCapturePipeline: @unchecked Sendable {
    let audioBuffer: ThreadSafeAudioBuffer
    let onAcceptedSamples: ([Float]) -> Void
    let onFirstAudio: (Int, UInt64, Int, Int, Double, Int, Int) -> Void
    let onLevel: (CGFloat) -> Void
    let onSpeechEnergy: (UInt64, Bool) -> Void
    let onCaptureHealth: (Int, UInt64, Int, Int, Float, Float) -> Void

    let lock = NSLock()
    var recordingEnabled: Bool = false
    var capturePaused: Bool = false
    var needsResumeSilenceWall: Bool = false
    var levelMonitoringEnabled: Bool = false
    var firstAudioReported: Bool = false
    var recordingSessionID: Int = 0
    var recordingAttemptID: UInt64 = 0
    var recordingStartHostTime: UInt64 = 0
    var recordingStopHostTime: UInt64?
    var resampleSourceRate: Double = 0
    var resampleSourceFrameCursor: Int64 = 0
    var resampleNextSourcePosition: Double = 0
    var resamplePreviousSample: Float?
    var lastInputSampleEnd: Int64?
    var captureHealthSampleCount: Int = 0
    var captureHealthTotalSampleCount: Int = 0
    var captureHealthSquareSum: Double = 0
    var captureHealthPeak: Float = 0

    // Smoothing state (kept off ASRService/@MainActor)
    var levelHistory: [CGFloat] = []
    var smoothedLevel: CGFloat = 0.0
    let historySize: Int = 2
    let silenceThreshold: CGFloat = 0.04

    static let hostTicksPerSecond: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        guard info.numer != 0 else { return 1_000_000_000 }
        return 1_000_000_000.0 * Double(info.denom) / Double(info.numer)
    }()

    init(
        audioBuffer: ThreadSafeAudioBuffer,
        onAcceptedSamples: @escaping ([Float]) -> Void,
        onFirstAudio: @escaping (Int, UInt64, Int, Int, Double, Int, Int) -> Void,
        onLevel: @escaping (CGFloat) -> Void,
        onSpeechEnergy: @escaping (UInt64, Bool) -> Void,
        onCaptureHealth: @escaping (Int, UInt64, Int, Int, Float, Float) -> Void
    ) {
        self.audioBuffer = audioBuffer
        self.onAcceptedSamples = onAcceptedSamples
        self.onFirstAudio = onFirstAudio
        self.onLevel = onLevel
        self.onSpeechEnergy = onSpeechEnergy
        self.onCaptureHealth = onCaptureHealth
    }

    func setRecordingEnabled(
        _ enabled: Bool,
        sessionID: Int = 0,
        attemptID: UInt64 = 0,
        startHostTime: UInt64 = 0
    ) {
        self.lock.lock()
        if enabled {
            self.firstAudioReported = false
            self.recordingSessionID = sessionID
            self.recordingAttemptID = attemptID
            self.recordingStartHostTime = startHostTime == 0 ? mach_absolute_time() : startHostTime
            self.recordingStopHostTime = nil
            self.capturePaused = false
            self.needsResumeSilenceWall = false
            self.resetResamplerLocked()
            self.lastInputSampleEnd = nil
            self.resetCaptureHealthLocked()
            self.recordingEnabled = true
        }
        if enabled == false {
            self.recordingEnabled = false
            self.capturePaused = false
            self.needsResumeSilenceWall = false
            self.recordingSessionID = 0
            self.recordingAttemptID = 0
            self.recordingStartHostTime = 0
            self.recordingStopHostTime = nil
            self.resetResamplerLocked()
            self.lastInputSampleEnd = nil
            self.resetCaptureHealthLocked()
            self.levelHistory.removeAll(keepingCapacity: true)
            self.smoothedLevel = 0.0
        }
        self.lock.unlock()
    }

    var isLevelMonitoringEnabled: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.levelMonitoringEnabled
    }

    func setCapturePaused(_ paused: Bool) {
        self.lock.lock()
        let wasPaused = self.capturePaused
        self.capturePaused = paused
        if wasPaused, paused == false {
            self.lastInputSampleEnd = nil
            self.resetResamplerLocked()
            self.needsResumeSilenceWall = true
        }
        self.lock.unlock()
    }

    var lastInputSampleEndForTesting: Int64? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.lastInputSampleEnd
    }

    var isCapturePaused: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.capturePaused
    }

    func setLevelMonitoringEnabled(_ enabled: Bool) {
        self.lock.lock()
        self.levelMonitoringEnabled = enabled
        if enabled == false, self.recordingEnabled == false {
            self.levelHistory.removeAll(keepingCapacity: true)
            self.smoothedLevel = 0
        }
        self.lock.unlock()
        if enabled == false {
            self.onLevel(0)
        }
    }

    /// Sets the exact last acquisition time accepted for the current session.
    /// Capture remains enabled until the backend has stopped and drained.
    func markRecordingEnd(atHostTime hostTime: UInt64) {
        self.lock.lock()
        if self.recordingEnabled {
            self.recordingStopHostTime = hostTime
        }
        self.lock.unlock()
    }

    func finishRecording() {
        self.setRecordingEnabled(false)
        self.onLevel(0.0)
    }

    /// Compatibility for capture teardown paths. Session-scoped timestamps
    /// replace the old cross-session preroll buffer, so there is nothing to clear.
    func clearPreroll() {
        // Intentionally empty.
    }

    func handle(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        if self.isCapturePaused { return }
        let mono = Self.downmixToMono(buffer)
        guard mono.isEmpty == false else {
            self.onLevel(0.0)
            return
        }
        self.handleMonoSamples(
            mono,
            sampleRate: buffer.format.sampleRate,
            inputHostTime: time.isHostTimeValid ? time.hostTime : 0,
            inputSampleTime: time.isSampleTimeValid ? time.sampleTime : -1,
            originalFrameCount: Int(buffer.frameLength)
        )
    }

    func handle(
        samples: UnsafePointer<Float>,
        frameCount: Int,
        sampleRate: Double,
        inputHostTime: UInt64,
        inputSampleTime: Int64
    ) {
        guard frameCount > 0 else { return }
        if self.isCapturePaused { return }
        self.handleMonoSamples(
            Array(UnsafeBufferPointer(start: samples, count: frameCount)),
            sampleRate: sampleRate,
            inputHostTime: inputHostTime,
            inputSampleTime: inputSampleTime,
            originalFrameCount: frameCount
        )
    }

    func handleMonoSamples(
        _ samples: [Float],
        sampleRate: Double,
        inputHostTime: UInt64,
        inputSampleTime: Int64,
        originalFrameCount: Int
    ) {
        guard samples.isEmpty == false, sampleRate > 0 else {
            self.onLevel(0.0)
            return
        }
        if self.isCapturePaused { return }

        self.lock.lock()
        let recordingEnabled = self.recordingEnabled
        let levelMonitoringEnabled = self.levelMonitoringEnabled
        guard recordingEnabled || levelMonitoringEnabled else {
            self.lock.unlock()
            return
        }
        if recordingEnabled == false {
            self.lock.unlock()
            self.onLevel(self.measureAudioLevel(samples).level)
            return
        }
        let startHostTime = self.recordingStartHostTime
        let stopHostTime = self.recordingStopHostTime
        let recordingSessionID = self.recordingSessionID
        let recordingAttemptID = self.recordingAttemptID
        self.lock.unlock()

        guard let acceptedRange = Self.acceptedFrameRange(
            frameCount: samples.count,
            sampleRate: sampleRate,
            packetHostTime: inputHostTime,
            startHostTime: startHostTime,
            stopHostTime: stopHostTime
        ) else {
            return
        }

        let acceptedSamples: [Float]
        if acceptedRange.lowerBound == 0, acceptedRange.upperBound == samples.count {
            acceptedSamples = samples
        } else {
            acceptedSamples = Array(samples[acceptedRange])
        }
        self.lock.lock()
        guard self.recordingEnabled,
              self.recordingSessionID == recordingSessionID,
              self.recordingAttemptID == recordingAttemptID
        else {
            self.lock.unlock()
            return
        }
        if inputSampleTime >= 0 {
            let acceptedSampleStart = inputSampleTime + Int64(acceptedRange.lowerBound)
            if let lastInputSampleEnd = self.lastInputSampleEnd,
               lastInputSampleEnd != acceptedSampleStart
            {
                // Do not interpolate across a hardware discontinuity or a
                // packet dropped under extreme consumer backpressure.
                self.resetResamplerLocked()
            }
            self.lastInputSampleEnd = inputSampleTime + Int64(acceptedRange.upperBound)
        }
        let mono16k = self.resampleTo16kLocked(
            acceptedSamples,
            sourceSampleRate: sampleRate
        )
        guard mono16k.isEmpty == false else {
            self.lock.unlock()
            return
        }
        let shouldReportFirstAudio = self.firstAudioReported == false
        if shouldReportFirstAudio {
            self.firstAudioReported = true
        }

        // Keep append and first-audio attribution inside the capture lock.
        // Disabling an attempt therefore returns only after every accepted
        // callback has committed its PCM and queued its attempt-scoped signal.
        // The silence wall shares this append with the first post-resume
        // packet so a commit-queue deliver cannot land between Time A and
        // the zeros. History audio stays the real microphone packet.
        if self.needsResumeSilenceWall {
            let wall = [Float](
                repeating: 0,
                count: LiveAudioRetention.resumeSilenceWallSamples
            )
            self.audioBuffer.append(wall)
            self.needsResumeSilenceWall = false
        }
        self.audioBuffer.append(mono16k)
        self.onAcceptedSamples(mono16k)
        if shouldReportFirstAudio {
            let acceptedHostTime = Self.hostTime(
                inputHostTime,
                advancedByFrames: acceptedRange.lowerBound,
                sampleRate: sampleRate
            )
            let acquisitionMs = Self.elapsedMilliseconds(
                from: startHostTime,
                to: acceptedHostTime
            )
            let deliveryMs = Self.elapsedMilliseconds(
                from: startHostTime,
                to: mach_absolute_time()
            )
            self.onFirstAudio(
                recordingSessionID,
                recordingAttemptID,
                Int(mono16k.count),
                originalFrameCount,
                sampleRate,
                acquisitionMs,
                deliveryMs
            )
        }
        self.lock.unlock()
        let measurement = self.measureAudioLevel(mono16k)
        self.onLevel(measurement.level)
        let acceptedHostTime = Self.hostTime(
            inputHostTime,
            advancedByFrames: acceptedRange.lowerBound,
            sampleRate: sampleRate
        )
        self.onSpeechEnergy(acceptedHostTime, measurement.level > 0)
        if let health = self.captureHealthDiagnostic(
            sampleCount: mono16k.count,
            rms: measurement.rms,
            peak: measurement.peak,
            sessionID: recordingSessionID,
            attemptID: recordingAttemptID
        ) {
            self.onCaptureHealth(
                recordingSessionID,
                recordingAttemptID,
                health.audioMs,
                health.sampleCount,
                health.rms,
                health.peak
            )
        }
    }

    static func acceptedFrameRange(
        frameCount: Int,
        sampleRate: Double,
        packetHostTime: UInt64,
        startHostTime: UInt64,
        stopHostTime: UInt64?
    ) -> Range<Int>? {
        guard frameCount > 0 else { return nil }
        // AVAudioEngine can occasionally omit host time. It remains the
        // conservative fallback and accepts the whole callback in that case.
        guard packetHostTime > 0, startHostTime > 0 else { return 0..<frameCount }

        var lowerBound = 0
        if packetHostTime < startHostTime {
            let framesBeforeStart = Int(ceil(
                Double(startHostTime - packetHostTime) /
                    Self.hostTicksPerSecond * sampleRate
            ))
            lowerBound = min(max(framesBeforeStart, 0), frameCount)
        }

        var upperBound = frameCount
        if let stopHostTime {
            if stopHostTime <= packetHostTime {
                return nil
            }
            let framesBeforeStop = Int(floor(
                Double(stopHostTime - packetHostTime) /
                    Self.hostTicksPerSecond * sampleRate
            ))
            upperBound = min(max(framesBeforeStop, 0), frameCount)
        }

        guard lowerBound < upperBound else { return nil }
        return lowerBound..<upperBound
    }

    static func hostTime(
        _ hostTime: UInt64,
        advancedByFrames frames: Int,
        sampleRate: Double
    ) -> UInt64 {
        guard hostTime > 0, frames > 0, sampleRate > 0 else { return hostTime }
        let ticks = Double(frames) / sampleRate * Self.hostTicksPerSecond
        return hostTime &+ UInt64(max(ticks.rounded(), 0))
    }

    static func elapsedMilliseconds(from start: UInt64, to end: UInt64) -> Int {
        guard start > 0, end >= start else { return 0 }
        return Int((Double(end - start) / self.hostTicksPerSecond * 1000).rounded())
    }

    func resetResamplerLocked() {
        self.resampleSourceRate = 0
        self.resampleSourceFrameCursor = 0
        self.resampleNextSourcePosition = 0
        self.resamplePreviousSample = nil
    }

    func resetCaptureHealthLocked() {
        self.captureHealthSampleCount = 0
        self.captureHealthTotalSampleCount = 0
        self.captureHealthSquareSum = 0
        self.captureHealthPeak = 0
    }

    /// Stateful linear resampling keeps fractional phase across small hardware
    /// callbacks. Stateless per-packet conversion silently shortens 44.1 kHz
    /// recordings and introduces a discontinuity at every device cycle.
    func resampleTo16kLocked(
        _ samples: [Float],
        sourceSampleRate: Double
    ) -> [Float] {
        guard samples.isEmpty == false else { return [] }
        if abs(self.resampleSourceRate - sourceSampleRate) > 0.5 {
            self.resetResamplerLocked()
            self.resampleSourceRate = sourceSampleRate
        }
        if sourceSampleRate == 16_000.0 {
            return samples
        }

        let chunkStart = Double(self.resampleSourceFrameCursor)
        let chunkEnd = chunkStart + Double(samples.count)
        let step = sourceSampleRate / 16_000.0
        var output: [Float] = []
        output.reserveCapacity(Int(ceil(Double(samples.count) / step)) + 1)

        while self.resampleNextSourcePosition < chunkEnd {
            let lowerFrame = Int64(floor(self.resampleNextSourcePosition))
            let fraction = Float(self.resampleNextSourcePosition - Double(lowerFrame))
            let localLower = lowerFrame - self.resampleSourceFrameCursor

            let lowerSample: Float
            let upperSample: Float
            if localLower < 0 {
                guard localLower == -1,
                      let previousSample = self.resamplePreviousSample
                else { break }
                lowerSample = previousSample
                upperSample = samples[0]
            } else {
                let index = Int(localLower)
                guard index < samples.count else { break }
                lowerSample = samples[index]
                if fraction == 0 {
                    upperSample = lowerSample
                } else {
                    guard index + 1 < samples.count else { break }
                    upperSample = samples[index + 1]
                }
            }

            output.append(lowerSample + (upperSample - lowerSample) * fraction)
            self.resampleNextSourcePosition += step
        }

        self.resampleSourceFrameCursor += Int64(samples.count)
        self.resamplePreviousSample = samples.last
        return output
    }

    func measureAudioLevel(_ samples: [Float]) -> (level: CGFloat, rms: Float, peak: Float) {
        guard samples.isEmpty == false else { return (0, 0, 0) }

        var sum: Float = 0.0
        vDSP_svesq(samples, 1, &sum, vDSP_Length(samples.count))
        let rms = sqrt(sum / Float(samples.count))
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))

        // Noise gate
        if rms < 0.002 {
            return (self.applySmoothingAndThreshold(0), rms, peak)
        }

        // dB -> normalized [0, 1]
        let dbLevel = 20 * log10(max(rms, 1e-10))
        let normalizedLevel = max(0, min(1, (dbLevel + 55) / 55))
        return (self.applySmoothingAndThreshold(CGFloat(normalizedLevel)), rms, peak)
    }

    func captureHealthDiagnostic(
        sampleCount: Int,
        rms: Float,
        peak: Float,
        sessionID: Int,
        attemptID: UInt64
    ) -> (audioMs: Int, sampleCount: Int, rms: Float, peak: Float)? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.recordingEnabled,
              self.recordingSessionID == sessionID,
              self.recordingAttemptID == attemptID
        else { return nil }

        self.captureHealthSampleCount += sampleCount
        self.captureHealthTotalSampleCount += sampleCount
        self.captureHealthSquareSum += Double(rms * rms) * Double(sampleCount)
        self.captureHealthPeak = max(self.captureHealthPeak, peak)
        guard self.captureHealthSampleCount >= 16_000 else { return nil }

        let windowSampleCount = self.captureHealthSampleCount
        let windowRMS = Float(sqrt(self.captureHealthSquareSum / Double(windowSampleCount)))
        let result = (
            audioMs: Int((Double(self.captureHealthTotalSampleCount) / 16_000 * 1000).rounded()),
            sampleCount: windowSampleCount,
            rms: windowRMS,
            peak: self.captureHealthPeak
        )
        self.captureHealthSampleCount = 0
        self.captureHealthSquareSum = 0
        self.captureHealthPeak = 0
        return result
    }

    func applySmoothingAndThreshold(_ newLevel: CGFloat) -> CGFloat {
        self.lock.lock()
        defer { self.lock.unlock() }

        self.levelHistory.append(newLevel)
        if self.levelHistory.count > self.historySize {
            self.levelHistory.removeFirst()
        }

        let average = self.levelHistory.reduce(0, +) / CGFloat(self.levelHistory.count)
        let smoothingFactor: CGFloat = 0.7
        self.smoothedLevel = (smoothingFactor * newLevel) + ((1 - smoothingFactor) * average)

        if self.smoothedLevel < self.silenceThreshold {
            return 0.0
        }

        return self.smoothedLevel
    }

    static func downmixToMono(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        let frameCount = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        if channels == 1 {
            return Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        }
        var mono = [Float](repeating: 0, count: frameCount)
        for c in 0..<channels {
            let src = channelData[c]
            vDSP_vadd(src, 1, mono, 1, &mono, 1, vDSP_Length(frameCount))
        }
        var div = Float(channels)
        vDSP_vsdiv(mono, 1, &div, &mono, 1, vDSP_Length(frameCount))
        return mono
    }
}
