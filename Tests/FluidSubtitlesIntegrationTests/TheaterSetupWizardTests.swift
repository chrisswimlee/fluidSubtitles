@testable import FluidSubtitles_Debug
import XCTest

@MainActor
final class TheaterSetupWizardTests: XCTestCase {
    func testWizardStepsWalkInOrder() {
        XCTAssertEqual(
            TheaterSetupWizard.Step.allCases.map(\.title),
            ["Welcome", "Languages", "Captions", "Audience", "Ready"]
        )
        XCTAssertEqual(TheaterSetupWizard.Step.welcome.next, .languages)
        XCTAssertEqual(TheaterSetupWizard.Step.captions.previous, .languages)
        XCTAssertNil(TheaterSetupWizard.Step.ready.next)
        XCTAssertEqual(TheaterSetupWizard.Step.ready.continueTitle, "Finish")
        XCTAssertEqual(
            TheaterSetupWizard.Step.welcome.subtitle,
            "A preview of the caption the room sees."
        )
        XCTAssertTrue(TheaterSetupWizard.Step.ready.subtitle.contains("open Theater"))
        XCTAssertTrue(TheaterReadiness.screenShareIncluded.contains("Screenshots"))
        XCTAssertTrue(TheaterReadiness.screenShare.contains("Share the slides window"))
        XCTAssertEqual(TheaterSetupWizard.Step.resolved(99), .welcome)
        XCTAssertEqual(TheaterSetupWizard.progress(for: .welcome), 0, accuracy: 0.001)
        XCTAssertEqual(TheaterSetupWizard.progress(for: .ready), 1, accuracy: 0.001)
    }

    func testSpokenLineCopyNamesPauseAndFinishedSentence() {
        XCTAssertTrue(TheaterReadiness.spokenLineTranslate.contains("original language"))
        XCTAssertTrue(TheaterReadiness.spokenLineSetupNote.contains("original language"))
        XCTAssertTrue(TheaterSetupWizard.welcomeDetail.contains("original language"))
        XCTAssertEqual(TheaterSetupWizard.accentTitle, "Accent color")
        XCTAssertTrue(TheaterSetupWizard.accentDetail.contains("Caption gold"))
        XCTAssertTrue(TheaterChromeHelp.spokenLine.contains("original language"))
        XCTAssertFalse(TheaterSpokenLineMode.off.showsSpokenLine)
        XCTAssertTrue(TheaterSpokenLineMode.afterPause.showsSpokenLine)
        XCTAssertEqual(TheaterSpokenLineMode.afterPause.displayName, "On the board")
        XCTAssertEqual(TheaterSpokenLineMode.resolved("whileTalking"), .afterPause)
        XCTAssertFalse(TheaterSpokenLineMode.allCases.map(\.displayName).contains("Board and Insert"))
        XCTAssertEqual(TheaterLinePrint.resolved(nil), .atOnce)
        XCTAssertEqual(TheaterCaptionSpacing.resolved(nil), 14)
        XCTAssertEqual(TheaterCaptionSpacing.resolved(0), 0)
        XCTAssertEqual(TheaterCaptionSpacing.resolved(48), 48)
        XCTAssertEqual(TheaterCaptionSpacing.resolved(-4), 0)
        XCTAssertEqual(TheaterCaptionSpacing.resolved(80), 48)
        XCTAssertEqual(TheaterLinePrint.resolved("word"), .word)
        XCTAssertTrue(TheaterSpokenLineMode.afterPause.help.contains("when the sentence is ready"))
        XCTAssertFalse(TheaterSpokenLineMode.afterPause.help.contains("notch"))
    }

    func testExistingOnboardingUsersSkipTheWizardUntilTheyOpenIt() {
        let settings = SettingsStore.shared
        let previousWizard = settings.theaterSetupWizardCompleted
        let previousOpened = settings.theaterSetupWizardOpened
        let previousStep = settings.theaterSetupWizardStep
        let previousOnboarding = settings.onboardingCompleted
        defer {
            settings.theaterSetupWizardCompleted = previousWizard
            settings.theaterSetupWizardOpened = previousOpened
            settings.theaterSetupWizardStep = previousStep
            settings.onboardingCompleted = previousOnboarding
        }

        settings.onboardingCompleted = true
        settings.defaults.removeObject(forKey: "TheaterSetupWizardCompleted")
        settings.bootstrapSetupWizardState()

        XCTAssertTrue(settings.theaterSetupWizardCompleted)
        XCTAssertFalse(settings.shouldShowSetupWizard)
    }

    func testFreshInstallSkipsTheWizardUntilOpened() {
        let settings = SettingsStore.shared
        let previousWizard = settings.theaterSetupWizardCompleted
        let previousOpened = settings.theaterSetupWizardOpened
        let previousStep = settings.theaterSetupWizardStep
        let previousOnboarding = settings.onboardingCompleted
        defer {
            settings.theaterSetupWizardCompleted = previousWizard
            settings.theaterSetupWizardOpened = previousOpened
            settings.theaterSetupWizardStep = previousStep
            settings.onboardingCompleted = previousOnboarding
        }

        settings.onboardingCompleted = false
        settings.defaults.removeObject(forKey: "TheaterSetupWizardCompleted")
        settings.bootstrapSetupWizardState()

        XCTAssertTrue(settings.theaterSetupWizardCompleted)
        XCTAssertFalse(settings.shouldShowSetupWizard)

        settings.onboardingCompleted = true
        XCTAssertFalse(settings.shouldShowSetupWizard)

        settings.startSetupWizard()
        XCTAssertTrue(settings.shouldShowSetupWizard)
        XCTAssertEqual(settings.theaterSetupWizardStep, 0)

        settings.theaterSetupWizardStep = 3
        XCTAssertEqual(settings.theaterSetupWizardStep, TheaterSetupWizard.Step.audience.rawValue)
        settings.completeSetupWizard()
        XCTAssertFalse(settings.shouldShowSetupWizard)
        XCTAssertEqual(settings.theaterSetupWizardStep, 0)
    }

    func testWelcomeHandoffDoesNotReopenTheWizard() {
        let settings = SettingsStore.shared
        let previousWizard = settings.theaterSetupWizardCompleted
        let previousOpened = settings.theaterSetupWizardOpened
        let previousStep = settings.theaterSetupWizardStep
        defer {
            settings.theaterSetupWizardCompleted = previousWizard
            settings.theaterSetupWizardOpened = previousOpened
            settings.theaterSetupWizardStep = previousStep
        }

        settings.defaults.set(false, forKey: "TheaterSetupWizardCompleted")
        settings.defaults.set(0, forKey: "TheaterSetupWizardStep")
        settings.bootstrapSetupWizardState()
        XCTAssertTrue(settings.theaterSetupWizardCompleted)
        XCTAssertFalse(settings.shouldShowSetupWizard)

        settings.startSetupWizard()
        settings.theaterSetupWizardStep = TheaterSetupWizard.Step.captions.rawValue
        settings.defaults.set(false, forKey: "TheaterSetupWizardCompleted")
        settings.bootstrapSetupWizardState()
        XCTAssertTrue(settings.theaterSetupWizardOpened)
        XCTAssertFalse(settings.theaterSetupWizardCompleted)
        XCTAssertEqual(settings.theaterSetupWizardStep, TheaterSetupWizard.Step.captions.rawValue)
    }

    func testUnopenedWizardClosesEvenPastWelcome() {
        let settings = SettingsStore.shared
        let previousWizard = settings.theaterSetupWizardCompleted
        let previousOpened = settings.theaterSetupWizardOpened
        let previousStep = settings.theaterSetupWizardStep
        defer {
            settings.theaterSetupWizardCompleted = previousWizard
            settings.theaterSetupWizardOpened = previousOpened
            settings.theaterSetupWizardStep = previousStep
        }

        settings.defaults.set(false, forKey: "TheaterSetupWizardCompleted")
        settings.defaults.set(false, forKey: "TheaterSetupWizardOpened")
        settings.defaults.set(TheaterSetupWizard.Step.captions.rawValue, forKey: "TheaterSetupWizardStep")
        settings.bootstrapSetupWizardState()
        XCTAssertTrue(settings.theaterSetupWizardCompleted)
        XCTAssertFalse(settings.shouldShowSetupWizard)
    }

    func testPreferredOnboardingRouteMatchesTheMacDefault() {
        let route = VoiceEngineLanguageCatalog.preferredOnboardingRoute(forLanguageID: "en")
        XCTAssertEqual(route?.model, SettingsStore.SpeechModel.defaultModel)
        XCTAssertEqual(route?.language.id, "en")
    }

    func testSpokenLineModeMigratesTheOldToggle() {
        let settings = SettingsStore.shared
        let previousMode = settings.theaterSpokenLineMode
        defer { settings.theaterSpokenLineMode = previousMode }

        settings.defaults.removeObject(forKey: "TheaterSpokenLineMode")
        settings.defaults.set(false, forKey: "TranslationShowSource")
        XCTAssertEqual(settings.theaterSpokenLineMode, .off)

        settings.defaults.removeObject(forKey: "TheaterSpokenLineMode")
        settings.defaults.set(true, forKey: "TranslationShowSource")
        XCTAssertEqual(settings.theaterSpokenLineMode, .afterPause)

        settings.defaults.set("whileTalking", forKey: "TheaterSpokenLineMode")
        XCTAssertEqual(settings.theaterSpokenLineMode, .afterPause)
        XCTAssertTrue(settings.translationShowSource)
    }

    func testAfterPauseHidesLiveSpokenAndWhileTalkingKeepsCommittedSources() {
        let whileTalking = TheaterCaptionFlow.lines(board: .make(translated: ["안녕."], sources: ["Hello we trained"], ids: [1]))
        XCTAssertEqual(whileTalking.map(\.text), ["안녕."])
        XCTAssertEqual(whileTalking.map(\.source), ["Hello we trained"])
        XCTAssertFalse(whileTalking.contains { $0.source == "And we shipped it" })

        let afterPause = TheaterCaptionFlow.lines(board: .make(translated: ["안녕."], sources: ["Hello we trained"], ids: [1]))
        XCTAssertEqual(afterPause.map(\.text), ["안녕."])
        XCTAssertEqual(afterPause.map(\.source), ["Hello we trained"])
        XCTAssertFalse(afterPause.contains { $0.source == "And we shipped it" })

        let afterPauseTitle = TheaterCaptionFlow.lines(board: .make(translated: ["안녕."], sources: ["Hello we trained"], ids: [1]))
        XCTAssertEqual(afterPauseTitle.map(\.text), ["안녕."])
        XCTAssertEqual(afterPauseTitle.last?.source, "Hello we trained")
        XCTAssertFalse(afterPauseTitle.contains { $0.isDraft })

        let afterPausePending = TheaterCaptionFlow.lines(board: .make(translated: []))
        XCTAssertTrue(afterPausePending.isEmpty)

        let afterPauseCommitted = TheaterCaptionFlow.lines(board: .make(translated: ["안녕."], sources: ["Hello we trained"], ids: [1]))
        XCTAssertEqual(afterPauseCommitted.last?.source, "Hello we trained")
    }

    func testBoardPreviewHidesSpokenWhenOffOrVoice() {
        let paired = TheaterBoardPreview.lines(
            session: .translation,
            spokenDisplay: .pairedAfterPause,
            sourceName: "English",
            targetName: "Korean"
        )
        XCTAssertEqual(paired.title, "Korean")
        XCTAssertEqual(paired.spoken, "English")

        let hidden = TheaterBoardPreview.lines(
            session: .translation,
            spokenDisplay: .hidden,
            sourceName: "English",
            targetName: "Korean"
        )
        XCTAssertEqual(hidden.title, "Korean")
        XCTAssertNil(hidden.spoken)

        let voice = TheaterBoardPreview.lines(
            session: .transcription,
            spokenDisplay: .paired,
            sourceName: "English",
            targetName: "Korean"
        )
        XCTAssertEqual(voice.title, "English")
        XCTAssertNil(voice.spoken)

        let same = TheaterBoardPreview.lines(
            session: .translation,
            spokenDisplay: .isTheCaption,
            sourceName: "English",
            targetName: "English"
        )
        XCTAssertEqual(same.title, "English")
        XCTAssertNil(same.spoken)

        XCTAssertTrue(TheaterReadiness.boardIdle.contains("Listen"))
        XCTAssertTrue(TheaterReadiness.boardListening.contains("Listening"))
    }
}
