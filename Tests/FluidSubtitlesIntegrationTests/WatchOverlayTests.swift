import AppKit
import AVFoundation
import CoreAudio
import XCTest
@testable import FluidSubtitles_Debug

final class WatchOverlayTests: XCTestCase {
    func testReadyGateWatchIgnoresMicrophoneAndNeedsScreenRecording() {
        let watchDenied = TheaterReadyGate.snapshot(
            engineSupportsSource: true,
            modelInstalled: true,
            sameLanguagePair: true,
            pack: .unknown,
            microphone: .denied,
            firstCaptionPrinted: false,
            mode: .watch,
            screenRecordingAllowed: false
        )
        XCTAssertFalse(watchDenied.canListen)
        XCTAssertTrue(watchDenied.nextAction.contains("Screen Recording"))
        XCTAssertTrue(watchDenied.nextAction.contains("reopen"))
        XCTAssertTrue(TheaterReadiness.gettingStartedOpenDetail.contains("Screen Recording"))
        XCTAssertTrue(TheaterReadiness.gettingStartedMicrophone.contains("Lectern"))

        let watchReady = TheaterReadyGate.snapshot(
            engineSupportsSource: true,
            modelInstalled: true,
            sameLanguagePair: true,
            pack: .unknown,
            microphone: .denied,
            firstCaptionPrinted: true,
            mode: .watch,
            screenRecordingAllowed: true
        )
        XCTAssertTrue(watchReady.canListen)
        XCTAssertTrue(watchReady.isFullyReady)

        let needsMacOS26 = TheaterReadyGate.snapshot(
            engineSupportsSource: true,
            modelInstalled: true,
            sameLanguagePair: true,
            pack: .installed,
            microphone: .authorized,
            firstCaptionPrinted: true,
            mode: .watch,
            screenRecordingAllowed: true,
            osSupported: false
        )
        XCTAssertFalse(needsMacOS26.canListen)
        XCTAssertEqual(needsMacOS26.nextAction, TheaterAvailability.unsupportedCopy)
    }

    func testJunkGateDropsBoilerplateAndPhraseLoops() {
        XCTAssertTrue(CaptionJunkGate.shouldDrop("Thanks for watching."))
        XCTAssertTrue(CaptionJunkGate.shouldDrop("감사합니다 감사합니다 감사합니다"))
        XCTAssertTrue(CaptionJunkGate.hasPhraseRepeat("hello hello hello"))
        XCTAssertFalse(CaptionJunkGate.shouldDrop("ㅋㅋㅋㅋ"))
        XCTAssertFalse(CaptionJunkGate.shouldDrop("ㅎㅎㅎ"))
        XCTAssertFalse(CaptionJunkGate.shouldDrop("진짜진짜"))
        XCTAssertFalse(CaptionJunkGate.shouldDrop("มากๆ"))
        XCTAssertFalse(CaptionJunkGate.shouldDrop("네."))
        XCTAssertFalse(CaptionJunkGate.shouldDrop("ครับ"))
        XCTAssertFalse(CaptionJunkGate.shouldDrop("Yes."))
        XCTAssertFalse(CaptionJunkGate.shouldDrop("오늘 모델을 학습했습니다."))
    }

    func testHowlGateFindsADelayedCopyAndFailsOpenOnUncorrelatedAudio() {
        let probe = Self.noise(count: 256, seed: 7)
        var reference = [Float](repeating: 0, count: 256 + 400 + 256)
        reference.replaceSubrange(0..<256, with: probe)
        reference.replaceSubrange(656..<912, with: probe)
        let peak = WatchFeedbackGate.peakCorrelation(
            probe: probe,
            reference: reference,
            sampleRate: 48_000
        )
        XCTAssertGreaterThan(peak.rho, 0.95)
        XCTAssertEqual(peak.lag, 656)

        let other = Self.noise(count: 256 + 800, seed: 99)
        let miss = WatchFeedbackGate.peakCorrelation(
            probe: probe,
            reference: other + probe,
            sampleRate: 48_000
        )
        XCTAssertLessThan(miss.rho, 0.55)

        let first = WatchFeedbackGate.shouldDrop(
            rho: 0.92,
            lag: 400,
            previousLag: 400,
            consecutiveHits: 2,
            probeEnergy: 0.02,
            previousEnergy: 0.018,
            aggressive: false
        )
        XCTAssertTrue(first.drop)

        let open = WatchFeedbackGate.shouldDrop(
            rho: 0.2,
            lag: 400,
            previousLag: nil,
            consecutiveHits: 0,
            probeEnergy: 0.02,
            previousEnergy: 0.01,
            aggressive: false
        )
        XCTAssertFalse(open.drop)

        XCTAssertTrue(
            WatchOutputRoute.looksLikeLoopbackOrAggregate(
                AudioDevice.Device(
                    id: 1,
                    uid: "BlackHole2ch_UID",
                    name: "BlackHole 2ch",
                    hasInput: true,
                    hasOutput: true,
                    transportType: kAudioDeviceTransportTypeVirtual
                )
            )
        )
        XCTAssertFalse(
            WatchOutputRoute.looksLikeLoopbackOrAggregate(
                AudioDevice.Device(
                    id: 2,
                    uid: "BuiltInSpeakerDevice",
                    name: "MacBook Pro Speakers",
                    hasInput: false,
                    hasOutput: true,
                    transportType: kAudioDeviceTransportTypeBuiltIn
                )
            )
        )
    }

    private static func noise(count: Int, seed: UInt64) -> [Float] {
        var rng = seed
        return (0..<count).map { _ in
            rng = rng &* 1_664_525 &+ 1_013_904_223
            return Float(Int(rng % 2_000) - 1_000) / 2_000
        }
    }

    func testNonInterleavedStereoDownmixAveragesChannels() {
        let left = UnsafeMutablePointer<Float>.allocate(capacity: 4)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: 4)
        defer {
            left.deallocate()
            right.deallocate()
        }
        left.initialize(repeating: 1, count: 4)
        right.initialize(repeating: 0, count: 4)
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(list.unsafeMutablePointer) }
        list.count = 2
        list[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(4 * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(left)
        )
        list[1] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(4 * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(right)
        )
        var asbd = AudioStreamBasicDescription()
        asbd.mSampleRate = 48_000
        asbd.mFormatID = kAudioFormatLinearPCM
        asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved
        asbd.mBitsPerChannel = 32
        asbd.mChannelsPerFrame = 2
        asbd.mFramesPerPacket = 1
        let mono = SystemAudioDownmix.monoSamples(
            asbd: asbd,
            bufferList: UnsafePointer(list.unsafeMutablePointer),
            frameCount: 4
        )
        XCTAssertEqual(mono, [0.5, 0.5, 0.5, 0.5])
    }

    func testNonInterleavedInt16DownmixAveragesChannels() {
        let left = UnsafeMutablePointer<Int16>.allocate(capacity: 2)
        let right = UnsafeMutablePointer<Int16>.allocate(capacity: 2)
        defer {
            left.deallocate()
            right.deallocate()
        }
        left.initialize(from: [Int16.max, Int16.max], count: 2)
        right.initialize(from: [0, 0], count: 2)
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(list.unsafeMutablePointer) }
        list.count = 2
        list[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(2 * MemoryLayout<Int16>.size),
            mData: UnsafeMutableRawPointer(left)
        )
        list[1] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(2 * MemoryLayout<Int16>.size),
            mData: UnsafeMutableRawPointer(right)
        )
        var asbd = AudioStreamBasicDescription()
        asbd.mSampleRate = 48_000
        asbd.mFormatID = kAudioFormatLinearPCM
        asbd.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsNonInterleaved
        asbd.mBitsPerChannel = 16
        asbd.mChannelsPerFrame = 2
        asbd.mFramesPerPacket = 1
        let mono = SystemAudioDownmix.monoSamples(
            asbd: asbd,
            bufferList: UnsafePointer(list.unsafeMutablePointer),
            frameCount: 2
        )
        XCTAssertEqual(mono?.count, 2)
        XCTAssertEqual(mono?[0] ?? 0, 0.5, accuracy: 0.01)
        XCTAssertEqual(mono?[1] ?? 0, 0.5, accuracy: 0.01)
    }

    func testPauseDropsPacketsAndResumeResetsSampleClock() {
        let pipeline = AudioCapturePipeline(
            audioBuffer: ThreadSafeAudioBuffer(),
            onAcceptedSamples: { _ in },
            onFirstAudio: { _, _, _, _, _, _, _ in },
            onLevel: { _ in },
            onSpeechEnergy: { _, _ in },
            onCaptureHealth: { _, _, _, _, _, _ in }
        )
        let samples: [Float] = [0.2, 0.2, 0.2, 0.2]
        let host = mach_absolute_time()
        pipeline.setRecordingEnabled(true, sessionID: 1, attemptID: 1, startHostTime: host)
        samples.withUnsafeBufferPointer { pointer in
            pipeline.handle(
                samples: pointer.baseAddress!,
                frameCount: samples.count,
                sampleRate: 16_000,
                inputHostTime: host,
                inputSampleTime: 0
            )
        }
        XCTAssertEqual(pipeline.lastInputSampleEndForTesting, 4)

        pipeline.setCapturePaused(true)
        samples.withUnsafeBufferPointer { pointer in
            pipeline.handle(
                samples: pointer.baseAddress!,
                frameCount: samples.count,
                sampleRate: 16_000,
                inputHostTime: mach_absolute_time(),
                inputSampleTime: 4_000
            )
        }
        XCTAssertEqual(pipeline.lastInputSampleEndForTesting, 4)

        pipeline.setCapturePaused(false)
        XCTAssertNil(pipeline.lastInputSampleEndForTesting)
        samples.withUnsafeBufferPointer { pointer in
            pipeline.handle(
                samples: pointer.baseAddress!,
                frameCount: samples.count,
                sampleRate: 16_000,
                inputHostTime: mach_absolute_time(),
                inputSampleTime: 0
            )
        }
        XCTAssertEqual(pipeline.lastInputSampleEndForTesting, 4)
    }

    func testWatchCaptureStopPolicyAndCopy() {
        XCTAssertFalse(WatchCaptureStop.shouldNotifyUser(intentionalStop: true, alreadyReported: false))
        XCTAssertFalse(WatchCaptureStop.shouldNotifyUser(intentionalStop: false, alreadyReported: true))
        XCTAssertTrue(WatchCaptureStop.shouldNotifyUser(intentionalStop: false, alreadyReported: false))
        XCTAssertEqual(WatchCaptureStop.userFacingStatus("   "), "Capture stopped.")
        XCTAssertEqual(WatchCaptureStop.userFacingStatus("The stream was stopped"), "The stream was stopped")
        XCTAssertEqual(WatchCaptureStop.userFacingStatus("The target app closed"), "Target app closed.")
        XCTAssertEqual(WatchCaptureStop.fallbackCopy, TheaterReadiness.watchFallbackCopy)
        XCTAssertEqual(WatchCaptureStop.waitingCopy, TheaterReadiness.watchWaitingCopy)
        XCTAssertFalse(WatchCaptureStop.shouldFallbackToThisMacOnSilence())
        XCTAssertTrue(WatchCaptureStop.helperHonestyCopy.contains("This Mac"))
        XCTAssertTrue(WatchCaptureStop.helperHonestyCopy.contains("WebKit"))
    }

    func testTheaterKeyPolicyHoldsKeyOnlyWhileEditing() {
        XCTAssertFalse(TheaterKeyPolicy.shouldRestoreExternalApp(isEditing: true))
        XCTAssertTrue(TheaterKeyPolicy.shouldRestoreExternalApp(isEditing: false))
    }

    func testWatchAppCatalogSkipsSelfAndKeepsSelectedApp() {
        let selfApp = NSRunningApplication.current
        let skipped = WatchAppCatalog.apps(
            running: [selfApp],
            excludingBundleID: selfApp.bundleIdentifier
        )
        XCTAssertFalse(skipped.contains { $0.id == selfApp.bundleIdentifier })

        let selected = WatchCaptureApp(id: "com.example.browser", title: "Browser")
        let kept = WatchAppCatalog.apps(running: [], including: selected)
        XCTAssertEqual(kept.map(\.id), ["com.example.browser"])
        XCTAssertEqual(kept.first?.title, "Browser")
    }

    func testWatchCaptureSourceFollowsPicker() {
        let settings = SettingsStore.shared
        let originalMode = settings.theaterSessionMode
        let originalTarget = settings.theaterWatchTarget
        let originalBundle = settings.theaterWatchAppBundleID
        defer {
            settings.theaterSessionMode = originalMode
            settings.theaterWatchTarget = originalTarget
            settings.theaterWatchAppBundleID = originalBundle
        }

        settings.theaterSessionMode = .watch
        settings.theaterWatchTarget = .thisMac
        settings.theaterWatchAppBundleID = ""
        XCTAssertEqual(settings.theaterCaptureSource, .watchThisMac)

        settings.theaterWatchTarget = .app
        settings.theaterWatchAppBundleID = "com.apple.Safari"
        XCTAssertEqual(settings.theaterCaptureSource, .watchApp)

        settings.theaterWatchTarget = .app
        settings.theaterWatchAppBundleID = ""
        XCTAssertEqual(settings.theaterCaptureSource, .watchThisMac)
    }

    @MainActor
    func testWatchCaptureStopEndsListenImmediately() {
        let controller = LiveTranslationController.shared
        controller.cancelSession()
        let settings = SettingsStore.shared
        let originalWindow = settings.theaterWindowEnabled
        settings.theaterWindowEnabled = true
        defer {
            controller.cancelSession()
            controller.subscriber.reset()
            settings.theaterWindowEnabled = originalWindow
        }

        controller.beginSession(kind: .captions)
        XCTAssertTrue(controller.isSessionActive)
        controller.handleWatchCaptureStopped("The target app closed")
        XCTAssertFalse(controller.isSessionActive)
        XCTAssertFalse(controller.isPaused)
        XCTAssertEqual(controller.subscriber.statusText, "Target app closed.")
    }

    func testWatchAppInclusionCoversBrowserHelpers() {
        XCTAssertTrue(WatchAppInclusion.matches(
            candidateBundleID: "com.apple.WebKit.WebContent",
            targetBundleID: "com.apple.Safari"
        ))
        XCTAssertTrue(WatchAppInclusion.matches(
            candidateBundleID: "com.google.Chrome.helper",
            targetBundleID: "com.google.Chrome"
        ))
        XCTAssertTrue(WatchAppInclusion.matches(
            candidateBundleID: "org.mozilla.plugincontainer",
            targetBundleID: "org.mozilla.firefox"
        ))
        XCTAssertFalse(WatchAppInclusion.matches(
            candidateBundleID: "com.google.Chrome",
            targetBundleID: "com.apple.Safari"
        ))
        XCTAssertEqual(
            WatchAppInclusion.includedBundleIDs(
                targetBundleID: "com.apple.Safari",
                candidates: [
                    "com.apple.Safari",
                    "com.apple.WebKit.GPU",
                    "com.google.Chrome",
                ]
            ),
            ["com.apple.Safari", "com.apple.WebKit.GPU"]
        )
    }

    func testTheaterStatusColorsAndWatchWaitingCopy() {
        XCTAssertFalse(TheaterStatusKind.success.usesWarningColor)
        XCTAssertTrue(TheaterStatusKind.failure.usesWarningColor)
        XCTAssertTrue(TheaterStatusKind.warning.usesWarningColor)
        XCTAssertEqual(TheaterStatus.success("Heard").kind, .success)
        XCTAssertEqual(TheaterStatus.failure("Denied").kind, .failure)
        XCTAssertEqual(
            LiveTranslationCommitContext.peeledNewTranslation(
                "Hello world. Next sentence.",
                priorTranslations: ["Hello world."],
                targetID: "en"
            ),
            "Next sentence."
        )
    }

    @MainActor
    func testWatchProbeCopyAndEnergyGate() {
        XCTAssertEqual(
            WatchCaptureProbe.outcome(resolution: .denied, listening: false),
            .denied
        )
        XCTAssertEqual(
            WatchCaptureProbe.outcome(resolution: .granted, listening: true),
            .busy
        )
        XCTAssertNil(WatchCaptureProbe.outcome(resolution: .granted, listening: false))
        XCTAssertEqual(WatchCaptureProbe.classify(peak: 0.02, packets: 4), .heardAudio)
        XCTAssertEqual(WatchCaptureProbe.classify(peak: 0.001, packets: 12), .silent)
        XCTAssertEqual(WatchCaptureProbe.classify(peak: 0.5, packets: 0), .silent)
        XCTAssertEqual(WatchCaptureProbe.statusKind(for: .heardAudio), .success)
        XCTAssertEqual(WatchCaptureProbe.statusKind(for: .silent), .info)
        XCTAssertEqual(WatchCaptureProbe.statusKind(for: .denied), .warning)
        XCTAssertTrue(WatchCaptureProbe.message(for: .heardAudio).contains("Heard system audio"))
        XCTAssertEqual(
            ScreenRecordingAccess.message(for: .needsReopen),
            ScreenRecordingAccess.reopenCopy
        )
        XCTAssertEqual(
            TheaterReadiness.watchListeningCopy(sourceTitle: "Safari"),
            "Listening… play audio in Safari. DRM and some calls cannot be captured."
        )
    }

    @MainActor
    func testWatchProbeStartsStreamWhenScreenRecordingGranted() async throws {
        LiveTranslationController.shared.cancelSession()
        guard ScreenRecordingAccess.isGranted else {
            throw XCTSkip(
                "Screen Recording is not granted. Check capture on Theater after you grant it and reopen."
            )
        }
        let outcome = await WatchCaptureProbe.run(timeoutNanoseconds: 1_200_000_000)
        switch outcome {
        case .heardAudio, .silent:
            break
        case .busy:
            throw XCTSkip("Listen was already running")
        case .noDisplay:
            throw XCTSkip("No display is available")
        case .denied, .needsReopen:
            XCTFail("Preflight was true but ScreenCaptureKit still blocked capture")
        case .failed(let message):
            XCTFail(message)
        }
    }
}
