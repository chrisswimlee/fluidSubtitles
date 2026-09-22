//
//  ContentView+Transcription.swift
//  fluid
//
//  Stop, process, and insert a finished dictation.
//

import AppKit
import AVFoundation
import Combine
import Foundation
import SwiftUI

extension ContentView {
    // MARK: - Stop and Process Transcription

    func processStoppedTranslation(
        transcribedText: String,
        route: DictationOutputRoute,
        pipelineID: String,
        pipelineStartedAt: TimeInterval,
        transcriptionDurationMilliseconds: Int?,
        audioFile: DictationAudioMetadata?,
        expectedOverlayLifecycleID: UInt64,
        stopOverlayDidRequestHide: Bool
    ) async {
        let kind = LiveTranslationController.shared.listenKind ?? .captions
        let translated = await LiveTranslationController.shared.finishSession(finalSource: transcribedText)
        self.asr.finalText = translated

        let shouldPersistOutputs = route == .normal && !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let appInfo = self.recordingAppInfo ?? self.getCurrentAppInfo()
        if shouldPersistOutputs, SettingsStore.shared.saveTranscriptionHistory {
            let historyEntryID = UUID()
            let historyTimestamp = Date()
            let pairs = LiveTranslationController.shared.subscriber.captionPairs
            TranscriptionHistoryStore.shared.addEntry(
                id: historyEntryID,
                timestamp: historyTimestamp,
                rawText: transcribedText,
                processedText: translated,
                appName: kind == .insert ? appInfo.name : "",
                windowTitle: kind == .insert ? appInfo.windowTitle : "",
                wasAIProcessed: false,
                processingModel: nil,
                transcriptionDurationMilliseconds: transcriptionDurationMilliseconds,
                aiProcessingDurationMilliseconds: nil,
                aiTokensPerSecond: nil,
                aiProcessingError: nil,
                captionPairs: pairs.isEmpty ? nil : pairs
            )
            self.persistDictationAudioIfNeeded(
                audioFile,
                entryID: historyEntryID,
                timestamp: historyTimestamp,
                model: self.currentTranscriptionModelInfo().model
            )
        }

        if shouldPersistOutputs, kind == .insert {
            let typingTarget = self.resolveTypingTargetPID()
            let targetBundleID = typingTarget.pid.flatMap {
                NSRunningApplication(processIdentifier: $0)?.bundleIdentifier
            }
            if TheaterInsertDelivery.shouldTypeCurrentListen(
                text: translated,
                targetBundleID: targetBundleID,
                selfBundleID: Bundle.main.bundleIdentifier
            ) {
                guard AXIsProcessTrusted() else {
                    LiveTranslationController.shared.onAccessibilityNeeded?()
                    return
                }
                if typingTarget.shouldRestoreOriginalFocus {
                    await self.restoreFocusToRecordingTarget()
                }
                self.asr.typeOutputPlanToActiveField(
                    .plain(translated),
                    preferredTargetPID: typingTarget.pid,
                    textReadyAt: ProcessInfo.processInfo.systemUptime,
                    tracksDictionaryCorrections: false,
                    preferPaste: InsertIMEGuard.shouldPreferPasteForTheaterCaption(),
                    completion: { _ in }
                )
                if SettingsStore.shared.copyTranscriptionToClipboard {
                    ClipboardService.copyToClipboard(translated)
                }
            } else if !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                LiveTranslationController.shared.reportListenStatus(
                    TheaterInsertDelivery.needsAnotherAppCopy,
                    kind: .warning
                )
            }
        }

        if !stopOverlayDidRequestHide {
            NotchOverlayManager.shared.updateTranscriptionText("")
            self.hideOverlayAfterOutput()
        }
        self.logPipelineCompletion(
            outcome: kind == .insert ? "translate_insert" : "translate_captions",
            pipelineID: pipelineID,
            pipelineStartedAt: pipelineStartedAt,
            textReadyAt: ProcessInfo.processInfo.systemUptime
        )
        _ = expectedOverlayLifecycleID
    }

    func processDictationPromptTest(_ transcribedText: String) async {
        let promptTest = DictationPromptTestCoordinator.shared
        promptTest.lastTranscriptionText = transcribedText
        promptTest.lastOutputText = ""
        promptTest.lastError = ""
        guard DictationAIPostProcessingGate.isProviderConfigured(
            providerID: promptTest.draftProviderID,
            model: promptTest.draftModel
        ) else {
            promptTest.lastError = "AI post-processing is not configured. Configure a provider/model (and API key for non-local endpoints) to test prompts."
            self.menuBarManager.setProcessing(false)
            return
        }
        promptTest.isProcessing = true
        defer {
            self.menuBarManager.setProcessing(false)
            promptTest.isProcessing = false
        }
        do {
            let result = try await self.processTextWithAI(
                transcribedText,
                overrideSystemPrompt: promptTest.draftPromptText,
                overrideProviderID: promptTest.draftProviderID,
                overrideModel: promptTest.draftModel
            )
            let appInfo = self.recordingAppInfo ?? self.getCurrentAppInfo()
            let literalFormattedResult = ASRService.applyDictationLiteralFormatting(
                result,
                appName: appInfo.name,
                bundleID: appInfo.bundleId,
                windowTitle: appInfo.windowTitle
            )
            promptTest.lastOutputText = ASRService.applyGAAVFormatting(literalFormattedResult)
        } catch {
            DebugLogger.shared.error("Prompt test AI call failed: \(error.localizedDescription)", source: "ContentView")
            promptTest.lastError = error.localizedDescription
        }
    }

    func makeAIProcessingFeedback(
        lifecycleID: UInt64
    ) -> (statusTask: Task<Void, Never>, streamPreview: DictationAIStreamPreviewBuffer) {
        // Fast local cleanup should finish before transient SwiftUI work can queue
        // ahead of its result. Slow providers still receive visible status feedback.
        let statusTask = scheduleDeferredMainActorOperation(
            afterNanoseconds: Self.aiProcessingStatusDelayNanoseconds
        ) {
            guard self.overlayLifecycleID == lifecycleID else {
                self.appBench("processing_ui_skipped status=Refining reason=stale_lifecycle")
                return
            }
            self.menuBarManager.flushDeferredStoppedRecordingState()
            self.menuBarManager.setProcessing(true)
            self.appBench("processing_ui_request status=Refining trigger=delayed_status")
            NotchOverlayManager.shared.updateTranscriptionText("Refining")
            self.appBench("processing_ui_requested status=Refining trigger=delayed_status")
        }
        let streamPreview = DictationAIStreamPreviewBuffer { text in
            guard self.overlayLifecycleID == lifecycleID else { return }
            NotchOverlayManager.shared.updateTranscriptionText(text)
        }
        return (statusTask, streamPreview)
    }

    func prepareOverlayForASRStop(
        shouldHideOverlayOnStop: Bool
    ) -> (didRequestHide: Bool, onFinalTranscriptionStarted: (@MainActor () -> Void)?) {
        if shouldHideOverlayOnStop {
            DebugLogger.shared.debug("Hiding dictation overlay at stop path", source: "ContentView")
            self.hideOverlayAsync(reason: "stop_path")
            return (true, nil)
        }

        guard self.asr.isFinalTranscriptionReady else {
            DebugLogger.shared.debug("Showing transcription processing state", source: "ContentView")
            self.appBench("processing_ui_request status=Transcribing")
            self.menuBarManager.setProcessing(true)
            NotchOverlayManager.shared.updateTranscriptionText("Transcribing")
            self.appBench("processing_ui_requested status=Transcribing")
            return (false, nil)
        }

        // Own the overlay before isRunning changes, but publish processing UI
        // only after final ASR has entered its executor.
        self.menuBarManager.reserveProcessingOverlay()
        self.appBench("processing_ui_reserved trigger=warm_final_asr")
        let onFinalTranscriptionStarted: @MainActor () -> Void = {
            self.menuBarManager.flushDeferredStoppedRecordingState()
            self.appBench("processing_ui_request status=Transcribing trigger=final_executor")
            self.menuBarManager.setProcessing(true)
            NotchOverlayManager.shared.updateTranscriptionText("Transcribing")
            self.appBench("processing_ui_requested status=Transcribing trigger=final_executor")
        }
        return (false, onFinalTranscriptionStarted)
    }

    func holdStopUIInvalidation(whileProcessing: Bool) -> UInt64? {
        whileProcessing ? self.asr.holdStopUIInvalidationForOutputPipeline() : nil
    }

    func releaseStopUIInvalidation(_ generation: UInt64?) {
        guard let generation else { return }
        self.asr.releaseStopUIInvalidationForOutputPipeline(generation)
    }

    func hideOverlayForDispatchedPaste(shouldHide: Bool, lifecycleID: UInt64) {
        guard shouldHide, self.overlayLifecycleID == lifecycleID else { return }
        self.appBench("overlay_hide_request reason=paste_dispatched")
        self.menuBarManager.beginProcessingCompletionAndHideOverlay()
    }

    func handleTypingDelivery(
        _ outcome: TypingService.DeliveryOutcome,
        pipelineID: String,
        pipelineStartedAt: TimeInterval,
        textReadyAt: TimeInterval,
        shouldHideOverlay: Bool,
        expectedOverlayLifecycleID: UInt64
    ) {
        self.logPipelineCompletion(
            outcome: String(describing: outcome),
            pipelineID: pipelineID,
            pipelineStartedAt: pipelineStartedAt,
            textReadyAt: textReadyAt
        )
        guard shouldHideOverlay else { return }
        guard self.overlayLifecycleID == expectedOverlayLifecycleID else {
            self.appBench(
                "overlay_hide_skipped reason=delivery_complete staleLifecycle=\(expectedOverlayLifecycleID) currentLifecycle=\(self.overlayLifecycleID)"
            )
            return
        }
        // Preserve delivery-timed dismissal for the send-suppressed status path.
        // Ordinary dictation already hid in the dispatch turn and returns above.
        self.appBench("overlay_hide_request reason=delivery_complete outcome=\(outcome)")
        self.menuBarManager.beginProcessingCompletionAndHideOverlay()
    }

    func logPipelineCompletion(
        outcome: String,
        pipelineID: String,
        pipelineStartedAt: TimeInterval,
        textReadyAt: TimeInterval
    ) {
        let finishedAt = ProcessInfo.processInfo.systemUptime
        DebugLogger.shared.info(
            "PIPELINE_SUMMARY id=\(pipelineID) t=\(finishedAt) " +
                "stopToReadyMs=\((textReadyAt - pipelineStartedAt) * 1000) readyToDeliveryMs=\((finishedAt - textReadyAt) * 1000) " +
                "totalMs=\((finishedAt - pipelineStartedAt) * 1000) outcome=\(outcome)",
            source: "AppBenchmark"
        )
    }

    func recordCompletedDictationPerformance(
        route: DictationOutputRoute,
        pipelineStartedAt: TimeInterval,
        readyAt: TimeInterval = ProcessInfo.processInfo.systemUptime,
        transcriptionDurationMilliseconds: Int?,
        aiProcessingDurationMilliseconds: Int?,
        fluidIntelligenceDurationMilliseconds _: Int?,
        outcome: String
    ) {
        guard route == .normal else { return }
        let readyMilliseconds = Int(((readyAt - pipelineStartedAt) * 1000).rounded())
        DebugLogger.shared.info(
            "dictation asrMs=\(transcriptionDurationMilliseconds.map(String.init) ?? "-") aiMs=\(aiProcessingDurationMilliseconds.map(String.init) ?? "-") readyMs=\(readyMilliseconds) outcome=\(outcome)",
            source: "AppBenchmark"
        )
    }

    func recordEmptyDictationPerformance(startedAt: TimeInterval, asrMs: Int?) {
        self.recordCompletedDictationPerformance(
            route: .normal,
            pipelineStartedAt: startedAt,
            transcriptionDurationMilliseconds: asrMs,
            aiProcessingDurationMilliseconds: nil,
            fluidIntelligenceDurationMilliseconds: nil,
            outcome: self.asr.lastStopOutcome == .failed ? "asr_failed" : "empty"
        )
    }

    func hideOverlayAfterOutput() {
        self.hideOverlayAsync(reason: "after_output")
    }

    func updateSpokenSendIndicatorForFinalParse(shouldSend: Bool) {
        if shouldSend, NotchContentState.shared.spokenSendIndicatorState == .sending {
            return
        }
        NotchContentState.shared.setSpokenSendIndicatorState(shouldSend ? .detected : .hidden)
    }

    func advanceOverlayLifecycle() {
        self.spokenSendAutoStopTask?.cancel()
        self.spokenSendAutoStopTask = nil
        self.stopSpokenSendVoiceActivityMonitoring()
        self.spokenSendAutoStopTriggered = false
        self.spokenSendCountdownStartedAt = nil
        self.spokenSendLastVoiceActivityAt = ProcessInfo.processInfo.systemUptime
        self.overlayLifecycleID &+= 1
        NotchContentState.shared.clearAIProcessingFailure()
    }

    func handleSpokenSendPartialTranscription(_ text: String) {
        _ = text
    }

    func startSpokenSendVoiceActivityMonitoring() {
        guard self.spokenSendVoiceActivityCancellable == nil else { return }
        self.spokenSendVoiceActivityCancellable = self.asr.audioLevelPublisher
            .receive(on: RunLoop.main)
            .sink { level in
                self.handleSpokenSendAudioLevel(level)
            }
    }

    func stopSpokenSendVoiceActivityMonitoring() {
        self.spokenSendVoiceActivityCancellable?.cancel()
        self.spokenSendVoiceActivityCancellable = nil
    }

    func hideOverlayAsync(reason: String) {
        let expectedOverlayLifecycleID = self.overlayLifecycleID
        self.appBench("overlay_hide_request reason=\(reason) lifecycle=\(expectedOverlayLifecycleID)")
        Task { @MainActor in
            guard self.overlayLifecycleID == expectedOverlayLifecycleID else {
                self.appBench(
                    "overlay_hide_skipped reason=\(reason) staleLifecycle=\(expectedOverlayLifecycleID) currentLifecycle=\(self.overlayLifecycleID)"
                )
                return
            }

            let overlayHideStartedAt = ProcessInfo.processInfo.systemUptime
            await self.menuBarManager.finishProcessingAndHideOverlay()
            self.appBench(
                "overlay_hidden reason=\(reason) elapsedMs=\(Int(((ProcessInfo.processInfo.systemUptime - overlayHideStartedAt) * 1000).rounded()))"
            )
        }
    }

    func persistDictationAudioIfNeeded(
        _ audio: DictationAudioMetadata?,
        entryID: UUID,
        timestamp _: Date,
        model _: String
    ) {
        guard let audio else { return }
        guard SettingsStore.shared.saveTranscriptionHistory,
              SettingsStore.shared.saveAudioWithTranscriptionHistory
        else {
            DictationAudioHistoryStore.shared.deleteAudio(fileName: audio.fileName)
            return
        }
        let saveGeneration = TranscriptionHistoryStore.shared.audioSaveGeneration
        TranscriptionHistoryStore.shared.attachAudio(
            audio,
            to: entryID,
            expectedSaveGeneration: saveGeneration
        )
        DictationAudioHistoryStore.shared.completePendingSave(fileName: audio.fileName)
    }

    var isOnboardingVoicePlaygroundStepActive: Bool {
        let onboardingPlaygroundStep = 4
        return !self.settings.onboardingCompleted &&
            self.settings.onboardingCurrentStep == onboardingPlaygroundStep
    }

    var isOnboardingSandboxRouteActive: Bool {
        self.isOnboardingVoicePlaygroundStepActive
    }

    func currentDictationOutputRouteForHotkeyStop() -> DictationOutputRoute {
        return .normal
    }

    func handleSpokenSendAudioLevel(_ level: CGFloat) {
        _ = level
    }

    func reprocessLastDictation() {}

    func copyLastDictationFromHistory() {}

    func pasteLastDictationFromHistory() {}

    func undoLastAIProcessingFromHistory() {}

    func applyHistoryTextOutput(_ text: String, saveToHistory: Bool) async {
        // Keep hotkey/recording state deterministic before applying output text.
        if self.asr.isRunning {
            DebugLogger.shared.info("Actions: stopping active recording before history action output", source: "ContentView")
            await self.asr.stopWithoutTranscription()
            self.cancelPrewarmDictationIfNeeded()
        }

        let appInfo = self.getCurrentAppInfo()
        let literalFormattedText = ASRService.applyDictationLiteralFormatting(
            text,
            appName: appInfo.name,
            bundleID: appInfo.bundleId,
            windowTitle: appInfo.windowTitle
        )
        let gaavText = ASRService.applyGAAVFormatting(literalFormattedText)
        let precedingText = SettingsStore.shared.needsDictationFormattingContext
            ? TypingService.textBeforeCursorInFocusedField()
            : ""
        var finalText = ASRService.applyContinuousDictationFormatting(gaavText, precedingText: precedingText)
        finalText = ASRService.applyTerminalLiteralAutocompleteSpacing(
            finalText,
            appName: appInfo.name,
            bundleID: appInfo.bundleId,
            windowTitle: appInfo.windowTitle
        )
        let outputPlan = ASRService.makeDictationLiteralOutputPlan(
            for: finalText,
            appName: appInfo.name,
            bundleID: appInfo.bundleId,
            windowTitle: appInfo.windowTitle
        )

        if saveToHistory, SettingsStore.shared.saveTranscriptionHistory {
            TranscriptionHistoryStore.shared.addEntry(
                rawText: text,
                processedText: finalText,
                appName: appInfo.name,
                windowTitle: appInfo.windowTitle,
                wasAIProcessed: false
            )
        }

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let isFluidFrontmost = frontmostApp?.bundleIdentifier == Bundle.main.bundleIdentifier

        if SettingsStore.shared.copyTranscriptionToClipboard, !isFluidFrontmost {
            ClipboardService.copyToClipboard(finalText)
        }

        let focusedPID = TypingService.captureSystemFocusedPID()
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        NotchContentState.shared.recordingTargetPID = focusedPID

        let shouldTypeExternally = !isFluidFrontmost
        if shouldTypeExternally {
            let typingTarget = self.resolveTypingTargetPID()
            if typingTarget.shouldRestoreOriginalFocus {
                await self.restoreFocusToRecordingTarget()
            }
            self.asr.typeOutputPlanToActiveField(
                outputPlan,
                preferredTargetPID: typingTarget.pid
            )
        }
    }

    func reprocessDictationText(_ transcribedText: String) async {
        // If live recording is still active, stop it first so reprocess does not
        // leave ASR running in the background (which causes the next hotkey press
        // to behave like a stop instead of start).
        if self.asr.isRunning {
            DebugLogger.shared.info("Actions: stopping active recording before reprocess", source: "ContentView")
            await self.asr.stopWithoutTranscription()
            self.cancelPrewarmDictationIfNeeded()
        }

        self.menuBarManager.setProcessing(true)
        NotchOverlayManager.shared.updateTranscriptionText("Reprocessing...")

        var aiFallbackReason: String?
        var postProcessingModel: String?
        var aiProcessingDurationMilliseconds: Int?
        var aiTokensPerSecond: Double?
        var aiFallbackNotificationError: String?
        let appInfo = self.getCurrentAppInfo()
        let normalizedTranscribedText = ASRService.applySpokenPunctuationFormatting(
            transcribedText,
            appName: appInfo.name,
            bundleID: appInfo.bundleId,
            windowTitle: appInfo.windowTitle
        )
        var finalText = normalizedTranscribedText
        let shouldUseAI = DictationAIPostProcessingGate.isConfigured(for: .primary, appBundleID: appInfo.bundleId)
        if shouldUseAI {
            postProcessingModel = self.currentDictationAIModelInfo(
                dictationSlot: .primary,
                appBundleID: appInfo.bundleId
            ).model
            let postProcessingStart = ProcessInfo.processInfo.systemUptime
            do {
                let result = try await self.processTextWithAIMetrics(
                    normalizedTranscribedText,
                    dictationSlot: .primary
                )
                finalText = result.text
                aiTokensPerSecond = result.tokensPerSecond
            } catch {
                DebugLogger.shared.error(
                    "AI reprocess failed, falling back to raw transcription: \(error.localizedDescription)",
                    source: "ContentView"
                )
                aiFallbackReason = error.localizedDescription
                aiFallbackNotificationError = DictationAIFailurePresentationPolicy.notificationMessage(for: error)
                finalText = normalizedTranscribedText
            }
            aiProcessingDurationMilliseconds = Int(
                ((ProcessInfo.processInfo.systemUptime - postProcessingStart) * 1000).rounded()
            )
        }

        finalText = ASRService.applyDictationLiteralFormatting(
            finalText,
            appName: appInfo.name,
            bundleID: appInfo.bundleId,
            windowTitle: appInfo.windowTitle
        )
        finalText = ASRService.applyGAAVFormatting(finalText)
        let precedingText = SettingsStore.shared.needsDictationFormattingContext
            ? TypingService.textBeforeCursorInFocusedField()
            : ""
        finalText = ASRService.applyContinuousDictationFormatting(finalText, precedingText: precedingText)
        finalText = ASRService.applyTerminalLiteralAutocompleteSpacing(
            finalText,
            appName: appInfo.name,
            bundleID: appInfo.bundleId,
            windowTitle: appInfo.windowTitle
        )
        self.recordingPrecedingText = ""
        let outputPlan = ASRService.makeDictationLiteralOutputPlan(
            for: finalText,
            appName: appInfo.name,
            bundleID: appInfo.bundleId,
            windowTitle: appInfo.windowTitle
        )

        if SettingsStore.shared.saveTranscriptionHistory {
            TranscriptionHistoryStore.shared.addEntry(
                rawText: transcribedText,
                processedText: finalText,
                appName: appInfo.name,
                windowTitle: appInfo.windowTitle,
                wasAIProcessed: postProcessingModel != nil && aiFallbackReason == nil,
                processingModel: postProcessingModel,
                aiProcessingDurationMilliseconds: aiProcessingDurationMilliseconds,
                aiTokensPerSecond: aiTokensPerSecond,
                aiProcessingError: aiFallbackReason
            )
        }
        let shouldShowAIProcessingFailure = DictationAIFailurePresentationPolicy.shouldPresent(
            shouldPersistOutputs: true,
            fallbackReason: aiFallbackReason
        )
        if !shouldShowAIProcessingFailure {
            self.pendingAIReprocessText = nil
        }

        if SettingsStore.shared.copyTranscriptionToClipboard {
            ClipboardService.copyToClipboard(finalText)
        }

        let focusedPID = TypingService.captureSystemFocusedPID()
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        NotchContentState.shared.recordingTargetPID = focusedPID

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let isFluidFrontmost = frontmostApp?.bundleIdentifier?.contains("fluid") == true
        let shouldTypeExternally = !isFluidFrontmost || self.isTranscriptionFocused == false
        if shouldTypeExternally {
            let typingTarget = self.resolveTypingTargetPID()
            if typingTarget.shouldRestoreOriginalFocus {
                await self.restoreFocusToRecordingTarget()
            }
            self.asr.typeOutputPlanToActiveField(
                outputPlan,
                preferredTargetPID: typingTarget.pid
            )
        }

        NotchOverlayManager.shared.updateTranscriptionText("")
        if shouldShowAIProcessingFailure {
            self.pendingAIReprocessText = transcribedText
            NotchContentState.shared.showAIProcessingFailure()
            self.menuBarManager.finishProcessingKeepingOverlayVisible()
            if let aiFallbackNotificationError {
                NotificationService.showAIProcessingFallback(error: aiFallbackNotificationError)
            }
        } else {
            self.hideOverlayAfterOutput()
        }

    }

    /// Cancel an in-flight prewarm. Called on abort / new recording start — NOT on
    /// a normal stop, because AI post-processing runs after stop and benefits from
    /// the warm prefix cache the prewarm prime.
    func cancelPrewarmDictationIfNeeded() {
        self.prewarmDictationTask?.cancel()
        self.prewarmDictationTask = nil
    }

    func handleLivePromptModeSwitch(_ mode: SettingsStore.PromptMode) {
        _ = mode
    }

    func handleLiveOverlayModeSwitch(_ mode: OverlayMode) {
        guard !NotchContentState.shared.isProcessing else { return }
        switch mode {
        case .dictation:
            self.handleLivePromptModeSwitch(.dictate)
        }
    }

    func insertCaptionIntoFrontmostApp(_ text: String) {
        let preferredPID = PresenterCaptionController.shared.preferredInsertTargetPID()
        if let preferredPID {
            TypingService.activateApp(pid: preferredPID)
        }
        self.asr.typeOutputPlanToActiveField(
            .plain(text),
            preferredTargetPID: preferredPID,
            textReadyAt: ProcessInfo.processInfo.systemUptime,
            tracksDictionaryCorrections: false,
            preferPaste: InsertIMEGuard.shouldPreferPasteForTheaterCaption(),
            completion: nil
        )
    }

    /// Best-effort: re-activate the app that was focused when recording started.
    /// Skips the AX restore work when the captured text element is already focused.
    func restoreFocusToRecordingTarget() async {
        guard let pid = NotchContentState.shared.recordingTargetPID else { return }
        let startedAt = ProcessInfo.processInfo.systemUptime
        self.appBench("focus_restore_start targetPID=\(pid)")
        if let focusTarget = self.recordingFocusTarget, focusTarget.pid == pid {
            if TypingService.isExactFocusTargetActive(focusTarget) {
                self.appBench("focus_restore_result activated=false element=true elapsedMs=0 reason=already_focused")
                return
            }
            let activated = TypingService.activateApp(pid: pid)
            let focusedElementRestored = TypingService.restoreFocusTarget(focusTarget)
            self.appBench(
                "focus_restore_result activated=\(activated) element=\(focusedElementRestored) elapsedMs=\(Int(((ProcessInfo.processInfo.systemUptime - startedAt) * 1000).rounded()))"
            )
            return
        }
        if TypingService.isCapturedFocusStillActive(for: pid) {
            self.appBench("focus_restore_result activated=false element=true elapsedMs=0 reason=already_focused")
            DebugLogger.shared.debug(
                "Restore focus skipped; captured element still focused, targetPID: \(pid)",
                source: "ContentView"
            )
            self.appBench("focus_restore_settle_done delayMs=0")
            return
        }
        let activated = TypingService.activateApp(pid: pid)
        let focusedElementRestored = TypingService.restoreCapturedFocus(in: pid)
        self.appBench(
            "focus_restore_result activated=\(activated) element=\(focusedElementRestored) elapsedMs=\(Int(((ProcessInfo.processInfo.systemUptime - startedAt) * 1000).rounded()))"
        )
        DebugLogger.shared.debug(
            "Restore focus -> appActivated: \(activated), elementFocusRestored: \(focusedElementRestored), targetPID: \(pid)",
            source: "ContentView"
        )
        self.appBench("focus_restore_settle_done delayMs=0")
    }
}
