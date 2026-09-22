import AVFoundation
import Foundation

/// First-run and stage-call checks. Listen still gates on engine + pack.
enum TheaterReadiness {
    static let captionsPrintAfterSentence =
        "Each sentence appears when it is ready. Pause and Stop drop a leftover. Listen and type still types that leftover."

    static let listeningStatus =
        "Listening. Each sentence appears when it is ready."

    static let listeningEmpty =
        "Listening. Each sentence appears when it is ready."

    static let pressListen =
        "Press Listen. Each sentence appears when it is ready."

    static let boardIdle =
        "Press Listen. Each sentence appears when it is ready."

    static let boardListening =
        "Listening. The next sentence appears here."

    static let talkPackCarryOver = "These names stay for the next talk until you Remove."

    static let audienceTitle = "Who sees captions?"
    static let audienceSlides = "Slides in the room"
    static let audienceZoom = "Zoom or Meet"
    static let audienceSlidesDetail =
        "Captions show on this Mac and a wired projector. Screen share and recordings do not see them."
    static let audienceZoomDetail =
        "Remote viewers see captions when you share the whole screen. Sharing only the slides window leaves captions out. Check once before the talk."
    static let hiddenFromZoomBadge = "Hidden from Zoom"

    /// Idle Overlay hides every control and lets clicks reach the slides.
    static let overlayIdleCoach =
        "Slides stay clickable. Control-Option-T shows tools. Control-Option-L starts Listen."

    static let overlayIdleHint = "Control-Option-L starts Listen. Control-Option-T shows tools."

    /// Presenter shortcuts are off, so the menu bar is the way back to the tools.
    static let overlayIdleMenuBarHint =
        "Slides stay clickable. Use the Theater item in the menu bar to show tools or Listen."

    static let stopHelp =
        "Stop. A real leftover sentence appears once. Printed lines stay."

    static let pauseHelp =
        "Pause. Drops a leftover. Printed lines stay. A translation already on its way may still land."

    static let resumeHelp =
        "Resume. Printed lines stay. A dropped leftover does not come back."

    static let pausedStatus = "Paused."

    static let dictationBusy =
        "Stop dictation first"

    static let openTheaterHelp =
        "Open Theater. Choose Pop-up or Overlay in Theater Window."

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
        "A line already on screen stays. Each sentence appears when it is ready. Pause and Stop drop a leftover. Listen and type still types that leftover into the other app."

    static let clearCaptions =
        "Clear removes every caption. Talk notes stay. Listen can keep going."

    static let clearCaptionsConfirm =
        "This removes every caption. Talk notes stay. Listen can keep going."

    static let talkPack =
        "Lock names from notes, a PDF, or a JSON list. They stay on this Mac."

    static let paceCue =
        "Behind means keep talking slower. Caught up means the last sentence is on screen."

    static let oneSpeakerCloseMic =
        "Best with one speaker and a close mic. Halls, PA bleed, and Q&A will miss words."

    static let transcriptionCopy =
        "Voice Engine sharpens speech into text. Voice writes that text in the language you speak. Switch to Translate for a supported language."

    static let insertIMECaveat =
        "some keyboards paste it instead of typing each letter"

    static let insertHelp =
        "Types this caption into the frontmost app, and \(insertIMECaveat)."

    static let typeIntoAppLocked =
        "Listen and type unlocks after your first Theater caption."

    static let typeIntoAppBody =
        "Press this shortcut in another app and it types what you say next."

    static let typeIntoAppShortcutDetail =
        "Starts Listen and types what you say next."

    static let typeIntoAppNeedsAccessibility =
        "This shortcut is saved, but macOS is blocking it. Allow Accessibility, click into another app, then press it."

    /// Type into app is off because every board line was already typed.
    static let insertAlreadyTyped = "Already typed. Copy still has the board."

    static let undoLastCaption =
        "Remove the last printed line. Off-screen captions are already gone. Listen can keep going."

    static let closeWhileListening =
        "Close Theater stops Listen."

    static let closeWhileListeningConfirm =
        "This stops Listen and hides Theater. Printed lines come back when you open it again."

    static let closeWhileListeningTitle = "Stop and close Theater?"

    static let closeWhileListeningButton = "Stop and Close"

    static let modeStopsListen =
        "Voice writes what you say. Translate turns each sentence into a supported language with Apple Translation. Switching stops Listen."

    static let spokenLineTitle = "Spoken line"

    static let spokenLineSameLanguage =
        "Same-language captions already show the spoken line."

    static let spokenLineTranslate =
        "Off is translation only. After a pause prints the original language under the sentence. While talking grows it under the title."

    static let spokenLineSetupNote =
        "Off keeps the translation only. The other choices put the original language under the title."

    static let captionsOnlyWindow =
        "On the Theater window, show captions only. Listen stays. Move the pointer to show languages and the rest."

    static let captionsOnlyPopupOnly =
        "Captions only is for Pop-up. Overlay is already text-only. Control-Option-T shows Overlay tools."

    static let howCaptionsAppear = "How new captions appear"

    static let captionSize = "Caption size."

    static let captionSizeSpoken =
        "Spoken and Show-as size. Show-as stays larger."

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
        "Caption plate puts a dark box behind each Overlay line so the text stays readable on white slides."

    static let talkPackClear =
        "Clear these notes so their names do not carry into the next talk."

    static let presenterHotkeys =
        "Control-Option-H hides or shows Theater, P pauses, K clears, T shows Overlay tools, L starts or stops Listen, = and - change caption size. The menu-bar Theater item changes font, size, plate, and position. Your slides keep focus. A custom Listen shortcut with the same chord wins."

    static let popupStyle =
        "Pop-up is a solid board that fills this display. Drag a corner to resize."

    static let transparentStyle =
        "Overlay keeps the caption text and hides the board, so slides show through and stay clickable. Control-Option-T shows tools."

    static let presentationStyle =
        "Choose Pop-up or Overlay. Open Theater to show it; Close Theater to hide it."

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
        let packOK = mode == .transcription || sameLanguagePair
            || pack == .installed || pack == .unknown
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
