import AVFoundation
import Foundation

/// First-run and stage-call checks. Listen still gates on engine + pack.
enum TheaterReadiness {
    static let captionsPrintAfterSentence =
        "The live caption grows while you talk. A finished sentence plus more speech starts the next pair. A pause commits leftover speech."

    static let listeningStatus =
        "Listening. A finished sentence plus more speech starts the next pair. Spoken and Show-as stay paired."

    static let listeningEmpty =
        "Listening… a finished sentence plus more speech starts the next pair. Spoken and Show-as stay paired."

    static let pressListen =
        "Press Listen. A finished sentence plus more speech starts the next pair. Spoken and Show-as stay paired."

    static let stopHelp =
        "Stop. Printed lines stay."

    static let pauseHelp =
        "Pause. Printed lines stay."

    static let resumeHelp =
        "Resume. Printed lines stay."

    static let pausedStatus = "Paused."

    static let dictationBusy =
        "Stop dictation first"

    static let openTheaterHelp =
        "Open Theater. Choose Pop-up or Transparent in Theater Window."

    static let showTheater = "Show Theater"

    static let closeTheater = "Close Theater"

    static let showTheaterHelp =
        "Show Theater. Listen stayed."

    static let closeTheaterHelp =
        "Close Theater."

    static let minimizeHelp =
        "Minimize. Theater leaves the stage. Listen stays."

    static let expandTheaterHelp =
        "Show the caption board"

    static let theaterMinimizedStatus =
        "Theater is minimized."

    static let theaterOpenStatus =
        "Theater is open."

    static let openTheaterAndListen = "Open Theater and Listen"

    static let openTheaterPressListen =
        "Open Theater, press Listen, and say a sentence."

    static let historyEmpty =
        "Open Theater and press Listen. Captions will appear here."

    static let gettingStartedReady = "Theater is ready"

    static let gettingStartedOpen = "Open Theater"

    static let gettingStartedReadyDetail =
        "A caption appeared. Open Theater anytime from the sidebar."

    static let gettingStartedOpenDetail =
        "Voice Engine sharpens speech into text. Translation Engine is Apple Translation on this Mac, with an optional experimental local LLM. Both use the microphone. Open Theater, pick Voice or Translate, then press Listen."

    static let gettingStartedMicrophone =
        "Theater needs the microphone to hear you."

    static let gettingStartedMicrophoneReady =
        "The microphone is allowed. Voice and Translate both use it."

    static let printedLinesStay =
        "A line already on screen stays. Pause and Stop do not rewrite it."

    static let clearCaptions =
        "Clear removes every caption. Talk notes stay. Listen can keep going."

    static let clearCaptionsConfirm =
        "This removes every caption. Talk notes stay. Listen can keep going."

    static let talkPack =
        "Lock names from notes, a PDF, or a JSON list. They stay on this Mac."

    static let paceCue =
        "Behind means keep talking slower. Caught up means the last clause is on screen."

    static let oneSpeakerCloseMic =
        "Best with one speaker and a close mic. Halls, PA bleed, and Q&A will miss words."

    static let transcriptionCopy =
        "Voice Engine sharpens speech into text. Voice writes that text in the language you speak. Switch to Translate for Korean, English, Thai, or Japanese."

    static let insertIMECaveat =
        "Type into app needs Accessibility. A Korean, Japanese, or Thai IME uses paste instead of keystrokes."

    static let insertHelp =
        "Types the current caption into the frontmost app. Copy takes every caption. \(insertIMECaveat)"

    static let typeIntoAppLocked =
        "Type into app is available after the first caption."

    static let typeIntoAppBody =
        "Click into an app, then use this shortcut to type the current caption. \(insertIMECaveat) Copy takes every caption."

    static let typeIntoAppShortcutDetail =
        "Separate from dictation. Types the current caption only."

    static let undoLastCaption =
        "Remove the last printed line. Off-screen captions are already gone. Listen can keep going."

    static let closeWhileListening =
        "Close Theater stops Listen."

    static let closeWhileListeningConfirm =
        "This stops Listen and hides Theater. Printed lines come back when you open it again."

    static let closeWhileListeningTitle = "Stop and close Theater?"

    static let closeWhileListeningButton = "Stop and Close"

    static let modeStopsListen =
        "Voice writes what you say. Translate turns each sentence into Korean, English, Thai, or Japanese with Apple Translation. Switching stops Listen."

    static let spokenLineSameLanguage =
        "Same-language captions already show the spoken line."

    static let spokenLineTranslate =
        "Show what you said under the translation, smaller and dimmer."

    static let captionsOnlyWindow =
        "On the Theater window, show captions only. Listen stays. Move the pointer to show languages and the rest."

    static let howCaptionsAppear = "How new captions appear"

    static let captionSize = "Caption size."

    static let captionSizeSpoken =
        "Spoken undertone size. The translated title is larger."

    static let downloadPack = "Download pack"

    static let allowMicrophone =
        "Press Listen to allow the microphone."

    static let latencyHUD =
        "mic is Listen to first audio. e2e is speech-start to the printed caption. ASR is the speech engine. MT is Apple Translation."

    static let timedExportHonesty =
        "SRT/VTT times are when the caption committed, not the spoken word."

    static let hideFromScreenShare =
        "Hide from screen share keeps Theater off Zoom, Keynote, and recordings. The window still shows on your display and on a wired projector. Turn it off for a Zoom or Meet talk so remote viewers see captions. On macOS 15 and later some apps still capture hidden windows, so share one window, not the whole screen."

    static let backingBar =
        "Backing bar puts a dark band behind transparent captions so they stay readable on white slides."

    static let talkPackClear =
        "Clear these notes so their names do not carry into the next talk."

    static let presenterHotkeys =
        "Control-Option-H hides or shows Theater, P pauses, K clears, = and - change the text size. Your slides keep focus."

    static let popupStyle =
        "Pop-up is a solid floating board you can place over slides or a second display."

    static let transparentStyle =
        "Transparent keeps the captions and hides the board, so slides show through."

    static let presentationStyle =
        "Choose Pop-up or Transparent. Open Theater to show it; Close Theater to hide it."

    static let alsoHearOtherLanguages =
        "Whisper can auto-detect English, Korean, Japanese, and Thai questions. Apple Speech stays on I speak."

    /// Either way copy. The toggle is off until a later release.
    static let dynamicPairing =
        "Speak either language of this pair. Theater shows both. Whisper hears both; Apple Speech stays on I speak."

    static func dynamicPairingHint(isWhisper: Bool) -> String {
        isWhisper
            ? "Either way: speak either language of this pair. Captions stay both."
            : "Either way can flip captions, but this Voice Engine stays on I speak. Whisper hears both languages."
    }

    static var macOSNote: String {
        TheaterAvailability.isSupported
            ? "This Mac can run Theater."
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
    /// Voice, Translate, and I speak / Show as. Apple Speech Analyzer stays macOS 26+.
    static var isSupported: Bool { true }

    static let unsupportedCopy =
        "Theater is not available on this Mac."
}

/// Listen stays off until the Voice Engine, pack, and microphone permission are green.
/// An undetermined mic still allows Listen so the first press can show the system prompt.
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
                return MicrophoneAccess.deniedCopy
            }
            if !self.microphoneAllowed {
                return TheaterReadiness.allowMicrophone
            }
            if !self.languagePackReady {
                return "Download the language pack for this pair."
            }
            if !self.firstCaptionPrinted {
                return self.mode == .transcription
                    ? "Press Listen and speak."
                    : "Press Listen and speak."
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
        mode: TheaterSessionMode = .translation,
        osSupported: Bool = true
    ) -> Snapshot {
        let canPromptMic = microphone != .denied && microphone != .restricted
        let packOK = mode == .transcription || sameLanguagePair || pack == .installed
        return Snapshot(
            osSupported: osSupported,
            voiceEngineReady: engineSupportsSource && modelInstalled,
            languagePackReady: packOK,
            microphoneAllowed: microphone == .authorized,
            captureAllowed: canPromptMic,
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
            osSupported: TheaterAvailability.isSupported
        )
    }

    static func microphoneAllowed(_ status: AVAuthorizationStatus) -> Bool {
        status == .authorized
    }
}
