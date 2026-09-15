import Darwin
import Foundation

/// Converts Core Audio host ticks into `ProcessInfo` uptime so tests can inject both clocks.
enum LiveTranslationHostClock {
    static let ticksPerSecond: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        guard info.numer != 0, info.denom != 0 else { return 1_000_000_000 }
        return 1_000_000_000.0 * Double(info.denom) / Double(info.numer)
    }()

    static func ticks(forSeconds seconds: TimeInterval) -> UInt64 {
        let value = (seconds * self.ticksPerSecond).rounded()
        guard value.isFinite, value > 0 else { return 0 }
        if value >= Double(UInt64.max) { return .max }
        return UInt64(value)
    }

    static func uptime(
        fromHostTime hostTime: UInt64,
        nowUptime: TimeInterval,
        nowHostTime: UInt64
    ) -> TimeInterval {
        guard hostTime > 0, self.ticksPerSecond > 0 else { return nowUptime }
        let (elapsedTicks, overflowed) = nowHostTime.subtractingReportingOverflow(hostTime)
        guard !overflowed else { return nowUptime }
        let elapsed = Double(elapsedTicks) / self.ticksPerSecond
        guard elapsed.isFinite else { return nowUptime }
        return nowUptime - elapsed
    }
}

enum LiveTranslationSilenceGate {
    static func isPastHold(
        lastVoicedUptime: TimeInterval?,
        now: TimeInterval,
        holdSeconds: TimeInterval = LiveTranslationTiming.silenceHoldSeconds
    ) -> Bool {
        guard let lastVoicedUptime else { return true }
        return now - lastVoicedUptime >= holdSeconds
    }

    static func shouldSkipASRTick(
        hadFirstTick: Bool,
        lastVoicedUptime: TimeInterval?,
        now: TimeInterval,
        holdSeconds: TimeInterval = LiveTranslationTiming.silenceHoldSeconds,
        consumedSilenceEdgeTick: Bool = false,
        thermal: ProcessInfo.ThermalState = .nominal
    ) -> Bool {
        guard hadFirstTick else { return false }
        guard self.isPastHold(
            lastVoicedUptime: lastVoicedUptime,
            now: now,
            holdSeconds: holdSeconds
        ) else { return false }
        return consumedSilenceEdgeTick || self.treatsSilenceEdgeAsConsumed(thermal)
    }

    /// Hot Macs skip the post-hold silence-edge tick so pause does not keep the Neural Engine warm.
    /// `.nominal`, `.fair`, and unknown states keep the existing consume-flag policy.
    static func treatsSilenceEdgeAsConsumed(_ thermal: ProcessInfo.ThermalState) -> Bool {
        switch thermal {
        case .serious, .critical:
            return true
        case .nominal, .fair:
            return false
        @unknown default:
            return false
        }
    }

    /// Critical thermal is the only state that swaps the Voice Engine.
    /// Serious keeps silence-edge tick thinning only.
    static func shouldDowngradeEngine(_ thermal: ProcessInfo.ThermalState) -> Bool {
        switch thermal {
        case .critical:
            return true
        default:
            return false
        }
    }
}

enum LiveTranslationThermalEngine {
    static let statusCopy = "Using Apple Speech because this Mac is hot."

    static func fallbackModel(isAppleSpeechAnalyzerAvailable: Bool) -> SettingsStore.SpeechModel {
        isAppleSpeechAnalyzerAvailable ? .appleSpeechAnalyzer : .appleSpeech
    }

    static func fallbackModel() -> SettingsStore.SpeechModel {
        if #available(macOS 26.0, *) {
            return self.fallbackModel(isAppleSpeechAnalyzerAvailable: true)
        }
        return self.fallbackModel(isAppleSpeechAnalyzerAvailable: false)
    }

    static func shouldApply(
        current: SettingsStore.SpeechModel,
        thermal: ProcessInfo.ThermalState,
        alreadyOverridden: Bool
    ) -> Bool {
        guard !alreadyOverridden else { return false }
        guard LiveTranslationSilenceGate.shouldDowngradeEngine(thermal) else { return false }
        switch current {
        case .appleSpeech, .appleSpeechAnalyzer:
            return false
        default:
            return true
        }
    }
}

enum LiveTranslationThermalReadout {
    static func label(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:
            return "nominal"
        case .fair:
            return "fair"
        case .serious:
            return "serious"
        case .critical:
            return "critical"
        @unknown default:
            return "unknown"
        }
    }
}

struct LiveTranslationLatencySample: Equatable {
    var micMilliseconds: Int?
    var endToEndMilliseconds: Int?
    var asrMilliseconds: Int?
    var machineTranslationMilliseconds: Int?
    var thermalState: ProcessInfo.ThermalState = .nominal

    var displayText: String {
        var parts: [String] = []
        if let micMilliseconds {
            let label = "mic"
            parts.append("\(label) \(micMilliseconds)")
        }
        if let endToEndMilliseconds {
            parts.append("\(endToEndMilliseconds)ms e2e")
        }
        if let asrMilliseconds {
            parts.append("ASR \(asrMilliseconds)")
        }
        if let machineTranslationMilliseconds, endToEndMilliseconds != nil || asrMilliseconds != nil {
            parts.append("MT \(machineTranslationMilliseconds)")
        } else if let machineTranslationMilliseconds {
            parts.append("MT \(machineTranslationMilliseconds)ms")
        }
        parts.append("thermal \(LiveTranslationThermalReadout.label(self.thermalState))")
        return parts.joined(separator: " · ")
    }

    var compactText: String {
        if let endToEndMilliseconds {
            return "\(endToEndMilliseconds)ms"
        }
        if let machineTranslationMilliseconds {
            return "MT \(machineTranslationMilliseconds)ms"
        }
        return ""
    }
}

struct LiveTranslationLatencyTracker: Equatable {
    private(set) var listenStart: TimeInterval?
    private(set) var firstBuffer: TimeInterval?
    private(set) var speechStart: TimeInterval?
    private(set) var asrReady: TimeInterval?
    private(set) var lastSample = LiveTranslationLatencySample()

    mutating func markListenStart(_ time: TimeInterval) {
        if self.listenStart == nil {
            self.listenStart = time
        }
    }

    mutating func markFirstBuffer(_ time: TimeInterval) {
        if self.firstBuffer == nil {
            self.firstBuffer = time
        }
        if self.listenStart == nil {
            self.listenStart = time
        }
    }

    mutating func markSpeechStart(_ time: TimeInterval) {
        if self.speechStart == nil {
            self.speechStart = time
        }
    }

    mutating func markASRReady(_ time: TimeInterval) {
        if self.asrReady == nil {
            self.asrReady = time
        }
    }

    @discardableResult
    mutating func markTranslated(
        at time: TimeInterval,
        mtMilliseconds: Int,
        thermal: ProcessInfo.ThermalState
    ) -> LiveTranslationLatencySample {
        let mic: Int?
        if let start = self.listenStart, let buffer = self.firstBuffer {
            mic = Int((max(0, buffer - start) * 1000).rounded())
        } else {
            mic = nil
        }
        let endToEnd = self.speechStart.map { start in
            Int((max(0, time - start) * 1000).rounded())
        }
        let asr: Int?
        if let start = self.speechStart, let ready = self.asrReady {
            asr = Int((max(0, ready - start) * 1000).rounded())
        } else {
            asr = nil
        }
        self.lastSample = LiveTranslationLatencySample(
            micMilliseconds: mic,
            endToEndMilliseconds: endToEnd,
            asrMilliseconds: asr,
            machineTranslationMilliseconds: mtMilliseconds,
            thermalState: thermal
        )
        return self.lastSample
    }

    mutating func refreshThermal(_ thermal: ProcessInfo.ThermalState) -> LiveTranslationLatencySample {
        self.lastSample.thermalState = thermal
        return self.lastSample
    }

    mutating func resetUtterance() {
        self.listenStart = nil
        self.firstBuffer = nil
        self.speechStart = nil
        self.asrReady = nil
    }
}

/// Last successful Theater clause clock, for filling docs after a real Listen.
enum LastListenLatencyStore {
    struct Record: Codable, Equatable {
        var micMilliseconds: Int?
        var endToEndMilliseconds: Int?
        var asrMilliseconds: Int?
        var machineTranslationMilliseconds: Int?
        var thermal: String
        var recordedAt: Date
    }

    static func write(
        _ sample: LiveTranslationLatencySample,
        to url: URL? = nil,
        fileManager: FileManager = .default
    ) {
        guard sample.endToEndMilliseconds != nil || sample.machineTranslationMilliseconds != nil else { return }
        let record = Record(
            micMilliseconds: sample.micMilliseconds,
            endToEndMilliseconds: sample.endToEndMilliseconds,
            asrMilliseconds: sample.asrMilliseconds,
            machineTranslationMilliseconds: sample.machineTranslationMilliseconds,
            thermal: LiveTranslationThermalReadout.label(sample.thermalState),
            recordedAt: Date()
        )
        let destination = url ?? self.url(fileManager: fileManager)
        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(record)
            try data.write(to: destination, options: .atomic)
        } catch {
            DebugLogger.shared.debug(
                "Could not write last Listen latency: \(error.localizedDescription)",
                source: "LiveTranslation"
            )
        }
    }

    static func read(from url: URL? = nil, fileManager: FileManager = .default) -> Record? {
        let source = url ?? self.url(fileManager: fileManager)
        guard let data = try? Data(contentsOf: source) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    static func url(fileManager: FileManager = .default) -> URL {
        AppSupportDirectory.url(fileManager: fileManager).appendingPathComponent("LastListenLatency.json")
    }
}
