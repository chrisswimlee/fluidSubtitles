@testable import FluidSubtitles_Debug
import AppKit
import XCTest

/// Theater owns Listen, identity, and leftover peel. FluidVoice dictation
/// is not the caption host.
@MainActor
final class TheaterShellOwnershipTests: XCTestCase {
    func testCaptionPolicyKeepsShortUtterancesAndDropsAudio() {
        let captions = TheaterSpeechPolicy.captions()
        XCTAssertTrue(captions.boundLiveTranscript)
        XCTAssertTrue(captions.keepShortUtterances)
        XCTAssertTrue(captions.preferLatestChunk)
        XCTAssertFalse(captions.retainsAudio)
        XCTAssertTrue(captions.isSessionActive)
        XCTAssertFalse(captions.pausesMedia)
        XCTAssertFalse(captions.playsListenChime)
    }

    func testInsertPolicyKeepsAudioForHistory() {
        let insert = TheaterSpeechPolicy.insert()
        XCTAssertTrue(insert.boundLiveTranscript)
        XCTAssertTrue(insert.keepShortUtterances)
        XCTAssertTrue(insert.preferLatestChunk)
        XCTAssertTrue(insert.retainsAudio)
        XCTAssertFalse(insert.pausesMedia)
        XCTAssertFalse(insert.playsListenChime)
        XCTAssertEqual(TheaterSpeechPolicy.forKind(.captions), TheaterSpeechPolicy.captions())
        XCTAssertEqual(TheaterSpeechPolicy.forKind(.insert), insert)
    }

    func testListenAndTypeStaysBlockedUntilAccessibility() {
        XCTAssertTrue(
            DictationHotkeyCaptureStart.blocksListenAndType(enabled: true, accessibilityTrusted: false)
        )
        XCTAssertFalse(
            DictationHotkeyCaptureStart.blocksListenAndType(enabled: true, accessibilityTrusted: true)
        )
        XCTAssertFalse(
            DictationHotkeyCaptureStart.blocksListenAndType(enabled: false, accessibilityTrusted: false)
        )
        XCTAssertTrue(
            DictationHotkeyCaptureStart.shouldRequestSystemPrompt(alreadyRequested: false, trusted: false)
        )
        XCTAssertFalse(
            DictationHotkeyCaptureStart.shouldRequestSystemPrompt(alreadyRequested: true, trusted: false)
        )
        XCTAssertFalse(
            DictationHotkeyCaptureStart.shouldRequestSystemPrompt(alreadyRequested: false, trusted: true)
        )
    }

    func testLegacyDictationShortcutLeavesTheMicrophoneIdle() {
        XCTAssertEqual(DictationHotkeyCaptureStart.resolve(hasCallback: false), .leaveMicrophoneIdle)
        XCTAssertEqual(DictationHotkeyCaptureStart.resolve(hasCallback: true), .invokeCallback)
        XCTAssertFalse(
            DictationHotkeyCaptureStart.releaseStopsCapture(holdMode: .transcription, theaterSessionActive: true)
        )
        XCTAssertFalse(
            DictationHotkeyCaptureStart.releaseStopsCapture(holdMode: .promptMode, theaterSessionActive: true)
        )
        XCTAssertTrue(
            DictationHotkeyCaptureStart.releaseStopsCapture(holdMode: .captionListen, theaterSessionActive: true)
        )
        XCTAssertTrue(
            DictationHotkeyCaptureStart.releaseStopsCapture(holdMode: .translateInsert, theaterSessionActive: true)
        )
        XCTAssertTrue(
            DictationHotkeyCaptureStart.releaseStopsCapture(holdMode: .transcription, theaterSessionActive: false)
        )
    }

    func testMainWindowTitleIsTheShellNotTheater() {
        XCTAssertTrue(MainWindowReveal.matchesTitle(FluidProduct.displayName))
        XCTAssertFalse(MainWindowReveal.matchesTitle("\(FluidProduct.displayName) Theater"))
        XCTAssertFalse(MainWindowReveal.matchesTitle("Settings"))
        XCTAssertFalse(MainWindowReveal.matchesTitle("FluidVoice"))
    }

    func testTheaterRecordingModeIsNotDictation() {
        XCTAssertFalse(LiveTranslationController.shared.isSessionActive)
    }

    func testCaptionListenIsItsOwnHoldMode() {
        XCTAssertNotEqual(HotkeyHoldModeType.captionListen, .transcription)
        XCTAssertNotEqual(HotkeyHoldModeType.captionListen, .translateInsert)
        XCTAssertNotEqual(HotkeyHoldModeType.captionListen, .promptMode)
    }

    func testFirstCommitKeepsTheColdAppleTimeout() {
        XCTAssertEqual(
            LiveTranslationTiming.translateClauseTimeoutNanoseconds,
            LiveTranslationTiming.commitMailboxTimeoutNanoseconds
        )
        XCTAssertEqual(
            LiveTranslationTiming.mailboxTimeoutNanoseconds(for: .firstCommit),
            LiveTranslationTiming.translateClauseTimeoutNanoseconds
        )
        XCTAssertEqual(
            LiveTranslationTiming.mailboxTimeoutNanoseconds(for: .commit),
            LiveTranslationTiming.commitMailboxTimeoutNanoseconds
        )
        XCTAssertTrue(TranslationRequestKind.firstCommit.occupiesCommitSlot)
        XCTAssertTrue(TranslationRequestKind.commit.occupiesCommitSlot)
        XCTAssertFalse(TranslationRequestKind.live.occupiesCommitSlot)
    }

    func testRemainingAfterCommittedUnitKeepsCJKLeftover() {
        XCTAssertEqual(
            LiveTranslationSubscriber.remainingAfterCommittedUnit(
                "오늘",
                in: "오늘 모델을 학습했습니다"
            ),
            "모델을 학습했습니다"
        )
        XCTAssertEqual(
            LiveTranslationSubscriber.remainingAfterCommittedUnit(
                "今日は",
                in: "今日は学習しました"
            ),
            "学習しました"
        )
        XCTAssertEqual(
            LiveTranslationSubscriber.remainingAfterCommittedUnit(
                "missing",
                in: "남은 문장입니다"
            ),
            "남은 문장입니다"
        )
        XCTAssertEqual(
            LiveTranslationSubscriber.remainingAfterCommittedUnit("", in: "still here"),
            "still here"
        )
    }

    func testMicrophoneAlertsAreFluidSubtitlesOnly() {
        XCTAssertTrue(
            MicrophoneChangeOverlayController.supportsAlerts(
                bundleIdentifier: FluidProduct.bundleIdentifier
            )
        )
        XCTAssertTrue(
            MicrophoneChangeOverlayController.supportsAlerts(
                bundleIdentifier: "\(FluidProduct.bundleIdentifier).debug"
            )
        )
        XCTAssertFalse(
            MicrophoneChangeOverlayController.supportsAlerts(bundleIdentifier: "com.FluidApp.app")
        )
        XCTAssertFalse(
            MicrophoneChangeOverlayController.supportsAlerts(bundleIdentifier: "com.FluidApp.app.debug")
        )
        XCTAssertFalse(MicrophoneChangeOverlayController.supportsAlerts(bundleIdentifier: nil))
    }

    func testLegacySupportFolderIsNotStolenFromFluidVoice() {
        XCTAssertTrue(
            AppSupportDirectory.shouldRenameLegacyFolder(
                named: "connectingCaptions",
                fluidVoiceInstalled: true
            )
        )
        XCTAssertFalse(
            AppSupportDirectory.shouldRenameLegacyFolder(
                named: FluidProduct.legacySupportFolderName,
                fluidVoiceInstalled: true
            )
        )
        XCTAssertFalse(
            AppSupportDirectory.shouldRenameLegacyFolder(
                named: FluidProduct.legacySupportFolderName,
                fluidVoiceInstalled: false
            )
        )
    }

    func testSettingsSearchDropsFluidVoiceAlias() {
        XCTAssertFalse(
            SettingsSearchIndex.results(for: "FluidVoice").contains { $0.target == .theaterAppearance }
        )
        XCTAssertFalse(
            SettingsSearchIndex.results(for: "fluidvoice").contains { $0.target == .theaterAppearance }
        )
    }

    func testProductSectionsHideDictation() {
        XCTAssertFalse(SettingsSection.productSections.contains(.dictation))
        XCTAssertTrue(SettingsSection.productSections.contains(.translation))
        XCTAssertTrue(SettingsSection.allCases.contains(.dictation))
    }


    func testBeginSessionDoesNotAlignSpokenEngine() {
        let controller = LiveTranslationController.shared
        let before = controller.alignSpokenEngineCallCountForTesting
        controller.beginSession(kind: .captions)
        XCTAssertEqual(controller.alignSpokenEngineCallCountForTesting, before)
        controller.cancelSession()
    }

    func testListenStartFailedUnlocksTheNextStart() {
        let controller = LiveTranslationController.shared
        let previousInsert = controller.onStartInsertListening
        let previousCaption = controller.onStartCaptionListening
        defer {
            controller.onStartInsertListening = previousInsert
            controller.onStartCaptionListening = previousCaption
            controller.listenStartFailed()
            controller.cancelSession()
        }
        var starts = 0
        controller.onStartInsertListening = { starts += 1 }
        controller.startInsertListening()
        XCTAssertEqual(starts, 1)
        controller.startInsertListening()
        XCTAssertEqual(starts, 1, "A busy start must not enqueue a second Listen")
        controller.listenStartFailed()
        controller.startInsertListening()
        XCTAssertEqual(starts, 2, "listenStartFailed must unlock the next Listen")
        controller.listenStartFailed()
    }

    func testSpokenSendStaysOffTheCaptionPath() {
        XCTAssertNil(LiveTranslationController.shared.listenKind)
    }

}

