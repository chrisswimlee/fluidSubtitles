import AppKit
import Combine
import Foundation
import SwiftUI
import Translation

/// On-device Apple Translation. One warm session per language pair.
@MainActor
final class AppleTranslationEngine: ObservableObject, TranslationEngine {
    static let shared = AppleTranslationEngine()

    let name = "Apple Translation"

    @Published var configuration: TranslationSession.Configuration?
    @Published private(set) var lastError: String?
    @Published private(set) var lastLatencyMilliseconds: Int?
    @Published private(set) var availableLanguages: [TranslationLanguage] = TranslationLanguageCatalog.all

    private var mailbox = TranslationRequestMailbox()
    private var lastPair: String = ""
    private let languageAvailability = LanguageAvailability()
    private var packStatusByPair: [String: TranslationPackAvailability] = [:]

    var isMailboxReady: Bool { self.mailbox.isReady }
    var hasQueuedOrInFlightCommit: Bool { self.mailbox.hasQueuedOrInFlightCommit }

    func cancelQueuedTranslations() {
        self.mailbox.cancelQueued(TranslationEngineError.superseded)
    }

    func prepare(source: TranslationLanguage, target: TranslationLanguage) {
        guard source.id != target.id else {
            self.tearDownSession(reason: "Language pair changed.")
            return
        }
        let sourceLanguage = source.localeLanguage
        let targetLanguage = target.localeLanguage
        let pair = Self.packCacheKey(source: source, target: target)
        if pair == self.lastPair, self.configuration != nil {
            return
        }
        self.lastPair = pair
        self.mailbox.cancelAll(TranslationEngineError(message: "Language pair changed."))
        self.configuration = TranslationSession.Configuration(
            source: sourceLanguage,
            target: targetLanguage
        )
    }

    func warm(source: TranslationLanguage, target: TranslationLanguage, timeoutSeconds: TimeInterval = 2) async {
        self.prepare(source: source, target: target)
        await self.waitUntilMailboxReady(timeoutSeconds: timeoutSeconds)
    }

    /// Re-triggers the SwiftUI host so macOS can show the language-pack sheet.
    func requestLanguagePackDownload() {
        TranslationPackDownloadController.present()
        guard var configuration = self.configuration else { return }
        configuration.invalidate()
        self.configuration = configuration
    }

    func translate(_ text: String, source: TranslationLanguage, target: TranslationLanguage) async throws -> String {
        try await self.translate(text, source: source, target: target, kind: .commit)
    }

    func translate(
        _ text: String,
        source: TranslationLanguage,
        target: TranslationLanguage,
        kind: TranslationRequestKind
    ) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard source.id != target.id else { return trimmed }

        self.prepare(source: source, target: target)
        await self.waitUntilMailboxReady()

        // Live may wait behind a commit. The mailbox already refuses to let
        // prefetch preempt a queued or running commit.
        switch Self.sessionChoice(mailboxReady: self.mailbox.isReady) {
        case .warmMailbox:
            return try await self.mailbox.submit(trimmed, kind: kind)
        case .installedSessionFallback:
            if #available(macOS 26.0, *) {
                if let installed = try await self.translateWithInstalledSession(
                    trimmed,
                    source: source,
                    target: target
                ) {
                    return installed
                }
            }
            return try await self.mailbox.submit(trimmed, kind: kind)
        }
    }

    enum SessionChoice: Equatable {
        case warmMailbox
        case installedSessionFallback
    }

    nonisolated static func sessionChoice(mailboxReady: Bool) -> SessionChoice {
        if mailboxReady { return .warmMailbox }
        if #available(macOS 26.0, *) {
            return .installedSessionFallback
        }
        return .warmMailbox
    }

    /// Theater only asks Apple about this pair. Enumerating every system
    /// locale pair can trap in Translation on macOS 26.
    nonisolated static func packCacheKey(source: TranslationLanguage, target: TranslationLanguage) -> String {
        "\(source.id)->\(target.id)"
    }

    /// Apple requires the session to stay in use only while `.translationTask`'s closure is
    /// running, so this must await the serve loop directly rather than detaching it — a
    /// detached Task lets the closure return immediately and the session becomes invalid
    /// while `serve` is still calling `translate` on it, which eventually traps.
    /// A new attach (pack sheet, configuration invalidate, extra host) claims the
    /// mailbox so the previous serve loop exits instead of overwriting its waiter.
    func attachSession(_ session: TranslationSession) async {
        do {
            try await session.prepareTranslation()
            self.lastError = nil
        } catch {
            self.lastError = error.localizedDescription
            DebugLogger.shared.debug(
                "Apple Translation prepare failed: \(error.localizedDescription)",
                source: "AppleTranslationEngine"
            )
        }
        let generation = self.mailbox.claimServe()
        await self.serve(session: session, mailbox: self.mailbox, generation: generation)
    }

    private func tearDownSession(reason: String) {
        guard !self.lastPair.isEmpty || self.configuration != nil else { return }
        self.lastPair = ""
        self.mailbox.cancelAll(TranslationEngineError(message: reason))
        self.configuration = nil
    }

    private func waitUntilMailboxReady(timeoutSeconds: TimeInterval = 2) async {
        guard self.configuration != nil else { return }
        if self.mailbox.isReady { return }
        let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
        while !self.mailbox.isReady, ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if Task.isCancelled { return }
        }
    }

    func packAvailability(
        source: TranslationLanguage,
        target: TranslationLanguage
    ) async -> TranslationPackAvailability {
        if source.id == target.id { return .installed }
        let key = Self.packCacheKey(source: source, target: target)
        if let cached = self.packStatusByPair[key], cached == .installed || cached == .unsupported {
            return cached
        }
        let status = await self.languageAvailability.status(
            from: source.localeLanguage,
            to: target.localeLanguage
        )
        let resolved: TranslationPackAvailability
        switch status {
        case .installed:
            resolved = .installed
        case .supported:
            resolved = .supported
        case .unsupported:
            resolved = .unsupported
        @unknown default:
            resolved = .unknown
        }
        if resolved == .installed || resolved == .unsupported {
            self.packStatusByPair[key] = resolved
        }
        return resolved
    }

    func checkAvailability(source: TranslationLanguage, target: TranslationLanguage) async -> String {
        if source.id == target.id {
            return "Ready — captioning \(source.displayName)"
        }
        let status = await self.packAvailability(source: source, target: target)
        switch status {
        case .installed:
            return "Ready — \(source.displayName) pack is installed."
        case .supported:
            if source.id == "en" {
                return "Download the \(target.displayName) pack before you Listen."
            }
            return "Download the language pack before you Listen."
        case .unsupported:
            return "This pair is not supported by Apple Translation"
        case .unknown:
            return "Unknown availability"
        }
    }

    @available(macOS 26.0, *)
    private func translateWithInstalledSession(
        _ text: String,
        source: TranslationLanguage,
        target: TranslationLanguage
    ) async throws -> String? {
        do {
            let session = Self.makeInstalledSession(
                source: source.localeLanguage,
                target: target.localeLanguage
            )
            let started = ProcessInfo.processInfo.systemUptime
            let response = try await session.translate(text)
            self.recordLatency(since: started)
            return response.targetText
        } catch {
            DebugLogger.shared.debug(
                "Apple Translation installed session unavailable, using SwiftUI host: \(error.localizedDescription)",
                source: "AppleTranslationEngine"
            )
            return nil
        }
    }

    @available(macOS 26.0, *)
    private static func makeInstalledSession(
        source: Locale.Language,
        target: Locale.Language
    ) -> TranslationSession {
        // preferredStrategy is a later SDK. Hosted CI is Xcode 26.3.
        return TranslationSession(installedSource: source, target: target)
    }

    private func serve(
        session: TranslationSession,
        mailbox: TranslationRequestMailbox,
        generation: UInt64
    ) async {
        while let request = await mailbox.next(generation: generation) {
            if Task.isCancelled {
                request.resume(.failure(TranslationEngineError(message: "Apple Translation stopped.")))
                break
            }
            if request.isCancelled { continue }
            let started = ProcessInfo.processInfo.systemUptime
            do {
                let text = try await Self.translate(
                    request.text,
                    session: session,
                    kind: request.kind,
                    isCancelled: { request.isCancelled }
                )
                self.recordLatency(since: started)
                if request.isCancelled { continue }
                request.resume(.success(text))
            } catch {
                self.lastError = error.localizedDescription
                if request.isCancelled { continue }
                request.resume(.failure(error))
                if (error as? TranslationEngineError)?.isTimeout == true {
                    self.remintSession()
                    break
                }
            }
        }
    }

    /// This loop serves one request at a time, so a single hung or slow
    /// `translate` call (e.g. a cold on-device session still warming up on
    /// the first sentence) would otherwise block every later sentence's
    /// commit behind it indefinitely — the caller's own timeout only
    /// abandons its wait, it does not stop this shared loop. Racing the call
    /// against the same deadline the caller uses keeps the queue moving so a
    /// slow first sentence cannot starve every sentence that follows it.
    private static func translate(
        _ text: String,
        session: TranslationSession,
        kind: TranslationRequestKind = .commit,
        isCancelled: @escaping () -> Bool = { false }
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await session.translate(text).targetText
            }
            group.addTask {
                try await Task.sleep(nanoseconds: LiveTranslationTiming.mailboxTimeoutNanoseconds(for: kind))
                throw TranslationEngineError.timeout
            }
            group.addTask {
                while !isCancelled() {
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                throw TranslationEngineError.superseded
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// Timeout or closing the pack sheet can leave the hidden host without a
    /// serve loop. Invalidate so `.translationTask` attaches again.
    func remintSession() {
        guard var configuration = self.configuration else { return }
        configuration.invalidate()
        self.configuration = configuration
    }

    private func recordLatency(since started: TimeInterval) {
        let ms = Int(((ProcessInfo.processInfo.systemUptime - started) * 1000).rounded())
        self.lastLatencyMilliseconds = ms
        DebugLogger.shared.debug(
            "Apple Translation finished in \(ms)ms",
            source: "AppleTranslationEngine"
        )
    }
}

/// Hidden SwiftUI host that Apple requires to mint a TranslationSession and download packs.
struct TranslationSessionHost: View {
    @ObservedObject var engine = AppleTranslationEngine.shared

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityHidden(true)
            .translationTask(self.engine.configuration) { session in
                await self.engine.attachSession(session)
            }
    }
}

enum TheaterPackListenGate {
    enum Decision: Equatable {
        case allow
        case needDownload
        case unsupported
        case notReady
    }

    /// Cold `LanguageAvailability` can report `.unknown`. A warm mailbox
    /// means this pair can already translate. Otherwise wait — do not open
    /// the pack sheet on a first-query unknown.
    static func decision(
        availability: TranslationPackAvailability,
        mailboxReady: Bool
    ) -> Decision {
        switch availability {
        case .installed:
            return .allow
        case .supported:
            return .needDownload
        case .unsupported:
            return .unsupported
        case .unknown:
            return mailboxReady ? .allow : .notReady
        }
    }
}

enum TranslationPackAvailability: Equatable {
    case installed
    case supported
    case unsupported
    case unknown

    var isReady: Bool { self == .installed }

    static func stricter(_ lhs: Self, _ rhs: Self) -> Self {
        func rank(_ value: Self) -> Int {
            switch value {
            case .installed: return 0
            case .unknown: return 1
            case .supported: return 2
            case .unsupported: return 3
            }
        }
        return rank(lhs) >= rank(rhs) ? lhs : rhs
    }
}

/// Either way (later) needs both directions. The download sheet attaches to the
/// missing pack, not always I speak → Show as.
enum TheaterPairPacks {
    static func combined(
        forward: TranslationPackAvailability,
        reverse: TranslationPackAvailability?,
        bidirectional: Bool
    ) -> TranslationPackAvailability {
        guard bidirectional, let reverse else { return forward }
        return TranslationPackAvailability.stricter(forward, reverse)
    }

    static func downloadPair(
        source: TranslationLanguage,
        target: TranslationLanguage,
        forward: TranslationPackAvailability,
        reverse: TranslationPackAvailability?,
        bidirectional: Bool
    ) -> (source: TranslationLanguage, target: TranslationLanguage) {
        guard bidirectional, source.id != target.id, let reverse else {
            return (source, target)
        }
        let attachReverse = reverse != .installed
            && (
                forward == .installed
                    || TranslationPackAvailability.stricter(forward, reverse) == reverse
            )
        return attachReverse ? (target, source) : (source, target)
    }
}

@MainActor
private final class TranslationPackDownloadPanelDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        TranslationPackDownloadController.dismiss()
    }
}

/// Visible window so Apple’s language-pack sheet is not attached to a 1×1 hidden panel.
@MainActor
enum TranslationPackDownloadController {
    private static var panel: NSPanel?
    private static let panelDelegate = TranslationPackDownloadPanelDelegate()

    static func present() {
        if self.panel == nil {
            let hosting = NSHostingController(rootView: TranslationPackDownloadView())
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 200),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            panel.title = "Download language pack"
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.delegate = self.panelDelegate
            panel.contentViewController = hosting
            if let screen = NSScreen.main ?? NSScreen.screens.first {
                let frame = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(
                    x: frame.midX - 220,
                    y: frame.midY - 100
                ))
            }
            self.panel = panel
        }
        self.panel?.makeKeyAndOrderFront(nil)
    }

    static func dismiss() {
        if let panel = self.panel {
            self.panel = nil
            panel.delegate = nil
            panel.contentViewController = nil
            panel.orderOut(nil)
        }
        AppleTranslationEngine.shared.remintSession()
    }
}

private struct TranslationPackDownloadView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Apple Translation needs this language pack once.")
                .font(.headline)
            Text("If macOS shows a download sheet, keep this window open until it finishes. Then press Listen on Theater.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TranslationSessionHost()
                .frame(width: 8, height: 8)
            HStack {
                Spacer()
                Button("Close") {
                    TranslationPackDownloadController.dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 440, height: 200, alignment: .topLeading)
    }
}

/// Keeps Apple Translation alive after the main window closes. Theater and Insert still need it.
@MainActor
enum TranslationSessionHostController {
    private static var panel: NSPanel?

    static func install() {
        guard self.panel == nil else { return }
        let hosting = NSHostingController(rootView: TranslationSessionHost())
        hosting.view.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        let panel = NSPanel(
            contentRect: NSRect(x: -80, y: -80, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.alphaValue = 0.02
        panel.level = .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.contentViewController = hosting
        panel.orderFrontRegardless()
        self.panel = panel
    }
}

final class TranslationRequestMailbox: @unchecked Sendable {
    struct Request {
        let text: String
        let kind: TranslationRequestKind
        fileprivate let box: ResumeBox

        var isCancelled: Bool { self.box.isFinished }

        func resume(_ result: Result<String, Error>) {
            self.box.resume(result)
        }
    }

    private let lock = NSLock()
    private var live: Request?
    private var commits: [Request] = []
    private var inFlight: Request?
    private var waiter: CheckedContinuation<Request?, Never>?
    private var isServing = false
    private var serveGeneration: UInt64 = 0

    var isReady: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.isServing || self.waiter != nil
    }

    /// Ends any previous serve loop, then returns the generation the new host owns.
    func claimServe() -> UInt64 {
        self.lock.lock()
        self.serveGeneration += 1
        let generation = self.serveGeneration
        self.isServing = true
        let previous = self.waiter
        self.waiter = nil
        self.lock.unlock()
        previous?.resume(returning: nil)
        return generation
    }

    /// True while a commit is waiting or running. Live may queue behind it.
    var hasQueuedOrInFlightCommit: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return !self.commits.isEmpty || self.inFlight?.kind.occupiesCommitSlot == true
    }

    func next() async -> Request? {
        let generation: UInt64 = self.lock.withLock {
            if self.serveGeneration == 0 {
                self.serveGeneration = 1
            }
            self.isServing = true
            return self.serveGeneration
        }
        return await self.next(generation: generation)
    }

    func next(generation: UInt64) async -> Request? {
        await withCheckedContinuation { continuation in
            self.lock.lock()
            guard generation == self.serveGeneration else {
                self.lock.unlock()
                continuation.resume(returning: nil)
                return
            }
            self.isServing = true
            if let request = self.dequeueLocked() {
                self.inFlight = request
                self.lock.unlock()
                continuation.resume(returning: request)
                return
            }
            if let previous = self.waiter {
                self.waiter = continuation
                self.lock.unlock()
                previous.resume(returning: nil)
                return
            }
            self.waiter = continuation
            self.lock.unlock()
        }
    }

    func submit(_ text: String, kind: TranslationRequestKind = .commit) async throws -> String {
        let box = ResumeBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                box.attach(continuation)
                let request = Request(text: text, kind: kind, box: box)
                var superseded: ResumeBox?
                var preempted: ResumeBox?
                var waiter: CheckedContinuation<Request?, Never>?
                var dequeued: Request?

                self.lock.lock()
                if !self.isServing, self.waiter == nil {
                    self.lock.unlock()
                    box.resume(.failure(TranslationEngineError(
                        message: "Apple Translation is not ready yet. Open Theater so the language pack can install."
                    )))
                    return
                }
                if kind == .live {
                    superseded = self.live?.box
                    self.live = request
                } else {
                    if self.inFlight?.kind == .live {
                        preempted = self.inFlight?.box
                    }
                    if let live = self.live {
                        superseded = live.box
                        self.live = nil
                    }
                    self.commits.append(request)
                }
                if let waiting = self.waiter {
                    dequeued = self.dequeueLocked()
                    if dequeued != nil {
                        self.inFlight = dequeued
                        self.waiter = nil
                        waiter = waiting
                    }
                }
                self.lock.unlock()
                superseded?.resume(.failure(TranslationEngineError.superseded))
                preempted?.resume(.failure(TranslationEngineError.superseded))
                if let waiter, let dequeued {
                    waiter.resume(returning: dequeued)
                }
            }
        } onCancel: {
            self.cancelBox(box, error: TranslationEngineError.superseded)
        }
    }

    func cancelQueued(_ error: Error) {
        self.lock.lock()
        let live = self.live
        self.live = nil
        let commits = self.commits
        self.commits.removeAll()
        let inFlight = self.inFlight
        self.inFlight = nil
        self.lock.unlock()
        live?.box.resume(.failure(error))
        inFlight?.box.resume(.failure(error))
        for commit in commits {
            commit.box.resume(.failure(error))
        }
    }

    private func cancelBox(_ box: ResumeBox, error: Error) {
        self.lock.lock()
        if self.live?.box === box { self.live = nil }
        self.commits.removeAll { $0.box === box }
        self.lock.unlock()
        box.resume(.failure(error))
    }

    func cancelAll(_ error: Error) {
        self.lock.lock()
        let live = self.live
        self.live = nil
        let commits = self.commits
        self.commits.removeAll()
        let inFlight = self.inFlight
        self.inFlight = nil
        let waiter = self.waiter
        self.waiter = nil
        self.isServing = false
        self.serveGeneration += 1
        self.lock.unlock()
        live?.box.resume(.failure(error))
        inFlight?.box.resume(.failure(error))
        for commit in commits {
            commit.box.resume(.failure(error))
        }
        waiter?.resume(returning: nil)
    }

    private func dequeueLocked() -> Request? {
        if !self.commits.isEmpty {
            return self.commits.removeFirst()
        }
        if let live = self.live {
            self.live = nil
            return live
        }
        return nil
    }
}

private final class ResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var continuation: CheckedContinuation<String, Error>?

    var isFinished: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.finished
    }

    func attach(_ continuation: CheckedContinuation<String, Error>) {
        self.lock.lock()
        self.continuation = continuation
        self.lock.unlock()
    }

    func resume(_ result: Result<String, Error>) {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard !self.finished, let continuation else { return }
        self.finished = true
        self.continuation = nil
        continuation.resume(with: result)
    }
}
