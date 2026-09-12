//
//  ASRService+Stop.swift
//  fluid
//
//  Stop, finalize, and tear down a recording.
//

import AVFoundation
import Combine
import Foundation

extension ASRService {
    func stop(
        onCaptureStopped: (@MainActor () -> Void)? = nil,
        onFinalTranscriptionStarted: (@MainActor () -> Void)? = nil,
        forDictionaryTraining: Bool = false
    ) async -> String {
        DebugLogger.shared.info("🛑 STOP() called - beginning shutdown sequence", source: "ASRService")
        self.lastStopOutcome = .empty
        self.lastFinalTranscriptionDurationMs = nil
        if forDictionaryTraining || self.isDictionaryTrainingCaptureActive {
            self.lastDictionaryTrainingResult = nil
        }
        self.lastCompletedAudioFile = nil
        let stopStartedAt = Date().timeIntervalSince1970
        self.benchmarkLog("stop_start ageMs=\(self.elapsedMilliseconds(since: self.benchmarkRecordingStartedAt)) bufferedSamples=\(self.audioBuffer.count)")

        if self.isStarting, self.isRunning == false {
            await self.cancelPendingAudioCaptureStart(reason: "recording_stop")
        }
        guard self.isRunning else {
            self.isDictionaryTrainingCaptureActive = false
            DebugLogger.shared.warning("⚠️ STOP() - not running, returning empty string", source: "ASRService")
            return ""
        }
        let stoppingSessionID = self.benchmarkSessionID
        guard let bufferHandoffToken = self.recordingBufferHandoffGate.begin() else {
            DebugLogger.shared.warning("STOP() ignored - recording buffer handoff already active", source: "ASRService")
            return ""
        }
        self.isStoppingFinalTranscription = true
        var completedBufferHandoff = false
        defer {
            if completedBufferHandoff == false {
                self.recordingBufferHandoffGate.complete(bufferHandoffToken)
            }
            self.publishStoppedState(for: stoppingSessionID)
            self.finishDeferredStopUIInvalidation()
            if self.benchmarkSessionID == stoppingSessionID {
                self.isStoppingFinalTranscription = false
            }
        }
        self.stopStreamingScheduler(sessionID: stoppingSessionID)
        let useDictionaryTrainingPath = forDictionaryTraining || self.isDictionaryTrainingCaptureActive
        defer {
            self.applyPendingParakeetVocabularyReloadIfNeeded()
            self.isDictionaryTrainingCaptureActive = false
        }

        await self.cancelAudioRouteRecoveryAndWait()
        guard self.isRunning, self.benchmarkSessionID == stoppingSessionID else {
            self.recordingBufferHandoffGate.complete(bufferHandoffToken)
            completedBufferHandoff = true
            return ""
        }

        // Capture media pause state before we reset it, for resuming at the end
        let shouldResumeMedia = self.didPauseMediaForThisSession
        self.didPauseMediaForThisSession = false // Reset for next session

        DebugLogger.shared.debug("📍 Preparing final transcription", source: "ASRService")

        // Freeze an exact acquisition boundary before stopping hardware. The
        // direct IOProc is synchronously drained and the pipeline trims the
        // final hardware packet to this host time, preserving the last phoneme
        // without appending audio from the next session.
        self.audioCapturePipeline.markRecordingEnd(atHostTime: mach_absolute_time())

        // Stop monitoring device to prevent callbacks after stop
        DebugLogger.shared.debug("👁️ Stopping device monitoring...", source: "ASRService")
        self.stopMonitoringDevice()
        DebugLogger.shared.debug("✅ Device monitoring stopped", source: "ASRService")

        self.benchmarkLog("capture_stop_await_begin")
        await self.stopActiveAudioCapture(reason: "recording_stop")
        self.benchmarkLog("capture_stop_await_return")
        self.audioCapturePipeline.finishRecording()
        self.benchmarkLog("capture_pipeline_finished")

        // A prepared direct IOProc owns only fixed memory and registration; it
        // does not run hardware, show the mic indicator, or hold Bluetooth in
        // headset mode. Keep it prepared across idle periods. AVAudioEngine is
        // detached immediately and released by the off-main serial drain so
        // Bluetooth can return to stereo A2DP without delaying stop cues or
        // transcription. The next capture waits on the drain before creating
        // another engine.
        if self.directAudioLifecycleController.snapshot.isPrepared {
            self.audioEngineStandbyTask?.cancel()
            self.audioEngineStandbyTask = nil
            DebugLogger.shared.debug("♻️ Direct audio capture remains prepared", source: "ASRService")
        } else {
            self.retireAudioEngine(reason: "recording_stop_release")
        }

        // Capture has fully ended — invoke the callback so callers can play a
        // stop cue or release capture-dependent UI without waiting on the
        // (potentially slow) final transcription pass.
        self.benchmarkLog("capture_stopped_callback_request")
        // stop() is MainActor-isolated; calling directly avoids needlessly
        // yielding and re-enqueuing this callback behind unrelated UI work.
        self.benchmarkLog("capture_stopped_callback_begin")
        onCaptureStopped?()
        self.benchmarkLog("capture_stopped_callback_end")
        self.benchmarkLog("capture_stopped_callback_return")

        let directCaptureSnapshot = self.directAudioLifecycleController.snapshot
        self.benchmarkLog(
            "audio_capture_prepared retained=\(directCaptureSnapshot.isPrepared) " +
                "phase=\(directCaptureSnapshot.phase.rawValue) generation=\(directCaptureSnapshot.generation)"
        )

        // The idle scheduler was cancelled before teardown. Only real provider work
        // can still own the PCM buffer here, so drain that operation without sending
        // cancellation into incremental provider state.
        DebugLogger.shared.debug("⏳ Awaiting active streaming work...", source: "ASRService")
        let streamingStopStartedAt = Date().timeIntervalSince1970
        guard await self.drainActiveStreamingWork(sessionID: stoppingSessionID) else {
            self.abortStreamingWavWriter()
            self.beginStreamingDrainRecovery(sessionID: stoppingSessionID, token: bufferHandoffToken)
            completedBufferHandoff = true // Recovery owns the PCM handoff until real work ends.
            self.lastStopOutcome = .failed
            if shouldResumeMedia { await MediaPlaybackService.shared.resumeIfWePaused(true) }
            self.benchmarkLog("stop_end result=error reason=streaming_drain_timeout")
            return ""
        }
        self.benchmarkLog("stop_streaming_wait elapsedMs=\(self.elapsedMilliseconds(since: streamingStopStartedAt))")
        DebugLogger.shared.debug("✅ Active streaming work completed", source: "ASRService")

        self.isProcessingChunk = false
        self.skipNextChunk = false
        self.previousFullTranscription.removeAll()

        // NOW it's safe to access the buffer - all pending tasks have completed
        let logicalSampleCount = self.audioBuffer.count
        var pcm = self.audioBuffer.getRetained()
        self.audioBuffer.clear()
        let hasRecognizedStreamingPreview = !self.partialTranscription
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        let committedPreviewText = self.committedStreamingText
        self.committedStreamingText.removeAll()
        self.streamingWorkState.endSession(stoppingSessionID)
        self.recordingBufferHandoffGate.complete(bufferHandoffToken)
        completedBufferHandoff = true
        self.benchmarkLog("stop_audio_drained samples=\(pcm.count) logicalSamples=\(logicalSampleCount) audioMs=\(Int((Double(logicalSampleCount) / 16_000.0 * 1000).rounded()))")

        // Drop recordings with no audio at all — nothing to transcribe.
        guard !pcm.isEmpty else {
            self.abortStreamingWavWriter()
            DebugLogger.shared.debug(
                "stop(): no audio captured, skipping transcription",
                source: "ASRService"
            )
            DebugLogger.shared.info(
                "Final ASR result | provider=\(self.transcriptionProvider.name) | samples=0 | textChars=0 | confidence=nil | reason=no_audio",
                source: "ASRService"
            )
            if shouldResumeMedia {
                await MediaPlaybackService.shared.resumeIfWePaused(true)
                DebugLogger.shared.info("🎵 Resumed system media after empty audio", source: "ASRService")
            }
            self.benchmarkLog("stop_end result=empty totalMs=\(self.elapsedMilliseconds(since: stopStartedAt)) reason=no_audio")
            return ""
        }

        if Self.shouldAssessShortAudioSilence(
            isEnabled: SettingsStore.shared.skipSilentRecordingsEnabled,
            useDictionaryTrainingPath: useDictionaryTrainingPath,
            hasRecognizedStreamingPreview: hasRecognizedStreamingPreview,
            keepShortUtterances: LiveTranslationController.shared.isSessionActive
        ) {
            let silenceGateStartedAt = ProcessInfo.processInfo.systemUptime
            let silenceAssessment = Self.assessShortAudioSilence(pcm)
            let silenceGateMicroseconds = Int(
                ((ProcessInfo.processInfo.systemUptime - silenceGateStartedAt) * 1_000_000).rounded()
            )
            self.benchmarkLog(
                "silence_gate eligible=\(silenceAssessment.isEligible) skip=\(silenceAssessment.shouldSkipTranscription) " +
                    "audioMs=\(silenceAssessment.durationMilliseconds) analysisUs=\(silenceGateMicroseconds) " +
                    "peak=\(String(format: "%.6f", silenceAssessment.peakAmplitude)) " +
                    "rms=\(String(format: "%.6f", silenceAssessment.rmsAmplitude)) " +
                    "maxFrameRms=\(String(format: "%.6f", silenceAssessment.maximumFrameRMS))"
            )

            if silenceAssessment.shouldSkipTranscription {
                self.abortStreamingWavWriter()
                DebugLogger.shared.info(
                    "Final ASR result | provider=\(self.transcriptionProvider.name) | samples=\(pcm.count) | textChars=0 | confidence=nil | reason=short_silence",
                    source: "ASRService"
                )
                if shouldResumeMedia {
                    await MediaPlaybackService.shared.resumeIfWePaused(true)
                    DebugLogger.shared.info("🎵 Resumed system media after silent audio", source: "ASRService")
                }
                self.benchmarkLog(
                    "stop_end result=empty totalMs=\(self.elapsedMilliseconds(since: stopStartedAt)) reason=short_silence"
                )
                return ""
            }
        } else if hasRecognizedStreamingPreview {
            self.benchmarkLog("silence_gate eligible=false skip=false reason=streaming_preview")
        }

        // Pad sub-1s buffers with trailing silence so short utterances (e.g.
        // "yes", "stop") still transcribe. whisper.cpp asserts on buffers
        // shorter than 1s; every other provider handles silence padding
        // without issue, so we pad unconditionally rather than branching per
        // provider.
        let minSamples = 16_000
        if pcm.count < minSamples {
            let originalCount = pcm.count
            pcm.append(contentsOf: repeatElement(0.0, count: minSamples - pcm.count))
            DebugLogger.shared.debug(
                "stop(): padded short audio with silence (\(originalCount) → \(pcm.count) samples)",
                source: "ASRService"
            )
        }

        do {
            var provider = self.transcriptionProvider
            let ensureStartedAt = Date().timeIntervalSince1970
            if self.isAsrReady, provider.isReady {
                self.benchmarkLog("stop_ensure_ready skipped=true elapsedMs=0")
            } else {
                self.publishStoppedState(for: stoppingSessionID)
                DebugLogger.shared.debug("🔍 Calling ensureAsrReady()...", source: "ASRService")
                try await self.ensureAsrReady()
                provider = self.transcriptionProvider
                self.benchmarkLog("stop_ensure_ready skipped=false elapsedMs=\(self.elapsedMilliseconds(since: ensureStartedAt))")
                DebugLogger.shared.debug("✅ ensureAsrReady() completed", source: "ASRService")
            }

            guard provider.isReady else {
                self.abortStreamingWavWriter()
                DebugLogger.shared.error("Transcription provider is not ready", source: "ASRService")
                self.lastStopOutcome = .failed
                // Resume media playback if we paused it
                if shouldResumeMedia {
                    await MediaPlaybackService.shared.resumeIfWePaused(true)
                    DebugLogger.shared.info("🎵 Resumed system media after provider not ready", source: "ASRService")
                }
                self.benchmarkLog("stop_end result=empty totalMs=\(self.elapsedMilliseconds(since: stopStartedAt)) reason=provider_not_ready")
                return ""
            }

            DebugLogger.shared.debug("Starting transcription with \(pcm.count) samples (\(Float(pcm.count) / 16_000.0) seconds)", source: "ASRService")
            let finalStartedAt = Date().timeIntervalSince1970
            var result: ASRTranscriptionResult
            let finalSource: String
            if useDictionaryTrainingPath {
                result = try await self.transcriptionExecutor.run { [provider] in
                    self.publishStoppedState(for: stoppingSessionID)
                    return try await provider.transcribeDictionaryTraining(pcm)
                }
                self.lastDictionaryTrainingResult = result
                finalSource = "dictionaryTraining"
            } else {
                let vocabularyProvider = provider as? FluidAudioProvider
                self.benchmarkLog(
                    "final_executor_request model=\(SettingsStore.shared.selectedSpeechModel.rawValue) " +
                        "samples=\(pcm.count) vocabEnabled=\(vocabularyProvider?.isWordBoostingActive == true) " +
                        "vocabTerms=\(vocabularyProvider?.boostedVocabularyTermsCount ?? 0)"
                )
                let delayedFinalStatusTask = scheduleDeferredMainActorOperation(
                    afterNanoseconds: Self.finalTranscriptionStatusDelayNanoseconds,
                    shouldRun: { [weak self] in self?.benchmarkSessionID == stoppingSessionID }
                ) { [weak self] in
                    guard let self else { return }
                    self.publishStoppedState(for: stoppingSessionID)
                    if let onFinalTranscriptionStarted {
                        self.benchmarkLog("final_started_callback_begin trigger=delayed_status")
                        onFinalTranscriptionStarted()
                        self.benchmarkLog("final_started_callback_end trigger=delayed_status")
                    }
                }
                defer { delayedFinalStatusTask.cancel() }
                result = try await self.transcriptionExecutor.run(benchmarkSessionID: self.benchmarkSessionID) { [provider] in
                    let executionStartedAt = ProcessInfo.processInfo.systemUptime
                    DebugLogger.shared.info("ASR_BENCH t=\(executionStartedAt) final_executor_begin mainThread=\(Thread.isMainThread)", source: "ASRBenchmark")
                    defer {
                        DebugLogger.shared.info("ASR_BENCH t=\(ProcessInfo.processInfo.systemUptime) final_executor_end", source: "ASRBenchmark")
                    }
                    return try await provider.transcribeFinalDelta(pcm, totalSampleCount: logicalSampleCount)
                }
                delayedFinalStatusTask.cancel()
                self.publishStoppedState(for: stoppingSessionID)
                self.benchmarkLog("final_executor_return")
                finalSource = "full"
            }
            let finalElapsedMs = self.elapsedMilliseconds(since: finalStartedAt)
            if !useDictionaryTrainingPath {
                self.lastFinalTranscriptionDurationMs = finalElapsedMs
                if provider.streamingPreviewMode == .trailingWindow {
                    result = ASRTranscriptionResult(
                        text: StreamingTranscriptStitcher.stitch(
                            committed: committedPreviewText.isEmpty ? self.partialTranscription : committedPreviewText,
                            incoming: result.text
                        ),
                        confidence: result.confidence,
                        pronunciationEnrollment: result.pronunciationEnrollment
                    )
                } else if result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result = ASRTranscriptionResult(
                        text: self.partialTranscription,
                        confidence: result.confidence,
                        pronunciationEnrollment: result.pronunciationEnrollment
                    )
                }
            }
            let finalAudioSeconds = Double(pcm.count) / 16_000.0
            let finalRTF = finalAudioSeconds > 0 ? (Double(finalElapsedMs) / 1000.0) / finalAudioSeconds : 0
            DebugLogger.shared.debug("stop(): final transcription finished source=\(finalSource)", source: "ASRService")
            DebugLogger.shared.debug(
                "Transcription completed: '\(result.text)' (confidence: \(result.confidence))",
                source: "ASRService"
            )
            DebugLogger.shared.info(
                "Final ASR result | provider=\(provider.name) | samples=\(pcm.count) | textChars=\(result.text.trimmingCharacters(in: .whitespacesAndNewlines).count) | confidence=\(result.confidence)",
                source: "ASRService"
            )
            self.benchmarkLog(
                "final_done elapsedMs=\(finalElapsedMs) samples=\(pcm.count) audioMs=\(Int((finalAudioSeconds * 1000).rounded())) " +
                    "textChars=\(result.text.trimmingCharacters(in: .whitespacesAndNewlines).count) rtf=\(String(format: "%.3f", finalRTF)) streamedChunks=\(self.benchmarkCompletedStreamingChunks) source=\(finalSource)"
            )

            // Mark first transcription as complete to clear loading state
            if !self.hasCompletedFirstTranscription {
                self.hasCompletedFirstTranscription = true
                DispatchQueue.main.async {
                    self.isLoadingModel = false
                    self.modelPreparationPhase = nil
                    DebugLogger.shared.info("✅ Model warmed up - first transcription completed", source: "ASRService")
                }
            }

            // Do not update self.finalText here to avoid instant binding insert in playground
            let textWithoutFillers = ASRService.removeFillerWords(result.text)
            let dictionaryText = useDictionaryTrainingPath
                ? textWithoutFillers
                : ASRService.applyCustomDictionary(textWithoutFillers)
            let outputText = useDictionaryTrainingPath
                ? dictionaryText
                : ASRService.applySpokenPunctuationFormatting(dictionaryText)
            if !useDictionaryTrainingPath {
                self.recordWordBoostHitIfAny(transcribedText: outputText)
            }
            DebugLogger.shared.debug("After post-processing: '\(outputText)'", source: "ASRService")
            self.benchmarkLog("stop_end result=success totalMs=\(self.elapsedMilliseconds(since: stopStartedAt)) recordingAgeMs=\(self.elapsedMilliseconds(since: self.benchmarkRecordingStartedAt)) cleanedChars=\(outputText.count)")
            if !useDictionaryTrainingPath {
                self.finishStreamingWavWriter(model: SettingsStore.shared.selectedSpeechModel.rawValue)
            } else {
                self.abortStreamingWavWriter()
            }
            self.scheduleIdleMemoryRelease()

            // Resume media playback if we paused it
            if shouldResumeMedia {
                await MediaPlaybackService.shared.resumeIfWePaused(true)
                DebugLogger.shared.info("🎵 Resumed system media after transcription", source: "ASRService")
            }

            self.lastStopOutcome = outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .empty
                : .success
            return outputText
        } catch {
            self.abortStreamingWavWriter()
            self.lastStopOutcome = .failed
            DebugLogger.shared.error("ASR transcription failed: \(error)", source: "ASRService")
            DebugLogger.shared.error("Error details: \(error.localizedDescription)", source: "ASRService")
            let nsError = error as NSError
            DebugLogger.shared.error("Error domain: \(nsError.domain), code: \(nsError.code)", source: "ASRService")
            DebugLogger.shared.error("Error userInfo: \(nsError.userInfo)", source: "ASRService")

            // Clear loading state if this was the first transcription attempt
            // This ensures the UI doesn't show a perpetual loading state on error
            if !self.hasCompletedFirstTranscription {
                self.hasCompletedFirstTranscription = true
                DispatchQueue.main.async {
                    self.isLoadingModel = false
                    self.modelPreparationPhase = nil
                    DebugLogger.shared.info("⚠️ First transcription failed - clearing loading state", source: "ASRService")
                }
            }

            // Note: We intentionally do NOT show an error popup here.
            // Common errors like "audio too short" are expected during normal use
            // (e.g., accidental hotkey press) and would disrupt the user's workflow.
            // Errors are logged for debugging purposes.

            // Resume media playback if we paused it
            if shouldResumeMedia {
                await MediaPlaybackService.shared.resumeIfWePaused(true)
                DebugLogger.shared.info("🎵 Resumed system media after transcription failure", source: "ASRService")
            }

            self.benchmarkLog("stop_end result=error totalMs=\(self.elapsedMilliseconds(since: stopStartedAt)) error=\(error.localizedDescription)")
            return ""
        }
    }

    func beginDeferredStopUIInvalidation() {
        self.stopUIInvalidationGate.begin()
        self.stopUIInvalidationTimeoutTask?.cancel()
        self.stopUIInvalidationTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard Task.isCancelled == false else { return }
            self?.forceFinishDeferredStopUIInvalidation()
        }
    }

    /// Keeps whole-view invalidation from rebuilding SwiftUI between final ASR
    /// and output dispatch. The generation makes stale pipeline cleanup harmless.
    func holdStopUIInvalidationForOutputPipeline() -> UInt64 {
        self.stopUIInvalidationHoldGeneration &+= 1
        let generation = self.stopUIInvalidationHoldGeneration
        self.activeStopUIInvalidationHold = generation
        self.stopUIInvalidationGate.holdForOutputPipeline()
        return generation
    }

    func releaseStopUIInvalidationForOutputPipeline(_ generation: UInt64) {
        guard self.activeStopUIInvalidationHold == generation else { return }
        self.activeStopUIInvalidationHold = nil
        self.flushDeferredStopUIInvalidation(
            shouldFlush: self.stopUIInvalidationGate.releaseOutputPipelineHold()
        )
    }

    /// Publishes the stopped state only after final ASR has entered its
    /// executor. Streaming ownership is revoked earlier by the scheduler and
    /// buffer handoff gates, so this keeps SwiftUI work off hardware teardown.
    func publishStoppedState(for sessionID: Int) {
        guard self.benchmarkSessionID == sessionID, self.isRunning else { return }
        DebugLogger.shared.debug("🚫 Publishing isRunning = false...", source: "ASRService")
        self.beginDeferredStopUIInvalidation()
        self.isRunning = false
        self.isStoppingFinalTranscription = false
        DebugLogger.shared.debug("✅ isRunning disabled", source: "ASRService")
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self,
                  self.benchmarkSessionID == sessionID,
                  self.isRunning == false
            else { return }
            self.audioCaptureStateDidSettle.send()
        }
    }

    func finishDeferredStopUIInvalidation() {
        self.flushDeferredStopUIInvalidation(shouldFlush: self.stopUIInvalidationGate.finish())
    }

    func forceFinishDeferredStopUIInvalidation() {
        self.activeStopUIInvalidationHold = nil
        self.flushDeferredStopUIInvalidation(shouldFlush: self.stopUIInvalidationGate.forceFinish())
    }

    func flushDeferredStopUIInvalidation(shouldFlush: Bool) {
        guard shouldFlush else { return }
        self.stopUIInvalidationTimeoutTask?.cancel()
        self.stopUIInvalidationTimeoutTask = nil
        self.objectWillChange.send()
        self.deferredStopUIInvalidationDidFlush.send()
    }

    func stopWithoutTranscription() async {
        if self.isStarting, self.isRunning == false {
            await self.cancelPendingAudioCaptureStart(reason: "stop_without_transcription")
        }
        guard self.isRunning else { return }
        let stoppingSessionID = self.benchmarkSessionID
        guard let bufferHandoffToken = self.recordingBufferHandoffGate.begin() else { return }
        var completedBufferHandoff = false
        defer {
            if completedBufferHandoff == false {
                self.recordingBufferHandoffGate.complete(bufferHandoffToken)
            }
        }
        self.stopStreamingScheduler(sessionID: stoppingSessionID)
        defer {
            self.applyPendingParakeetVocabularyReloadIfNeeded()
            self.isDictionaryTrainingCaptureActive = false
        }

        await self.cancelAudioRouteRecoveryAndWait()
        guard self.isRunning, self.benchmarkSessionID == stoppingSessionID else {
            self.recordingBufferHandoffGate.complete(bufferHandoffToken)
            completedBufferHandoff = true
            return
        }

        // Capture media pause state before we reset it, for resuming at the end
        let shouldResumeMedia = self.didPauseMediaForThisSession
        self.didPauseMediaForThisSession = false // Reset for next session

        DebugLogger.shared.info("🛑 Stopping recording - releasing audio devices", source: "ASRService")

        // CRITICAL: Set isRunning to false FIRST to signal any in-flight chunks to abort early
        self.isRunning = false
        self.audioCapturePipeline.setRecordingEnabled(false)

        // Stop monitoring device
        self.stopMonitoringDevice()

        await self.stopActiveAudioCapture(
            retainDirectPreparedCapture: false,
            reason: "stop_without_transcription"
        )
        DebugLogger.shared.debug("Audio capture stopped", source: "ASRService")

        // Cancel/no-transcription paths stay conservative and retire the engine.
        await self.retireAudioEngineAndWait(reason: "stop_without_transcription")
        self.audioCaptureStateDidSettle.send()

        guard await self.drainActiveStreamingWork(sessionID: stoppingSessionID) else {
            self.beginStreamingDrainRecovery(sessionID: stoppingSessionID, token: bufferHandoffToken)
            completedBufferHandoff = true
            if shouldResumeMedia { await MediaPlaybackService.shared.resumeIfWePaused(true) }
            return
        }

        // NOW it's safe to clear the buffer
        self.abortStreamingWavWriter()
        self.audioBuffer.clear()
        self.committedStreamingText.removeAll()
        self.streamingWorkState.endSession(stoppingSessionID)
        self.recordingBufferHandoffGate.complete(bufferHandoffToken)
        completedBufferHandoff = true
        self.partialTranscription.removeAll()
        self.previousFullTranscription.removeAll()
        self.lastBoostHitTerm = nil
        self.lastProcessedSampleCount = 0
        self.isProcessingChunk = false
        self.skipNextChunk = false
        self.refreshWordBoostStatus()

        // Resume media playback if we paused it
        if shouldResumeMedia {
            await MediaPlaybackService.shared.resumeIfWePaused(true)
            DebugLogger.shared.info("🎵 Resumed system media after stopping without transcription", source: "ASRService")
        }
    }

    func configureSession() throws {
        DebugLogger.shared.debug("🔧 configureSession() - ENTERED", source: "ASRService")

        let wasWarm = self.hasWarmAudioEngine
        let engine = self.engine
        DebugLogger.shared.debug(
            wasWarm ? "♻️ Reusing warm audio engine" : "ℹ️ Creating audio engine lazily",
            source: "ASRService"
        )

        if engine.isRunning {
            DebugLogger.shared.debug("⚠️ Engine is running, stopping before configuration", source: "ASRService")
            engine.stop()
            DebugLogger.shared.debug("✅ Engine stopped", source: "ASRService")
        }

        // Force input node instantiation (ensures the underlying AUHAL AudioUnit exists)
        DebugLogger.shared.debug("📍 Forcing input node instantiation...", source: "ASRService")
        _ = engine.inputNode
        DebugLogger.shared.debug("Input node instantiated", source: "ASRService")

        // Force output node instantiation for output device binding
        DebugLogger.shared.debug("📍 Forcing output node instantiation...", source: "ASRService")
        _ = engine.outputNode
        DebugLogger.shared.debug("✅ Output node instantiated", source: "ASRService")

        // NOTE: Device binding occurs in startEngine() BEFORE engine.prepare()
        // Per CoreAudio docs, device must be set before AudioUnit initialization (prepare)
        // Since sync mode is always ON, binding actually no-ops and uses system defaults

        DebugLogger.shared.debug("✅ configureSession() - COMPLETED", source: "ASRService")
    }

    /// In independent mode, attempt to bind AVAudioEngine's input to the user's preferred input device.
    /// In sync-with-system mode, we intentionally do nothing so the engine follows macOS defaults.
    /// Returns true if binding succeeded or if no binding was needed, false if binding failed completely.
    @discardableResult
    func bindPreferredInputDeviceIfNeeded() -> Bool {
        DebugLogger.shared.debug("bindPreferredInputDeviceIfNeeded() - Starting input device binding", source: "ASRService")

        guard let device = self.resolvedInputDeviceForCapture() else {
            DebugLogger.shared.error(
                "No input device available for manual microphone capture.",
                source: "ASRService"
            )
            return false
        }

        DebugLogger.shared.debug(
            "Attempting to bind AVAudioEngine input to capture device '\(device.name)' (uid: \(device.uid))",
            source: "ASRService"
        )

        let ok = self.setEngineInputDevice(deviceID: device.id, deviceUID: device.uid, deviceName: device.name)
        if ok == false {
            DebugLogger.shared.warning(
                "Failed to bind engine input to '\(device.name)' (uid: \(device.uid)). Trying system default input.",
                source: "ASRService"
            )
            return self.tryBindToSystemDefaultInput()
        }

        DebugLogger.shared.info("✅ Bound AVAudioEngine input to '\(device.name)'", source: "ASRService")
        return true
    }

    /// In independent mode, attempt to bind AVAudioEngine's output to the user's preferred output device.
    /// In sync-with-system mode, we intentionally do nothing so the engine follows macOS defaults.
    /// Returns true if binding succeeded or if no binding was needed, false if binding failed completely.
    @discardableResult
    func bindPreferredOutputDeviceIfNeeded() -> Bool {
        DebugLogger.shared.debug("bindPreferredOutputDeviceIfNeeded() - Starting output device binding", source: "ASRService")

        DebugLogger.shared.info("Using current macOS default output device", source: "ASRService")
        return true
    }

    /// Attempts to bind to the system default input device as a fallback.
    /// Returns true if binding succeeded, false otherwise.
    func tryBindToSystemDefaultInput() -> Bool {
        guard let defaultDevice = AudioDevice.getDefaultInputDevice() else {
            DebugLogger.shared.error(
                "No system default input device available. Cannot start audio capture.",
                source: "ASRService"
            )
            return false
        }

        DebugLogger.shared.info(
            "Attempting to bind to system default input: '\(defaultDevice.name)' (uid: \(defaultDevice.uid))",
            source: "ASRService"
        )

        let ok = self.setEngineInputDevice(
            deviceID: defaultDevice.id,
            deviceUID: defaultDevice.uid,
            deviceName: defaultDevice.name
        )

        if !ok {
            DebugLogger.shared.error(
                "Failed to bind to system default input device '\(defaultDevice.name)'. Audio capture cannot proceed.",
                source: "ASRService"
            )
        }

        return ok
    }

    /// Attempts to bind to the system default output device as a fallback.
    /// Returns true if binding succeeded, false otherwise.
    func tryBindToSystemDefaultOutput() -> Bool {
        DebugLogger.shared.debug("tryBindToSystemDefaultOutput() - Starting", source: "ASRService")

        guard let defaultDevice = AudioDevice.getDefaultOutputDevice() else {
            DebugLogger.shared.error(
                "No system default output device available. Cannot bind output.",
                source: "ASRService"
            )
            return false
        }

        DebugLogger.shared.info(
            "Attempting to bind to system default output: '\(defaultDevice.name)' (uid: \(defaultDevice.uid))",
            source: "ASRService"
        )

        let ok = self.setEngineOutputDevice(
            deviceID: defaultDevice.id,
            deviceUID: defaultDevice.uid,
            deviceName: defaultDevice.name
        )

        if !ok {
            DebugLogger.shared.error(
                "Failed to bind to system default output device '\(defaultDevice.name)'. Audio playback may not work correctly.",
                source: "ASRService"
            )
        }

        return ok
    }

    /// Selects a specific CoreAudio device for AVAudioEngine's input node without changing system defaults.
    /// This uses the AUHAL AudioUnit backing `engine.inputNode` on macOS.
    @discardableResult
    func setEngineInputDevice(deviceID: AudioObjectID, deviceUID: String, deviceName: String) -> Bool {
        DebugLogger.shared.debug("setEngineInputDevice() - Binding input to device ID: \(deviceID)", source: "ASRService")
        AppServices.shared.microphonePreferenceCoordinator.reportResolvedSelection(
            uid: deviceUID,
            name: deviceName
        )

        let inputNode = self.engine.inputNode

        // `AVAudioInputNode` is backed by an AudioUnit on macOS. Setting this property selects
        // which physical device the node captures from.
        guard let audioUnit = inputNode.audioUnit else {
            DebugLogger.shared.error(
                "Unable to access AudioUnit for AVAudioEngine.inputNode; cannot bind to '\(deviceName)' (uid: \(deviceUID))",
                source: "ASRService"
            )
            return false
        }

        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioObjectID>.size)
        )

        if status != noErr {
            // OSStatus -10851 (kAudioUnitErr_InvalidPropertyValue) occurs for aggregate devices (Bluetooth, etc.)
            // This is expected for certain device types - not a fatal error
            if status == -10_851 {
                DebugLogger.shared.warning(
                    "Cannot bind INPUT to '\(deviceName)' - likely an aggregate device (OSStatus: \(status)). Will use system default.",
                    source: "ASRService"
                )
            } else {
                DebugLogger.shared.error(
                    "AudioUnitSetProperty(CurrentDevice) failed for INPUT '\(deviceName)' (uid: \(deviceUID), id: \(deviceID)) with OSStatus: \(status)",
                    source: "ASRService"
                )
            }
            return false
        }

        DebugLogger.shared.info("✅ Bound ASR input to '\(deviceName)' (uid: \(deviceUID), id: \(deviceID))", source: "ASRService")
        return true
    }

    /// Selects a specific CoreAudio device for AVAudioEngine's output node without changing system defaults.
    /// This uses the AUHAL AudioUnit backing `engine.outputNode` on macOS.
    @discardableResult
    func setEngineOutputDevice(deviceID: AudioObjectID, deviceUID: String, deviceName: String) -> Bool {
        DebugLogger.shared.debug("setEngineOutputDevice() - Binding output to device ID: \(deviceID)", source: "ASRService")

        let outputNode = self.engine.outputNode

        // `AVAudioOutputNode` is backed by an AudioUnit on macOS. Setting this property selects
        // which physical device the node outputs to.
        guard let audioUnit = outputNode.audioUnit else {
            DebugLogger.shared.error(
                "Unable to access AudioUnit for AVAudioEngine.outputNode; cannot bind to '\(deviceName)' (uid: \(deviceUID))",
                source: "ASRService"
            )
            return false
        }

        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioObjectID>.size)
        )

        if status != noErr {
            // OSStatus -10851 (kAudioUnitErr_InvalidPropertyValue) occurs for aggregate devices (Bluetooth, etc.)
            // This is expected for certain device types - not a fatal error
            if status == -10_851 {
                DebugLogger.shared.warning(
                    "Cannot bind OUTPUT to '\(deviceName)' - likely an aggregate device (OSStatus: \(status)). Will use system default.",
                    source: "ASRService"
                )
            } else {
                DebugLogger.shared.error(
                    "AudioUnitSetProperty(CurrentDevice) failed for OUTPUT '\(deviceName)' (uid: \(deviceUID), id: \(deviceID)) with OSStatus: \(status)",
                    source: "ASRService"
                )
            }
            return false
        }

        DebugLogger.shared.info("✅ Bound ASR output to '\(deviceName)' (uid: \(deviceUID), id: \(deviceID))", source: "ASRService")
        return true
    }

    /// Explicitly unbinds the input device from AVAudioEngine's AudioUnit
    /// This is CRITICAL for releasing Bluetooth devices so macOS can switch back to high-quality A2DP mode
    func unbindInputDevice() {
        DebugLogger.shared.debug("unbindInputDevice() - Releasing input device binding to restore Bluetooth quality", source: "ASRService")

        guard let audioUnit = self.engine.inputNode.audioUnit else {
            DebugLogger.shared.warning("No AudioUnit for input node - cannot unbind device", source: "ASRService")
            return
        }

        // Set device to kAudioObjectUnknown (0) to explicitly release the device binding
        var unknownDevice = AudioObjectID(kAudioObjectUnknown)
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &unknownDevice,
            UInt32(MemoryLayout<AudioObjectID>.size)
        )

        if status == noErr {
            DebugLogger.shared.info("✅ Input device unbound - Bluetooth can now return to high-quality mode", source: "ASRService")
        } else {
            DebugLogger.shared.error("❌ Failed to unbind input device: OSStatus \(status)", source: "ASRService")
        }
    }

    /// Explicitly unbinds the output device from AVAudioEngine's AudioUnit
    /// This ensures complete release of audio device resources
    func unbindOutputDevice() {
        DebugLogger.shared.debug("unbindOutputDevice() - Releasing output device binding", source: "ASRService")

        guard let audioUnit = self.engine.outputNode.audioUnit else {
            DebugLogger.shared.warning("No AudioUnit for output node - cannot unbind device", source: "ASRService")
            return
        }

        // Set device to kAudioObjectUnknown (0) to explicitly release the device binding
        var unknownDevice = AudioObjectID(kAudioObjectUnknown)
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &unknownDevice,
            UInt32(MemoryLayout<AudioObjectID>.size)
        )

        if status == noErr {
            DebugLogger.shared.info("✅ Output device unbound - Audio device fully released", source: "ASRService")
        } else {
            DebugLogger.shared.error("❌ Failed to unbind output device: OSStatus \(status)", source: "ASRService")
        }
    }

    func startEngine() async throws {
        DebugLogger.shared.debug("🚀 startEngine() - ENTERED", source: "ASRService")
        var attempts = 0
        var lastError: Error?

        while attempts < 3 {
            do {
                // CRITICAL: Bind devices BEFORE prepare() - must be set before AudioUnit initialization
                // Note: This may fail for aggregate devices (Bluetooth, etc.) with OSStatus -10851
                // In that case, we fall back to system defaults (same as sync mode)
                DebugLogger.shared.debug("🎚️ Binding input device (before prepare)...", source: "ASRService")
                let inputBindOk = self.bindPreferredInputDeviceIfNeeded()
                DebugLogger.shared.debug("✅ Input device binding result: \(inputBindOk)", source: "ASRService")

                DebugLogger.shared.debug("🔊 Binding output device (before prepare)...", source: "ASRService")
                let outputBindOk = self.bindPreferredOutputDeviceIfNeeded()
                DebugLogger.shared.debug("✅ Output device binding result: \(outputBindOk)", source: "ASRService")

                // If binding failed (e.g., aggregate device), engine will use system defaults
                if !inputBindOk || !outputBindOk {
                    DebugLogger.shared.info(
                        "⚠️ Device binding failed (likely aggregate device). Engine will use system default devices.",
                        source: "ASRService"
                    )
                }

                // Prepare the engine to allocate resources and establish format SYNCHRONOUSLY
                // This ensures the audio graph is fully initialized before we proceed
                DebugLogger.shared.debug("📋 Preparing engine (allocating resources)...", source: "ASRService")
                self.engine.prepare()
                DebugLogger.shared.debug("✅ Engine prepared", source: "ASRService")

                // Log engine state before attempting to start
                let inputNode = self.engine.inputNode
                let inputFormat = inputNode.inputFormat(forBus: 0)
                DebugLogger.shared.debug(
                    "(startEngine(): before engine.start attempt \(attempts + 1)) " +
                        "Engine IO device = \(inputNode.outputFormat(forBus: 0).sampleRate)Hz, " +
                        "Input format = \(inputFormat.sampleRate)Hz \(inputFormat.channelCount)ch",
                    source: "ASRService"
                )

                try self.engine.start()
                DebugLogger.shared.info("AVAudioEngine started successfully on attempt \(attempts + 1)", source: "ASRService")
                return
            } catch {
                lastError = error
                attempts += 1

                // Log the actual error from AVFoundation
                DebugLogger.shared.error(
                    "AVAudioEngine start failed (attempt \(attempts)/3): \(error.localizedDescription) " +
                        "[Domain: \((error as NSError).domain), Code: \((error as NSError).code)]",
                    source: "ASRService"
                )

                // If this isn't the last attempt, recreate engine and reconfigure
                if attempts < 3 {
                    DebugLogger.shared.debug("⚠️ Start failed, recreating engine for retry...", source: "ASRService")
                    await self.retireAudioEngineAndWait(reason: "start_retry")
                    // Need to reconfigure the new engine
                    try? self.configureSession()
                    DebugLogger.shared.debug("✅ Engine recreated and reconfigured, will retry", source: "ASRService")
                }
            }
        }

        // All retries failed - throw the actual error with context
        let errorMessage = "Failed to start AVAudioEngine after 3 attempts. Last error: \(lastError?.localizedDescription ?? "unknown")"
        DebugLogger.shared.error(errorMessage, source: "ASRService")

        // If we have a last error, wrap it with more context; otherwise create a new error
        if let lastError = lastError {
            throw NSError(
                domain: "ASRService",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: errorMessage,
                    NSUnderlyingErrorKey: lastError,
                ]
            )
        } else {
            throw NSError(domain: "ASRService", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMessage])
        }
    }

    func removeEngineTap() {
        guard self.isEngineTapInstalled else { return }
        if let engine = self.engineStorage as? AVAudioEngine {
            engine.inputNode.removeTap(onBus: 0)
        }
        self.isEngineTapInstalled = false
    }

    func setupEngineTap() throws {
        DebugLogger.shared.debug("🎧 setupEngineTap() - ENTERED", source: "ASRService")
        let input = self.engine.inputNode

        // On Intel Macs (especially after wake from sleep), the audio HAL may not have
        // finished initializing even after engine.start() returns. The format can be
        // temporarily 0Hz/0ch while the hardware negotiates with CoreAudio.
        // We retry a few times with small delays to handle this race condition.
        var inFormat = input.inputFormat(forBus: 0)
        var retryCount = 0
        let maxRetries = 5
        let retryDelayMs: UInt32 = 100_000 // 100ms in microseconds

        while inFormat.sampleRate == 0 || inFormat.channelCount == 0 {
            retryCount += 1
            if retryCount > maxRetries {
                DebugLogger.shared.error(
                    "❌ INVALID INPUT FORMAT after \(maxRetries) retries: \(inFormat.sampleRate)Hz \(inFormat.channelCount)ch - Cannot install tap!",
                    source: "ASRService"
                )
                throw NSError(
                    domain: "ASRService",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Audio input format is invalid (\(inFormat.sampleRate)Hz, \(inFormat.channelCount)ch). The microphone may still be initializing after wake from sleep. Please try again in a few seconds."]
                )
            }

            DebugLogger.shared.warning(
                "⏳ Input format not ready (attempt \(retryCount)/\(maxRetries)): \(inFormat.sampleRate)Hz \(inFormat.channelCount)ch - waiting 100ms...",
                source: "ASRService"
            )

            // Small synchronous delay to let HAL initialize
            // Using usleep since we're on MainActor and need to block briefly
            usleep(retryDelayMs)

            // Re-query the format
            inFormat = input.inputFormat(forBus: 0)
        }

        if retryCount > 0 {
            DebugLogger.shared.info(
                "✅ Input format became valid after \(retryCount) retries: \(inFormat.sampleRate)Hz \(inFormat.channelCount)ch",
                source: "ASRService"
            )
        }

        DebugLogger.shared.debug(
            "✅ Valid input format: \(inFormat.sampleRate)Hz \(inFormat.channelCount)ch",
            source: "ASRService"
        )

        self.inputFormat = inFormat
        let pipeline = self.audioCapturePipeline
        if self.isEngineTapInstalled {
            input.removeTap(onBus: 0)
            self.isEngineTapInstalled = false
        }
        DebugLogger.shared.debug("🎧 Installing tap on bus 0...", source: "ASRService")
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { buffer, time in
            pipeline.handle(buffer: buffer, time: time)
        }
        self.isEngineTapInstalled = true
        DebugLogger.shared.debug("✅ setupEngineTap() - COMPLETED", source: "ASRService")
    }

    func scheduleAudioRouteRecovery(
        reason: String,
        requiresIdlePrewarm: Bool = false,
        reconcilesInputSelection: Bool = false,
        invalidatesCurrentStart: Bool = false
    ) {
        guard self.isTerminating == false else {
            self.benchmarkLog("route_recovery_ignored reason=app_terminating event=\(reason)")
            return
        }
        if AudioCaptureIdlePolicy.shouldDeferRouteRecoveryToBluetoothStart(
            directCaptureEnabled: SettingsStore.shared.experimentalDirectAudioCaptureEnabled,
            isStarting: self.isStarting,
            isRunning: self.isRunning,
            attemptedInputIsBluetooth: self.audioStartAttemptIsBluetooth
        ) {
            // AirPods and other Bluetooth inputs can replace their streams more
            // than once while entering microphone mode. The active start owns
            // its bounded retry loop; a second recovery owner would exclude the
            // same healthy device before the Bluetooth route settles.
            let disposition = AudioCaptureIdlePolicy.bluetoothStartupRouteChangeDisposition(
                invalidatesCurrentStart: invalidatesCurrentStart,
                requiresIdlePrewarm: requiresIdlePrewarm,
                reconcilesInputSelection: reconcilesInputSelection
            )
            if disposition == .retryCurrentStart {
                // Make routeStayedStable false even if first PCM won the
                // readiness-gate race. The startup loop then retries the same
                // Bluetooth input without handing it to active-route recovery.
                self.audioRouteRecoveryGeneration &+= 1
                self.benchmarkLog(
                    "bluetooth_start_route_invalidation_retry event=\(reason) " +
                        "routeGeneration=\(self.audioRouteRecoveryGeneration)"
                )
                return
            }
            if disposition == .preserveDeferredWork {
                self.deferredBluetoothStartupRouteRecovery.preserve(
                    reason: reason,
                    requiresIdlePrewarm: requiresIdlePrewarm,
                    reconcilesInputSelection: reconcilesInputSelection
                )
            }
            self.benchmarkLog(
                "bluetooth_start_route_change_deferred event=\(reason) " +
                    "disposition=\(disposition)"
            )
            return
        }
        self.audioRouteRecoveryGeneration &+= 1
        let requiresPrewarmAfterRecovery =
            requiresIdlePrewarm || self.pendingAudioRouteRecovery?.requiresIdlePrewarm == true
        let reconcilesInputAfterRecovery =
            reconcilesInputSelection || self.pendingAudioRouteRecovery?.reconcilesInputSelection == true
        let request = AudioRouteRecoveryRequest(
            generation: self.audioRouteRecoveryGeneration,
            reason: reason,
            requiresIdlePrewarm: requiresPrewarmAfterRecovery,
            reconcilesInputSelection: reconcilesInputAfterRecovery
        )
        self.pendingAudioRouteRecovery = request

        self.audioLevelSubject.send(0.0)
        if self.isRunning || self.isStarting {
            // Stop accepting samples immediately, but do not touch AVAudioEngine
            // until Core Audio has been quiet for the debounce interval.
            self.audioCapturePipeline.setRecordingEnabled(false)
            DebugLogger.shared.warning(
                "Audio route changed during capture; waiting for topology quiet " +
                    "(\(reason), generation=\(request.generation), " +
                    "isStarting=\(self.isStarting), isRunning=\(self.isRunning))",
                source: "ASRService"
            )
        } else {
            DebugLogger.shared.debug(
                "Audio route changed while idle; waiting for topology quiet (\(reason), generation=\(request.generation))",
                source: "ASRService"
            )
        }

        self.audioRouteRecoveryTask?.cancel()
        guard self.isRecoveringAudioRoute == false else {
            // The in-flight recovery observes cancellation after its awaited
            // retirement barrier, then arms the latest generation.
            return
        }

        self.armAudioRouteRecovery(request)
    }

    func armAudioRouteRecovery(_ request: AudioRouteRecoveryRequest) {
        let recoveryDelayNanoseconds = self.audioRouteRecoveryDelayNanoseconds
        self.audioRouteRecoveryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: recoveryDelayNanoseconds)
            } catch {
                return
            }
            await self?.performAudioRouteRecovery(request)
        }
    }

    /// Cancels a sleeping or active recovery and waits until any detached engine
    /// release has drained. Start/stop paths use this to avoid racing a route
    /// rebuild that yielded while AVAudioEngine was deallocating.
    func cancelAudioRouteRecoveryAndWait() async {
        self.audioRouteRecoveryGeneration &+= 1
        self.pendingAudioRouteRecovery = nil
        let task = self.audioRouteRecoveryTask
        task?.cancel()
        _ = await task?.result
        self.audioRouteRecoveryTask = nil
        self.isRecoveringAudioRoute = false
        await self.audioEngineRetirementDrain.waitForScheduledReleases()
    }

    /// Recording startup must let an already-scheduled route rebuild finish.
    /// Cancelling it here can preserve the stale prepared generation that the
    /// route event was meant to retire.
    func waitForPendingAudioRouteRecoveryBeforeStart() async {
        let startedAt = Date().timeIntervalSince1970
        var waitedGenerations: [UInt64] = []
        while let task = self.audioRouteRecoveryTask {
            let generation = self.audioRouteRecoveryGeneration
            waitedGenerations.append(generation)
            self.benchmarkLog("route_recovery_handoff_wait generation=\(generation)")
            _ = await task.result
            if self.pendingAudioRouteRecovery == nil,
               self.isRecoveringAudioRoute == false
            {
                self.audioRouteRecoveryTask = nil
                break
            }
        }
        await self.audioEngineRetirementDrain.waitForScheduledReleases()
        self.benchmarkLog(
            "route_recovery_handoff_end generations=\(waitedGenerations) " +
                "elapsedMs=\(self.elapsedMilliseconds(since: startedAt)) " +
                "capturePhase=\(self.directAudioLifecycleController.snapshot.phase.rawValue)"
        )
    }

    func performAudioRouteRecovery(_ request: AudioRouteRecoveryRequest) async {
        guard self.isTerminating == false,
              request.generation == self.audioRouteRecoveryGeneration,
              Task.isCancelled == false
        else { return }
        guard self.isRecoveringAudioRoute == false else { return }

        self.isRecoveringAudioRoute = true
        defer {
            self.finishAudioRouteRecovery(request)
        }

        if request.reconcilesInputSelection,
           await self.reconcileInputSelectionAfterTopologySettles(request) == false
        {
            return
        }

        if self.isRunning {
            await self.recoverActiveAudioRoute(request)
        } else {
            await self.recoverIdleAudioRoute(request)
        }
    }

    func finishAudioRouteRecovery(_ completedRequest: AudioRouteRecoveryRequest) {
        self.isRecoveringAudioRoute = false

        guard let pendingRequest = self.pendingAudioRouteRecovery else {
            self.audioRouteRecoveryTask = nil
            return
        }
        guard pendingRequest.generation != completedRequest.generation else {
            self.pendingAudioRouteRecovery = nil
            self.audioRouteRecoveryTask = nil
            return
        }

        self.armAudioRouteRecovery(pendingRequest)
    }

    func reconcileInputSelectionAfterTopologySettles(
        _ request: AudioRouteRecoveryRequest
    ) async -> Bool {
        let snapshot = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let devices = AudioDevice.listInputDevicesRefreshingLiveness()
                let defaultInputUID = AudioDevice.getDefaultInputDevice()?.uid
                continuation.resume(returning: (devices, defaultInputUID))
            }
        }
        guard request.generation == self.audioRouteRecoveryGeneration,
              Task.isCancelled == false
        else { return false }

        let currentUIDs = Set(snapshot.0.map(\.uid))
        guard currentUIDs == self.cachedDeviceUIDs else {
            self.cacheCurrentDeviceList(snapshot.0)
            self.scheduleAudioRouteRecovery(
                reason: "input topology still settling",
                requiresIdlePrewarm: request.requiresIdlePrewarm,
                reconcilesInputSelection: true
            )
            return false
        }

        AppServices.shared.microphonePreferenceCoordinator.reconcileMicrophoneSelection(
            availableInputs: snapshot.0,
            defaultInputUID: snapshot.1
        )
        return true
    }

    func recoverIdleAudioRoute(_ request: AudioRouteRecoveryRequest) async {
        let shouldRebuild = self.hasPreparedAudioCapture || request.requiresIdlePrewarm
        guard shouldRebuild else { return }
        let shouldRestoreMicrophonePreview = self.isMicrophonePreviewRequested
        let microphonePreviewGeneration = self.microphonePreviewOperationGeneration

        // If another event arrives while retirement is draining, the next
        // generation still needs to restore the prepared capture backend.
        self.pendingAudioRouteRecovery = AudioRouteRecoveryRequest(
            generation: request.generation,
            reason: request.reason,
            requiresIdlePrewarm: true,
            reconcilesInputSelection: request.reconcilesInputSelection
        )
        await self.directAudioLifecycleController.invalidate(
            reason: "idle_route_change:\(request.reason)"
        )
        await self.retireAudioEngineAndWait(reason: "idle_route_change:\(request.reason)")

        guard request.generation == self.audioRouteRecoveryGeneration, Task.isCancelled == false else { return }
        if shouldRestoreMicrophonePreview,
           self.isMicrophonePreviewRequested,
           microphonePreviewGeneration == self.microphonePreviewOperationGeneration
        {
            await self.startMicrophonePreview()
        } else {
            await self.prewarmConfiguredAudioCaptureIfPossible(
                reason: "idle_route_change",
                allowDuringRouteRecovery: true
            )
        }
    }

    func recoverActiveAudioRoute(_ request: AudioRouteRecoveryRequest) async {
        guard self.isRunning else { return }

        DebugLogger.shared.info(
            "Recovering audio route after \(request.reason) (generation=\(request.generation))",
            source: "ASRService"
        )
        self.audioCapturePipeline.setRecordingEnabled(false)
        self.stopMonitoringDevice()
        await self.stopActiveAudioCapture(
            retainDirectPreparedCapture: false,
            reason: "active_route_recovery"
        )
        await self.retireAudioEngineAndWait(reason: "audio_route_recovery")

        guard request.generation == self.audioRouteRecoveryGeneration, Task.isCancelled == false else { return }

        do {
            let maximumAttempts = SettingsStore.shared.experimentalDirectAudioCaptureEnabled
                ? max(AudioDevice.listInputDevices().count, 1) + 1
                : 1
            var failedInputUIDs = Set<String>()
            var immediatelyRetriedInputUID: String?
            var completedAttempts = 0

            while completedAttempts < maximumAttempts {
                completedAttempts += 1
                self.audioCaptureAttemptID &+= 1
                let readinessAttemptID = self.audioCaptureAttemptID
                self.audioCaptureReadinessGate.arm(
                    sessionID: self.benchmarkSessionID,
                    attemptID: readinessAttemptID
                )
                self.audioCapturePipeline.setRecordingEnabled(
                    true,
                    sessionID: self.benchmarkSessionID,
                    attemptID: readinessAttemptID,
                    startHostTime: mach_absolute_time()
                )

                do {
                    try await self.startConfiguredAudioCapture(excluding: failedInputUIDs)
                } catch {
                    if let failedUID = self.audioStartAttemptInputUID {
                        let retrySameInput = immediatelyRetriedInputUID == nil
                        if retrySameInput {
                            immediatelyRetriedInputUID = failedUID
                        }
                        if retrySameInput == false {
                            failedInputUIDs.insert(failedUID)
                        }
                    }
                    guard completedAttempts < maximumAttempts else { throw error }
                    self.audioCapturePipeline.setRecordingEnabled(false)
                    await self.stopActiveAudioCapture(
                        retainDirectPreparedCapture: false,
                        reason: "active_route_recovery_start_retry"
                    )
                    continue
                }

                guard request.generation == self.audioRouteRecoveryGeneration,
                      Task.isCancelled == false
                else {
                    self.audioCapturePipeline.setRecordingEnabled(false)
                    await self.stopActiveAudioCapture(
                        retainDirectPreparedCapture: false,
                        reason: "superseded_route_recovery_start"
                    )
                    return
                }
                let readiness = await self.audioCaptureReadinessGate.wait(
                    sessionID: self.benchmarkSessionID,
                    attemptID: readinessAttemptID,
                    timeoutNanoseconds: self.firstPCMTimeoutNanoseconds
                )
                guard request.generation == self.audioRouteRecoveryGeneration,
                      Task.isCancelled == false
                else {
                    self.audioCapturePipeline.setRecordingEnabled(false)
                    await self.stopActiveAudioCapture(
                        retainDirectPreparedCapture: false,
                        reason: "superseded_route_recovery_readiness"
                    )
                    return
                }
                if readiness == .ready {
                    AppServices.shared.microphonePreferenceCoordinator.confirmActiveSelection(
                        uid: self.audioStartAttemptInputUID,
                        name: self.audioStartAttemptInputName
                    )
                    self.benchmarkLog(
                        "route_recovery_first_pcm generation=\(request.generation) " +
                            "attempt=\(completedAttempts) attemptID=\(readinessAttemptID) " +
                            "bufferedSamples=\(self.audioBuffer.count)"
                    )

                    if self.activeAudioCaptureBackend == .audioEngine,
                       let currentDevice = self.getCurrentlyBoundInputDevice()
                    {
                        self.startMonitoringDevice(currentDevice.id)
                    }

                    DebugLogger.shared.info(
                        "Audio route recovery succeeded (generation=\(request.generation), " +
                            "attempt=\(completedAttempts))",
                        source: "ASRService"
                    )
                    return
                }

                if let failedUID = self.audioStartAttemptInputUID {
                    let retrySameInput = readiness == .formatInvalidated &&
                        immediatelyRetriedInputUID == nil
                    if retrySameInput {
                        immediatelyRetriedInputUID = failedUID
                    }
                    if retrySameInput == false {
                        failedInputUIDs.insert(failedUID)
                    }
                }
                guard completedAttempts < maximumAttempts else {
                    throw NSError(
                        domain: "ASRService",
                        code: -3,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "No replacement microphone delivered audio (\(readiness)).",
                        ]
                    )
                }
                self.audioCapturePipeline.setRecordingEnabled(false)
                await self.stopActiveAudioCapture(
                    retainDirectPreparedCapture: false,
                    reason: "active_route_recovery_readiness_retry"
                )
            }
            throw NSError(
                domain: "ASRService",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "No replacement microphone is available."]
            )
        } catch {
            guard request.generation == self.audioRouteRecoveryGeneration, Task.isCancelled == false else { return }
            self.audioCapturePipeline.setRecordingEnabled(false)
            await self.stopActiveAudioCapture(
                retainDirectPreparedCapture: false,
                reason: "active_route_recovery_failed"
            )
            DebugLogger.shared.error("Audio route recovery failed: \(error)", source: "ASRService")
            AppServices.shared.microphonePreferenceCoordinator.markActiveSelectionUnavailable()

            // Avoid asking stopWithoutTranscription() to await the recovery task
            // that is currently executing this catch block.
            self.audioRouteRecoveryTask = nil
            await self.stopWithoutTranscription()
            NotificationCenter.default.post(
                name: NSNotification.Name("ASRServiceDeviceDisconnected"),
                object: nil,
                userInfo: ["errorMessage": "Recording stopped because the audio device changed."]
            )
        }
    }

    func handleDirectCaptureFormatInvalidation(
        _ invalidation: DirectCoreAudioLifecycleController.FormatInvalidation
    ) async {
        let captureSnapshot = self.directAudioLifecycleController.snapshot
        guard invalidation.generation == captureSnapshot.generation else {
            self.benchmarkLog(
                "direct_format_invalidation_ignored staleGeneration=\(invalidation.generation) " +
                    "currentGeneration=\(captureSnapshot.generation) property=\(invalidation.reason)"
            )
            return
        }
        let sessionID = self.benchmarkSessionID
        self.audioCapturePipeline.setRecordingEnabled(false)
        if self.isStarting, self.isRunning == false {
            await self.audioCaptureReadinessGate.signalFormatInvalidation(
                sessionID: sessionID,
                attemptID: self.audioCaptureAttemptID
            )
        }
        self.benchmarkLog(
            "direct_format_invalidation generation=\(invalidation.generation) " +
                "device=\(invalidation.deviceID) property=\(invalidation.reason) " +
                "wasRunning=\(invalidation.wasRunning) isStarting=\(self.isStarting)"
        )
        AppServices.shared.audioObserver.signalInputAvailabilityChanged()
        if invalidation.reason == "audio_service_restarted" {
            self.reestablishAudioHardwareListenersAfterServiceReset()
            AppServices.shared.audioObserver.restartObservingAfterAudioServiceReset()
        }
        DebugLogger.shared.warning(
            "Direct capture generation \(invalidation.generation) invalidated by " +
                "\(invalidation.reason); scheduling serialized route recovery",
            source: "ASRService"
        )
        self.scheduleAudioRouteRecovery(
            reason: "direct format changed: \(invalidation.reason)",
            requiresIdlePrewarm: true,
            invalidatesCurrentStart: true
        )
    }

    func handleDefaultInputChanged() {
        // Microphone priority is app-owned. A macOS default-input change must
        // never move or restart the selected microphone.
    }

    func handleDefaultOutputChanged() {
        // Input-only direct capture has no output device dependency.
        if self.directAudioLifecycleController.snapshot.isPrepared {
            return
        }

        self.scheduleAudioRouteRecovery(reason: "default output changed")
    }

    func handleEngineConfigurationChanged(_ changedEngineIdentifier: ObjectIdentifier) {
        guard let currentEngine = self.engineStorage as? AVAudioEngine,
              ObjectIdentifier(currentEngine) == changedEngineIdentifier
        else { return }
        guard AudioCaptureIdlePolicy.shouldRecoverEngineConfigurationChange(
            isRunning: self.isRunning,
            isStarting: self.isStarting
        ) else {
            DebugLogger.shared.debug(
                "Ignoring AVAudioEngine configuration change while capture is idle",
                source: "ASRService"
            )
            return
        }

        self.scheduleAudioRouteRecovery(reason: "engine configuration changed")
    }

    func registerEngineConfigurationChangeObserver() {
        guard self.engineConfigurationChangeObserver == nil else { return }

        // queue: nil (synchronous delivery on the posting thread) is load-bearing:
        // AVAudioEngine posts this notification from its internal serial queue, and
        // NotificationCenter blocks a post until queued observers finish. With
        // queue: .main that wait can never end when the main thread is itself
        // blocked on the engine's queue (dealloc/stop during retirement) — a
        // permanent deadlock (#542). The body only hops to the main actor, which
        // is safe from any thread.
        self.engineConfigurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let changedEngine = notification.object as? AVAudioEngine else { return }
            let changedEngineIdentifier = ObjectIdentifier(changedEngine)
            Task { @MainActor [weak self] in
                self?.handleEngineConfigurationChanged(changedEngineIdentifier)
            }
        }
    }

    func reestablishAudioHardwareListenersAfterServiceReset() {
        // The reset invalidates these registrations in HAL; do not attempt to
        // remove the stale tokens before installing replacements.
        self.defaultInputListenerInstalled = false
        self.defaultInputListenerToken = nil
        self.defaultOutputListenerToken = nil
        self.deviceListListenerInstalled = false
        self.deviceListListenerToken = nil
        self.monitoredDeviceID = nil
        self.monitoredDeviceIsAliveListenerToken = nil
        self.registerDefaultDeviceChangeListener()
        self.registerDeviceListChangeListener()
        let defaultInputReady = self.defaultInputListenerInstalled
        let defaultOutputReady = self.defaultOutputListenerToken != nil
        let deviceListReady = self.deviceListListenerInstalled
        self.benchmarkLog(
            "audio_service_restart listeners_reestablished " +
                "defaultInput=\(defaultInputReady) defaultOutput=\(defaultOutputReady) " +
                "deviceList=\(deviceListReady)"
        )
        let logMessage =
            "ASR hardware listeners after Core Audio service reset: " +
            "defaultInput=\(defaultInputReady), defaultOutput=\(defaultOutputReady), " +
            "deviceList=\(deviceListReady)"
        if defaultInputReady, defaultOutputReady, deviceListReady {
            DebugLogger.shared.warning(
                "Re-registered \(logMessage)",
                source: "ASRService"
            )
        } else {
            DebugLogger.shared.error(
                "Failed to fully re-register \(logMessage)",
                source: "ASRService"
            )
        }
    }

    func registerDefaultDeviceChangeListener() {
        guard self.defaultInputListenerInstalled == false || self.defaultOutputListenerToken == nil else { return }
        var inputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var outputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        if self.defaultInputListenerInstalled == false {
            let inputToken: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                // Defer to next runloop pass — CoreAudio may hold an internal lock during
                // this callback, and our handler makes synchronous CoreAudio queries that
                // would deadlock waiting for the same lock.
                DispatchQueue.main.async { self?.handleDefaultInputChanged() }
            }
            let inputStatus = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &inputAddress,
                DispatchQueue.main,
                inputToken
            )

            if inputStatus == noErr {
                self.defaultInputListenerInstalled = true
                self.defaultInputListenerToken = inputToken
            } else {
                self.defaultInputListenerToken = nil
                DebugLogger.shared.error("Failed to register default input listener: \(inputStatus)", source: "ASRService")
            }
        }

        if self.defaultOutputListenerToken == nil {
            let outputToken: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                DispatchQueue.main.async { self?.handleDefaultOutputChanged() }
            }
            let outputStatus = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &outputAddress,
                DispatchQueue.main,
                outputToken
            )

            if outputStatus == noErr {
                self.defaultOutputListenerToken = outputToken
            } else {
                self.defaultOutputListenerToken = nil
                DebugLogger.shared.warning("Failed to register default output listener: \(outputStatus)", source: "ASRService")
            }
        }
    }
}
