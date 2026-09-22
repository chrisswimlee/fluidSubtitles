import Combine
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
        does: "Stop Listen. A real leftover clause appears once; a fragment does not. Printed lines stay.",
        shortcut: "Control-Option-L"
    )
    static let pause = tag(
        "Pause",
        does: "Hold capture and drop a leftover fragment. Printed lines stay; an in-flight translation may still land.",
        shortcut: "Control-Option-P"
    )
    static let resume = tag(
        "Resume",
        does: "Continue Listen. Printed lines stay. A dropped fragment does not come back.",
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
        does: "Voice writes what you say. Translate captions into a supported language. Switching stops Listen."
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
        does: "Typeface for spoken and Show-as."
    )
    static let smaller = tag(
        "Smaller captions",
        does: "Shrink spoken and Show-as.",
        shortcut: "Control-Option-Minus"
    )
    static let larger = tag(
        "Larger captions",
        does: "Grow spoken and Show-as.",
        shortcut: "Control-Option-Equals"
    )
    static let copyAll = tag(
        "Copy all",
        does: "Copy every caption on the board."
    )
    static let insert = tag(
        "Type into app",
        does: "Type this Listen into the frontmost app. Copy takes the whole board. Needs Accessibility. Korean, Japanese, or Thai may paste."
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
        "Settings",
        does: "Spoken line, Overlay or Pop-up, plate, position, and screen share."
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
        "Spoken line",
        does: "Off hides the original language. Any other choice prints it under each delivered sentence."
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
    static let fillScreen = tag(
        "Fill screen",
        does: "Cover this display so captions have the whole board."
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
        case .fillScreen: return Self.fillScreen
        case .lowerThird: return Self.lowerThird
        case .topBand: return Self.topBand
        case .sideColumn: return Self.sideColumn
        case .captionBar: return Self.captionBar
        }
    }

    static func captionFont(current: String) -> String {
        tag("Caption font", does: "Typeface for spoken and Show-as. Now \(current).")
    }

}

struct TheaterHoverHelpValue: Equatable {
    var text: String
    var anchor: CGRect
}

@MainActor
final class TheaterHoverHelpBroker: ObservableObject {
    @Published private(set) var value: TheaterHoverHelpValue?

    func show(_ value: TheaterHoverHelpValue) {
        guard self.value != value else { return }
        self.value = value
    }

    func hide(text: String) {
        guard self.value?.text == text else { return }
        self.value = nil
    }

    func clear() {
        guard self.value != nil else { return }
        self.value = nil
    }
}

private struct TheaterHoverHelpBrokerKey: EnvironmentKey {
    static let defaultValue: TheaterHoverHelpBroker? = nil
}

extension EnvironmentValues {
    var theaterHoverHelp: TheaterHoverHelpBroker? {
        get { self[TheaterHoverHelpBrokerKey.self] }
        set { self[TheaterHoverHelpBrokerKey.self] = newValue }
    }
}

enum TheaterHoverHelp {
    static let space = "theater.hoverHelp"
    static let maxBubbleWidth: CGFloat = 280
    static let margin: CGFloat = 12
    static let gap: CGFloat = 8
    static let revealDelayNanoseconds: UInt64 = 220_000_000

    static func bubbleWidth(containerWidth: CGFloat) -> CGFloat {
        max(0, min(Self.maxBubbleWidth, containerWidth - Self.margin * 2))
    }

    static func bubbleOrigin(
        anchor: CGRect,
        container: CGSize,
        bubbleSize: CGSize
    ) -> CGPoint {
        let maxX = max(Self.margin, container.width - bubbleSize.width - Self.margin)
        let x = min(max(anchor.minX, Self.margin), maxX)
        let below = anchor.maxY + Self.gap
        let above = anchor.minY - Self.gap - bubbleSize.height
        let minY = Self.margin
        let maxY = max(minY, container.height - bubbleSize.height - Self.margin)
        if below <= maxY {
            return CGPoint(x: x, y: below)
        }
        if above >= minY {
            return CGPoint(x: x, y: above)
        }
        return CGPoint(x: x, y: min(max(below, minY), maxY))
    }
}

struct TheaterHoverHelpBubble: View {
    var text: String
    var anchor: CGRect
    var container: CGSize
    @State private var bubbleSize = CGSize(width: 240, height: 44)

    var body: some View {
        let width = TheaterHoverHelp.bubbleWidth(containerWidth: self.container.width)
        let fitted = CGSize(
            width: min(self.bubbleSize.width, width),
            height: self.bubbleSize.height
        )
        let origin = TheaterHoverHelp.bubbleOrigin(
            anchor: self.anchor,
            container: self.container,
            bubbleSize: fitted
        )
        Text(self.text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.94))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: width, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.88))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    }
            }
            .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
            .background {
                GeometryReader { bubble in
                    Color.clear
                        .onAppear { self.adoptBubbleSize(bubble.size) }
                        .onChange(of: bubble.size) { _, size in
                            self.adoptBubbleSize(size)
                        }
                }
            }
            .offset(x: origin.x, y: origin.y)
            .onChange(of: self.text) { _, _ in
                self.bubbleSize = CGSize(width: 240, height: 44)
            }
            .accessibilityIdentifier("theater.window.hoverHelp")
    }

    private func adoptBubbleSize(_ size: CGSize) {
        guard size != .zero, size != self.bubbleSize else { return }
        self.bubbleSize = size
    }
}

private struct TheaterHoverTagModifier: ViewModifier {
    let text: String
    @Environment(\.theaterHoverHelp) private var broker
    @State private var hovering = false
    @State private var revealed = false
    @State private var revealTask: Task<Void, Never>?
    @State private var anchor = CGRect.zero

    func body(content: Content) -> some View {
        content
            .accessibilityHint(self.text)
            .background {
                GeometryReader { proxy in
                    let frame = proxy.frame(in: .named(TheaterHoverHelp.space))
                    Color.clear
                        .onAppear { self.adoptAnchor(frame) }
                        .onChange(of: frame.origin) { _, _ in self.adoptAnchor(frame) }
                        .onChange(of: frame.size) { _, _ in self.adoptAnchor(frame) }
                }
            }
            .onHover { hovering in
                self.hovering = hovering
                self.revealTask?.cancel()
                if hovering {
                    self.revealTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: TheaterHoverHelp.revealDelayNanoseconds)
                        guard !Task.isCancelled, self.hovering else { return }
                        self.revealed = true
                        self.publish()
                    }
                } else {
                    self.revealed = false
                    self.broker?.hide(text: self.text)
                }
            }
            .onChange(of: self.text) { _, _ in
                guard self.revealed else { return }
                self.publish()
            }
            .onDisappear {
                self.revealTask?.cancel()
                if self.revealed {
                    self.broker?.hide(text: self.text)
                }
                self.revealed = false
            }
    }

    private func adoptAnchor(_ frame: CGRect) {
        let next = frame.integral
        guard next != self.anchor else { return }
        self.anchor = next
        guard self.revealed else { return }
        self.publish()
    }

    private func publish() {
        guard !self.text.isEmpty else { return }
        self.broker?.show(TheaterHoverHelpValue(text: self.text, anchor: self.anchor))
    }
}

extension View {
    /// Theater paints this on hover. Home and menus still use `.help`.
    @ViewBuilder
    func theaterTag(_ text: String, paints: Bool = true) -> some View {
        if paints {
            self.modifier(TheaterHoverTagModifier(text: text))
        } else {
            self.help(text)
        }
    }
}
