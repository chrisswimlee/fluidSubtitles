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
        XCTAssertTrue(TheaterSpokenLineMode.whileTalking.translatesLive)
        XCTAssertTrue(TheaterSpokenLineMode.afterPause.holdsTranslationUntilPause)
        XCTAssertFalse(TheaterSpokenLineMode.off.translatesLive)
        XCTAssertFalse(TheaterSpokenLineMode.off.holdsTranslationUntilPause)
        XCTAssertTrue(TheaterSpokenLineMode.afterPause.help.contains("original language"))
        XCTAssertTrue(TheaterSpokenLineMode.whileTalking.help.contains("original language"))
    }

    func testExistingOnboardingUsersSkipTheWizardUntilTheyOpenIt() {
        let settings = SettingsStore.shared
        let previousWizard = settings.theaterSetupWizardCompleted
        let previousStep = settings.theaterSetupWizardStep
        let previousOnboarding = settings.onboardingCompleted
        defer {
            settings.theaterSetupWizardCompleted = previousWizard
            settings.theaterSetupWizardStep = previousStep
            settings.onboardingCompleted = previousOnboarding
        }

        settings.onboardingCompleted = true
        settings.defaults.removeObject(forKey: "TheaterSetupWizardCompleted")
        settings.bootstrapSetupWizardState()

        XCTAssertTrue(settings.theaterSetupWizardCompleted)
        XCTAssertFalse(settings.shouldShowSetupWizard)
    }

    func testFreshInstallShowsTheWizardAfterOnboarding() {
        let settings = SettingsStore.shared
        let previousWizard = settings.theaterSetupWizardCompleted
        let previousStep = settings.theaterSetupWizardStep
        let previousOnboarding = settings.onboardingCompleted
        defer {
            settings.theaterSetupWizardCompleted = previousWizard
            settings.theaterSetupWizardStep = previousStep
            settings.onboardingCompleted = previousOnboarding
        }

        settings.onboardingCompleted = false
        settings.defaults.removeObject(forKey: "TheaterSetupWizardCompleted")
        settings.bootstrapSetupWizardState()

        XCTAssertFalse(settings.theaterSetupWizardCompleted)
        XCTAssertFalse(settings.shouldShowSetupWizard)

        settings.onboardingCompleted = true
        XCTAssertTrue(settings.shouldShowSetupWizard)

        settings.theaterSetupWizardStep = 3
        XCTAssertEqual(settings.theaterSetupWizardStep, TheaterSetupWizard.Step.audience.rawValue)
        settings.completeSetupWizard()
        XCTAssertFalse(settings.shouldShowSetupWizard)
        XCTAssertEqual(settings.theaterSetupWizardStep, 0)

        settings.startSetupWizard()
        XCTAssertTrue(settings.shouldShowSetupWizard)
        XCTAssertEqual(settings.theaterSetupWizardStep, 0)
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

        settings.theaterSpokenLineMode = .whileTalking
        XCTAssertEqual(settings.theaterSpokenLineMode, .whileTalking)
        XCTAssertTrue(settings.translationShowSource)
        XCTAssertTrue(TheaterSpokenLineMode.whileTalking.printsLiveSpoken)
        XCTAssertFalse(TheaterSpokenLineMode.afterPause.printsLiveSpoken)
    }

    func testAfterPauseHidesLiveSpokenAndWhileTalkingKeepsCommittedSources() {
        let whileTalking = TheaterCaptionFlow.lines(
            committed: ["안녕."],
            committedIDs: [1],
            committedSources: ["Hello we trained"],
            draft: "",
            sourceDraft: "And we shipped it",
            spokenDisplay: .paired
        )
        XCTAssertEqual(whileTalking.map(\.text), ["안녕."])
        XCTAssertEqual(whileTalking.map(\.source), ["Hello we trained"])
        XCTAssertFalse(whileTalking.contains { $0.source == "And we shipped it" })

        let afterPause = TheaterCaptionFlow.lines(
            committed: ["안녕."],
            committedIDs: [1],
            committedSources: ["Hello we trained"],
            draft: "",
            sourceDraft: "And we shipped it",
            spokenDisplay: .pairedAfterPause
        )
        XCTAssertEqual(afterPause.map(\.text), ["안녕."])
        XCTAssertEqual(afterPause.map(\.source), ["Hello we trained"])
        XCTAssertFalse(afterPause.contains { $0.source == "And we shipped it" })

        let afterPauseTitle = TheaterCaptionFlow.lines(
            committed: ["안녕."],
            committedIDs: [1],
            committedSources: ["Hello we trained"],
            draft: "그리고 출시했습니다",
            sourceDraft: "And we shipped it",
            spokenDisplay: .pairedAfterPause
        )
        XCTAssertEqual(afterPauseTitle.map(\.text), ["안녕."])
        XCTAssertEqual(afterPauseTitle.last?.source, "Hello we trained")
        XCTAssertFalse(afterPauseTitle.contains { $0.isDraft })

        let afterPausePending = TheaterCaptionFlow.lines(
            committed: [],
            draft: "",
            sourceDraft: "And we shipped it",
            pendingSources: ["Today we trained the model."],
            spokenDisplay: .pairedAfterPause
        )
        XCTAssertTrue(afterPausePending.isEmpty)

        let afterPauseCommitted = TheaterCaptionFlow.lines(
            committed: ["안녕."],
            committedIDs: [1],
            committedSources: ["Hello we trained"],
            draft: "",
            sourceDraft: "",
            spokenDisplay: .pairedAfterPause
        )
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
