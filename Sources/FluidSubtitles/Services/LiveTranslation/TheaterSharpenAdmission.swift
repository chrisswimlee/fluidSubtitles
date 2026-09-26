import Foundation

/// Local MLX sharpening yields when the Mac is hot or the compressor is already active.
enum TheaterSharpenAdmission {
    static func allows(
        thermal: ProcessInfo.ThermalState,
        memoryPressure: DispatchSource.MemoryPressureEvent
    ) -> Bool {
        switch thermal {
        case .serious, .critical:
            return false
        case .nominal, .fair:
            break
        @unknown default:
            break
        }
        if memoryPressure.contains(.warning) || memoryPressure.contains(.critical) {
            return false
        }
        return true
    }

    static func isWithdrawal(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let engine = error as? TranslationEngineError, engine.isSharpenWithdrawn { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        if let llm = error as? LLMError, case .networkError(let inner) = llm {
            if inner is CancellationError { return true }
            if let urlError = inner as? URLError, urlError.code == .cancelled { return true }
        }
        return false
    }
}

/// Watches thermal state and memory pressure, and cancels an in-flight polish request.
final class TheaterAcceleratorGate: @unchecked Sendable {
    static let shared = TheaterAcceleratorGate(observingSystem: true)

    private final class CancelBox: @unchecked Sendable {
        private let lock = NSLock()
        private var cancel: (() -> Void)?
        private var cancelled = false

        func arm(_ cancel: @escaping () -> Void) {
            self.lock.lock()
            self.cancel = cancel
            let cancelled = self.cancelled
            self.lock.unlock()
            if cancelled { cancel() }
        }

        func fire() {
            self.lock.lock()
            self.cancelled = true
            let cancel = self.cancel
            self.lock.unlock()
            cancel?()
        }
    }

    private let lock = NSLock()
    private var memoryPressure = DispatchSource.MemoryPressureEvent.normal
    private var cancellations: [UUID: CancelBox] = [:]
    private var source: DispatchSourceMemoryPressure?
    private var thermalObserver: NSObjectProtocol?
    private var wasAllowing = true

    init(observingSystem: Bool) {
        guard observingSystem else { return }
        let queue = DispatchQueue(label: "com.fluidsubtitles.mlx.sharpen", qos: .background)
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.noteMemoryPressure(source.data)
        }
        source.activate()
        self.source = source
        self.thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.refreshAdmission()
        }
    }

    deinit {
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
        }
        self.source?.cancel()
    }

    var allowsSharpen: Bool {
        self.lock.lock()
        let pressure = self.memoryPressure
        self.lock.unlock()
        return TheaterSharpenAdmission.allows(
            thermal: ProcessInfo.processInfo.thermalState,
            memoryPressure: pressure
        )
    }

    func track<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        guard let registration = self.beginTracking() else {
            throw TranslationEngineError.sharpenWithdrawn
        }
        let task = Task.detached { try await operation() }
        registration.box.arm { task.cancel() }
        if self.allowsSharpen == false {
            task.cancel()
        }
        defer { self.end(registration.id) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func beginTracking() -> (id: UUID, box: CancelBox)? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.allowsLocked() else { return nil }
        let id = UUID()
        let box = CancelBox()
        self.cancellations[id] = box
        return (id, box)
    }

    func cancelInFlight() {
        self.lock.lock()
        let boxes = Array(self.cancellations.values)
        self.lock.unlock()
        boxes.forEach { $0.fire() }
    }

    private func noteMemoryPressure(_ event: DispatchSource.MemoryPressureEvent) {
        self.lock.lock()
        self.memoryPressure = event
        self.lock.unlock()
        self.refreshAdmission()
    }

    private func refreshAdmission() {
        let allows = self.allowsSharpen
        self.lock.lock()
        let changed = allows != self.wasAllowing
        self.wasAllowing = allows
        self.lock.unlock()
        guard changed, allows == false else { return }
        DebugLogger.shared.info(
            "Local sharpening paused while this Mac is hot or short on memory.",
            source: "TheaterSharpen"
        )
        self.cancelInFlight()
    }

    private func allowsLocked() -> Bool {
        TheaterSharpenAdmission.allows(
            thermal: ProcessInfo.processInfo.thermalState,
            memoryPressure: self.memoryPressure
        )
    }

    private func end(_ id: UUID) {
        self.lock.lock()
        self.cancellations.removeValue(forKey: id)
        self.lock.unlock()
    }
}
