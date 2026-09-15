//
//  ASRService+Types.swift
//  fluid
//
//  ASR helpers that sit beside ASRService.
//

import Foundation
#if arch(arm64)
import FluidAudio
#endif

/// Serializes transcription operations and lets teardown cancel the real queued work.
actor TranscriptionExecutor {
    var lastTask: Task<Void, Never>?
    var operationCancellations: [UUID: () -> Void] = [:]

    func run<T>(benchmarkSessionID: Int? = nil, _ operation: @escaping () async throws -> T) async throws -> T {
        logTranscriptionExecutorPhase("entered", sessionID: benchmarkSessionID)
        let previous = self.lastTask
        let operationID = UUID()
        let task = Task<T, Error> {
            logTranscriptionExecutorPhase("task_started", sessionID: benchmarkSessionID)
            _ = await previous?.result
            logTranscriptionExecutorPhase("previous_finished", sessionID: benchmarkSessionID)
            try Task.checkCancellation()
            return try await operation()
        }
        self.operationCancellations[operationID] = { task.cancel() }
        self.lastTask = Task { _ = try? await task.value }
        defer { self.operationCancellations.removeValue(forKey: operationID) }
        return try await task.value
    }

    func cancelAndAwaitPending() async {
        for cancel in self.operationCancellations.values {
            cancel()
        }
        _ = await self.lastTask?.result
        self.lastTask = nil
        self.operationCancellations.removeAll()
    }
}

private nonisolated func logTranscriptionExecutorPhase(_ phase: String, sessionID: Int?) {
    guard let sessionID else { return }
    let timestamp = ProcessInfo.processInfo.systemUptime
    DebugLogger.shared.info(
        "ASR_BENCH t=\(timestamp) session=\(sessionID) final_queue_\(phase) mainThread=\(Thread.isMainThread)",
        source: "ASRBenchmark"
    )
}

nonisolated func logStreamingProviderOperationReturn(
    sessionID: Int,
    operationID: UUID,
    route: String
) {
    let returnedAt = ProcessInfo.processInfo.systemUptime
    DebugLogger.shared.info(
        "ASR_BENCH t=\(returnedAt) streaming_provider_operation_return " +
            "session=\(sessionID) operation=\(operationID.uuidString) route=\(route)",
        source: "ASRBenchmark"
    )
}

/// Keeps a stop-state UI refresh from entering the main-actor queue ahead of
/// final transcription. The owner must always finish the gate; repeated finishes
/// are harmless so early-return paths can share one cleanup.
struct ASRStopUIInvalidationGate {
    private(set) var isDeferring = false
    var hasOutputPipelineHold = false
    var stopDidFinish = false

    mutating func holdForOutputPipeline() {
        self.isDeferring = true
        self.hasOutputPipelineHold = true
    }

    mutating func begin() {
        self.isDeferring = true
    }

    mutating func finish() -> Bool {
        guard self.isDeferring else { return false }
        self.stopDidFinish = true
        return self.completeIfReady()
    }

    mutating func releaseOutputPipelineHold() -> Bool {
        self.hasOutputPipelineHold = false
        guard self.stopDidFinish else {
            let wasDeferring = self.isDeferring
            self.isDeferring = false
            return wasDeferring
        }
        return self.completeIfReady()
    }

    mutating func forceFinish() -> Bool {
        self.hasOutputPipelineHold = false
        self.stopDidFinish = true
        return self.completeIfReady()
    }

    private mutating func completeIfReady() -> Bool {
        guard self.isDeferring, self.stopDidFinish, self.hasOutputPipelineHold == false else { return false }
        self.isDeferring = false
        self.stopDidFinish = false
        return true
    }
}

@MainActor
func scheduleDeferredMainActorOperation(
    afterNanoseconds delayNanoseconds: UInt64,
    shouldRun: @escaping @MainActor () -> Bool = { true },
    operation: @escaping @MainActor () -> Void
) -> Task<Void, Never> {
    Task { @MainActor in
        do {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        } catch {
            return
        }
        guard Task.isCancelled == false, shouldRun() else { return }
        operation()
    }
}

/// Identifies the recording and provider generation allowed to publish a live preview.
/// Operation completion uses the narrower operation identity so stale cleanup cannot
/// clear state owned by a newer chunk.
struct StreamingTranscriptionWorkState {
    private(set) var sessionID: Int?
    private(set) var activeOperationID: UUID?
    private(set) var providerGeneration: UInt64 = 0

    mutating func beginSession(_ sessionID: Int) {
        self.sessionID = sessionID
        self.activeOperationID = nil
    }

    mutating func beginOperation(
        sessionID: Int,
        operationID: UUID
    ) -> UInt64? {
        guard self.sessionID == sessionID, self.activeOperationID == nil else { return nil }
        self.activeOperationID = operationID
        return self.providerGeneration
    }

    func ownsOperation(sessionID: Int, operationID: UUID) -> Bool {
        self.sessionID == sessionID && self.activeOperationID == operationID
    }

    func canPublish(
        sessionID: Int,
        operationID: UUID,
        providerGeneration: UInt64
    ) -> Bool {
        self.ownsOperation(sessionID: sessionID, operationID: operationID) &&
            self.providerGeneration == providerGeneration
    }

    func canPublishPreview(
        sessionID: Int,
        operationID: UUID,
        providerGeneration: UInt64,
        isRunning: Bool,
        schedulingSessionID: Int?
    ) -> Bool {
        isRunning &&
            schedulingSessionID == sessionID &&
            self.canPublish(
                sessionID: sessionID,
                operationID: operationID,
                providerGeneration: providerGeneration
            )
    }

    mutating func finishOperation(sessionID: Int, operationID: UUID) -> Bool {
        guard self.ownsOperation(sessionID: sessionID, operationID: operationID) else { return false }
        self.activeOperationID = nil
        return true
    }

    mutating func invalidateProvider() {
        self.providerGeneration &+= 1
    }

    mutating func endSession(_ sessionID: Int) {
        guard self.sessionID == sessionID, self.activeOperationID == nil else { return }
        self.sessionID = nil
    }
}

/// Blocks a new recording only while the previous recording still owns the shared PCM buffer.
/// Cancelling a pending start releases its waiter without completing the active handoff.
@MainActor
final class RecordingBufferHandoffGate {
    struct Token: Equatable {
        let id = UUID()
    }

    var activeToken: Token?
    var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var isRecovering = false

    var isActive: Bool { self.activeToken != nil }
    var pendingWaiterCount: Int { self.waiters.count }

    func begin() -> Token? {
        guard self.activeToken == nil else { return nil }
        let token = Token()
        self.activeToken = token
        return token
    }

    func waitUntilAvailable() async {
        guard self.activeToken != nil else { return }
        await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
    }

    func releasePendingWaiters() {
        let waiters = self.waiters
        self.waiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }

    func complete(_ token: Token) {
        guard self.activeToken == token else { return }
        self.activeToken = nil
        self.isRecovering = false
        self.releasePendingWaiters()
    }

    func markTimedOut(_ token: Token) {
        guard self.activeToken == token else { return }
        self.isRecovering = true
        // Wake starts already waiting so they fail visibly instead of hanging.
        self.releasePendingWaiters()
    }
}

/// Owns the cancellable idle delay separately from provider work. Normal recording
/// stop cancels only the delay; an active provider operation is allowed to settle.
@MainActor
final class StreamingTaskLifecycle {
    var scheduler: (id: UUID, task: Task<Void, Never>)?
    var active: (sessionID: Int, operationID: UUID, task: Task<Void, Never>)?
    var drainWaiters: [UUID: (operationID: UUID, continuation: CheckedContinuation<Bool, Never>, timer: Task<Void, Never>)] = [:]

    var hasScheduledIdleWork: Bool { self.scheduler != nil }
    var hasActiveWork: Bool { self.active != nil }
    var pendingDrainCount: Int { self.drainWaiters.count }

    @discardableResult
    func schedule(
        sessionID: Int,
        delayNanoseconds: UInt64,
        operation: @escaping @MainActor (UUID) async -> Void,
        completion: @escaping @MainActor (UUID) -> Void
    ) -> Bool {
        guard self.scheduler == nil, self.active == nil else { return false }
        let schedulerID = UUID()
        let task = Task { @MainActor [weak self] in
            if delayNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                } catch {
                    return
                }
            }
            guard let self,
                  Task.isCancelled == false,
                  self.scheduler?.id == schedulerID
            else { return }

            self.scheduler = nil
            let operationID = UUID()
            let activeTask = Task { @MainActor [weak self] in
                await operation(operationID)
                guard let self,
                      self.active?.sessionID == sessionID,
                      self.active?.operationID == operationID
                else { return }
                self.active = nil
                completion(operationID)
                let completedWaiters = self.drainWaiters.filter { $0.value.operationID == operationID }
                for id in completedWaiters.keys {
                    self.finishDrain(id: id, completed: true)
                }
            }
            self.active = (sessionID, operationID, activeTask)
        }
        self.scheduler = (schedulerID, task)
        return true
    }

    @discardableResult
    func cancelScheduler() -> Bool {
        guard let scheduler = self.scheduler else { return false }
        self.scheduler = nil
        scheduler.task.cancel()
        return true
    }

    func activeTaskToDrain(sessionID: Int) -> Task<Void, Never>? {
        guard let active = self.active, active.sessionID == sessionID else { return nil }
        return active.task
    }

    /// Deadline bounds the caller only. Never cancel or release a provider still
    /// using incremental state. Completion removes the timer; timeout removes the waiter.
    func drain(sessionID: Int, timeoutNanoseconds: UInt64) async -> Bool {
        guard let active = self.active, active.sessionID == sessionID else { return true }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            let timer = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                } catch { return }
                self?.finishDrain(id: id, completed: false)
            }
            self.drainWaiters[id] = (active.operationID, continuation, timer)
        }
    }

    func finishDrain(id: UUID, completed: Bool) {
        guard let waiter = self.drainWaiters.removeValue(forKey: id) else { return }
        waiter.timer.cancel()
        waiter.continuation.resume(returning: completed)
    }
}

struct ShortAudioSilenceAssessment: Equatable {
    let durationMilliseconds: Int
    let isEligible: Bool
    let shouldSkipTranscription: Bool
    let peakAmplitude: Float
    let rmsAmplitude: Float
    let maximumFrameRMS: Float
}

enum AudioCaptureStartOutcome: Equatable {
    case started
    case alreadyActive
    case failed
}

enum ASRStopOutcome: Equatable {
    case success
    case empty
    case failed
}

// swiftlint:disable file_length type_body_length function_body_length cyclomatic_complexity
// Tracked grandfather: speech engine. New product surfaces do not belong here.
/// A comprehensive speech recognition service that handles real-time audio transcription.
///
/// This service manages the entire ASR (Automatic Speech Recognition) pipeline including:
/// - Audio capture and processing
/// - Model downloading and management
/// - Real-time transcription
/// - Audio level visualization
/// - Text-to-speech integration
///
/// The service is designed to work seamlessly with macOS system APIs and provides
/// robust error handling and performance optimization.
///
/// ## Language Support
/// fluidSubtitles only hears Korean, English, Thai, and Japanese. Parakeet Flash and TDT stay on English.
/// Apple Speech and Whisper cover Korean, English, Thai, and Japanese. Nemotron Thai is experimental.
/// ## Thread Safety
/// All public methods are marked with @MainActor to ensure thread safety.
/// Audio processing happens on background threads for optimal performance.
///
/// ## Model Management
/// The service automatically downloads and manages ASR models from Hugging Face.
/// Models are cached locally to avoid repeated downloads.
