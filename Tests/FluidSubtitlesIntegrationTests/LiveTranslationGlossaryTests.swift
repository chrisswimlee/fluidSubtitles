import AppKit
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
        XCTAssertEqual(TranslationLanguageCatalog.language(matchingSpokenID: "en").id, "en")
    }

    func testUnsupportedSpokenLanguagesFallBackToEnglish() {
        XCTAssertNil(TranslationLanguageCatalog.language(id: "ja"))
        XCTAssertNil(TranslationLanguageCatalog.language(id: "zh-TW"))
        XCTAssertEqual(TranslationLanguageCatalog.language(matchingSpokenID: "ja-JP").id, "en")
        XCTAssertEqual(TranslationLanguageCatalog.language(matchingSpokenID: "zh-CN").id, "en")
    }

    func testLanguagesFromAppleListStayKoreanEnglishThai() {
        let languages = TranslationLanguageCatalog.languages(from: [
            Locale.Language(identifier: "en-IN"),
            Locale.Language(identifier: "en"),
            Locale.Language(identifier: "th"),
            Locale.Language(identifier: "ko"),
            Locale.Language(identifier: "ja"),
            Locale.Language(identifier: "vi"),
        ])
        XCTAssertEqual(languages.map(\.id), ["en", "ko", "th"])
    }

    func testVoiceEngineLanguagesAreKoreanEnglishThai() {
        XCTAssertEqual(
            Set(VoiceEngineLanguageCatalog.allLanguages().map(\.id)),
            ["en", "ko", "th"]
        )
    }

    func testDefaultTargetAvoidsTheSpokenLanguage() {
        XCTAssertEqual(
            TranslationLanguageCatalog.defaultTarget(forSource: TranslationLanguageCatalog.english).id,
            "ko"
        )
        XCTAssertEqual(
            TranslationLanguageCatalog.defaultTarget(forSource: TranslationLanguageCatalog.korean).id,
            "en"
        )
        XCTAssertEqual(
            TranslationLanguageCatalog.defaultTarget(forSource: TranslationLanguageCatalog.thai).id,
            "en"
        )
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

    func testSetSourceLanguageLeavesEnglishOnlyEnginesForKorean() {
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
        XCTAssertNotEqual(settings.selectedSpeechModel, .parakeetRealtime)
        XCTAssertNotEqual(settings.selectedSpeechModel, .parakeetTDTv2)
        XCTAssertTrue(VoiceEngineLanguageCatalog.supports(settings.selectedSpeechModel, languageID: "ko"))
        XCTAssertTrue(SpokenLanguageResolver.voiceEngineSupportsSource(settings: settings))
        XCTAssertTrue(
            SpokenLanguageResolver.stageEngineSummary(settings: settings).contains("Korean")
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
            ["en", "ko", "th"]
        )

        SpokenLanguageResolver.setSourceLanguage(TranslationLanguageCatalog.korean, settings: settings)
        settings.translationTargetLanguageID = "ko"
        SpokenLanguageResolver.setSourceLanguage(TranslationLanguageCatalog.korean, settings: settings)
        XCTAssertEqual(settings.translationTargetLanguageID, "ko")
    }

    @MainActor
    func testSameLanguageControllerDoesNotSwapOrRequireAPack() async {
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
    func testListenAutoSwitchesKoreanOffEnglishOnlyEngines() async {
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
        XCTAssertTrue(ready)
        XCTAssertNotEqual(settings.selectedSpeechModel, .parakeetRealtime)
        XCTAssertTrue(VoiceEngineLanguageCatalog.supports(settings.selectedSpeechModel, languageID: "ko"))
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
            "Parakeet Flash and TDT v2 only hear English. Theater will switch to Apple Speech or Whisper for Thai."
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
        XCTAssertEqual(
            SpokenLanguageHints.orderedIDs(primaryID: "ko", alsoHearOthers: true),
            ["ko", "en", "th"]
        )
        XCTAssertNil(SpokenLanguageHints.whisperLanguageCode(stored: "ko", alsoHearOthers: true))
        XCTAssertEqual(SpokenLanguageHints.whisperLanguageCode(stored: "ko", alsoHearOthers: false), "ko")
    }

    func testTheaterHidesFromScreenShareWithSharingTypeNone() {
        XCTAssertEqual(TheaterWindowSharing.sharingType(hideFromScreenShare: true), .none)
        XCTAssertEqual(TheaterWindowSharing.sharingType(hideFromScreenShare: false), .readOnly)
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
}
