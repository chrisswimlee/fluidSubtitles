import AppKit
import AVFoundation
import XCTest
@testable import FluidSubtitles_Debug

final class LiveTranslationGlossaryTests: XCTestCase {
    func testProtectAndRestoreKeepsNames() {
        let terms = ["fluidSubtitles", "Keynote"]
        let protected = TranslationGlossary.protect(
            "We are demoing fluidSubtitles in Keynote today",
            terms: terms
        )
        XCTAssertFalse(protected.text.contains("fluidSubtitles"))
        XCTAssertFalse(protected.text.contains("Keynote"))
        XCTAssertEqual(
            TranslationGlossary.restore(protected.text, tokens: protected.tokens),
            "We are demoing fluidSubtitles in Keynote today"
        )
    }

    func testLostProtectedTermsRejectsDroppedNames() {
        XCTAssertEqual(
            TranslationGlossary.lostProtectedTerms(
                source: "We are demoing fluidSubtitles in Keynote today",
                polished: "We are demoing the app in Keynote today",
                terms: ["fluidSubtitles", "Keynote"]
            ),
            ["fluidSubtitles"]
        )
        XCTAssertTrue(
            TranslationGlossary.lostProtectedTerms(
                source: "We are demoing fluidSubtitles in Keynote today",
                polished: "We are demoing fluidSubtitles in Keynote today",
                terms: ["fluidSubtitles", "Keynote"]
            ).isEmpty
        )
    }

    func testEmptyTermsLeaveTextAlone() {
        let protected = TranslationGlossary.protect("hello", terms: [])
        XCTAssertEqual(protected.text, "hello")
        XCTAssertTrue(protected.tokens.isEmpty)
    }

    func testLanguageMatching() {
        XCTAssertEqual(TranslationLanguageCatalog.language(matchingSpokenID: "th-TH").id, "th")
        XCTAssertEqual(TranslationLanguageCatalog.language(matchingSpokenID: "ko-KR").id, "ko")
        XCTAssertEqual(TranslationLanguageCatalog.language(matchingSpokenID: "ja-JP").id, "ja")
        XCTAssertEqual(TranslationLanguageCatalog.language(matchingSpokenID: "en").id, "en")
    }

    func testUnsupportedSpokenLanguagesFallBackToEnglish() {
        XCTAssertNil(TranslationLanguageCatalog.language(id: "el"))
        XCTAssertNil(TranslationLanguageCatalog.language(id: "hu"))
        XCTAssertEqual(TranslationLanguageCatalog.language(matchingSpokenID: "el-GR").id, "en")
        XCTAssertEqual(TranslationLanguageCatalog.language(matchingSpokenID: "hu-HU").id, "en")
        XCTAssertEqual(TranslationLanguageCatalog.language(id: "zh-TW")?.id, "zh")
        XCTAssertEqual(TranslationLanguageCatalog.language(id: "vi")?.id, "vi")
        XCTAssertEqual(TranslationLanguageCatalog.language(matchingSpokenID: "nb-NO").id, "no")
    }

    func testLanguagesFromAppleListFollowTheCatalog() {
        let languages = TranslationLanguageCatalog.languages(from: [
            Locale.Language(identifier: "en-IN"),
            Locale.Language(identifier: "en"),
            Locale.Language(identifier: "th"),
            Locale.Language(identifier: "ko"),
            Locale.Language(identifier: "ja"),
            Locale.Language(identifier: "vi"),
            Locale.Language(identifier: "nb"),
        ])
        XCTAssertEqual(languages.map(\.id), TranslationLanguageCatalog.all.map(\.id))
        let norwegian = languages.first { $0.id == "no" }
        XCTAssertEqual(norwegian?.localeLanguage.languageCode?.identifier, "nb")
    }

    func testVoiceEngineLanguagesMatchTheCatalog() {
        XCTAssertEqual(
            Set(VoiceEngineLanguageCatalog.allLanguages().map(\.id)),
            TranslationLanguageCatalog.supportedIDs
        )
    }

    func testDefaultTargetMatchesTheSpokenLanguage() {
        XCTAssertEqual(
            TranslationLanguageCatalog.defaultTarget(forSource: TranslationLanguageCatalog.english).id,
            "en"
        )
        XCTAssertEqual(
            TranslationLanguageCatalog.defaultTarget(forSource: TranslationLanguageCatalog.korean).id,
            "ko"
        )
        XCTAssertEqual(
            TranslationLanguageCatalog.defaultTarget(forSource: TranslationLanguageCatalog.thai).id,
            "th"
        )
        XCTAssertEqual(
            TranslationLanguageCatalog.defaultTarget(forSource: TranslationLanguageCatalog.japanese).id,
            "ja"
        )
    }

    func testEnglishPreferredVoiceEngineIsAppleSpeech() throws {
        let english = try XCTUnwrap(VoiceEngineLanguageCatalog.language(id: "en"))
        let routes = VoiceEngineLanguageCatalog.routes(for: english)
        let first = try XCTUnwrap(routes.first)
        XCTAssertTrue(
            first.model == .appleSpeechAnalyzer || first.model == .appleSpeech,
            "First-run English should be Apple Speech, not Parakeet. Got \(first.model)"
        )
        XCTAssertNotEqual(first.model, .parakeetRealtime)

        let recommended = routes.filter { $0.badgeText == "Recommended" }
        XCTAssertEqual(recommended.count, 1)
        XCTAssertTrue(
            recommended.first?.model == .appleSpeechAnalyzer
                || recommended.first?.model == .appleSpeech
        )
        if let flash = routes.first(where: { $0.model == .parakeetRealtime }) {
            XCTAssertEqual(flash.badgeText, "Faster English")
        }
    }

    func testDefaultSpeechModelIsAppleSpeech() {
        let model = SettingsStore.SpeechModel.defaultModel
        XCTAssertTrue(
            model == .appleSpeechAnalyzer || model == .appleSpeech || model == .whisperBase,
            "First launch should not persist Parakeet TDT. Got \(model)"
        )
        XCTAssertNotEqual(model, .parakeetTDT)
    }

    func testSourceLanguageFollowsTheVoiceEngine() {
        let settings = SettingsStore.shared
        let originalModel = settings.selectedSpeechModel
        let originalLocale = settings.selectedAppleSpeechLocaleIdentifier
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        defer {
            settings.selectedSpeechModel = originalModel
            settings.selectedAppleSpeechLocaleIdentifier = originalLocale
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
        }

        settings.translationSourceLanguageID = "ko"
        settings.translationTargetLanguageID = "en"
        settings.selectedSpeechModel = .parakeetTDTv2
        settings.selectedAppleSpeechLocaleIdentifier = "en-US"

        XCTAssertEqual(SpokenLanguageResolver.sourceLanguage().id, "ko")
        XCTAssertEqual(SpokenLanguageResolver.spokenLanguageID(), "en")
        XCTAssertFalse(SpokenLanguageResolver.voiceEngineSupportsSource())
        XCTAssertEqual(
            SpokenLanguageResolver.voiceEngineMismatchMessage(),
            "Parakeet Flash and TDT v2 only hear English. Switch to Apple Speech, Cohere, or Whisper for Korean."
        )

        settings.selectedSpeechModel = .parakeetTDT
        XCTAssertFalse(VoiceEngineLanguageCatalog.supports(.parakeetTDT, languageID: "ko"))
        XCTAssertFalse(VoiceEngineLanguageCatalog.supports(.parakeetRealtime, languageID: "th"))
        XCTAssertTrue(VoiceEngineLanguageCatalog.supports(.parakeetRealtime, languageID: "en"))
    }

    func testSetSourceLanguageKeepsTheSelectedVoiceEngine() {
        let settings = SettingsStore.shared
        let originalModel = settings.selectedSpeechModel
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        let originalWhisper = settings.selectedWhisperLanguageCode
        let originalApple = settings.selectedAppleSpeechLocaleIdentifier
        defer {
            settings.selectedSpeechModel = originalModel
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
            settings.selectedWhisperLanguageCode = originalWhisper
            settings.selectedAppleSpeechLocaleIdentifier = originalApple
        }

        settings.selectedSpeechModel = .parakeetRealtime
        SpokenLanguageResolver.setSourceLanguage(TranslationLanguageCatalog.korean, settings: settings)
        XCTAssertEqual(settings.selectedSpeechModel, .parakeetRealtime)
        XCTAssertFalse(SpokenLanguageResolver.voiceEngineSupportsSource(settings: settings))
        XCTAssertEqual(
            SpokenLanguageResolver.voiceEngineMismatchMessage(settings: settings),
            "Parakeet Flash and TDT v2 only hear English. Switch to Apple Speech, Cohere, or Whisper for Korean."
        )
    }

    @MainActor
    func testSettingsBackupRoundTripsTheaterKeys() async throws {
        let settings = SettingsStore.shared
        let originalTheater = settings.theaterWindowEnabled
        let originalInsertEnabled = settings.translationInsertHotkeyEnabled
        let originalInsertShortcut = settings.translationInsertHotkeyShortcut
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        defer {
            settings.theaterWindowEnabled = originalTheater
            settings.translationInsertHotkeyEnabled = originalInsertEnabled
            settings.translationInsertHotkeyShortcut = originalInsertShortcut
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
        }

        let shortcut = HotkeyShortcut(keyCode: 17, modifierFlags: [.option, .command])
        settings.theaterWindowEnabled = true
        settings.translationInsertHotkeyEnabled = true
        settings.translationInsertHotkeyShortcut = shortcut
        settings.translationSourceLanguageID = "ko"
        settings.translationTargetLanguageID = "en"

        let document = try await BackupService.shared.makeBackupDocument()
        XCTAssertEqual(document.settings.theaterWindowEnabled, true)
        XCTAssertEqual(document.settings.translationInsertHotkeyEnabled, true)
        XCTAssertEqual(document.settings.translationInsertHotkeyShortcut, shortcut)
        XCTAssertEqual(document.settings.translationSourceLanguageID, "ko")
        XCTAssertEqual(document.settings.translationTargetLanguageID, "en")

        settings.theaterWindowEnabled = false
        settings.translationInsertHotkeyEnabled = false
        settings.translationInsertHotkeyShortcut = nil
        settings.translationSourceLanguageID = "en"
        settings.translationTargetLanguageID = "th"
        settings.restore(from: document.settings)

        XCTAssertTrue(settings.theaterWindowEnabled)
        XCTAssertTrue(settings.translationInsertHotkeyEnabled)
        XCTAssertEqual(settings.translationInsertHotkeyShortcut, shortcut)
        XCTAssertEqual(settings.translationSourceLanguageID, "ko")
        XCTAssertEqual(settings.translationTargetLanguageID, "en")
    }

    func testSameLanguagePairsPersistAndLabelCaptions() {
        let settings = SettingsStore.shared
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        defer {
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
        }

        for language in TranslationLanguageCatalog.all {
            settings.translationSourceLanguageID = language.id
            settings.translationTargetLanguageID = language.id
            XCTAssertEqual(settings.translationSourceLanguageID, language.id)
            XCTAssertEqual(settings.translationTargetLanguageID, language.id)
            XCTAssertTrue(SpokenLanguageResolver.isSameLanguagePair(settings: settings))
            XCTAssertEqual(
                SpokenLanguageResolver.pairLabel(settings: settings),
                "\(language.displayName) captions"
            )
        }

        XCTAssertEqual(
            TranslationLanguageCatalog.targets(excluding: TranslationLanguageCatalog.korean).map(\.id),
            TranslationLanguageCatalog.all.map(\.id)
        )

        SpokenLanguageResolver.setSourceLanguage(TranslationLanguageCatalog.korean, settings: settings)
        settings.translationTargetLanguageID = "ko"
        SpokenLanguageResolver.setSourceLanguage(TranslationLanguageCatalog.korean, settings: settings)
        XCTAssertEqual(settings.translationTargetLanguageID, "ko")
    }

    @MainActor
    func testSameLanguageControllerDoesNotSwapOrRequireAPack() async throws {
        // ensureReadyToListen asks for the microphone. On a headless runner that
        // prompt never answers, and without access `ready` cannot be true.
        try XCTSkipUnless(
            AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            "Needs microphone access already granted"
        )
        let settings = SettingsStore.shared
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        defer {
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
        }
        settings.translationSourceLanguageID = "en"
        settings.translationTargetLanguageID = "en"
        LiveTranslationController.shared.swapDirection()
        XCTAssertEqual(settings.translationSourceLanguageID, "en")
        XCTAssertEqual(settings.translationTargetLanguageID, "en")
        LiveTranslationController.shared.applyTargetLanguage("en")
        XCTAssertEqual(settings.translationTargetLanguageID, "en")
        let ready = await LiveTranslationController.shared.ensureReadyToListen()
        XCTAssertTrue(ready)
        var startedInsert = false
        LiveTranslationController.shared.onStartInsertListening = {
            startedInsert = true
        }
        defer { LiveTranslationController.shared.onStartInsertListening = nil }
        LiveTranslationController.shared.startInsertListening()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(startedInsert)
        let availability = await AppleTranslationEngine.shared.checkAvailability(
            source: TranslationLanguageCatalog.english,
            target: TranslationLanguageCatalog.english
        )
        XCTAssertTrue(availability.contains("captioning English"))
    }

    @MainActor
    func testListenKeepsSelectedEngineAndRefusesKoreanOnParakeet() async {
        let settings = SettingsStore.shared
        let originalModel = settings.selectedSpeechModel
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        defer {
            settings.selectedSpeechModel = originalModel
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
        }
        settings.selectedSpeechModel = .parakeetRealtime
        settings.translationSourceLanguageID = "ko"
        settings.translationTargetLanguageID = "en"
        XCTAssertFalse(SpokenLanguageResolver.voiceEngineSupportsSource())
        let ready = await LiveTranslationController.shared.ensureReadyToListen()
        XCTAssertFalse(ready)
        XCTAssertEqual(settings.selectedSpeechModel, .parakeetRealtime)
        XCTAssertTrue(
            LiveTranslationController.shared.subscriber.statusText.contains("only hear English")
        )
    }

    @MainActor
    func testFinishedLinePolishIsAvailableWhenMLXIsEnabled() {
        let settings = SettingsStore.shared
        let original = settings.mlxRunnerEnabled
        defer { settings.mlxRunnerEnabled = original }
        settings.mlxRunnerEnabled = true
        XCTAssertTrue(LLMTranslationEngine().isAvailable(settings: settings))
        XCTAssertEqual(MLXRunnerService.shared.canServe, MLXRunnerService.shared.status.running)
    }

    func testAppleLanguagePrefersInstalledEnglish() {
        let installedEnglish = Locale.Language(identifier: "en")
        let regionalEnglish = Locale.Language(identifier: "en-IN")
        let resolved = TranslationLanguageCatalog.appleLanguage(
            for: TranslationLanguageCatalog.english,
            from: [regionalEnglish, installedEnglish]
        )
        XCTAssertEqual(resolved.minimalIdentifier, "en")
    }

    func testThaiNemotronExperimentalWarnsEvenWhenSpokenMatches() {
        let settings = SettingsStore.shared
        let originalModel = settings.selectedSpeechModel
        let originalNemotron = settings.selectedNemotronLanguage
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        defer {
            settings.selectedSpeechModel = originalModel
            settings.selectedNemotronLanguage = originalNemotron
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
        }

        settings.translationSourceLanguageID = "th"
        settings.translationTargetLanguageID = "en"
        settings.selectedSpeechModel = .nemotronStreaming
        settings.selectedNemotronLanguage = SettingsStore.NemotronLanguage(rawValue: "th-TH")

        XCTAssertTrue(settings.selectedNemotronLanguage.displayName.localizedCaseInsensitiveContains("experimental"))
        XCTAssertEqual(
            SpokenLanguageResolver.voiceEngineSupportsSource(settings: settings),
            VoiceEngineLanguageCatalog.supports(.nemotronStreaming, languageID: "th")
        )
        XCTAssertEqual(
            SpokenLanguageResolver.voiceEngineMismatchMessage(settings: settings),
            TranslationLanguageCatalog.thaiNemotronExperimentalWarning
        )
        XCTAssertNil(SpokenLanguageResolver.theaterEngineHint(settings: settings))
        XCTAssertEqual(
            SpokenLanguageResolver.stageEngineSummary(settings: settings),
            TranslationLanguageCatalog.thaiNemotronExperimentalWarning
        )
    }

    func testThaiNemotronSpokenMismatchUsesExperimentalWarning() {
        let settings = SettingsStore.shared
        let originalModel = settings.selectedSpeechModel
        let originalNemotron = settings.selectedNemotronLanguage
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        defer {
            settings.selectedSpeechModel = originalModel
            settings.selectedNemotronLanguage = originalNemotron
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
        }

        settings.translationSourceLanguageID = "th"
        settings.translationTargetLanguageID = "en"
        settings.selectedSpeechModel = .nemotronOffline
        settings.selectedNemotronLanguage = .english

        XCTAssertEqual(SpokenLanguageResolver.spokenLanguageID(settings: settings), "en")
        XCTAssertFalse(SpokenLanguageResolver.voiceEngineSupportsSource(settings: settings))
        XCTAssertEqual(
            SpokenLanguageResolver.voiceEngineMismatchMessage(settings: settings),
            TranslationLanguageCatalog.thaiNemotronExperimentalWarning
        )
    }

    func testThaiNemotronExperimentalDisplayWarnsWhenSpokenIsNotThai() {
        let settings = SettingsStore.shared
        let originalModel = settings.selectedSpeechModel
        let originalNemotron = settings.selectedNemotronLanguage
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        defer {
            settings.selectedSpeechModel = originalModel
            settings.selectedNemotronLanguage = originalNemotron
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
        }

        settings.translationSourceLanguageID = "th"
        settings.translationTargetLanguageID = "en"
        settings.selectedSpeechModel = .nemotronStreaming
        settings.selectedNemotronLanguage = SettingsStore.NemotronLanguage(rawValue: "el-GR")

        XCTAssertTrue(settings.selectedNemotronLanguage.displayName.localizedCaseInsensitiveContains("experimental"))
        XCTAssertNotEqual(SpokenLanguageResolver.spokenLanguageID(settings: settings).lowercased().prefix(2), "th")
        XCTAssertFalse(SpokenLanguageResolver.voiceEngineSupportsSource(settings: settings))
        XCTAssertEqual(
            SpokenLanguageResolver.voiceEngineMismatchMessage(settings: settings),
            TranslationLanguageCatalog.thaiNemotronExperimentalWarning
        )
    }

    func testThaiWhisperEnglishMismatchPrefersAppleSpeechOrWhisper() {
        let settings = SettingsStore.shared
        let originalModel = settings.selectedSpeechModel
        let originalWhisper = settings.selectedWhisperLanguageCode
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        defer {
            settings.selectedSpeechModel = originalModel
            settings.selectedWhisperLanguageCode = originalWhisper
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
        }

        settings.translationSourceLanguageID = "th"
        settings.translationTargetLanguageID = "en"
        settings.selectedSpeechModel = .whisperSmall
        settings.selectedWhisperLanguageCode = "en"

        XCTAssertFalse(SpokenLanguageResolver.voiceEngineSupportsSource(settings: settings))
        let message = SpokenLanguageResolver.voiceEngineMismatchMessage(settings: settings)
        XCTAssertEqual(
            message,
            "The current Voice Engine is set to hear English, not Thai. Apple Speech or Whisper is the better Theater default."
        )
        XCTAssertNil(SpokenLanguageResolver.theaterEngineHint(settings: settings))
    }

    func testThaiWhisperMatchShowsHintNotMismatch() {
        let settings = SettingsStore.shared
        let originalModel = settings.selectedSpeechModel
        let originalWhisper = settings.selectedWhisperLanguageCode
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        defer {
            settings.selectedSpeechModel = originalModel
            settings.selectedWhisperLanguageCode = originalWhisper
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
        }

        settings.translationSourceLanguageID = "th"
        settings.translationTargetLanguageID = "en"
        settings.selectedSpeechModel = .whisperSmall
        settings.selectedWhisperLanguageCode = "th"

        XCTAssertTrue(VoiceEngineLanguageCatalog.supports(.whisperSmall, languageID: "th"))
        XCTAssertTrue(SpokenLanguageResolver.voiceEngineSupportsSource(settings: settings))
        XCTAssertNil(SpokenLanguageResolver.voiceEngineMismatchMessage(settings: settings))
        XCTAssertEqual(
            SpokenLanguageResolver.theaterEngineHint(settings: settings),
            TranslationLanguageCatalog.thaiTheaterEngineHint
        )
        XCTAssertEqual(
            TranslationLanguageCatalog.theaterEngineHint(forSource: TranslationLanguageCatalog.thai),
            "Thai speech works best with Apple Speech or Whisper."
        )
        XCTAssertNil(TranslationLanguageCatalog.theaterEngineHint(forSource: TranslationLanguageCatalog.korean))
        XCTAssertNil(TranslationLanguageCatalog.theaterEngineHint(forSource: TranslationLanguageCatalog.japanese))
        XCTAssertNil(TranslationLanguageCatalog.theaterEngineHint(forSource: TranslationLanguageCatalog.english))
    }

    func testKoreanParakeetMismatchMentionsPreferredEngines() {
        let settings = SettingsStore.shared
        let originalModel = settings.selectedSpeechModel
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        defer {
            settings.selectedSpeechModel = originalModel
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
        }

        settings.translationSourceLanguageID = "ko"
        settings.translationTargetLanguageID = "en"
        settings.selectedSpeechModel = .parakeetTDTv2

        XCTAssertFalse(VoiceEngineLanguageCatalog.supports(.parakeetTDTv2, languageID: "ko"))
        XCTAssertFalse(SpokenLanguageResolver.voiceEngineSupportsSource(settings: settings))
        XCTAssertEqual(
            SpokenLanguageResolver.voiceEngineMismatchMessage(settings: settings),
            "Parakeet Flash and TDT v2 only hear English. Switch to Apple Speech, Cohere, or Whisper for Korean."
        )

        settings.selectedSpeechModel = .parakeetTDT
        XCTAssertFalse(VoiceEngineLanguageCatalog.supports(.parakeetTDT, languageID: "ko"))
        XCTAssertEqual(
            SpokenLanguageResolver.voiceEngineMismatchMessage(settings: settings),
            "Parakeet TDT v3 does not hear Korean. Switch to Apple Speech, Cohere, or Whisper."
        )

        settings.translationSourceLanguageID = "ja"
        XCTAssertFalse(VoiceEngineLanguageCatalog.supports(.parakeetTDT, languageID: "ja"))
        XCTAssertEqual(
            SpokenLanguageResolver.voiceEngineMismatchMessage(settings: settings),
            "Parakeet TDT v3 does not hear Japanese. Switch to Apple Speech, Cohere, or Whisper."
        )
    }

    func testKoreanSpokenEnglishMismatchMentionsPreferredEngines() {
        let settings = SettingsStore.shared
        let originalModel = settings.selectedSpeechModel
        let originalWhisper = settings.selectedWhisperLanguageCode
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        defer {
            settings.selectedSpeechModel = originalModel
            settings.selectedWhisperLanguageCode = originalWhisper
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
        }

        settings.translationSourceLanguageID = "ko"
        settings.translationTargetLanguageID = "en"
        settings.selectedSpeechModel = .whisperSmall
        settings.selectedWhisperLanguageCode = "en"

        XCTAssertEqual(SpokenLanguageResolver.spokenLanguageID(settings: settings), "en")
        XCTAssertFalse(SpokenLanguageResolver.voiceEngineSupportsSource(settings: settings))
        XCTAssertEqual(
            SpokenLanguageResolver.voiceEngineMismatchMessage(settings: settings),
            "The current Voice Engine is set to hear English, not Korean. Switch to Apple Speech, Cohere, or Whisper."
        )
        XCTAssertNil(SpokenLanguageResolver.theaterEngineHint(settings: settings))
    }

    func testThaiParakeetKeepsEnglishOnlyWarning() {
        let settings = SettingsStore.shared
        let originalModel = settings.selectedSpeechModel
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        defer {
            settings.selectedSpeechModel = originalModel
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
        }

        settings.translationSourceLanguageID = "th"
        settings.translationTargetLanguageID = "en"
        settings.selectedSpeechModel = .parakeetRealtime

        XCTAssertFalse(VoiceEngineLanguageCatalog.supports(.parakeetRealtime, languageID: "th"))
        XCTAssertFalse(SpokenLanguageResolver.voiceEngineSupportsSource(settings: settings))
        XCTAssertEqual(
            SpokenLanguageResolver.voiceEngineMismatchMessage(settings: settings),
            "Parakeet Flash and TDT v2 only hear English. Switch Voice Engine to Apple Speech or Whisper for Thai."
        )
        XCTAssertNil(SpokenLanguageResolver.theaterEngineHint(settings: settings))
    }

    func testKoreanWhisperMatchHasNoMismatch() {
        let settings = SettingsStore.shared
        let originalModel = settings.selectedSpeechModel
        let originalWhisper = settings.selectedWhisperLanguageCode
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        defer {
            settings.selectedSpeechModel = originalModel
            settings.selectedWhisperLanguageCode = originalWhisper
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
        }

        settings.translationSourceLanguageID = "ko"
        settings.translationTargetLanguageID = "en"
        settings.selectedSpeechModel = .whisperSmall
        settings.selectedWhisperLanguageCode = "ko"

        XCTAssertTrue(VoiceEngineLanguageCatalog.supports(.whisperSmall, languageID: "ko"))
        XCTAssertTrue(SpokenLanguageResolver.voiceEngineSupportsSource(settings: settings))
        XCTAssertNil(SpokenLanguageResolver.voiceEngineMismatchMessage(settings: settings))
        XCTAssertNil(SpokenLanguageResolver.theaterEngineHint(settings: settings))
    }

    func testSpokenLanguageHintsPutISpeakFirstThenTheOtherTwo() {
        XCTAssertEqual(
            SpokenLanguageHints.orderedIDs(primaryID: "ko", alsoHearOthers: false),
            ["ko"]
        )
        // I speak first, then every other product language once.
        let ordered = SpokenLanguageHints.orderedIDs(primaryID: "ko", alsoHearOthers: true)
        XCTAssertEqual(ordered.first, "ko")
        XCTAssertEqual(ordered.count, TranslationLanguageCatalog.all.count)
        XCTAssertEqual(Set(ordered), Set(TranslationLanguageCatalog.all.map(\.id)))
        XCTAssertEqual(Array(ordered.prefix(4)), ["ko", "en", "ja", "th"])
        XCTAssertNil(SpokenLanguageHints.whisperLanguageCode(stored: "ko", alsoHearOthers: true))
        XCTAssertEqual(SpokenLanguageHints.whisperLanguageCode(stored: "ko", alsoHearOthers: false), "ko")
    }

    func testTheaterStaysInScreenshots() {
        XCTAssertEqual(TheaterWindowSharing.sharingType(), .readOnly)
    }

    func testLectureTermPackReadsTypeWhisperCorrectionsAndBareNames() throws {
        let typeWhisper = """
        {
          "terms": ["fluidSubtitles"],
          "corrections": [
            {"original": "fluid subtitles", "replacement": "fluidSubtitles"}
          ]
        }
        """.data(using: .utf8)!
        let pack = try LectureTermPack.document(from: typeWhisper)
        XCTAssertEqual(pack.customWords.map(\.text), ["fluidSubtitles"])
        XCTAssertEqual(pack.replacements.first?.from, ["fluid subtitles"])
        XCTAssertEqual(pack.replacements.first?.to, "fluidSubtitles")

        let names = try LectureTermPack.document(from: Data("[\"Keynote\",\"Nemotron\"]".utf8))
        XCTAssertEqual(names.customWords.map(\.text), ["Keynote", "Nemotron"])
        XCTAssertTrue(names.replacements.isEmpty)
    }

    func testFirstKoreanGreetingCanKeepAShortConfirm() {
        XCTAssertTrue(LiveTranslationConfirm.prefersFirstConfirmation(confirmed: "네", heard: "네"))
        XCTAssertTrue(LiveTranslationConfirm.prefersFirstConfirmation(confirmed: "OK", heard: "ok"))
        XCTAssertFalse(LiveTranslationConfirm.prefersFirstConfirmation(confirmed: "", heard: "네"))
        XCTAssertTrue(
            LiveTranslationConfirm.prefersFirstConfirmation(
                confirmed: "Today we trained the model.",
                heard: "Today we trained"
            )
        )
    }

    func testSpokenScriptDetectorReadsThePairLanguages() {
        XCTAssertEqual(SpokenScriptDetector.languageID(in: "Hello there", among: ["en", "ko"]), "en")
        XCTAssertEqual(SpokenScriptDetector.languageID(in: "안녕하세요 여러분", among: ["en", "ko"]), "ko")
        XCTAssertEqual(SpokenScriptDetector.languageID(in: "こんにちは皆さん", among: ["en", "ja"]), "ja")
        XCTAssertEqual(SpokenScriptDetector.languageID(in: "สวัสดีครับ", among: ["en", "th"]), "th")
        XCTAssertNil(SpokenScriptDetector.languageID(in: "Hi 안녕", among: ["en", "ko"]))
        XCTAssertNil(SpokenScriptDetector.languageID(in: "A", among: ["en", "ko"]))
    }

    func testAlsoHearOthersSegmentsExtrasByScriptWithoutFlippingThePair() {
        let settings = SettingsStore.shared
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        let originalAlsoHear = settings.theaterAlsoHearOtherLanguages
        defer {
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
            settings.theaterAlsoHearOtherLanguages = originalAlsoHear
        }

        settings.translationSourceLanguageID = "en"
        settings.translationTargetLanguageID = "ko"
        settings.theaterAlsoHearOtherLanguages = false
        XCTAssertEqual(
            SpokenLanguageResolver.listenLanguageID(for: "안녕하세요 여러분", settings: settings),
            "en"
        )

        settings.theaterAlsoHearOtherLanguages = true
        XCTAssertEqual(
            SpokenLanguageResolver.listenLanguageID(for: "안녕하세요 여러분", settings: settings),
            "ko"
        )
        XCTAssertEqual(
            SpokenLanguageResolver.listenLanguageID(for: "สวัสดีครับ", settings: settings),
            "th"
        )
        XCTAssertEqual(
            SpokenLanguageResolver.listenLanguageID(for: "Hello there", settings: settings),
            "en"
        )
        let pair = SpokenLanguageResolver.pairForSpokenText("안녕하세요 여러분", settings: settings)
        XCTAssertEqual(pair.source.id, "en")
        XCTAssertEqual(pair.target.id, "ko")
    }

    func testSpokenEngineReloadWaitsUntilASRIsIdle() {
        XCTAssertTrue(TheaterSpokenEngineReload.shouldWaitForIdle(sessionWasActive: true, asrBusy: false))
        XCTAssertTrue(TheaterSpokenEngineReload.shouldWaitForIdle(sessionWasActive: false, asrBusy: true))
        XCTAssertFalse(TheaterSpokenEngineReload.shouldWaitForIdle(sessionWasActive: false, asrBusy: false))
        XCTAssertFalse(TheaterSpokenEngineReload.canReload(asrBusy: true))
        XCTAssertTrue(TheaterSpokenEngineReload.canReload(asrBusy: false))
        XCTAssertTrue(TranslationEngineError.timeout.isTimeout)
    }

    func testDynamicPairingStaysPinnedWhileEitherWayIsDeferred() {
        let settings = SettingsStore.shared
        let originalSource = settings.translationSourceLanguageID
        let originalTarget = settings.translationTargetLanguageID
        let originalMode = settings.theaterSessionMode
        let originalDynamic = settings.theaterDynamicPairing
        defer {
            settings.translationSourceLanguageID = originalSource
            settings.translationTargetLanguageID = originalTarget
            settings.theaterSessionMode = originalMode
            settings.theaterDynamicPairing = originalDynamic
        }

        settings.theaterSessionMode = .translation
        settings.translationSourceLanguageID = "en"
        settings.translationTargetLanguageID = "ko"
        settings.theaterDynamicPairing = true

        XCTAssertFalse(SpokenLanguageResolver.dynamicPairingAvailable)
        XCTAssertFalse(SpokenLanguageResolver.isDynamicPairingEnabled(settings: settings))
        let korean = SpokenLanguageResolver.pairForSpokenText("안녕하세요 여러분", settings: settings)
        XCTAssertEqual(korean.source.id, "en")
        XCTAssertEqual(korean.target.id, "ko")
        let english = SpokenLanguageResolver.pairForSpokenText("Hello everyone", settings: settings)
        XCTAssertEqual(english.source.id, "en")
        XCTAssertEqual(english.target.id, "ko")
        XCTAssertEqual(SpokenLanguageResolver.pairLabel(settings: settings), "English → Korean")
    }

    func testEitherWayCombinesPacksAndAttachesTheMissingDirection() {
        let english = TranslationLanguageCatalog.english
        let korean = TranslationLanguageCatalog.korean
        XCTAssertEqual(
            TheaterPairPacks.combined(forward: .installed, reverse: .supported, bidirectional: true),
            .supported
        )
        XCTAssertEqual(
            TheaterPairPacks.combined(forward: .installed, reverse: .supported, bidirectional: false),
            .installed
        )
        let reverseMissing = TheaterPairPacks.downloadPair(
            source: english,
            target: korean,
            forward: .installed,
            reverse: .supported,
            bidirectional: true
        )
        XCTAssertEqual(reverseMissing.source.id, "ko")
        XCTAssertEqual(reverseMissing.target.id, "en")
        let forwardMissing = TheaterPairPacks.downloadPair(
            source: english,
            target: korean,
            forward: .supported,
            reverse: .installed,
            bidirectional: true
        )
        XCTAssertEqual(forwardMissing.source.id, "en")
        XCTAssertEqual(forwardMissing.target.id, "ko")
        let oneWay = TheaterPairPacks.downloadPair(
            source: english,
            target: korean,
            forward: .installed,
            reverse: .supported,
            bidirectional: false
        )
        XCTAssertEqual(oneWay.source.id, "en")
        XCTAssertEqual(oneWay.target.id, "ko")
    }

    func testUnknownPackAllowsListenWhenMailboxIsReady() {
        XCTAssertEqual(
            TheaterPackListenGate.decision(availability: .installed, mailboxReady: false),
            .allow
        )
        XCTAssertEqual(
            TheaterPackListenGate.decision(availability: .unknown, mailboxReady: true),
            .allow
        )
        XCTAssertEqual(
            TheaterPackListenGate.decision(availability: .unknown, mailboxReady: false),
            .notReady
        )
        XCTAssertEqual(
            TheaterPackListenGate.decision(availability: .supported, mailboxReady: true),
            .needDownload
        )
        XCTAssertEqual(
            TheaterPackListenGate.decision(availability: .unsupported, mailboxReady: true),
            .unsupported
        )
    }

    func testTalkPackExtractsRepeatedNamesFromNotes() {
        let notes = """
        Q3 Review
        We will demo fluidSubtitles in Keynote today.
        fluidSubtitles stays on this Mac.
        Keynote is the deck.
        Nemotron hears Thai.
        Nemotron stays local.
        매출목표
        매출목표
        """
        let terms = TheaterTalkPack.extractTerms(from: notes)
        XCTAssertTrue(terms.contains("fluidSubtitles"), "terms=\(terms)")
        XCTAssertTrue(terms.contains("Keynote"))
        XCTAssertTrue(terms.contains("Nemotron"))
        XCTAssertTrue(terms.contains("매출목표"))
        XCTAssertTrue(terms.contains("Q3") || terms.contains("Q3 Review"))
        XCTAssertFalse(terms.contains("today"))
        XCTAssertFalse(terms.contains("Review"))
        XCTAssertFalse(terms.contains("Welcome"))
        XCTAssertFalse(terms.contains("stays"))
        XCTAssertFalse(terms.contains("local"))
        XCTAssertLessThanOrEqual(terms.count, TheaterTalkPack.maxTerms)
    }

    func testTalkPackIgnoresSlideChromeAndSentenceStarts() {
        let notes = """
        Thank You
        Next Steps
        Welcome
        This Mac stays local.
        Please use real-time captions
        Satoshi Nakamoto built Bitcoin.
        Seoul National University
        """
        let terms = TheaterTalkPack.extractTerms(from: notes)
        XCTAssertTrue(terms.contains("Satoshi Nakamoto"), "terms=\(terms)")
        XCTAssertTrue(terms.contains("Seoul National University"))
        XCTAssertFalse(terms.contains(where: { $0.contains("\n") }), "terms=\(terms)")
        XCTAssertFalse(terms.contains("Thank You"))
        XCTAssertFalse(terms.contains("Next Steps"))
        XCTAssertFalse(terms.contains("Welcome"))
        XCTAssertFalse(terms.contains("This Mac"))
        XCTAssertFalse(terms.contains("real-time"))
        XCTAssertFalse(terms.contains("Bitcoin"))
    }

    func testTalkPackKeepsKoreanNamesNotSentences() {
        let notes = """
        오늘 발표
        이재용 회장이 삼성전자 실적을 설명합니다.
        매출목표는 전년 대비 성장입니다.
        그리고 그리고 그리고
        서울대학교 연구팀이 참여했습니다.
        """
        let terms = TheaterTalkPack.extractTerms(from: notes)
        XCTAssertTrue(terms.contains("이재용"), "terms=\(terms)")
        XCTAssertTrue(terms.contains("삼성전자"))
        XCTAssertTrue(terms.contains("매출목표"))
        XCTAssertTrue(terms.contains("서울대학교"))
        XCTAssertFalse(terms.contains("그리고"))
        XCTAssertFalse(terms.contains(where: { $0.contains("설명합니다") }))
        XCTAssertFalse(terms.contains(where: { $0.count > 16 }))
    }

    func testTalkPackKeepsThaiPlaceNamesNotClauses() {
        let notes = """
        วันนี้เราจะพูดถึงกรุงเทพมหานคร
        กรุงเทพมหานคร เป็นเมืองหลวง
        ขอบคุณ ครับ ครับ
        """
        let terms = TheaterTalkPack.extractTerms(from: notes)
        XCTAssertTrue(terms.contains("กรุงเทพมหานคร"), "terms=\(terms)")
        XCTAssertFalse(terms.contains("ครับ"))
        XCTAssertFalse(terms.contains("ขอบคุณ"))
        XCTAssertFalse(terms.contains("เป็นเมืองหลวง"))
        XCTAssertFalse(terms.contains(where: { $0.count > 16 }))
    }

    func testGlossaryDoesNotLockAcronymsInsideWords() {
        let protected = TranslationGlossary.protect(
            "Nemotron hears Thai and it is available in title.",
            terms: ["AI", "IT"]
        )
        XCTAssertEqual(protected.text, "Nemotron hears Thai and it is available in title.")
        XCTAssertTrue(protected.tokens.isEmpty)

        let locked = TranslationGlossary.protect("We use AI in Thai class.", terms: ["AI"])
        XCTAssertFalse(locked.text.contains("AI"))
        XCTAssertEqual(
            TranslationGlossary.restore(locked.text, tokens: locked.tokens),
            "We use AI in Thai class."
        )
        XCTAssertFalse(
            TranslationGlossary.lostProtectedTerms(
                source: "Nemotron hears Thai.",
                polished: "Nemotron hears Thai.",
                terms: ["AI"]
            ).contains("AI")
        )
    }

    func testTalkPackReadsJSONNamesAndCapsTheList() throws {
        let json = try TheaterTalkPack.document(
            from: Data("[\"Keynote\",\"Nemotron\"]".utf8),
            fileName: "names.json"
        )
        XCTAssertEqual(Set(json.terms), ["Keynote", "Nemotron"])
        XCTAssertEqual(json.fileName, "names.json")

        let blob = (1...300)
            .map { "TermName\($0) TermName\($0)" }
            .joined(separator: "\n")
        XCTAssertEqual(TheaterTalkPack.extractTerms(from: blob).count, TheaterTalkPack.maxTerms)
    }

    func testTalkPackTermsJoinTheGlossaryUntilClear() {
        let settings = SettingsStore.shared
        let originalName = settings.theaterTalkPackFileName
        let originalTerms = settings.theaterTalkPackTerms
        defer {
            settings.theaterTalkPackFileName = originalName
            settings.theaterTalkPackTerms = originalTerms
        }

        settings.applyTheaterTalkPack(
            TheaterTalkPack.Document(fileName: "q3.txt", terms: ["Nemotron"], sourceCharacterCount: 12)
        )
        XCTAssertTrue(settings.hasTheaterTalkPack)
        XCTAssertTrue(TranslationGlossary.protectedTerms(from: settings).contains("Nemotron"))
        let protected = TranslationGlossary.protect("Nemotron hears Thai.", terms: TranslationGlossary.protectedTerms(from: settings))
        XCTAssertFalse(protected.text.contains("Nemotron"))
        XCTAssertEqual(
            TranslationGlossary.restore(protected.text, tokens: protected.tokens),
            "Nemotron hears Thai."
        )

        settings.clearTheaterTalkPack()
        XCTAssertFalse(settings.hasTheaterTalkPack)
        XCTAssertFalse(TranslationGlossary.protectedTerms(from: settings).contains("Nemotron"))
    }
}
