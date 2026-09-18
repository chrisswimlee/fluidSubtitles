import SwiftUI

/// Hover tags for Theater chrome: Name — what it does. Shortcut if any.
enum TheaterChromeHelp {
    static func tag(_ name: String, does: String, shortcut: String? = nil) -> String {
        if let shortcut {
            return "\(name) — \(does) \(shortcut)."
        }
        return "\(name) — \(does)"
    }

    static let listen = tag(
        "Listen",
        does: "Start the microphone. A finished sentence starts the next caption.",
        shortcut: "Control-Option-L"
    )
    static let stop = tag(
        "Stop",
        does: "Stop Listen. Printed lines stay.",
        shortcut: "Control-Option-L"
    )
    static let pause = tag(
        "Pause",
        does: "Freeze capture. Printed lines stay.",
        shortcut: "Control-Option-P"
    )
    static let resume = tag(
        "Resume",
        does: "Continue Listen. Printed lines stay.",
        shortcut: "Control-Option-P"
    )
    static let iSpeak = tag(
        "I speak",
        does: "Language you talk in. Voice Engine follows this."
    )
    static let showAs = tag(
        "Show as",
        does: "Language printed as the caption title."
    )
    static let swapLanguages = tag(
        "Swap languages",
        does: "Swap spoken and translated languages. Stops Listen."
    )
    static let mode = tag(
        "Theater mode",
        does: "Voice writes what you say. Translate captions Korean, English, Thai, or Japanese. Switching stops Listen."
    )
    static let retry = tag(
        "Retry",
        does: "Retry the last failed translation."
    )
    static let downloadPack = tag(
        "Download pack",
        does: "Download the Apple Translation pack for this pair."
    )
    static let captionsOnly = tag(
        "Captions only",
        does: "Hide extra tools on Pop-up. Listen stays. Move the pointer to show languages without moving the captions."
    )
    static let showAllControls = tag(
        "Show all controls",
        does: "Bring back languages, theme, and board tools."
    )
    static let minimize = tag(
        "Minimize Theater",
        does: "Hide the board. Listen stays.",
        shortcut: "Control-Option-H"
    )
    static let expand = tag(
        "Expand Theater",
        does: "Show the caption board again.",
        shortcut: "Control-Option-H"
    )
    static let paceCue = tag(
        "Pace cue",
        does: "Behind means talk slower. Caught up means the last clause is on screen."
    )
    static let latency = tag(
        "Latency",
        does: "mic is Listen to first audio. e2e is speech-start to the printed caption. ASR is the speech engine. MT is Apple Translation."
    )
    static let theme = tag(
        "Theater theme",
        does: "Dark or Light for this window, independent of the main window."
    )
    static let captionFont = tag(
        "Caption font",
        does: "Typeface for spoken and translated lines."
    )
    static let smaller = tag(
        "Smaller spoken line",
        does: "Shrink the spoken undertone. Translation stays larger.",
        shortcut: "Control-Option--"
    )
    static let larger = tag(
        "Larger spoken line",
        does: "Grow the spoken undertone. Translation stays larger.",
        shortcut: "Control-Option-="
    )
    static let copyAll = tag(
        "Copy all",
        does: "Copy every caption on the board."
    )
    static let insert = tag(
        "Type into app",
        does: "Type the current caption into the frontmost app. Needs Accessibility. Korean, Japanese, or Thai may paste."
    )
    static let undo = tag(
        "Undo last caption",
        does: "Remove the last printed line. Listen can keep going."
    )
    static let clear = tag(
        "Clear captions",
        does: "Remove every caption. Talk notes stay. Listen can keep going.",
        shortcut: "Control-Option-K"
    )
    static let board = tag(
        "Board",
        does: "Overlay for text on slides. Pop-up for a solid box. Also spoken line, plate, position, and screen share."
    )
    static let more = tag(
        "More",
        does: "Edit captions, export, or close Theater. Close stops Listen."
    )
    static let popup = tag(
        "Pop-up",
        does: "Solid floating box you can place over slides or a second display."
    )
    static let overlay = tag(
        "Overlay",
        does: "Only the caption text. Slides stay clickable.",
        shortcut: "Control-Option-T shows tools"
    )
    static let hideFromScreenShare = tag(
        "Hide from screen share",
        does: "Keeps Theater off Zoom and recordings. Turn off so a remote audience sees captions."
    )
    static let captionPlate = tag(
        "Caption plate",
        does: "Dark box behind each Overlay line so white slides stay readable."
    )
    static let highContrast = tag(
        "High contrast",
        does: "Stronger board fill and a halo on caption text."
    )
    static let spokenLine = tag(
        "Show the spoken line",
        does: "Show what you said under the translation so both rooms can follow."
    )
    static let printIn = tag(
        "Caption print-in",
        does: "How the live caption appears: Flow, Word, Fade, or Instant."
    )
    static let editCaptions = tag(
        "Edit captions",
        does: "Change printed text on this board."
    )
    static let doneEditing = tag(
        "Done",
        does: "Save caption edits and return to the live board."
    )
    static let exportBilingual = tag(
        "Bilingual text",
        does: "Save spoken and translated lines as a text file."
    )
    static let exportSRT = tag(
        "SRT",
        does: "Save captions with commit times, not spoken-word times."
    )
    static let exportVTT = tag(
        "VTT",
        does: "Save captions with commit times, not spoken-word times."
    )
    static let closeTheater = tag(
        "Close Theater",
        does: "Hide Theater and stop Listen."
    )
    static let talkNotes = tag(
        "Talk notes",
        does: "Names locked from notes or a deck. They stay on this Mac."
    )
    static let clearTalkNotes = tag(
        "Clear talk notes",
        does: "Remove these names so they do not carry into the next talk."
    )
    static let status = tag(
        "Status",
        does: "Listen, pack, or engine messages for this board."
    )
    static let overlayTools = tag(
        "Overlay tools",
        does: "Show Overlay Listen and board tools.",
        shortcut: "Control-Option-T"
    )
    static let lowerThird = tag(
        "Lower third",
        does: "Place the board on the bottom third of this display."
    )
    static let topBand = tag(
        "Top band",
        does: "Place the board on the top third of this display."
    )
    static let sideColumn = tag(
        "Side column",
        does: "Place the board as a column on the right of this display."
    )
    static let captionBar = tag(
        "Caption bar",
        does: "Thin strip at the bottom for Overlay captions on slides."
    )

    static func position(_ preset: TheaterPositionPreset) -> String {
        switch preset {
        case .lowerThird: return Self.lowerThird
        case .topBand: return Self.topBand
        case .sideColumn: return Self.sideColumn
        case .captionBar: return Self.captionBar
        }
    }

}

extension View {
    func theaterTag(_ text: String) -> some View {
        self.help(text).accessibilityHint(text)
    }
}
