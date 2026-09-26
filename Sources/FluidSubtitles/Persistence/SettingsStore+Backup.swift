//
//  SettingsStore+Backup.swift
//  Fluid
//
//  Settings backup payload encode and restore.
//

import Combine
import Foundation

extension SettingsStore {
    func makeBackupPayload() -> SettingsBackupPayload {
        SettingsBackupPayload(
            selectedProviderID: self.selectedProviderID,
            selectedModelByProvider: self.selectedModelByProvider,
            savedProviders: self.savedProviders,
            modelReasoningConfigs: self.modelReasoningConfigs,
            privateAIPrefixKVCacheEnabled: self.privateAIPrefixKVCacheEnabled,
            privateAIBoostEnabled: self.privateAIBoostEnabled,
            privateAIBackendPreference: self.privateAIBackendPreference,
            privateAIContextTokenLimit: self.privateAIContextTokenLimit,
            selectedSpeechModel: self.selectedSpeechModel,
            selectedWhisperLanguageCode: Self.whisperLanguageBackupValue(for: self.selectedWhisperLanguageCode),
            selectedCohereLanguage: self.selectedCohereLanguage,
            selectedNemotronLanguage: self.selectedNemotronLanguage,
            selectedAppleSpeechLocaleIdentifier: self.selectedAppleSpeechLocaleIdentifier,
            hotkeyShortcut: self.hotkeyShortcut,
            primaryDictationShortcuts: self.primaryDictationShortcuts,
            promptModeHotkeyShortcut: self.promptModeHotkeyShortcut,
            promptModeShortcutEnabled: self.promptModeShortcutEnabled,
            promptModeSelectedPromptID: self.promptModeSelectedPromptID,
            secondaryDictationPromptOff: self.isSecondaryDictationPromptOff,
            cancelRecordingHotkeyShortcut: self.cancelRecordingHotkeyShortcut,
            pasteLastTranscriptionHotkeyShortcut: self.pasteLastTranscriptionHotkeyShortcut,
            pasteLastTranscriptionShortcutEnabled: self.pasteLastTranscriptionShortcutEnabled,
            showThinkingTokens: nil,
            hideFromDockAndAppSwitcher: self.hideFromDockAndAppSwitcher,
            showMainWindowAtLoginLaunch: self.showMainWindowAtLoginLaunch,
            accentColorOption: self.accentColorOption,
            transcriptionStartSound: self.transcriptionStartSound,
            transcriptionSoundVolume: self.transcriptionSoundVolume,
            transcriptionSoundIndependentVolume: self.transcriptionSoundIndependentVolume,
            autoUpdateCheckEnabled: self.autoUpdateCheckEnabled,
            betaReleasesEnabled: self.betaReleasesEnabled,
            enableDebugLogs: self.enableDebugLogs,
            pressAndHoldMode: self.pressAndHoldMode,
            hotkeyMode: self.hotkeyMode,
            enableStreamingPreview: self.enableStreamingPreview,
            experimentalParakeetUnifiedFinalEnabled: self.experimentalParakeetUnifiedFinalEnabled,
            showHistoryPerformanceMetrics: self.showHistoryPerformanceMetrics,
            skipSilentRecordingsEnabled: self.skipSilentRecordingsEnabled,
            enableAIStreaming: self.enableAIStreaming,
            copyTranscriptionToClipboard: self.copyTranscriptionToClipboard,
            textInsertionMode: self.textInsertionMode,
            spokenSendEnabled: self.spokenSendEnabled,
            spokenSendImmediatelyEnabled: self.spokenSendImmediatelyEnabled,
            spokenSendPhrase: self.spokenSendPhrase,
            spokenSendKey: self.spokenSendKey,
            preferredInputDeviceUID: self.preferredInputDeviceUID,
            microphonePriority: self.microphonePriority,
            suppressedMicrophoneUIDs: self.suppressedMicrophoneUIDs.sorted(),
            preferredOutputDeviceUID: self.preferredOutputDeviceUID,
            // Kept in the backup schema for compatibility with older builds.
            // Current builds always resolve microphones from the priority list.
            microphoneSelectionMode: .manual,
            visualizerNoiseThreshold: self.visualizerNoiseThreshold,
            overlayPosition: self.overlayPosition,
            overlayBottomOffset: self.overlayBottomOffset,
            overlaySize: self.overlaySize,
            transcriptionPreviewCharLimit: self.transcriptionPreviewCharLimit,
            userTypingWPM: self.userTypingWPM,
            saveTranscriptionHistory: self.saveTranscriptionHistory,
            historyRetention: self.historyRetention.rawValue,
            saveAudioWithTranscriptionHistory: self.saveAudioWithTranscriptionHistory,
            audioHistoryBudgetGB: self.audioHistoryBudgetGB,
            notifyAIProcessingFailures: self.notifyAIProcessingFailures,
            showMicrophoneChangeAlerts: self.showMicrophoneChangeAlerts,
            weekendsDontBreakStreak: self.weekendsDontBreakStreak,
            fillerWords: self.fillerWords,
            removeFillerWordsEnabled: self.removeFillerWordsEnabled,
            autoConvertPunctuationEnabled: self.autoConvertPunctuationEnabled,
            literalDictationFormattingEnabled: self.literalDictationFormattingEnabled,
            punctuationDictionaryPrefix: self.punctuationDictionaryPrefix,
            punctuationDictionaryRules: self.punctuationDictionaryRules,
            spokenFormattingActionRules: self.spokenFormattingActionRules,
            gaavModeEnabled: self.gaavModeEnabled,
            gaavLowercaseFirstLetterEnabled: self.gaavLowercaseFirstLetterEnabled,
            gaavRemoveTrailingPeriodEnabled: self.gaavRemoveTrailingPeriodEnabled,
            continuousDictationModeEnabled: self.continuousDictationModeEnabled,
            continuousDictationSpacingEnabled: self.continuousDictationSpacingEnabled,
            contextAwareCapitalizationEnabled: self.contextAwareCapitalizationEnabled,
            pauseMediaDuringTranscription: self.pauseMediaDuringTranscription,
            automaticDictionaryLearningEnabled: self.automaticDictionaryLearningEnabled,
            automaticDictionarySuggestionFrequency: self.automaticDictionarySuggestionFrequency,
            pronunciationMatchingEnabled: self.pronunciationMatchingEnabled,
            vocabularyBoostingEnabled: self.vocabularyBoostingEnabled,
            customDictionaryEntries: self.customDictionaryEntries,
            selectedDictationPromptID: self.selectedDictationPromptID,
            dictationPromptOff: self.isDictationPromptOff,
            dictationPromptRoutingScope: self.dictationPromptRoutingScope,
            defaultDictationPromptOverride: self.defaultDictationPromptOverride,
            theaterWindowEnabled: self.theaterWindowEnabled,
            translationInsertHotkeyEnabled: self.translationInsertHotkeyEnabled,
            translationInsertHotkeyShortcut: self.translationInsertHotkeyShortcut,
            captionListenHotkeyEnabled: self.captionListenHotkeyEnabled,
            captionListenHotkeyShortcut: self.captionListenHotkeyShortcut,
            translationSourceLanguageID: self.translationSourceLanguageID,
            translationTargetLanguageID: self.translationTargetLanguageID,
            presenterFontSize: self.presenterFontSize,
            presenterFontFamily: self.presenterFontFamily,
            theaterHideChrome: self.theaterHideChrome,
            theaterHighContrast: self.theaterHighContrast,
            theaterAppearance: self.theaterAppearance,
            theaterPresentationStyle: self.theaterPresentationStyle,
            theaterHideFromScreenShare: self.theaterHideFromScreenShare,
            theaterAlsoHearOtherLanguages: self.theaterAlsoHearOtherLanguages,
            theaterDynamicPairing: self.theaterDynamicPairing,
            theaterCaptionPrintStyle: nil,
            theaterSpokenLineMode: self.theaterSpokenLineMode.rawValue,
            theaterCaptionSpacing: self.theaterCaptionSpacing
        )
    }

    func restore(from payload: SettingsBackupPayload) {
        self.restore(from: payload, promptProfiles: self.dictationPromptProfiles, appPromptBindings: self.appPromptBindings)
    }

    func restore(
        from payload: SettingsBackupPayload,
        promptProfiles: [DictationPromptProfile],
        appPromptBindings: [AppPromptBinding]
    ) {
        self.savedProviders = payload.savedProviders
        self.selectedProviderID = payload.selectedProviderID
        self.selectedModelByProvider = payload.selectedModelByProvider
        self.modelReasoningConfigs = payload.modelReasoningConfigs
        if let privateAIPrefixKVCacheEnabled = payload.privateAIPrefixKVCacheEnabled {
            self.privateAIPrefixKVCacheEnabled = privateAIPrefixKVCacheEnabled
        }
        if let privateAIBoostEnabled = payload.privateAIBoostEnabled {
            self.privateAIBoostEnabled = privateAIBoostEnabled
        }
        if let privateAIBackendPreference = payload.privateAIBackendPreference {
            self.privateAIBackendPreference = privateAIBackendPreference
        }
        if let privateAIContextTokenLimit = payload.privateAIContextTokenLimit {
            self.privateAIContextTokenLimit = privateAIContextTokenLimit
        }
        self.selectedSpeechModel = payload.selectedSpeechModel
        if let selectedWhisperLanguageCode = payload.selectedWhisperLanguageCode {
            self.selectedWhisperLanguageCode = Self.whisperLanguageCode(fromBackupValue: selectedWhisperLanguageCode)
        }
        self.selectedCohereLanguage = payload.selectedCohereLanguage
        if let selectedNemotronLanguage = payload.selectedNemotronLanguage {
            self.selectedNemotronLanguage = selectedNemotronLanguage
        }
        if let selectedAppleSpeechLocaleIdentifier = payload.selectedAppleSpeechLocaleIdentifier {
            self.selectedAppleSpeechLocaleIdentifier = selectedAppleSpeechLocaleIdentifier
        }
        self.primaryDictationShortcuts = payload.primaryDictationShortcuts ?? [payload.hotkeyShortcut]
        self.promptModeHotkeyShortcut = payload.promptModeHotkeyShortcut
        self.promptModeShortcutEnabled = payload.promptModeShortcutEnabled
        self.cancelRecordingHotkeyShortcut = payload.cancelRecordingHotkeyShortcut
        // Both guarded so restoring an older backup (which predates these fields) doesn't wipe a
        // currently-configured shortcut or leave the feature enabled with no shortcut bound.
        if let pasteLastTranscriptionHotkeyShortcut = payload.pasteLastTranscriptionHotkeyShortcut {
            self.pasteLastTranscriptionHotkeyShortcut = pasteLastTranscriptionHotkeyShortcut
        }
        if let pasteLastTranscriptionShortcutEnabled = payload.pasteLastTranscriptionShortcutEnabled {
            self.pasteLastTranscriptionShortcutEnabled = pasteLastTranscriptionShortcutEnabled
        }
        self.hideFromDockAndAppSwitcher = payload.hideFromDockAndAppSwitcher
        self.showMainWindowAtLoginLaunch = payload.showMainWindowAtLoginLaunch ?? true
        self.accentColorOption = payload.accentColorOption
        self.transcriptionStartSound = payload.transcriptionStartSound
        self.transcriptionSoundVolume = payload.transcriptionSoundVolume
        self.transcriptionSoundIndependentVolume = payload.transcriptionSoundIndependentVolume
        self.autoUpdateCheckEnabled = payload.autoUpdateCheckEnabled
        self.betaReleasesEnabled = payload.betaReleasesEnabled
        self.enableDebugLogs = payload.enableDebugLogs
        self.hotkeyMode = payload.hotkeyMode ?? (payload.pressAndHoldMode ? .hold : .toggle)
        self.enableStreamingPreview = payload.enableStreamingPreview
        if let experimentalParakeetUnifiedFinalEnabled = payload.experimentalParakeetUnifiedFinalEnabled {
            self.experimentalParakeetUnifiedFinalEnabled = experimentalParakeetUnifiedFinalEnabled
        }
        if let showHistoryPerformanceMetrics = payload.showHistoryPerformanceMetrics {
            self.showHistoryPerformanceMetrics = showHistoryPerformanceMetrics
        }
        if let skipSilentRecordingsEnabled = payload.skipSilentRecordingsEnabled {
            self.skipSilentRecordingsEnabled = skipSilentRecordingsEnabled
        }
        self.enableAIStreaming = payload.enableAIStreaming
        self.copyTranscriptionToClipboard = payload.copyTranscriptionToClipboard
        self.textInsertionMode = payload.textInsertionMode
        if let spokenSendEnabled = payload.spokenSendEnabled {
            self.spokenSendEnabled = spokenSendEnabled
        }
        if let spokenSendImmediatelyEnabled = payload.spokenSendImmediatelyEnabled {
            self.spokenSendImmediatelyEnabled = spokenSendImmediatelyEnabled
        }
        if let spokenSendPhrase = payload.spokenSendPhrase {
            self.spokenSendPhrase = spokenSendPhrase
        }
        if let spokenSendKey = payload.spokenSendKey {
            self.spokenSendKey = spokenSendKey
        }
        self.preferredInputDeviceUID = payload.preferredInputDeviceUID
        self.suppressedMicrophoneUIDs = Set(payload.suppressedMicrophoneUIDs ?? [])
        if let microphonePriority = payload.microphonePriority {
            self.microphonePriority = microphonePriority
        } else {
            self.microphonePriority = []
        }
        self.preferredOutputDeviceUID = payload.preferredOutputDeviceUID
        if payload.microphonePriority != nil {
            self.microphoneSelectionMode = .manual
            self.microphoneSelectionMigrationVersion = Self.microphonePriorityMigrationVersion
        } else if payload.microphoneSelectionMode == .system {
            self.microphoneSelectionMode = .system
            self.microphoneSelectionMigrationVersion = 0
        } else {
            self.microphoneSelectionMode = .manual
        }
        self.visualizerNoiseThreshold = payload.visualizerNoiseThreshold
        self.overlayPosition = payload.overlayPosition
        self.overlayBottomOffset = payload.overlayBottomOffset
        self.overlaySize = payload.overlaySize
        self.transcriptionPreviewCharLimit = payload.transcriptionPreviewCharLimit
        self.userTypingWPM = payload.userTypingWPM
        self.saveTranscriptionHistory = payload.saveTranscriptionHistory
        if let historyRetention = payload.historyRetention {
            self.historyRetention = HistoryRetention.resolved(historyRetention)
        }
        if let saveAudioWithTranscriptionHistory = payload.saveAudioWithTranscriptionHistory {
            self.saveAudioWithTranscriptionHistory = saveAudioWithTranscriptionHistory
        }
        if let audioHistoryBudgetGB = payload.audioHistoryBudgetGB {
            self.audioHistoryBudgetGB = audioHistoryBudgetGB
        }
        if let notifyAIProcessingFailures = payload.notifyAIProcessingFailures {
            self.notifyAIProcessingFailures = notifyAIProcessingFailures
        }
        if let showMicrophoneChangeAlerts = payload.showMicrophoneChangeAlerts {
            self.showMicrophoneChangeAlerts = showMicrophoneChangeAlerts
        }
        self.weekendsDontBreakStreak = payload.weekendsDontBreakStreak
        self.fillerWords = payload.fillerWords
        self.removeFillerWordsEnabled = payload.removeFillerWordsEnabled
        if let autoConvertPunctuationEnabled = payload.autoConvertPunctuationEnabled {
            self.autoConvertPunctuationEnabled = autoConvertPunctuationEnabled
        }
        if let literalDictationFormattingEnabled = payload.literalDictationFormattingEnabled {
            self.literalDictationFormattingEnabled = literalDictationFormattingEnabled
        }
        if let punctuationDictionaryPrefix = payload.punctuationDictionaryPrefix {
            self.punctuationDictionaryPrefix = punctuationDictionaryPrefix
        }
        if let punctuationDictionaryRules = payload.punctuationDictionaryRules {
            self.punctuationDictionaryRules = punctuationDictionaryRules
        }
        if let spokenFormattingActionRules = payload.spokenFormattingActionRules {
            self.spokenFormattingActionRules = spokenFormattingActionRules
        }
        let restoredGaavModeEnabled = payload.gaavModeEnabled
        let restoredContinuousDictationModeEnabled = payload.continuousDictationModeEnabled ?? false
        self.gaavModeEnabled = restoredGaavModeEnabled
        self.gaavLowercaseFirstLetterEnabled = payload.gaavLowercaseFirstLetterEnabled ?? restoredGaavModeEnabled
        self.gaavRemoveTrailingPeriodEnabled = payload.gaavRemoveTrailingPeriodEnabled ?? restoredGaavModeEnabled
        self.continuousDictationModeEnabled = restoredContinuousDictationModeEnabled
        self.continuousDictationSpacingEnabled = payload.continuousDictationSpacingEnabled ?? restoredContinuousDictationModeEnabled
        self.contextAwareCapitalizationEnabled = payload.contextAwareCapitalizationEnabled ?? restoredContinuousDictationModeEnabled
        self.pauseMediaDuringTranscription = payload.pauseMediaDuringTranscription
        if let automaticDictionaryLearningEnabled = payload.automaticDictionaryLearningEnabled {
            self.automaticDictionaryLearningEnabled = automaticDictionaryLearningEnabled
        }
        if let automaticDictionarySuggestionFrequency = payload.automaticDictionarySuggestionFrequency {
            self.automaticDictionarySuggestionFrequency = automaticDictionarySuggestionFrequency
        }
        if let pronunciationMatchingEnabled = payload.pronunciationMatchingEnabled {
            self.pronunciationMatchingEnabled = pronunciationMatchingEnabled
        }
        self.vocabularyBoostingEnabled = payload.vocabularyBoostingEnabled
        self.customDictionaryEntries = payload.customDictionaryEntries

        self.dictationPromptProfiles = promptProfiles
        self.appPromptBindings = appPromptBindings
        self.selectedDictationPromptID = payload.selectedDictationPromptID
        self.isDictationPromptOff = payload.dictationPromptOff ?? self.isDictationPromptOff
        self.dictationPromptRoutingScope = payload.dictationPromptRoutingScope ?? .allApps
        self.defaultDictationPromptOverride = payload.defaultDictationPromptOverride
        if let theaterWindowEnabled = payload.theaterWindowEnabled {
            self.theaterWindowEnabled = theaterWindowEnabled
        }
        if let translationInsertHotkeyEnabled = payload.translationInsertHotkeyEnabled {
            self.translationInsertHotkeyEnabled = translationInsertHotkeyEnabled
            self.translationInsertHotkeyShortcut = payload.translationInsertHotkeyShortcut
        }
        if let captionListenHotkeyEnabled = payload.captionListenHotkeyEnabled {
            self.captionListenHotkeyEnabled = captionListenHotkeyEnabled
            self.captionListenHotkeyShortcut = payload.captionListenHotkeyShortcut
        }
        if let theaterHideChrome = payload.theaterHideChrome {
            self.theaterHideChrome = theaterHideChrome
        }
        if let theaterHighContrast = payload.theaterHighContrast {
            self.theaterHighContrast = theaterHighContrast
        }
        if let theaterAppearance = payload.theaterAppearance {
            self.theaterAppearance = theaterAppearance
        }
        if let theaterPresentationStyle = payload.theaterPresentationStyle {
            self.theaterPresentationStyle = theaterPresentationStyle
        }
        if let theaterHideFromScreenShare = payload.theaterHideFromScreenShare {
            self.theaterHideFromScreenShare = theaterHideFromScreenShare
        }
        if let theaterAlsoHearOtherLanguages = payload.theaterAlsoHearOtherLanguages {
            self.theaterAlsoHearOtherLanguages = theaterAlsoHearOtherLanguages
        }
        if let theaterDynamicPairing = payload.theaterDynamicPairing {
            self.theaterDynamicPairing = theaterDynamicPairing
        }
        if let theaterCaptionSpacing = payload.theaterCaptionSpacing {
            self.theaterCaptionSpacing = theaterCaptionSpacing
        }
        if let theaterSpokenLineMode = payload.theaterSpokenLineMode {
            self.theaterSpokenLineMode = TheaterSpokenLineMode.resolved(theaterSpokenLineMode)
        }
        if let translationSourceLanguageID = payload.translationSourceLanguageID {
            self.translationSourceLanguageID = translationSourceLanguageID
        }
        if let translationTargetLanguageID = payload.translationTargetLanguageID {
            self.translationTargetLanguageID = translationTargetLanguageID
        }
        if let presenterFontSize = payload.presenterFontSize {
            self.presenterFontSize = presenterFontSize
        }
        if let presenterFontFamily = payload.presenterFontFamily {
            self.presenterFontFamily = presenterFontFamily
        }
        self.promptModeSelectedPromptID = payload.promptModeSelectedPromptID
        self.isSecondaryDictationPromptOff = payload.secondaryDictationPromptOff ?? false
        self.normalizePromptSelectionsIfNeeded()
        self.purgeRetiredAppleIntelligenceState()
        self.pauseMediaDuringTranscription = false
        self.spokenSendEnabled = false
        self.spokenSendImmediatelyEnabled = false
        self.autoConvertPunctuationEnabled = false
        self.removeFillerWordsEnabled = false
        self.enableTranscriptionSounds = false
        self.transcriptionSoundIndependentVolume = false
        self.promptModeShortcutEnabled = false
        self.automaticDictionaryLearningEnabled = false
    }
}
