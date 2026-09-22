//
//  ContentView+AIProcessing.swift
//  fluid
//
//  Dictation AI enhancement and prompt traces.
//

import Foundation
import SwiftUI

extension ContentView {
    // MARK: - Modular AI Processing

    struct AITextProcessingResult {
        let text: String
        let tokensPerSecond: Double?
        let fluidIntelligenceLatencyMilliseconds: Int?
    }

    func processTextWithAI(
        _ inputText: String,
        overrideSystemPrompt: String? = nil,
        overrideProviderID: String? = nil,
        overrideModel: String? = nil,
        dictationSlot: SettingsStore.DictationShortcutSlot? = nil,
        streamHandler: PrivateAIStreamHandler? = nil,
        benchmarkID: String? = nil
    ) async throws -> String {
        try await self.processTextWithAIMetrics(
            inputText,
            overrideSystemPrompt: overrideSystemPrompt,
            overrideProviderID: overrideProviderID,
            overrideModel: overrideModel,
            dictationSlot: dictationSlot,
            streamHandler: streamHandler,
            benchmarkID: benchmarkID
        ).text
    }

    func processTextWithAIMetrics(
        _ inputText: String,
        overrideSystemPrompt: String? = nil,
        overrideProviderID: String? = nil,
        overrideModel: String? = nil,
        dictationSlot: SettingsStore.DictationShortcutSlot? = nil,
        streamHandler: PrivateAIStreamHandler? = nil,
        benchmarkID: String? = nil
    ) async throws -> AITextProcessingResult {
        let routeStartedAt = ProcessInfo.processInfo.systemUptime
        let appInfo = self.recordingAppInfo ?? self.getCurrentAppInfo()
        let route: DictationProviderRoute
        if let overrideProviderID, let overrideModel {
            route = DictationProviderRoute.resolve(
                settings: SettingsStore.shared,
                providerID: overrideProviderID,
                model: overrideModel
            )
        } else {
            route = DictationProviderRoute.resolve(
                settings: SettingsStore.shared,
                dictationSlot: dictationSlot,
                appBundleID: appInfo.bundleId
            )
        }
        self.appBench(
            "ai_route_resolved elapsedMs=\(Int(((ProcessInfo.processInfo.systemUptime - routeStartedAt) * 1000).rounded()))"
        )
        let currentSelectedProviderID = route.providerID
        let derivedCurrentProvider = route.providerKey
        let derivedBaseURL = route.baseURL
        let derivedSelectedModel = route.model

        guard !derivedCurrentProvider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProcessingError.noVerifiedProvider
        }
        if derivedSelectedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AIProcessingError.missingModel(provider: derivedCurrentProvider)
        }

        DebugLogger.shared.debug("processTextWithAI using provider=\(derivedCurrentProvider), model=\(derivedSelectedModel)", source: "ContentView")

        let isDictationCall = overrideSystemPrompt != nil || dictationSlot != nil
        let isPrivateAIProvider = route.usesPrivateAI
        let usePrivateAIProvider = overrideSystemPrompt == nil &&
            isDictationCall &&
            (isPrivateAIProvider || PrivateAIIntegrationService.shouldHandleDictation(model: derivedSelectedModel))

        if usePrivateAIProvider {
            if self.shouldTracePromptProcessing {
                self.logDictationPromptTrace("Private AI Provider task", value: "dictationEnhancement")
                self.logDictationPromptTrace("Input transcription (Q)", value: inputText)
                self.logDictationPromptTrace("Selected context text", value: "<none (dictation mode)>")
            }

            self.appBench("ai_private_call")
            let fluidIntelligenceStartedAt = ProcessInfo.processInfo.systemUptime
            let response = try await PrivateAIIntegrationService.shared.enhanceDictation(
                inputText,
                runtime: PrivateAIIntegrationService.RuntimeConfiguration(
                    selectedProviderID: currentSelectedProviderID,
                    providerKey: derivedCurrentProvider,
                    baseURL: derivedBaseURL,
                    model: derivedSelectedModel,
                    apiKey: route.apiKey,
                    localModelPath: PrivateAIIntegrationService.configuredLocalModelPath,
                    usesStablePromptPrefixKVCache: SettingsStore.shared.privateAIPrefixKVCacheEnabled,
                    usesFluid1Boost: SettingsStore.shared.privateAIBoostEnabled,
                    contextTokenLimit: SettingsStore.shared.privateAIContextTokenLimit
                ),
                context: PrivateAIIntegrationService.AppContext(
                    appName: appInfo.name,
                    bundleID: appInfo.bundleId,
                    windowTitle: appInfo.windowTitle,
                    appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                ),
                streamHandler: streamHandler
            )
            self.appBench("ai_private_return")

            if self.shouldTracePromptProcessing {
                self.logDictationPromptTrace("Model answer (A)", value: response.outputText)
            }
            let tokensPerSecond = response.tokensPerSecond.flatMap { value in
                value.isFinite && value > 0 ? value : nil
            }
            let fluidIntelligenceLatencyMilliseconds = Int(
                ((ProcessInfo.processInfo.systemUptime - fluidIntelligenceStartedAt) * 1000).rounded()
            )
            return AITextProcessingResult(
                text: response.outputText,
                tokensPerSecond: tokensPerSecond,
                fluidIntelligenceLatencyMilliseconds: fluidIntelligenceLatencyMilliseconds
            )
        }

        // Resolve the effective prompt once so every provider path honors
        // transient overrides such as "Transcribe with Prompt".
        let promptText: String = {
            let override = overrideSystemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !override.isEmpty { return override }
            return self.buildSystemPrompt(appInfo: appInfo, dictationSlot: dictationSlot)
        }()

        // Dictation enhancement folds the prompt + transcript into a single user
        // turn (substituting `${transcript}` when present, otherwise appending
        // the transcript after a blank line). Non-dictation callers — the AI
        // chat tab specifically — keep the legacy two-message layout where
        // the prompt is the system turn and the input is the user turn.
        let systemPrompt: String
        let userMessageContent: String
        if isDictationCall {
            systemPrompt = ""
            userMessageContent = SettingsStore.renderDictationUserMessage(
                promptText: promptText,
                transcript: inputText
            )
        } else {
            systemPrompt = promptText
            userMessageContent = inputText
        }

        // Skip API key validation for local endpoints
        let isLocal = self.isLocalEndpoint(derivedBaseURL)
        let apiKey = route.apiKey

        if !isLocal {
            guard !apiKey.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else {
                throw AIProcessingError.missingAPIKey(provider: derivedCurrentProvider)
            }
        }

        DebugLogger.shared.debug("Using app context for AI: app=\(appInfo.name), bundleId=\(appInfo.bundleId), title=\(appInfo.windowTitle)", source: "ContentView")
        if self.shouldTracePromptProcessing {
            let activeSlot = dictationSlot ?? self.currentDictationShortcutSlot() ?? .primary
            let selectedProfile = SettingsStore.shared.resolvedDictationPromptProfile(
                for: activeSlot,
                appBundleID: appInfo.bundleId
            )
            let selectedPromptName: String = {
                if SettingsStore.shared.dictationPromptSelection(for: activeSlot) == .off {
                    return "Off"
                }
                if let profile = selectedProfile {
                    return profile.name.isEmpty ? "Untitled Prompt" : profile.name
                }
                return "Default"
            }()
            self.logDictationPromptTrace("Selected prompt profile", value: selectedPromptName)
            self.logDictationPromptTrace(
                "Prompt body (custom/default body)",
                value: SettingsStore.shared.effectiveDictationPromptBody(for: activeSlot, appBundleID: appInfo.bundleId)
            )
            self.logDictationPromptTrace("Built-in default system prompt (baseline)", value: SettingsStore.defaultSystemPromptText(for: .dictate))
            self.logDictationPromptTrace("Prompt override in use", value: (overrideSystemPrompt?.isEmpty == false) ? "yes" : "no")
            if let overrideSystemPrompt, !overrideSystemPrompt.isEmpty {
                self.logDictationPromptTrace("Override system prompt", value: overrideSystemPrompt)
            }
            self.logDictationPromptTrace("Final system prompt sent to model", value: systemPrompt)
            self.logDictationPromptTrace("Input transcription (Q)", value: inputText)
            if userMessageContent != inputText {
                self.logDictationPromptTrace("Final user message sent to model", value: userMessageContent)
            }
            self.logDictationPromptTrace("Selected context text", value: "<none (dictation mode)>")
        }

        // Check if this model doesn't support the temperature parameter
        let isTemperatureUnsupported = SettingsStore.shared.isTemperatureUnsupported(derivedSelectedModel)

        // Get reasoning config for this model (uses per-model settings or auto-detection)
        // This handles custom parameters like reasoning_effort, enable_thinking, etc.
        let providerKey = self.providerKey(for: currentSelectedProviderID)
        let reasoningConfig = SettingsStore.shared.getReasoningConfig(forModel: derivedSelectedModel, provider: providerKey)

        // Build extra parameters from reasoning config
        var extraParams: [String: Any] = [:]
        if let config = reasoningConfig, config.isEnabled {
            if config.parameterName == "enable_thinking" {
                // DeepSeek uses boolean
                extraParams = [config.parameterName: config.parameterValue == "true"]
            } else {
                // OpenAI/Groq use string values (reasoning_effort, etc.)
                extraParams = [config.parameterName: config.parameterValue]
            }
            DebugLogger.shared.debug(
                "Added reasoning param: \(config.parameterName)=\(config.parameterValue)",
                source: "ContentView"
            )
        }

        // Build messages array. For dictation enhancement the whole prompt +
        // transcript is folded into a single user message, so we omit the
        // (empty) system role. Non-dictation callers keep the legacy
        // system + user shape.
        var messages: [[String: Any]] = []
        if !systemPrompt.isEmpty {
            messages.append(["role": "system", "content": systemPrompt])
        }
        messages.append(["role": "user", "content": userMessageContent])

        let enableStreaming = streamHandler != nil

        // Build LLMClient configuration
        var config = LLMClient.Config(
            messages: messages,
            model: derivedSelectedModel,
            baseURL: derivedBaseURL,
            apiKey: apiKey,
            streaming: enableStreaming,
            tools: [],
            temperature: isTemperatureUnsupported ? nil : 0.2,
            extraParameters: extraParams,
            benchmarkID: benchmarkID
        )
        if enableStreaming {
            config.onContentChunk = { chunk in
                streamHandler?(chunk)
            }
        }

        DebugLogger.shared.info("Using LLMClient for transcription (streaming=\(enableStreaming))", source: "ContentView")

        let response: LLMClient.Response
        if enableStreaming {
            do {
                response = try await LLMClient.shared.call(config)
            } catch {
                guard DictationStreamingFallbackPolicy.shouldRetryWithoutStreaming(after: error) else {
                    self.appBench("ai_streaming_fallback_skipped reason=transport_or_cancel")
                    throw error
                }
                self.appBench("ai_streaming_fallback_start")
                DebugLogger.shared.warning(
                    "Streaming dictation post-processing failed; retrying without streaming: \(error.localizedDescription)",
                    source: "ContentView"
                )
                let fallbackConfig = LLMClient.Config(
                    messages: messages,
                    model: derivedSelectedModel,
                    baseURL: derivedBaseURL,
                    apiKey: apiKey,
                    streaming: false,
                    tools: [],
                    temperature: isTemperatureUnsupported ? nil : 0.2,
                    extraParameters: extraParams,
                    benchmarkID: benchmarkID
                )
                response = try await LLMClient.shared.call(fallbackConfig)
            }
        } else {
            response = try await LLMClient.shared.call(config)
        }

        // Log thinking if present (for debugging)
        if let thinking = response.thinking {
            DebugLogger.shared.debug("LLM thinking tokens extracted (\(thinking.count) chars)", source: "ContentView")
            if self.shouldTracePromptProcessing {
                self.logDictationPromptTrace("Model thinking", value: thinking)
            }
        }

        if self.shouldTracePromptProcessing {
            self.logDictationPromptTrace("Model answer (A)", value: response.content)
        }

        guard !response.content.isEmpty else {
            throw AIProcessingError.emptyResponse
        }
        return AITextProcessingResult(
            text: response.content,
            tokensPerSecond: nil,
            fluidIntelligenceLatencyMilliseconds: nil
        )
    }
}
