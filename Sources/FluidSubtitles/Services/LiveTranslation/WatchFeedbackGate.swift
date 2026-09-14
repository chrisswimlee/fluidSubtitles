import CoreAudio
import Foundation

/// Watch howl detector. Correlates the newest packet against a delayed ring of
/// the same capture. Do not subtract the default hardware output from This Mac
/// — that mix is the program itself.
enum WatchFeedbackGate {
    static let minLagSeconds: Double = 0.008
    static let maxLagSeconds: Double = 0.16
    static let defaultThreshold: Float = 0.88
    static let aggressiveThreshold: Float = 0.78
    static let hitsToDrop = 3
    static let energyFloor: Float = 0.004

    static func threshold(aggressive: Bool) -> Float {
        aggressive ? self.aggressiveThreshold : self.defaultThreshold
    }

    /// Normalized peak cross-correlation of `probe` against `reference` at
    /// lags between `minLagSeconds` and `maxLagSeconds`.
    static func peakCorrelation(
        probe: [Float],
        reference: [Float],
        sampleRate: Double
    ) -> (rho: Float, lag: Int) {
        guard sampleRate > 0, probe.count >= 32, reference.count > probe.count else {
            return (0, 0)
        }
        let minLag = max(1, Int((self.minLagSeconds * sampleRate).rounded()))
        let maxLag = min(
            reference.count - probe.count,
            Int((self.maxLagSeconds * sampleRate).rounded())
        )
        guard maxLag >= minLag else { return (0, 0) }

        var probeEnergy: Float = 0
        for sample in probe {
            probeEnergy += sample * sample
        }
        guard probeEnergy > 1e-8 else { return (0, 0) }
        let probeRMS = sqrt(probeEnergy)

        var bestRho: Float = 0
        var bestLag = 0
        let start = reference.count - probe.count
        for lag in minLag...maxLag {
            let offset = start - lag
            guard offset >= 0 else { continue }
            var dot: Float = 0
            var refEnergy: Float = 0
            for index in 0..<probe.count {
                let sample = reference[offset + index]
                dot += probe[index] * sample
                refEnergy += sample * sample
            }
            guard refEnergy > 1e-8 else { continue }
            let rho = abs(dot) / (probeRMS * sqrt(refEnergy))
            if rho > bestRho {
                bestRho = rho
                bestLag = lag
            }
        }
        return (bestRho, bestLag)
    }

    static func shouldDrop(
        rho: Float,
        lag: Int,
        previousLag: Int?,
        consecutiveHits: Int,
        probeEnergy: Float,
        previousEnergy: Float,
        aggressive: Bool
    ) -> (drop: Bool, nextHits: Int, nextLag: Int?) {
        guard probeEnergy >= self.energyFloor, lag > 0 else {
            return (false, 0, nil)
        }
        let threshold = self.threshold(aggressive: aggressive)
        let lagStable: Bool
        if let previousLag {
            lagStable = abs(previousLag - lag) <= max(1, previousLag / 8)
        } else {
            lagStable = true
        }
        let rising = probeEnergy >= previousEnergy * 0.95
        if rho >= threshold, lagStable, rising {
            let hits = consecutiveHits + 1
            return (hits >= self.hitsToDrop, hits, lag)
        }
        return (false, 0, rho >= threshold ? lag : nil)
    }
}

/// Process-local chime marker so Watch can tighten the howl gate when Fluid
/// playback may have been re-injected through a virtual device.
enum WatchPlaybackReference {
    private static let lock = NSLock()
    private static var lastChimeUptime: TimeInterval = 0

    static func noteChime() {
        self.lock.lock()
        self.lastChimeUptime = ProcessInfo.processInfo.systemUptime
        self.lock.unlock()
    }

    static func recentlyPlayed(within: TimeInterval = 0.6) -> Bool {
        self.lock.lock()
        let last = self.lastChimeUptime
        self.lock.unlock()
        return last > 0 && ProcessInfo.processInfo.systemUptime - last < within
    }
}

enum WatchOutputRoute {
    static let warningCopy =
        "Default output looks like a virtual or aggregate device. Watch may hear a looped mix."

    static func looksLikeLoopbackOrAggregate(
        _ device: AudioDevice.Device? = AudioDevice.getDefaultOutputDevice()
    ) -> Bool {
        guard let device else { return false }
        if device.transportType == kAudioDeviceTransportTypeVirtual
            || device.transportType == kAudioDeviceTransportTypeAggregate
        {
            return true
        }
        let haystack = "\(device.uid) \(device.name)".lowercased()
        let hints = [
            "blackhole", "loopback", "soundflower", "aggregate",
            "multi-output", "multioutput", "groundcontrol", "virtual"
        ]
        return hints.contains { haystack.contains($0) }
    }
}

/// Stateful Watch packet filter. Fail open when the score is uncertain.
final class WatchFeedbackSession: @unchecked Sendable {
    private let lock = NSLock()
    private var ring: [Float] = []
    private var lastLag: Int?
    private var consecutiveHits = 0
    private var lastEnergy: Float = 0
    private let maxRingSeconds: Double = 0.24

    func admit(
        _ samples: UnsafePointer<Float>,
        count: Int,
        sampleRate: Double,
        aggressive: Bool = false
    ) -> Bool {
        guard count > 0, sampleRate > 0 else { return true }
        let probe = Array(UnsafeBufferPointer(start: samples, count: count))
        var energy: Float = 0
        for sample in probe {
            energy += sample * sample
        }
        energy = sqrt(energy / Float(count))

        self.lock.lock()
        self.ring.append(contentsOf: probe)
        let maxRing = Int((self.maxRingSeconds * sampleRate).rounded())
        if self.ring.count > maxRing {
            self.ring.removeFirst(self.ring.count - maxRing)
        }
        let reference = self.ring
        let previousLag = self.lastLag
        let previousHits = self.consecutiveHits
        let previousEnergy = self.lastEnergy
        self.lock.unlock()

        let peak = WatchFeedbackGate.peakCorrelation(
            probe: probe,
            reference: reference,
            sampleRate: sampleRate
        )
        let tighter = aggressive || WatchPlaybackReference.recentlyPlayed()
        let decision = WatchFeedbackGate.shouldDrop(
            rho: peak.rho,
            lag: peak.lag,
            previousLag: previousLag,
            consecutiveHits: previousHits,
            probeEnergy: energy,
            previousEnergy: previousEnergy,
            aggressive: tighter
        )
        self.lock.lock()
        self.lastLag = decision.nextLag
        self.consecutiveHits = decision.nextHits
        self.lastEnergy = energy
        self.lock.unlock()
        return !decision.drop
    }
}
