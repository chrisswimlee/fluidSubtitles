import AVFoundation
import Foundation

/// First-run and stage-call checks. Listen still gates on engine + pack.
enum TheaterReadiness {
    static let captionsPrintAfterSentence =
        "Captions print after each finished sentence, not word by word."

    static let printedLinesStay =
        "A line already on screen stays. Pause and Stop do not rewrite it."

    static let oneSpeakerCloseMic =
        "Best with one speaker and a close mic. Halls, PA bleed, and Q&A will miss words."

    static let insertIMECaveat =
        "Type into app needs Accessibility. Korean and Thai depend on the other app’s input method."

    static let timedExportHonesty =
        "SRT/VTT times are when the caption committed, not the spoken word."

    static let hideFromScreenShare =
        "Hide from screen share keeps Theater off Zoom, Keynote, and recordings. The window still shows on your display and on a wired projector."

    static let alsoHearOtherLanguages =
        "Whisper can auto-detect English, Korean, and Thai questions. Apple Speech stays on I speak."

    static var macOSNote: String {
        if #available(macOS 26.0, *) {
            return "macOS 26: Speech Analyzer and low-latency Apple Translation are available."
        }
        return "macOS 15 runs Theater. macOS 26 adds Speech Analyzer and faster on-device Translation."
    }

    static func voiceEngineLine(asrReady: Bool, modelsOnDisk: Bool) -> String {
        if asrReady || modelsOnDisk {
            return SpokenLanguageResolver.stageEngineSummary()
        }
        return "Download a Voice Engine before Listen. Apple Speech is enough to try."
    }
}

/// Listen stays off until engine, pack, and microphone are green.
enum TheaterReadyGate {
    struct Snapshot: Equatable {
        var voiceEngineReady: Bool
        var languagePackReady: Bool
        var microphoneAllowed: Bool
        var firstCaptionPrinted: Bool

        var canListen: Bool {
            self.voiceEngineReady && self.languagePackReady && self.microphoneAllowed
        }

        var isFullyReady: Bool {
            self.canListen && self.firstCaptionPrinted
        }

        var nextAction: String {
            if !self.voiceEngineReady {
                return "Download a Voice Engine for the language you speak. Apple Speech is enough to try."
            }
            if !self.microphoneAllowed {
                return "Allow the microphone in System Settings."
            }
            if !self.languagePackReady {
                return "Download the Apple Translation pack for this pair."
            }
            if !self.firstCaptionPrinted {
                return "Press Listen and speak one sentence."
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
        firstCaptionPrinted: Bool
    ) -> Snapshot {
        let micOK = microphone != .denied && microphone != .restricted
        let packOK = sameLanguagePair || pack == .installed
        return Snapshot(
            voiceEngineReady: engineSupportsSource && modelInstalled,
            languagePackReady: packOK,
            microphoneAllowed: micOK,
            firstCaptionPrinted: firstCaptionPrinted
        )
    }

    static func microphoneAllowed(_ status: AVAuthorizationStatus) -> Bool {
        status != .denied && status != .restricted
    }
}