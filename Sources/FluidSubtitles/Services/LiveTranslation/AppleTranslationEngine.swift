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

    func prepare(source: TranslationLanguage, target: TranslationLanguage) {
        guard source.id != target.id else {
            self.configuration = nil
            return
        }
        let sourceLanguage = self.resolvedAppleLanguage(source)
        let targetLanguage = self.resolvedAppleLanguage(target)
        let pair = "\(sourceLanguage.minimalIdentifier)->\(targetLanguage.minimalIdentifier)"
        guard pair != self.lastPair else { return }
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
    }

    /// Re-triggers the SwiftUI host so macOS can show the language-pack sheet.
    func requestLanguagePackDownload() {
        guard var configuration = self.configuration else { return }
        configuration.invalidate()
        self.configuration = configuration
    }

    func translate(_ text: String, source: TranslationLanguage, target: TranslationLanguage) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard source.id != target.id else { return trimmed }

        await self.ensureSupportedLanguages()
        self.prepare(source: source, target: target)

        if #available(macOS 26.0, *) {
            if let installed = try await self.translateWithInstalledSession(
                trimmed,
                source: source,
                target: target
            ) {
                return installed
            }
        }

        return try await self.mailbox.submit(trimmed)
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
        self.sessionTask?.cancel()
        self.sessionTask = Task { [mailbox] in
            await self.serve(session: session, mailbox: mailbox)
        }
    }

    func checkAvailability(source: TranslationLanguage, target: TranslationLanguage) async -> String {
        await self.ensureSupportedLanguages()
        let sourceLanguage = self.resolvedAppleLanguage(source)
        let targetLanguage = self.resolvedAppleLanguage(target)
        let availability = LanguageAvailability()
        let status = await availability.status(from: sourceLanguage, to: targetLanguage)
        let englishIsPresent = self.supportedLanguages.contains {
            $0.languageCode?.identifier.lowercased() == "en"
        }
        switch status {
        case .installed:
            return "Ready on this Mac — using the \(source.displayName) pack already on this computer"
        case .supported:
            if englishIsPresent, source.id == "en" {
                return "English is already on this Mac. Download \(target.displayName) once before presenting."
            }
            return "Supported — download the language pack once before presenting"
        case .unsupported:
            return "This pair is not supported by Apple Translation"
        @unknown default:
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
            let session: TranslationSession
            let sourceLanguage = self.resolvedAppleLanguage(source)
            let targetLanguage = self.resolvedAppleLanguage(target)
            session = TranslationSession(
                installedSource: sourceLanguage,
                target: targetLanguage
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

    private func serve(session: TranslationSession, mailbox: TranslationRequestMailbox) async {
        for await request in mailbox.requests {
            if Task.isCancelled { break }
            let started = ProcessInfo.processInfo.systemUptime
            do {
                let response = try await session.translate(request.text)
                self.recordLatency(since: started)
                request.resume(.success(response.targetText))
            } catch {
                self.lastError = error.localizedDescription
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

private final class TranslationRequestMailbox: @unchecked Sendable {
    struct Request {
        let text: String
        let resume: (Result<String, Error>) -> Void
    }

    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Request>.Continuation] = [:]
    private var waiters: [CheckedContinuation<String, Error>] = []

    var requests: AsyncStream<Request> {
        AsyncStream { continuation in
            let id = UUID()
            self.lock.lock()
            self.continuations[id] = continuation
            self.lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.lock.lock()
                self?.continuations[id] = nil
                self?.lock.unlock()
            }
        }
    }

    func submit(_ text: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = Request(text: text) { result in
                continuation.resume(with: result)
            }
            self.lock.lock()
            let sinks = Array(self.continuations.values)
            self.lock.unlock()
            guard let sink = sinks.first else {
                continuation.resume(throwing: TranslationEngineError(
                    message: "Apple Translation is not ready yet. Open Live Translation once so the language pack can install."
                ))
                return
            }
            sink.yield(request)
        }
    }

    func cancelAll(_ error: Error) {
        self.lock.lock()
        let sinks = Array(self.continuations.values)
        self.lock.unlock()
        for sink in sinks {
            sink.finish()
        }
    }
}
