import AVFoundation
import Foundation

/// First-run and stage-call checks. Listen still gates on engine + pack.
enum TheaterReadiness {
    static let captionsPrintAfterSentence =
        "A sentence prints when it finishes. A long run-on starts printing while you talk."

    static let listeningStatus =
        "Listening. The current sentence prints as you go."

    static let listeningEmpty =
        "Listening… the current sentence prints as you go."

    static let pressListen =
        "Press Listen. The current sentence prints as you go."

    static let stopHelp =
        "Stop. Printed lines stay."

    static let resumeHelp =
        "Resume captions. Printed lines stay."

    static let dictationBusy =
        "Stop dictation first"

    static let openTheaterHelp =
        "Open Theater. Choose Pop-up or Transparent in Theater Window."

    static let openTheaterAndListen = "Open Theater and Listen"

    static let openTheaterPressListen =
        "Open Theater, press Listen, and say a sentence."

    static let historyEmpty =
        "Open Theater and press Listen. Captions from this Mac will appear here."

    static let gettingStartedReady = "Theater is ready"

    static let gettingStartedOpen = "Open Theater and Listen"

    static let gettingStartedReadyDetail =
        "A caption appeared. Open Theater anytime from the sidebar."

    static let gettingStartedOpenDetail =
        "Lectern needs the microphone. Watch needs Screen Recording (quit and reopen after you grant it). Open Theater, then press Listen until a caption appears."

    static let gettingStartedScreenRecording =
        "Watch captions another app. After you grant Screen Recording, quit and reopen FluidSubtitles."

    static let gettingStartedScreenRecordingReady =
        "Watch can capture system audio. Quit and reopen if Check capture still fails."

    static let gettingStartedMicrophone =
        "Lectern Theater needs the microphone to caption speech."

    static let gettingStartedMicrophoneReady =
        "Lectern can hear you. Watch uses Screen Recording instead."

    static let printedLinesStay =
        "A line already on screen stays. Pause and Stop do not rewrite it."

    static let clearCaptions =
        "Clear removes the board and the session archive. Listen can keep going."

    static let clearCaptionsConfirm =
        "This removes every caption on the board and the session archive. Listen can keep going."

    static let oneSpeakerCloseMic =
        "Best with one speaker and a close mic. Halls, PA bleed, and Q&A will miss words."

    static let watchCopy =
        "Watch captions what another app is playing. I speak is the language of the video — Korean, English, or Thai. This Mac is the default. Safari and Chrome helpers mix more than one tab. A virtual or aggregate output can loop the mix. DRM and some calls stay silent. Screen Recording is required; after you grant it, quit and reopen FluidSubtitles."

    static let watchWaitingCopy = WatchCaptureStop.waitingCopy

    static let watchNoAudio =
        "Listening… play audio in another app. DRM and some calls cannot be captured."

    static func watchListeningCopy(sourceTitle: String) -> String {
        "Listening… play audio in \(sourceTitle). DRM and some calls cannot be captured."
    }

    static let watchFallbackCopy = WatchCaptureStop.fallbackCopy

    static let insertIMECaveat =
        "Type into app needs Accessibility. A Korean or Thai IME uses paste instead of keystrokes."

    static let insertHelp =
        "Types this Listen into the frontmost app. Copy takes the whole board. \(insertIMECaveat)"

    static let undoLastCaption =
        "Remove the last printed line. Older archive lines stay. Listen can keep going."

    static let closeWhileListening =
        "Close Theater stops Listen."

    static let closeWhileListeningConfirm =
        "This stops Listen and hides Theater. Printed lines come back when you open it again."

    static let watchSourceStopsListen =
        "This stops Listen and switches the Watch source."

    static let modeStopsListen =
        "Changing Lectern or Watch stops Listen."

    static let spokenLineSameLanguage =
        "Same-language captions already show the spoken line."

    static let latencyHUD =
        "mic is Listen to first audio (Watch uses cap). e2e is speech-start to the printed caption. ASR is the speech engine. MT is Apple Translation."

    static let timedExportHonesty =
        "SRT/VTT times are when the caption committed, not the spoken word."

    static let hideFromScreenShare =
        "Hide from screen share keeps Theater off Zoom, Keynote, and recordings. The window still shows on your display and on a wired projector."

    static let popupStyle =
        "Pop-up is a solid floating board you can park over the lectern."

    static let transparentStyle =
        "Transparent keeps the captions and hides the board, so slides show through."

    static let presentationStyle =
        "Choose Pop-up or Transparent. Open Theater to show it; Close Theater to hide it."

    static let alsoHearOtherLanguages =
        "Whisper can auto-detect English, Korean, and Thai questions. Apple Speech stays on I speak."

    static var macOSNote: String {
        TheaterAvailability.isSupported
            ? "macOS 26: Speech Analyzer and low-latency Apple Translation are available."
            : TheaterAvailability.unsupportedCopy
    }

    static func voiceEngineLine(asrReady: Bool, modelsOnDisk: Bool) -> String {
        if asrReady || modelsOnDisk {
            return SpokenLanguageResolver.stageEngineSummary()
        }
        return "Download a Voice Engine before Listen. Apple Speech is enough to try."
    }
}

enum TheaterAvailability {
    static var isSupported: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    static let unsupportedCopy =
        "Theater needs macOS 26. Dictation still works on this Mac."
}

/// Listen stays off until macOS 26, engine, pack, and the mode's capture permission are green.
enum TheaterReadyGate {
    struct Snapshot: Equatable {
        var osSupported: Bool
        var voiceEngineReady: Bool
        var languagePackReady: Bool
        var microphoneAllowed: Bool
        var captureAllowed: Bool
        var firstCaptionPrinted: Bool
        var mode: TheaterSessionMode

        var canListen: Bool {
            self.osSupported && self.voiceEngineReady && self.languagePackReady && self.captureAllowed
        }

        var isFullyReady: Bool {
            self.canListen && self.firstCaptionPrinted
        }

        var nextAction: String {
            if !self.osSupported {
                return TheaterAvailability.unsupportedCopy
            }
            if !self.voiceEngineReady {
                return "Download a Voice Engine for the language you speak. Apple Speech is enough to try."
            }
            if !self.captureAllowed {
                if self.mode == .watch {
                    return ScreenRecordingAccess.deniedCopy
                }
                return "Allow the microphone in System Settings."
            }
            if !self.languagePackReady {
                return "Download the Apple Translation pack for this pair."
            }
            if !self.firstCaptionPrinted {
                return self.mode == .watch
                    ? "Press Listen and play one sentence."
                    : "Press Listen and speak one sentence."
            }
            return "Ready."
        }
    }

    static func snapshot(
        engineSupportsSource: Bool,
        modelInstalled: Bool,
        sameLanguagePair: Bool,
        pack: TranslationPackAvailability,
        microphone: AVAuthorizationStatus,
        firstCaptionPrinted: Bool,
        mode: TheaterSessionMode = .lectern,
        screenRecordingAllowed: Bool = false,
        osSupported: Bool = true
    ) -> Snapshot {
        let micOK = microphone != .denied && microphone != .restricted
        let packOK = sameLanguagePair || pack == .installed
        let captureOK = mode == .watch ? screenRecordingAllowed : micOK
        return Snapshot(
            osSupported: osSupported,
            voiceEngineReady: engineSupportsSource && modelInstalled,
            languagePackReady: packOK,
            microphoneAllowed: micOK,
            captureAllowed: captureOK,
            firstCaptionPrinted: firstCaptionPrinted,
            mode: mode
        )
    }

    @MainActor
    static func liveSnapshot(
        pack: TranslationPackAvailability,
        microphone: AVAuthorizationStatus,
        firstCaptionPrinted: Bool
    ) -> Snapshot {
        self.snapshot(
            engineSupportsSource: SpokenLanguageResolver.voiceEngineSupportsSource(),
            modelInstalled: SettingsStore.shared.selectedSpeechModel.isInstalled,
            sameLanguagePair: SpokenLanguageResolver.isSameLanguagePair(),
            pack: pack,
            microphone: microphone,
            firstCaptionPrinted: firstCaptionPrinted,
            mode: SettingsStore.shared.theaterSessionMode,
            screenRecordingAllowed: ScreenRecordingAccess.isGranted,
            osSupported: TheaterAvailability.isSupported
        )
    }

    static func microphoneAllowed(_ status: AVAuthorizationStatus) -> Bool {
        status != .denied && status != .restricted
    }
}