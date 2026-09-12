//
//  ContentView+Types.swift
//  fluid
//
//  Dictation shortcut targets and AI processing errors.
//

import AppKit
import Foundation
import SwiftUI

// MARK: - AI Processing Errors

nonisolated enum AIProcessingError: LocalizedError {
    case noVerifiedProvider
    case missingAPIKey(provider: String)
    case missingModel(provider: String)
    case emptyResponse
    case dictationExceedsAIContextWindow

    var errorDescription: String? {
        switch self {
        case .noVerifiedProvider:
            return "No verified AI provider selected"
        case let .missingAPIKey(provider):
            return "API key not set for \(provider)"
        case let .missingModel(provider):
            return "No model selected for \(provider)"
        case .emptyResponse:
            return "AI returned an empty response"
        case .dictationExceedsAIContextWindow:
            return "Dictation exceeded the AI context window"
        }
    }

    /// Configuration errors the user can fix in AI Providers.
    var isConfigurationError: Bool {
        switch self {
        case .noVerifiedProvider, .missingAPIKey, .missingModel:
            return true
        case .emptyResponse, .dictationExceedsAIContextWindow:
            return false
        }
    }
}

nonisolated enum DictationAIFailurePresentationPolicy {
    static func shouldPresent(shouldPersistOutputs: Bool, fallbackReason: String?) -> Bool {
        shouldPersistOutputs && fallbackReason != nil
    }

    static func notificationMessage(for error: Error) -> String {
        if let aiError = error as? AIProcessingError, aiError.isConfigurationError {
            return "\(aiError.localizedDescription). Open AI Providers to configure a provider."
        }
        return error.localizedDescription
    }
}

nonisolated enum DictationStreamingFallbackPolicy {
    static func shouldRetryWithoutStreaming(after error: Error) -> Bool {
        if error is CancellationError || error is URLError {
            return false
        }
        guard let llmError = error as? LLMError else { return true }
        switch llmError {
        case .networkError, .timeout, .invalidURL, .encodingError, .invalidRequest:
            return false
        case .invalidResponse, .httpError:
            return true
        }
    }
}

final nonisolated class DictationAIStreamPreviewBuffer: @unchecked Sendable {
    typealias Publisher = @MainActor @Sendable (String) -> Void

    private let lock = NSLock()
    private let minimumUpdateInterval: TimeInterval
    private let publisher: Publisher
    private var bufferedText = ""
    private var lastPublishedText = ""
    private var nextEligibleUIUpdate: TimeInterval
    private var isUIUpdateScheduled = false

    init(
        minimumUpdateInterval: TimeInterval = 0.033,
        initialUpdateDelay: TimeInterval = 0.5,
        publisher: @escaping Publisher = { text in
            NotchOverlayManager.shared.updateTranscriptionText(text)
        }
    ) {
        self.minimumUpdateInterval = minimumUpdateInterval
        self.nextEligibleUIUpdate = ProcessInfo.processInfo.systemUptime + initialUpdateDelay
        self.publisher = publisher
    }

    func append(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        let shouldSchedule = self.lock.withLock {
            self.bufferedText += chunk
            guard !self.isUIUpdateScheduled,
                  ProcessInfo.processInfo.systemUptime >= self.nextEligibleUIUpdate
            else {
                return false
            }
            self.isUIUpdateScheduled = true
            return true
        }
        guard shouldSchedule else { return }

        Task { @MainActor [weak self] in
            self?.publishScheduledUpdate()
        }
    }

    @MainActor
    func flush() {
        guard let text = self.takeTextForPublishing(requiresScheduledUpdate: false) else { return }
        self.publisher(text)
    }

    @MainActor
    private func publishScheduledUpdate() {
        guard let text = self.takeTextForPublishing(requiresScheduledUpdate: true) else { return }
        self.publisher(text)
    }

    private func takeTextForPublishing(requiresScheduledUpdate: Bool) -> String? {
        self.lock.withLock {
            if requiresScheduledUpdate, !self.isUIUpdateScheduled {
                return nil
            }
            self.isUIUpdateScheduled = false
            self.nextEligibleUIUpdate = ProcessInfo.processInfo.systemUptime + self.minimumUpdateInterval
            guard self.bufferedText != self.lastPublishedText else { return nil }
            self.lastPublishedText = self.bufferedText
            return self.bufferedText
        }
    }
}

enum PrimaryDictationShortcutEdit: Hashable {
    case add
    case replace(Int)

    var replacementIndex: Int? {
        if case let .replace(index) = self { return index }
        return nil
    }
}

enum ShortcutRecordingTarget: Hashable {
    case primaryDictation(PrimaryDictationShortcutEdit)
    case secondaryDictation
    case cancel
    case pasteLast
    case translateInsert
    case captionListen
    case dictationPrompt(String)
    case newPrompt

    var title: String {
        switch self {
        case .primaryDictation:
            return "Primary Dictation Shortcut"
        case .secondaryDictation:
            return "Secondary Dictation Shortcut"
        case .cancel:
            return "Cancel Recording"
        case .pasteLast:
            return "Paste Last Transcription"
        case .translateInsert:
            return "Translate into App"
        case .captionListen:
            return "Theater Listen"
        case .dictationPrompt:
            return "Prompt Shortcut"
        case .newPrompt:
            return "New Prompt Shortcut"
        }
    }

    var enablesFeatureOnAssignment: Bool {
        switch self {
        case .secondaryDictation, .pasteLast, .translateInsert, .captionListen:
            return true
        case .primaryDictation, .cancel, .dictationPrompt, .newPrompt:
            return false
        }
    }

    var promptConfigurationKey: String? {
        if case let .dictationPrompt(key) = self { return key }
        return nil
    }

    var allowsMouseShortcut: Bool {
        switch self {
        case .primaryDictation, .pasteLast:
            return true
        case .secondaryDictation, .cancel, .translateInsert, .captionListen, .dictationPrompt, .newPrompt:
            return false
        }
    }

    var isPrimaryDictation: Bool {
        if case .primaryDictation = self { return true }
        return false
    }

    var primaryDictationReplacementIndex: Int? {
        if case let .primaryDictation(edit) = self {
            return edit.replacementIndex
        }
        return nil
    }
}
