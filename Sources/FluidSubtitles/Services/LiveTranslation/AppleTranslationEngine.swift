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
    private var sessionTask: Task<Void, Never>?
    private var lastPair: String = ""
    private var supportedLanguages: [Locale.Language] = []

    var isMailboxReady: Bool { self.mailbox.isReady }
    var hasQueuedOrInFlightCommit: Bool { self.mailbox.hasQueuedOrInFlightCommit }

    func prepare(source: TranslationLanguage, target: TranslationLanguage) {
        guard source.id != target.id else {
            self.tearDownSession(reason: "Language pair changed.")
            return
        }
        let sourceLanguage = self.resolvedAppleLanguage(source)
        let targetLanguage = self.resolvedAppleLanguage(target)
        let pair = "\(sourceLanguage.minimalIdentifier)->\(targetLanguage.minimalIdentifier)"
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

    func warm(source: TranslationLanguage, target: TranslationLanguage) async {
        await self.ensureSupportedLanguages()
        self.prepare(source: source, target: target)
        await self.waitUntilMailboxReady()
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

        await self.ensureSupportedLanguages()
        self.prepare(source: source, target: target)
        await self.waitUntilMailboxReady()

        if kind == .live, self.mailbox.hasQueuedOrInFlightCommit {
            throw TranslationEngineError(message: "Commit is in flight.")
        }
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
        self.replaceSessionTask(serving: session)
    }

    private func tearDownSession(reason: String) {
        guard !self.lastPair.isEmpty || self.configuration != nil else { return }
        self.lastPair = ""
        self.mailbox.cancelAll(TranslationEngineError(message: reason))
        self.configuration = nil
    }

    private func replaceSessionTask(serving session: TranslationSession) {
        self.sessionTask?.cancel()
        // Keep queued commits. Pair changes already cancelAll in prepare/tearDown.
        self.sessionTask = Task { [mailbox] in
            await self.serve(session: session, mailbox: mailbox)
        }
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
        await self.ensureSupportedLanguages()
        let sourceLanguage = self.resolvedAppleLanguage(source)
        let targetLanguage = self.resolvedAppleLanguage(target)
        let status = await LanguageAvailability().status(from: sourceLanguage, to: targetLanguage)
        switch status {
        case .installed:
            return .installed
        case .supported:
            return .supported
        case .unsupported:
            return .unsupported
        @unknown default:
            return .unknown
        }
    }

    func checkAvailability(source: TranslationLanguage, target: TranslationLanguage) async -> String {
        if source.id == target.id {
            return "Ready — captioning \(source.displayName)"
        }
        let status = await self.packAvailability(source: source, target: target)
        let englishIsPresent = self.supportedLanguages.contains {
            $0.languageCode?.identifier.lowercased() == "en"
        }
        switch status {
        case .installed:
            return "Ready — \(source.displayName) pack is installed."
        case .supported:
            if englishIsPresent, source.id == "en" {
                return "Download the \(target.displayName) pack before you Listen."
            }
            return "Download the language pack before you Listen."
        case .unsupported:
            return "This pair is not supported by Apple Translation"
        case .unknown:
            return "Unknown availability"
        }
    }

    private func ensureSupportedLanguages() async {
        guard self.supportedLanguages.isEmpty else { return }
        let supported = await LanguageAvailability().supportedLanguages
        self.supportedLanguages = supported
        let languages = TranslationLanguageCatalog.languages(from: supported)
        if !languages.isEmpty {
            self.availableLanguages = languages
        }
    }

    private func resolvedAppleLanguage(_ language: TranslationLanguage) -> Locale.Language {
        TranslationLanguageCatalog.appleLanguage(for: language, from: self.supportedLanguages)
    }

    @available(macOS 26.0, *)
    private func translateWithInstalledSession(
        _ text: String,
        source: TranslationLanguage,
        target: TranslationLanguage
    ) async throws -> String? {
        do {
            let sourceLanguage = self.resolvedAppleLanguage(source)
            let targetLanguage = self.resolvedAppleLanguage(target)
            let session = Self.makeInstalledSession(source: sourceLanguage, target: targetLanguage)
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

    private func serve(session: TranslationSession, mailbox: TranslationRequestMailbox) async {
        while let request = await mailbox.next() {
            if Task.isCancelled { break }
            if request.isCancelled { continue }
            let started = ProcessInfo.processInfo.systemUptime
            do {
                let response = try await session.translate(request.text)
                self.recordLatency(since: started)
                if request.isCancelled { continue }
                request.resume(.success(response.targetText))
            } catch {
                self.lastError = error.localizedDescription
                if request.isCancelled { continue }
                request.resume(.failure(error))
            }
        }
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

/// Visible window so Apple’s language-pack sheet is not attached to a 1×1 hidden panel.
@MainActor
enum TranslationPackDownloadController {
    private static var panel: NSPanel?

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
        self.panel?.orderOut(nil)
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

    var isReady: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.isServing || self.waiter != nil
    }

    /// Live prefetch must not start while a commit is waiting or running.
    var hasQueuedOrInFlightCommit: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return !self.commits.isEmpty || self.inFlight?.kind == .commit
    }

    func next() async -> Request? {
        await withCheckedContinuation { continuation in
            self.lock.lock()
            self.isServing = true
            if let request = self.dequeueLocked() {
                self.inFlight = request
                self.lock.unlock()
                continuation.resume(returning: request)
                return
            }
            self.waiter = continuation
            self.lock.unlock()
        }
    }

    func submit(_ text: String, kind: TranslationRequestKind = .commit) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let box = ResumeBox(continuation)
            let request = Request(text: text, kind: kind, box: box)
            var superseded: ResumeBox?
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
            if let waiter, let dequeued {
                waiter.resume(returning: dequeued)
            }
        }
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
    private let continuation: CheckedContinuation<String, Error>

    init(_ continuation: CheckedContinuation<String, Error>) {
        self.continuation = continuation
    }

    var isFinished: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.finished
    }

    func resume(_ result: Result<String, Error>) {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard !self.finished else { return }
        self.finished = true
        self.continuation.resume(with: result)
    }
}
