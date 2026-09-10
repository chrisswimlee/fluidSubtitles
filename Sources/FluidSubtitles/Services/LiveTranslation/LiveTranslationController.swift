import AppKit
import Combine
import Foundation

@MainActor
final class LiveTranslationController: ObservableObject {
    static let shared = LiveTranslationController()

    @Published private(set) var isSessionActive = false
    @Published private(set) var listenKind: TranslationListenKind?
    let subscriber = LiveTranslationSubscriber()
    let appleEngine = AppleTranslationEngine.shared

    var onStartCaptionListening: (() -> Void)?
    var onStopListening: (() async -> Void)?
    var onInsertCaption: ((String) -> Void)?

    private var abandonCaptionSession = false
    private var sessionToken: UInt64 = 0
    private var stopToken: UInt64 = 0
    private var cancellables: Set<AnyCancellable> = []

    var shouldHandleTranslationStop: Bool {
        self.isSessionActive || self.abandonCaptionSession
    }

    private init() {
        self.subscriber.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                self?.refreshPresenter()
            }
            .store(in: &self.cancellables)
    }

    var overlayText: String {
        guard self.isSessionActive else { return self.subscriber.sourceDraft }
        let target = self.subscriber.translatedDraft
        if SettingsStore.shared.translationShowSource, !self.subscriber.sourceDraft.isEmpty {
            if target.isEmpty { return self.subscriber.sourceDraft }
            return "\(target)\n\(self.subscriber.sourceDraft)"
        }
        return target.isEmpty ? self.subscriber.sourceDraft : target
    }

    func beginSession(kind: TranslationListenKind) {
        self.sessionToken += 1
        self.abandonCaptionSession = false
        self.isSessionActive = true
        self.listenKind = kind
        PresenterCaptionController.shared.commitEdits()
        self.subscriber.beginListening()
        TranslationSessionHostController.install()
        let source = SpokenLanguageResolver.sourceLanguage()
        let target = SpokenLanguageResolver.targetLanguage()
        Task {
            await self.appleEngine.warm(source: source, target: target)
        }
        if kind == .captions {
            PresenterCaptionController.shared.setVisible(true)
        }
        if SettingsStore.shared.mlxRunnerEnabled {
            Task {
                await MLXRunnerService.shared.ensureRunning()
            }
        }
        self.refreshPresenter()
    }

    func handlePartial(_ text: String) {
        guard self.isSessionActive else { return }
        self.subscriber.handlePartial(text)
        if self.listenKind == .insert {
            NotchOverlayManager.shared.updateTranscriptionText(self.overlayText)
        }
    }

    func finishSession(finalSource: String) async -> String {
        let token = self.stopToken
        guard token == self.sessionToken else {
            if !self.isSessionActive {
                self.abandonCaptionSession = false
                self.listenKind = nil
            }
            return ""
        }
        if self.abandonCaptionSession {
            self.abandonCaptionSession = false
            self.isSessionActive = false
            self.listenKind = nil
            self.subscriber.reset()
            return ""
        }
        let kind = self.listenKind
        let translated = await self.subscriber.translateFinal(finalSource)
        guard token == self.sessionToken, !self.abandonCaptionSession else {
            if self.abandonCaptionSession {
                self.abandonCaptionSession = false
                self.isSessionActive = false
                self.listenKind = nil
                self.subscriber.reset()
            }
            return ""
        }
        self.isSessionActive = false
        self.listenKind = nil
        let text = kind == .insert
            ? self.subscriber.consumePendingInsertDocument()
            : translated
        self.refreshPresenter()
        return text
    }

    func cancelSession() {
        self.abandonCaptionSession = false
        self.isSessionActive = false
        self.listenKind = nil
        self.subscriber.endListening()
        self.refreshPresenter()
    }

    func theaterWasClosed() {
        if self.listenKind == .insert {
            PresenterCaptionController.shared.clearDisplay()
            return
        }
        if self.listenKind == .captions {
            self.abandonCaptionSession = true
            self.stopToken = self.sessionToken
            self.isSessionActive = false
            self.stopListening()
        }
        self.subscriber.reset()
        PresenterCaptionController.shared.clearDisplay()
    }

    func syncTheater() {
        self.refreshPresenter()
    }

    func swapDirection() {
        let settings = SettingsStore.shared
        let currentSource = SpokenLanguageResolver.sourceLanguage(settings: settings)
        let currentTarget = SpokenLanguageResolver.targetLanguage(settings: settings)
        SpokenLanguageResolver.setSourceLanguage(currentTarget, settings: settings)
        settings.translationTargetLanguageID = currentSource.id
        self.appleEngine.prepare(source: currentTarget, target: currentSource)
    }

    func applyEditedDocument(_ text: String) {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        self.subscriber.applyEditedLines(lines)
        self.refreshPresenter()
    }

    func startCaptionListening() {
        PresenterCaptionController.shared.commitEdits()
        PresenterCaptionController.shared.makeKeyForInteraction()
        SettingsStore.shared.playgroundUsed = true
        self.onStartCaptionListening?()
    }

    func stopListening() {
        self.stopToken = self.sessionToken
        Task { await self.onStopListening?() }
    }

    func insertCaptionText() {
        let text: String
        if PresenterCaptionController.shared.isEditing {
            text = PresenterCaptionController.shared.documentTextForDelivery()
            self.subscriber.markAllPosted()
        } else {
            text = self.subscriber.consumePendingInsertDocument()
        }
        guard !text.isEmpty else { return }
        self.onInsertCaption?(text)
    }

    func copyCaptionText() {
        let text = PresenterCaptionController.shared.documentTextForDelivery()
        guard !text.isEmpty else { return }
        ClipboardService.copyToClipboard(text)
    }

    func restoreTheaterIfNeeded() {
        TranslationSessionHostController.install()
        SettingsStore.shared.theaterWindowEnabled = false
        PresenterCaptionController.shared.orderOutIfClosed()
    }

    private func refreshPresenter() {
        guard SettingsStore.shared.theaterWindowEnabled else { return }
        let lastCommitted = self.subscriber.committedLines.last ?? ""
        let draft = self.subscriber.translatedDraft
        PresenterCaptionController.shared.update(
            source: self.subscriber.sourceDraft,
            draft: draft == lastCommitted ? "" : draft,
            committed: self.subscriber.committedLines,
            committedIDs: self.subscriber.committedLineIDs,
            committedSources: self.subscriber.committedSourceLines,
            pairLabel: SpokenLanguageResolver.pairLabel(),
            status: self.subscriber.statusText,
            isListening: self.isSessionActive
        )
    }
}
