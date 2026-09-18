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
                appName: appInfo.name,
                windowTitle: appInfo.windowTitle,
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

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let isFluidFrontmost = frontmostApp?.bundleIdentifier == Bundle.main.bundleIdentifier
        let shouldType = shouldPersistOutputs && kind == .insert && !isFluidFrontmost && !translated.isEmpty
        if shouldType {
            let typingTarget = self.resolveTypingTargetPID()
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

    func stopAndProcessTranscription(route: DictationOutputRoute = .normal) async {
        let pipelineID = UUID().uuidString
        await DebugLogger.$pipelineID.withValue(pipelineID) {
            await self.processStoppedTranscription(route: route, pipelineID: pipelineID)
        }
    }

    func processStoppedTranscription(route: DictationOutputRoute, pipelineID: String) async {
        let pipelineStartedAt = ProcessInfo.processInfo.systemUptime
        let expectedOverlayLifecycleID = self.overlayLifecycleID
        self.appBench("pipeline_begin id=\(pipelineID) route=\(route.rawValue)")
        defer {
            self.appBench("pipeline_handler_return id=\(pipelineID) elapsedMs=\((ProcessInfo.processInfo.systemUptime - pipelineStartedAt) * 1000) deliveryMayBePending=true")
        }
        DebugLogger.shared.info("Output route selected: \(route.rawValue)", source: "ContentView")
        self.appBench("stop_path_enter route=\(route.rawValue)")

        let modeAtStop = self.activeRecordingMode
        let activeDictationSlot = self.currentDictationShortcutSlot(for: modeAtStop)
        let promptOverride = self.promptModeOverrideText
        let promptTest = DictationPromptTestCoordinator.shared
        let shouldUseAIOnStop = activeDictationSlot.map {
            DictationAIPostProcessingGate.isConfigured(for: $0, appBundleID: self.recordingAppInfo?.bundleId)
        } ?? DictationAIPostProcessingGate.isConfigured(for: .primary, appBundleID: self.recordingAppInfo?.bundleId)
        let shouldHideOverlayOnStop = route == .normal &&
            !promptTest.isActive &&
            !shouldUseAIOnStop &&
            !self.settings.spokenSendEnabled
        DebugLogger.shared.info(
            "Routing decision snapshot | activeMode=\(modeAtStop.rawValue) | overlay=\(NotchContentState.shared.mode.rawValue)",
            source: "ContentView"
        )

        self.clearActiveRecordingMode()
        let stopOverlay = self.prepareOverlayForASRStop(shouldHideOverlayOnStop: shouldHideOverlayOnStop)
        let stopUIInvalidationHold = self.holdStopUIInvalidation(whileProcessing: !stopOverlay.didRequestHide)
        defer { self.releaseStopUIInvalidation(stopUIInvalidationHold) }

        // Stop the ASR service and wait for transcription to complete
        // The processing indicator will stay visible during this phase
        let asrStopStartedAt = ProcessInfo.processInfo.systemUptime
        self.appBench("asr_stop_call")
        // Play the stop cue as soon as the audio engine has stopped, before the
        // (potentially slow) final transcription pass. Scoped to dictation only —
        // Command/Edit modes call asr.stop() without this callback.
        let transcribedText = await asr.stop(
            onCaptureStopped: {
                TranscriptionSoundPlayer.shared.playStopSound()
            },
            onFinalTranscriptionStarted: stopOverlay.onFinalTranscriptionStarted
        )
        self.appBench("asr_stop_return elapsedMs=\(Int(((ProcessInfo.processInfo.systemUptime - asrStopStartedAt) * 1000).rounded()))")
        let audioFile = self.asr.consumeLastCompletedAudioFile()
        let transcriptionDurationMilliseconds = self.asr.consumeLastFinalTranscriptionDurationMs()
        DebugLogger.shared.info(
            "Stop transcription result | chars=\(transcribedText.count) | empty=\(transcribedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)",
            source: "ContentView"
        )

        guard transcribedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            // Empty results have no delivery callback, so clear their stale
            // preview before the existing empty-result dismissal path runs.
            NotchOverlayManager.shared.updateTranscriptionText("")
            LiveTranslationController.shared.cancelSession()
            DebugLogger.shared.debug("Transcription returned empty text", source: "ContentView")
            if route == .normal, !promptTest.isActive {
                self.recordEmptyDictationPerformance(startedAt: pipelineStartedAt, asrMs: transcriptionDurationMilliseconds)
            }
            // Finish the same short exit transition even when no text is emitted.
            if !stopOverlay.didRequestHide {
                await self.menuBarManager.finishProcessingAndHideOverlay()
            }
            return
        }

        // Prompt Test Mode: reroute dictation hotkey output into the prompt editor (no typing/clipboard/history).
        if promptTest.isActive {
            LiveTranslationController.shared.cancelSession()
            await self.processDictationPromptTest(transcribedText)
            return
        }

        if NotchOverlayManager.shared.isBottomOverlayVisible {
            BottomOverlayWindowController.shared.beginReleaseTransition()
        }

        if LiveTranslationController.shared.shouldHandleTranslationStop {
            await self.processStoppedTranslation(
                transcribedText: transcribedText,
                route: route,
                pipelineID: pipelineID,
                pipelineStartedAt: pipelineStartedAt,
                transcriptionDurationMilliseconds: transcriptionDurationMilliseconds,
                audioFile: audioFile,
                expectedOverlayLifecycleID: expectedOverlayLifecycleID,
                stopOverlayDidRequestHide: stopOverlay.didRequestHide
            )
            return
        }

        var finalText: String
        var aiFallbackReason: String?
        var postProcessingModel: String?
        var aiProcessingDurationMilliseconds: Int?
        var fluidIntelligenceDurationMilliseconds: Int?
        var aiTokensPerSecond: Double?
        var aiFallbackNotificationError: String?
        let appInfo = self.recordingAppInfo ?? self.getCurrentAppInfo()
        let punctuationFormattedText = ASRService.applySpokenPunctuationFormatting(
            transcribedText,
            appName: appInfo.name,
            bundleID: appInfo.bundleId,
            windowTitle: appInfo.windowTitle
        )
        let spokenSendParse = SpokenSendParser.parse(
            punctuationFormattedText,
            phrase: self.settings.spokenSendPhrase,
            enabled: route == .normal && self.settings.spokenSendEnabled
        )
        self.updateSpokenSendIndicatorForFinalParse(shouldSend: spokenSendParse.shouldSend)
        let normalizedTranscribedText = spokenSendParse.text
        let sendsExistingDraft = spokenSendParse.shouldSend &&
            normalizedTranscribedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let shouldUseAI = !sendsExistingDraft && (activeDictationSlot.map {
            DictationAIPostProcessingGate.isConfigured(for: $0, appBundleID: appInfo.bundleId)
        } ?? DictationAIPostProcessingGate.isConfigured(for: .primary, appBundleID: appInfo.bundleId))
        let transcriptionModelInfo = self.currentTranscriptionModelInfo()
        let postProcessingModelInfo = self.currentDictationAIModelInfo(
            dictationSlot: activeDictationSlot,
            appBundleID: appInfo.bundleId
        )

        if shouldUseAI {
            DebugLogger.shared.debug("Routing transcription through AI post-processing", source: "ContentView")
            postProcessingModel = postProcessingModelInfo.model
            let postProcessingInputChars = normalizedTranscribedText.count
            let postProcessingStart = ProcessInfo.processInfo.systemUptime
            let processingFeedback = self.makeAIProcessingFeedback(lifecycleID: expectedOverlayLifecycleID)
            let refiningStatusTask = processingFeedback.statusTask
            defer { refiningStatusTask.cancel() }

            let streamPreview = processingFeedback.streamPreview
            let streamHandler: PrivateAIStreamHandler = { chunk in
                streamPreview.append(chunk)
            }

            do {
                self.logAIProcessCall(pipelineID, postProcessingModelInfo, postProcessingInputChars)
                let result = try await self.processTextWithAIMetrics(
                    normalizedTranscribedText,
                    overrideSystemPrompt: promptOverride,
                    dictationSlot: activeDictationSlot,
                    streamHandler: streamHandler,
                    benchmarkID: pipelineID
                )
                refiningStatusTask.cancel()
                finalText = result.text
                self.appBench("ai_process_return id=\(pipelineID)")
                aiTokensPerSecond = result.tokensPerSecond
                fluidIntelligenceDurationMilliseconds = result.fluidIntelligenceLatencyMilliseconds
                streamPreview.flush()
                self.appBench("ai_preview_flushed id=\(pipelineID)")
            } catch {
                refiningStatusTask.cancel()
                self.appBench("ai_process_fail id=\(pipelineID)")
                // Fall back to the raw transcription so the user still gets
                // their words typed instead of an error string.
                DebugLogger.shared.error(
                    "AI post-processing failed, falling back to raw transcription: \(error.localizedDescription)",
                    source: "ContentView"
                )
                aiFallbackReason = error.localizedDescription
                aiFallbackNotificationError = DictationAIFailurePresentationPolicy.notificationMessage(for: error)
                finalText = normalizedTranscribedText
            }
            let postProcessingLatencyMs = Int(
                ((ProcessInfo.processInfo.systemUptime - postProcessingStart) * 1000).rounded()
            )
            aiProcessingDurationMilliseconds = postProcessingLatencyMs
            let postProcessingProviderName = postProcessingModelInfo.provider ?? "unknown"
            let postProcessingModelName = postProcessingModelInfo.model ?? "unknown"
            DebugLogger.shared.info(
                "Dictation AI post-processing finished in \(postProcessingLatencyMs)ms "
                    + "provider=\(postProcessingProviderName) model=\(postProcessingModelName) "
                    + "inputChars=\(postProcessingInputChars) fallback=\(aiFallbackReason != nil)",
                source: "ContentView"
            )
        } else {
            finalText = normalizedTranscribedText
        }

        // Normalize literal command and mention syntax after AI cleanup and before final user preferences.
        finalText = ASRService.applyDictationLiteralFormatting(
            finalText,
            appName: appInfo.name,
            bundleID: appInfo.bundleId,
            windowTitle: appInfo.windowTitle
        )
        // Apply GAAV formatting as the FINAL step (after AI post-processing)
        // This ensures the user's preference for no capitalization/period is respected
        finalText = ASRService.applyGAAVFormatting(finalText)
        // Apply Continuous Dictation Mode after GAAV so smart caps use the field
        // context captured at recording start, and the trailing space enables chaining.
        finalText = ASRService.applyContinuousDictationFormatting(finalText, precedingText: self.recordingPrecedingText)
        finalText = ASRService.applyTerminalLiteralAutocompleteSpacing(
            finalText,
            appName: appInfo.name,
            bundleID: appInfo.bundleId,
            windowTitle: appInfo.windowTitle
        )
        self.recordingPrecedingText = ""
        self.asr.finalText = finalText
        if route == .onboardingSandbox,
           self.isOnboardingVoicePlaygroundStepActive,
           !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            self.settings.onboardingPlaygroundValidated = true
            self.settings.playgroundUsed = true
            self.playgroundUsed = true
        }

        DebugLogger.shared.info("Transcription finalized (chars: \(finalText.count))", source: "ContentView")
        let finalTextReadyAt = ProcessInfo.processInfo.systemUptime
        self.recordCompletedDictationPerformance(
            route: route,
            pipelineStartedAt: pipelineStartedAt,
            readyAt: finalTextReadyAt,
            transcriptionDurationMilliseconds: transcriptionDurationMilliseconds,
            aiProcessingDurationMilliseconds: aiProcessingDurationMilliseconds,
            fluidIntelligenceDurationMilliseconds: fluidIntelligenceDurationMilliseconds,
            outcome: aiFallbackReason == nil ? "success" : "ai_fallback"
        )
        let finalOutputPlan = ASRService.makeDictationLiteralOutputPlan(
            for: finalText,
            appName: appInfo.name,
            bundleID: appInfo.bundleId,
            windowTitle: appInfo.windowTitle
        )
        self.appBench("transcription_finalized chars=\(finalText.count)")
        self.appBench("text_ready chars=\(finalText.count)")
        self.appBench("pipeline_text_ready id=\(pipelineID) stopToReadyMs=\((finalTextReadyAt - pipelineStartedAt) * 1000)")

        let shouldPersistOutputs = route == .normal
        if !shouldPersistOutputs {
            DebugLogger.shared.info(
                "Sandbox route active: suppressing clipboard/history/external typing side effects",
                source: "ContentView"
            )
        }

        let shouldShowAIProcessingFailure = DictationAIFailurePresentationPolicy.shouldPresent(
            shouldPersistOutputs: shouldPersistOutputs,
            fallbackReason: aiFallbackReason
        )
        if !shouldShowAIProcessingFailure {
            self.pendingAIReprocessText = nil
        }

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let frontmostName = frontmostApp?.localizedName ?? "Unknown"
        let isFluidFrontmost = frontmostApp?.bundleIdentifier == Bundle.main.bundleIdentifier

        // Save to transcription history (transcription mode only, if enabled)
        if shouldPersistOutputs, !sendsExistingDraft, SettingsStore.shared.saveTranscriptionHistory {
            let historyEntryID = UUID()
            let historyTimestamp = Date()
            TranscriptionHistoryStore.shared.addEntry(
                id: historyEntryID,
                timestamp: historyTimestamp,
                rawText: spokenSendParse.shouldSend ? normalizedTranscribedText : transcribedText,
                processedText: finalText,
                appName: appInfo.name,
                windowTitle: appInfo.windowTitle,
                wasAIProcessed: postProcessingModel != nil && aiFallbackReason == nil,
                processingModel: postProcessingModel,
                transcriptionDurationMilliseconds: transcriptionDurationMilliseconds,
                aiProcessingDurationMilliseconds: aiProcessingDurationMilliseconds,
                aiTokensPerSecond: aiTokensPerSecond,
                aiProcessingError: aiFallbackReason
            )
            self.persistDictationAudioIfNeeded(
                audioFile,
                entryID: historyEntryID,
                timestamp: historyTimestamp,
                model: transcriptionModelInfo.model
            )
        }
        // When this app itself is frontmost, the bound editor already receives `finalText`.
        // Avoid re-inserting or overwriting the clipboard in that self-target case.
        let shouldCopyToClipboard = shouldPersistOutputs &&
            !sendsExistingDraft &&
            SettingsStore.shared.copyTranscriptionToClipboard &&
            !isFluidFrontmost

        if shouldCopyToClipboard {
            ClipboardService.copyToClipboard(finalText)
        }

        var didTypeExternally = false
        var didScheduleOverlayHideAfterDelivery = false
        let shouldTypeExternally = shouldPersistOutputs && !isFluidFrontmost

        DebugLogger.shared.debug(
            "Typing decision → frontmost: \(frontmostName), fluidFrontmost: \(isFluidFrontmost), editorFocused: \(self.isTranscriptionFocused), willTypeExternally: \(shouldTypeExternally)",
            source: "ContentView"
        )

        if shouldTypeExternally {
            let typingTarget = self.resolveTypingTargetPID()
            let spokenSendRequested = spokenSendParse.shouldSend
            let targetMatchesRecordingFocus = typingTarget.pid != nil
                && typingTarget.pid == self.recordingFocusTarget?.pid
            let spokenSendAllowed = spokenSendRequested
                && aiFallbackReason == nil
                && (sendsExistingDraft || !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                && targetMatchesRecordingFocus
                && !self.isSpokenSendBlockedApp(appInfo)
            // Submit insertion first, then retire the overlay in this same main
            // turn. The worker can paste concurrently; dismissal must not queue
            // behind history notifications or a subsequent SwiftUI render.
            if typingTarget.shouldRestoreOriginalFocus {
                await self.restoreFocusToRecordingTarget()
            }
            if spokenSendAllowed {
                NotchContentState.shared.setSpokenSendIndicatorState(.sending)
                NotchOverlayManager.shared.updateTranscriptionText("Sending")
            }
            self.appBench(
                "text_ready_to_type_request elapsedMs=\(Int(((ProcessInfo.processInfo.systemUptime - finalTextReadyAt) * 1000).rounded()))"
            )
            if spokenSendAllowed {
                let deliveryOutcome = await self.deliverSpokenSend(
                    finalOutputPlan,
                    targetPID: typingTarget.pid,
                    textReadyAt: finalTextReadyAt
                )
                self.logPipelineCompletion(
                    outcome: String(describing: deliveryOutcome),
                    pipelineID: pipelineID,
                    pipelineStartedAt: pipelineStartedAt,
                    textReadyAt: finalTextReadyAt
                )
                didTypeExternally = deliveryOutcome.didInsert
            } else {
                let shouldHideOverlayAfterDelivery = !shouldShowAIProcessingFailure
                    && !stopOverlay.didRequestHide
                self.asr.typeOutputPlanToActiveField(
                    finalOutputPlan,
                    preferredTargetPID: typingTarget.pid,
                    textReadyAt: finalTextReadyAt,
                    tracksDictionaryCorrections: true,
                    completion: { outcome in
                        self.handleTypingDelivery(
                            outcome,
                            pipelineID: pipelineID,
                            pipelineStartedAt: pipelineStartedAt,
                            textReadyAt: finalTextReadyAt,
                            shouldHideOverlay: shouldHideOverlayAfterDelivery && spokenSendRequested,
                            expectedOverlayLifecycleID: expectedOverlayLifecycleID
                        )
                    }
                )
                self.hideOverlayForDispatchedPaste(shouldHide: shouldHideOverlayAfterDelivery && !spokenSendRequested, lifecycleID: expectedOverlayLifecycleID)
                didScheduleOverlayHideAfterDelivery = shouldHideOverlayAfterDelivery
                didTypeExternally = true
            }
            if spokenSendRequested, !spokenSendAllowed {
                NotchContentState.shared.setSpokenSendIndicatorState(.failed)
                DebugLogger.shared.warning(
                    "Spoken Send skipped because delivery safety checks did not pass",
                    source: "ContentView"
                )
                if aiFallbackReason == nil {
                    NotchOverlayManager.shared.updateTranscriptionText("Text inserted — send skipped")
                    try? await Task.sleep(nanoseconds: 650_000_000)
                }
            }
            NotchContentState.shared.setSpokenSendIndicatorState(.hidden)
            if !shouldShowAIProcessingFailure,
               !stopOverlay.didRequestHide,
               !didScheduleOverlayHideAfterDelivery
            {
                NotchOverlayManager.shared.updateTranscriptionText("")
                self.hideOverlayAfterOutput()
            }
        }

        // Submit raw fallback delivery before failure UI or notification work can
        // compete with it on the main actor. Sandbox runs never present either.
        if shouldShowAIProcessingFailure {
            self.pendingAIReprocessText = spokenSendParse.shouldSend ? normalizedTranscribedText : transcribedText
            NotchContentState.shared.showAIProcessingFailure()
            self.menuBarManager.finishProcessingKeepingOverlayVisible()
            if let aiFallbackNotificationError {
                NotificationService.showAIProcessingFallback(error: aiFallbackNotificationError)
            }
        }

        if !didTypeExternally, !shouldShowAIProcessingFailure, !stopOverlay.didRequestHide {
            self.hideOverlayAfterOutput()
        }
        if !shouldTypeExternally {
            self.logPipelineCompletion(
                outcome: shouldPersistOutputs ? "internal_editor" : "sandbox",
                pipelineID: pipelineID,
                pipelineStartedAt: pipelineStartedAt,
                textReadyAt: finalTextReadyAt
            )
        }
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
        guard self.settings.spokenSendEnabled else { return }
        let isDictationMode = self.activeRecordingMode == .dictate || self.activeRecordingMode == .promptMode
        let shouldStop = isDictationMode &&
            self.currentDictationOutputRouteForHotkeyStop() == .normal &&
            self.asr.isRunning &&
            !self.spokenSendAutoStopTriggered &&
            SpokenSendParser.shouldStopImmediately(
                text,
                phrase: self.settings.spokenSendPhrase,
                spokenSendEnabled: self.settings.spokenSendEnabled,
                sendImmediatelyEnabled: self.settings.spokenSendImmediatelyEnabled
            )

        guard shouldStop else {
            self.spokenSendAutoStopTask?.cancel()
            self.spokenSendAutoStopTask = nil
            self.stopSpokenSendVoiceActivityMonitoring()
            self.spokenSendCountdownStartedAt = nil
            if !self.spokenSendAutoStopTriggered,
               NotchContentState.shared.spokenSendIndicatorState == .countingDown
            {
                NotchContentState.shared.setSpokenSendIndicatorState(.hidden)
            }
            return
        }

        guard self.spokenSendAutoStopTask == nil else {
            return
        }

        let expectedOverlayLifecycleID = self.overlayLifecycleID
        let countdownStartedAt = ProcessInfo.processInfo.systemUptime
        self.spokenSendCountdownStartedAt = countdownStartedAt
        self.spokenSendLastVoiceActivityAt = countdownStartedAt
        self.startSpokenSendVoiceActivityMonitoring()
        let expectedCountdownID = NotchContentState.shared.beginSpokenSendCountdown()
        self.spokenSendAutoStopTask = Task { @MainActor in
            // Keep one countdown across harmless streaming refinements such as punctuation or casing.
            try? await Task.sleep(nanoseconds: SpokenSendParser.immediateStopSettleNanoseconds)
            let quietDuration = ProcessInfo.processInfo.systemUptime - self.spokenSendLastVoiceActivityAt
            guard !Task.isCancelled,
                  self.overlayLifecycleID == expectedOverlayLifecycleID,
                  NotchContentState.shared.spokenSendCountdownID == expectedCountdownID,
                  self.asr.isRunning,
                  self.activeRecordingMode == .dictate || self.activeRecordingMode == .promptMode,
                  self.currentDictationOutputRouteForHotkeyStop() == .normal,
                  !self.spokenSendAutoStopTriggered,
                  SpokenSendParser.canCompleteImmediateStop(
                      self.asr.partialTranscription,
                      phrase: self.settings.spokenSendPhrase,
                      spokenSendEnabled: self.settings.spokenSendEnabled,
                      sendImmediatelyEnabled: self.settings.spokenSendImmediatelyEnabled,
                      quietDuration: quietDuration
                  )
            else {
                if self.overlayLifecycleID == expectedOverlayLifecycleID,
                   NotchContentState.shared.spokenSendCountdownID == expectedCountdownID
                {
                    self.spokenSendAutoStopTask = nil
                    self.stopSpokenSendVoiceActivityMonitoring()
                    self.spokenSendCountdownStartedAt = nil
                    if NotchContentState.shared.spokenSendIndicatorState == .countingDown {
                        NotchContentState.shared.setSpokenSendIndicatorState(.hidden)
                    }
                }
                return
            }

            self.spokenSendAutoStopTask = nil
            self.stopSpokenSendVoiceActivityMonitoring()
            self.spokenSendCountdownStartedAt = nil
            self.spokenSendAutoStopTriggered = true
            NotchContentState.shared.setSpokenSendIndicatorState(.sending)
            DebugLogger.shared.info("Spoken Send countdown completed; stopping dictation", source: "ContentView")
            await self.stopAndProcessTranscription(route: .normal)
        }
    }

    func handleSpokenSendAudioLevel(_ level: CGFloat) {
        guard SpokenSendParser.isMeaningfulVoiceActivity(level) else { return }

        let activityAt = ProcessInfo.processInfo.systemUptime
        self.spokenSendLastVoiceActivityAt = activityAt
        guard let countdownStartedAt = self.spokenSendCountdownStartedAt,
              SpokenSendParser.shouldCancelCountdownForVoiceActivity(
                  countdownStartedAt: countdownStartedAt,
                  voiceActivityAt: activityAt
              ),
              self.spokenSendAutoStopTask != nil
        else {
            return
        }

        self.spokenSendAutoStopTask?.cancel()
        self.spokenSendAutoStopTask = nil
        self.stopSpokenSendVoiceActivityMonitoring()
        self.spokenSendCountdownStartedAt = nil
        if NotchContentState.shared.spokenSendIndicatorState == .countingDown {
            NotchContentState.shared.setSpokenSendIndicatorState(.hidden)
        }
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
        let isDictationMode = self.activeRecordingMode == .dictate || self.activeRecordingMode == .promptMode

        if self.isOnboardingSandboxRouteActive && isDictationMode {
            return .onboardingSandbox
        }
        return .normal
    }

    func reprocessLastDictation() {
        if let pendingText = self.pendingAIReprocessText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !pendingText.isEmpty
        {
            DebugLogger.shared.info("Actions: Reprocessing pending failed dictation", source: "ContentView")
            Task { @MainActor in
                await self.reprocessDictationText(pendingText)
            }
            return
        }

        guard let last = TranscriptionHistoryStore.shared.entries.first else {
            DebugLogger.shared.info("Actions: Reprocess requested but history is empty", source: "ContentView")
            return
        }

        let rawText = last.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty else {
            DebugLogger.shared.info("Actions: Reprocess skipped because latest history raw text is empty", source: "ContentView")
            return
        }

        DebugLogger.shared.info("Actions: Reprocessing latest dictation history entry", source: "ContentView")
        Task { @MainActor in
            await self.reprocessDictationText(rawText)
        }
    }

    func copyLastDictationFromHistory() {
        guard let text = TranscriptionHistoryStore.shared.latestClipboardText else {
            DebugLogger.shared.info("Actions: Copy requested but no transcription is available", source: "ContentView")
            return
        }

        _ = ClipboardService.copyToClipboard(text)
        DebugLogger.shared.info("Actions: Copied latest transcription to clipboard", source: "ContentView")
    }

    /// Re-inserts the most recent transcription into the focused text field using the same
    /// clipboard-free insertion path as live dictation. Unlike copy, this never touches the
    /// system clipboard, and unlike reprocess, it pastes the existing text verbatim (no new
    /// history entry, no reformatting). Useful when the original auto-insert dropped the tail.
    func pasteLastDictationFromHistory() {
        guard let last = TranscriptionHistoryStore.shared.entries.first else {
            DebugLogger.shared.info("Actions: Paste requested but history is empty", source: "ContentView")
            return
        }

        // Prefer the processed text (what was actually delivered, possibly AI-enhanced),
        // falling back to raw for older entries or when enhancement was off.
        let processed = last.processedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = last.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = processed.isEmpty ? raw : processed
        guard !text.isEmpty else {
            DebugLogger.shared.info("Actions: Paste skipped because latest history text is empty", source: "ContentView")
            return
        }

        Task { @MainActor in
            // Only one paste may be pending at a time. Because the paste waits for the modifier keys
            // to release, a quick double/triple-tap of the chord would otherwise queue several Tasks
            // that all insert at once on release. This collapses them to a single paste while still
            // allowing a deliberate repeat (press, it lands, then press again).
            guard !Self.isPasteLastInProgress else {
                DebugLogger.shared.info("Actions: Paste skipped - a paste is already pending", source: "ContentView")
                return
            }
            Self.isPasteLastInProgress = true
            defer { Self.isPasteLastInProgress = false }

            // The hotkey fires on key-down while its own modifier keys (e.g. ⌘⌃) are still
            // physically held. Synthesizing text in that state makes the target app treat the
            // characters as keyboard shortcuts and drop them, so the paste lands once the keys are
            // released — effectively "paste when you let go". The timeout is generous so a normal
            // hold (or a quick repeated press) still pastes on release; it only aborts if a modifier
            // is genuinely stuck, rather than typing a corrupted/destructive shortcut sequence.
            guard await Self.waitForHotkeyModifiersReleased(timeout: 5) else {
                DebugLogger.shared.info("Actions: Paste aborted - modifier keys still held after timeout", source: "ContentView")
                return
            }

            // Re-check here rather than only at the hotkey trigger: the overlay menu entry point
            // has no pre-check, and the wait above may have elapsed since the trigger fired.
            guard !self.asr.isRunning else {
                DebugLogger.shared.info("Actions: Paste skipped - recording in progress", source: "ContentView")
                return
            }

            let typingTarget = self.resolveTypingTargetPID()
            guard typingTarget.pid != nil else {
                DebugLogger.shared.info("Actions: Paste skipped - no external target field available", source: "ContentView")
                return
            }
            if typingTarget.shouldRestoreOriginalFocus {
                await self.restoreFocusToRecordingTarget()
            }
            let appInfo = self.getCurrentAppInfo()
            let outputPlan = ASRService.makeDictationLiteralOutputPlan(
                for: text,
                appName: appInfo.name,
                bundleID: appInfo.bundleId,
                windowTitle: appInfo.windowTitle
            )
            self.asr.typeOutputPlanToActiveField(outputPlan, preferredTargetPID: typingTarget.pid)
            DebugLogger.shared.info("Actions: Pasted latest transcription into focused field", source: "ContentView")
        }
    }

    /// Guards against overlapping paste insertions: only one "paste last transcription" may be
    /// pending at a time (see pasteLastDictationFromHistory). A rapid re-tap while one is still
    /// waiting for the modifier keys to release is ignored rather than queuing a duplicate insert.
    /// Only ever touched on the main actor.
    static var isPasteLastInProgress = false

    /// Polls until the keyboard modifier keys are released, returning `true` once they are, or
    /// `false` if the timeout elapses with keys still held. Used before synthesizing a paste so the
    /// inserted characters aren't swallowed as modifier+key shortcuts.
    static func waitForHotkeyModifiersReleased(timeout: TimeInterval) async -> Bool {
        let relevant: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.isDisjoint(with: relevant) {
                return true
            }
            try? await Task.sleep(nanoseconds: 15_000_000) // 15ms
        }
        return false
    }

    func undoLastAIProcessingFromHistory() {
        guard let last = TranscriptionHistoryStore.shared.entries.first else {
            DebugLogger.shared.info("Actions: Undo AI requested but history is empty", source: "ContentView")
            return
        }

        let rawText = last.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty else {
            DebugLogger.shared.info("Actions: Undo AI skipped because latest history raw text is empty", source: "ContentView")
            return
        }

        guard last.wasAIProcessed else {
            DebugLogger.shared.info("Actions: Undo AI skipped because latest entry was not AI processed", source: "ContentView")
            return
        }

        DebugLogger.shared.info("Actions: Restoring latest transcription raw text (undo AI)", source: "ContentView")
        Task { @MainActor in
            await self.applyHistoryTextOutput(rawText, saveToHistory: true)
        }
    }

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

        self.setActiveRecordingMode(.dictate)
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

        self.clearActiveRecordingMode()
    }

    func setActiveRecordingMode(_ mode: ActiveRecordingMode) {
        if mode != .dictate, mode != .promptMode {
            self.clearActiveDictationShortcutState()
        }
        self.activeRecordingMode = mode
    }

    func clearActiveRecordingMode() {
        self.setActiveRecordingMode(.none)
    }

    /// Cancel an in-flight prewarm. Called on abort / new recording start — NOT on
    /// a normal stop, because AI post-processing runs after stop and benefits from
    /// the warm prefix cache the prewarm prime.
    func cancelPrewarmDictationIfNeeded() {
        self.prewarmDictationTask?.cancel()
        self.prewarmDictationTask = nil
    }

    func handleLivePromptModeSwitch(_ mode: SettingsStore.PromptMode) {
        guard !NotchContentState.shared.isProcessing else { return }
        guard mode.normalized == .dictate else { return }
        guard self.activeRecordingMode != .dictate || NotchContentState.shared.mode != .dictation else { return }
        self.setActiveRecordingMode(.dictate)
        self.menuBarManager.setOverlayMode(.dictation)
    }

    func handleLiveOverlayModeSwitch(_ mode: OverlayMode) {
        guard !NotchContentState.shared.isProcessing else { return }
        switch mode {
        case .dictation:
            self.handleLivePromptModeSwitch(.dictate)
        }
    }

    /// Capture app context at start to avoid mismatches if the user switches apps mid-session
    func startRecording() {
        let model = SettingsStore.shared.selectedSpeechModel
        DebugLogger.shared.info(
            "ContentView: startRecording() for model=\(model.displayName), supportsStreaming=\(model.supportsStreaming)",
            source: "ContentView"
        )
        guard !self.asr.isRunningOrStarting else {
            DebugLogger.shared.debug("ContentView: start ignored because capture is already active", source: "ContentView")
            return
        }

        self.advanceOverlayLifecycle()
        self.setActiveRecordingMode(.dictate)
        let shouldShowDictationOverlay = self.asr.micStatus == .authorized
        let shouldPlayStartSound = self.asr.micStatus == .authorized

        // Ensure normal dictation mode is set (command/rewrite modes set their own)
        if shouldShowDictationOverlay {
            self.menuBarManager.setOverlayMode(.dictation)
            self.menuBarManager.showRecordingOverlayImmediately()
            DebugLogger.shared.benchmark(
                "APP_BENCH",
                message: "overlay_phase phase=connecting",
                source: "AppBenchmark"
            )
        }

        Task {
            let startOutcome = await self.asr.start(onCaptureStarted: {
                if shouldPlayStartSound {
                    TranscriptionSoundPlayer.shared.playStartSound()
                }
                self.captureRecordingContext()
                self.prewarmPrivateAIDictationIfNeeded(for: .primary)
                DebugLogger.shared.benchmark(
                    "APP_BENCH",
                    message: "overlay_phase phase=recording trigger=first_pcm",
                    source: "AppBenchmark"
                )
            })
            if startOutcome == .failed {
                self.menuBarManager.hideRecordingOverlayImmediately(reason: "asr_start_failed")
            }
        }

        // Pre-load model in background while recording (avoids 10s freeze on stop)
        Task {
            do {
                DebugLogger.shared.debug("ContentView: pre-load model task started", source: "ContentView")
                try await self.asr.ensureAsrReady()
                DebugLogger.shared.debug("Model pre-loaded during recording", source: "ContentView")
            } catch {
                DebugLogger.shared.error("Failed to pre-load model: \(error)", source: "ContentView")
            }
        }
    }

    func startCaptionListening() {
        guard !self.asr.isRunningOrStarting else { return }
        guard TheaterAvailability.isSupported else {
            LiveTranslationController.shared.reportListenFailure(TheaterAvailability.unsupportedCopy)
            return
        }
        MicrophoneAccess.refresh(self.asr)
        if MicrophoneAccess.isDenied(self.asr.micStatus) {
            LiveTranslationController.shared.reportListenFailure(MicrophoneAccess.deniedCopy)
            return
        }
        if !self.asr.isAsrReady && !self.asr.modelsExistOnDisk {
            LiveTranslationController.shared.reportListenFailure("Download a Voice Engine first.")
            return
        }
        Task {
            let granted = await MicrophoneAccess.authorize(updating: self.asr)
            if !granted {
                LiveTranslationController.shared.reportListenFailure(MicrophoneAccess.deniedCopy)
                return
            }
            await LiveTranslationController.shared.awaitInitialTranslationWarmupIfNeeded()
            LiveTranslationController.shared.beginSession(kind: .captions)
            self.setActiveRecordingMode(.dictate)
            let startOutcome = await self.asr.start(onCaptureStarted: {
                TranscriptionSoundPlayer.shared.playStartSound()
            })
            if startOutcome == .failed {
                LiveTranslationController.shared.cancelSession()
                LiveTranslationController.shared.reportListenFailure(
                    MicrophoneAccess.isAuthorized(self.asr.micStatus)
                        ? "Could not start listening. Check the microphone and Voice Engine."
                        : MicrophoneAccess.deniedCopy
                )
            }
        }
        Task {
            try? await self.asr.ensureAsrReady()
        }
    }

    func startInsertTranslationListening() {
        guard !self.asr.isRunningOrStarting else { return }
        self.advanceOverlayLifecycle()
        self.setActiveRecordingMode(.dictate)
        LiveTranslationController.shared.beginSession(kind: .insert)
        if self.asr.micStatus == .authorized {
            self.menuBarManager.setOverlayMode(.dictation)
            self.menuBarManager.showRecordingOverlayImmediately()
        }
        Task {
            let startOutcome = await self.asr.start(onCaptureStarted: {
                TranscriptionSoundPlayer.shared.playStartSound()
                self.captureRecordingContext()
            })
            if startOutcome == .failed {
                LiveTranslationController.shared.cancelSession()
                self.menuBarManager.hideRecordingOverlayImmediately(reason: "asr_start_failed")
            }
        }
        Task {
            try? await self.asr.ensureAsrReady()
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

    func prewarmPrivateAIDictationIfNeeded(for slot: SettingsStore.DictationShortcutSlot) {
        let appBundleID = self.recordingAppInfo?.bundleId
        let settings = SettingsStore.shared
        let route = DictationProviderRoute.resolve(
            settings: settings,
            dictationSlot: slot,
            appBundleID: appBundleID
        )
        guard route.usesPrivateAI,
              DictationAIPostProcessingGate.isConfigured(for: slot, appBundleID: appBundleID)
        else { return }

        // Cancel any prior prewarm so rapid start/stop doesn't queue duplicate
        // actor work on PrivateAIIntegrationService.
        self.prewarmDictationTask?.cancel()
        self.prewarmDictationTask = Task {
            DebugLogger.shared.debug(
                "ContentView: AI dictation prewarm started slot=\(slot.rawValue)",
                source: "ContentView"
            )
            await PrivateAIIntegrationService.shared.prewarmDictation()
            DebugLogger.shared.debug(
                "AI dictation prewarm complete slot=\(slot.rawValue)",
                source: "ContentView"
            )
            if !Task.isCancelled {
                self.prewarmDictationTask = nil
            }
        }
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
