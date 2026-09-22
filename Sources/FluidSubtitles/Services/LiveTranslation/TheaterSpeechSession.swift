import Combine
import Foundation

/// Policy the Voice Engine reads for a Theater Listen.
/// Captions do not write a history WAV. Insert keeps dictation audio settings.
@MainActor
struct TheaterSpeechPolicy: Equatable {
    var boundLiveTranscript: Bool
    var keepShortUtterances: Bool
    var preferLatestChunk: Bool
    var retainsAudio: Bool
    var isSessionActive: Bool
    var pausesMedia: Bool
    var playsListenChime: Bool

    static func captions() -> TheaterSpeechPolicy {
        TheaterSpeechPolicy(
            boundLiveTranscript: true,
            keepShortUtterances: true,
            preferLatestChunk: true,
            retainsAudio: false,
            isSessionActive: true,
            pausesMedia: false,
            playsListenChime: false
        )
    }

    static func insert() -> TheaterSpeechPolicy {
        TheaterSpeechPolicy(
            boundLiveTranscript: true,
            keepShortUtterances: true,
            preferLatestChunk: true,
            retainsAudio: true,
            isSessionActive: true,
            pausesMedia: false,
            playsListenChime: false
        )
    }

    static func forKind(_ kind: TranslationListenKind) -> TheaterSpeechPolicy {
        kind == .insert ? self.insert() : self.captions()
    }
}

/// Installs Theater's capture policy on ASR and owns the live partial bus.
@MainActor
final class TheaterSpeechSession: SpeechCapturePolicy {
    static let shared = TheaterSpeechSession()

    private(set) var policy: TheaterSpeechPolicy?
    private var partials: AnyCancellable?

    var isSessionActive: Bool { self.policy?.isSessionActive == true }
    var boundLiveTranscript: Bool { self.policy?.boundLiveTranscript == true }
    var keepShortUtterances: Bool { self.policy?.keepShortUtterances == true }
    var preferLatestChunk: Bool { self.policy?.preferLatestChunk == true }
    var retainsAudio: Bool { self.policy?.retainsAudio ?? true }
    var pausesMedia: Bool { self.policy?.pausesMedia == true }
    var playsListenChime: Bool { self.policy?.playsListenChime == true }

    private init() {}

    /// Once per Listen: idle → I speak pin → packs → session → policy.
    func prepareListen(kind: TranslationListenKind, asr: ASRService) async -> Bool {
        let controller = LiveTranslationController.shared
        await controller.awaitASRIdle()
        if !TheaterSpokenEngineReload.canReload(asrBusy: asr.isRunningOrStarting) {
            controller.listenStartFailed()
            controller.reportListenFailure("Still stopping the last Listen. Try again.")
            return false
        }
        controller.alignSpokenEngineWithTheater()
        let ready = await controller.ensureReadyToListen()
        guard ready else {
            controller.listenStartFailed()
            return false
        }
        if kind == .insert, !controller.appleEngine.isMailboxReady {
            controller.reportListenStatus("Starting translation…", kind: .info)
        }
        await controller.awaitInitialTranslationWarmupIfNeeded()
        controller.beginSession(kind: kind)
        self.install(kind: kind, asr: asr)
        return true
    }

    func install(kind: TranslationListenKind, asr: ASRService) {
        self.policy = TheaterSpeechPolicy.forKind(kind)
        asr.speechCapturePolicy = self
        self.partials?.cancel()
        self.partials = asr.$partialTranscription
            .removeDuplicates()
            .sink { [weak self] text in
                guard self?.isSessionActive == true, asr.isRunning else { return }
                LiveTranslationController.shared.handlePartial(text)
            }
    }

    func clear(asr: ASRService) {
        if asr.speechCapturePolicy === self {
            asr.speechCapturePolicy = nil
        }
        self.policy = nil
        self.partials?.cancel()
        self.partials = nil
    }

    func markFirstBuffer() {
        LiveTranslationController.shared.markFirstBuffer()
    }

    func markSpeechStart(hostTime: UInt64) {
        LiveTranslationController.shared.markSpeechStart(hostTime: hostTime)
    }

    func markSilenceHold() {
        LiveTranslationController.shared.markSilenceHold()
    }

    func handleEndOfUtterance() {
        LiveTranslationController.shared.handleEndOfUtterance()
    }
}
