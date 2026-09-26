import CoreGraphics
import Foundation

/// When the original language prints under Show-as.
enum TheaterSpokenLineMode: String, CaseIterable, Identifiable {
    case off
    case afterPause

    var id: String { self.rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .afterPause: return "On the board"
        }
    }

    var help: String {
        switch self {
        case .off:
            return "Translation only. The original language stays off the board."
        case .afterPause:
            return "The original language prints under Show-as when the sentence is ready."
        }
    }

    var showsSpokenLine: Bool { self != .off }

    static func resolved(_ stored: String?) -> TheaterSpokenLineMode {
        let trimmed = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Board and Insert wrote `whileTalking`. That notch path is gone.
        if trimmed == "whileTalking" { return .afterPause }
        return Self(rawValue: trimmed) ?? .afterPause
    }

    /// Old Show the spoken line toggle. On becomes On the board.
    static func migrated(fromShowSource show: Bool?) -> TheaterSpokenLineMode {
        show == false ? .off : .afterPause
    }
}

/// Points between stacked captions. The board used 14 before this was a setting.
enum TheaterCaptionSpacing {
    static let range: ClosedRange<Int> = 0...48
    static let defaultPoints = 14

    static func resolved(_ stored: Int?) -> Int {
        guard let stored else { return Self.defaultPoints }
        return min(Self.range.upperBound, max(Self.range.lowerBound, stored))
    }
}

/// How an accepted line arrives on the board.
enum TheaterLinePrint: String, CaseIterable, Identifiable {
    case atOnce
    case word
    case letter
    case fade

    var id: String { self.rawValue }

    var displayName: String {
        switch self {
        case .atOnce: return "At once"
        case .word: return "By word"
        case .letter: return "By letter"
        case .fade: return "Fade"
        }
    }

    var help: String {
        switch self {
        case .atOnce:
            return "The whole line appears together."
        case .word:
            return "The line fills in one word at a time."
        case .letter:
            return "The line fills in one letter at a time."
        case .fade:
            return "The whole line fades in."
        }
    }

    static func resolved(_ stored: String?) -> TheaterLinePrint {
        let trimmed = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Self(rawValue: trimmed) ?? .atOnce
    }
}

/// Pause between each print step. Fade uses this as how long the line takes to arrive.
enum TheaterPrintGap: String, CaseIterable, Identifiable {
    case tight
    case close
    case open
    case wide

    var id: String { self.rawValue }

    var displayName: String {
        switch self {
        case .tight: return "Tight"
        case .close: return "Close"
        case .open: return "Open"
        case .wide: return "Wide"
        }
    }

    /// Time between one word or letter and the next.
    var stepSeconds: TimeInterval {
        switch self {
        case .tight: return 0.02
        case .close: return 0.05
        case .open: return 0.1
        case .wide: return 0.18
        }
    }

    /// How long a fade takes. Wider gaps arrive more slowly.
    var fadeSeconds: TimeInterval {
        switch self {
        case .tight: return 0.18
        case .close: return 0.35
        case .open: return 0.55
        case .wide: return 0.85
        }
    }

    static func resolved(_ stored: String?) -> TheaterPrintGap {
        let trimmed = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Self(rawValue: trimmed) ?? .close
    }
}

/// Whether an accepted clause draws its spoken sentence under Show-as.
enum TheaterCaptionSpokenDisplay: Equatable {
    /// Show-as on top, spoken sentence under it, once the clause is accepted.
    case paired
    /// Same board as `paired`. On the board uses this.
    case pairedAfterPause
    /// Same-language: the spoken text is the caption.
    case isTheCaption
    /// Translation only. The spoken sentence stays off the board.
    case hidden

    var printsSpokenOnCommitted: Bool {
        self == .paired || self == .pairedAfterPause
    }

    static func resolved(mode: TheaterSpokenLineMode, sameLanguage: Bool) -> TheaterCaptionSpokenDisplay {
        if sameLanguage { return .isTheCaption }
        switch mode {
        case .off: return .hidden
        case .afterPause: return .pairedAfterPause
        }
    }

    static func resolved(showSpokenLine: Bool, sameLanguage: Bool) -> TheaterCaptionSpokenDisplay {
        self.resolved(mode: showSpokenLine ? .afterPause : .off, sameLanguage: sameLanguage)
    }
}

/// Idle Home, wizard, and empty-board ghosts. Language names only — never a fake caption.
enum TheaterBoardPreview {
    struct Lines: Equatable {
        let title: String
        let spoken: String?
    }

    static func lines(
        session: TheaterSessionMode,
        spokenDisplay: TheaterCaptionSpokenDisplay,
        sourceName: String,
        targetName: String
    ) -> Lines {
        if session == .transcription {
            return Lines(title: sourceName, spoken: nil)
        }
        switch spokenDisplay {
        case .isTheCaption:
            return Lines(title: sourceName, spoken: nil)
        case .hidden:
            return Lines(title: targetName, spoken: nil)
        case .paired, .pairedAfterPause:
            return Lines(title: targetName, spoken: sourceName)
        }
    }

    static func current(session: TheaterSessionMode, spokenMode: TheaterSpokenLineMode) -> Lines {
        self.lines(
            session: session,
            spokenDisplay: TheaterCaptionSpokenDisplay.resolved(
                mode: spokenMode,
                sameLanguage: SpokenLanguageResolver.isSameLanguagePair()
            ),
            sourceName: SpokenLanguageResolver.sourceLanguage().displayName,
            targetName: SpokenLanguageResolver.targetLanguage().displayName
        )
    }
}

/// Place Theater on the visible display. With no chosen position, Pop-up fills
/// that display on Open. A chosen position is used instead, including after
/// Open and when the display changes. A resize is kept for this open and
/// across Minimize. Overlay falls back to a caption bar and never upgrades a
/// thin frame to the whole screen.
enum TheaterWindowPlacement {
    static let legacyDefaultSize = CGSize(width: 1100, height: 440)

    static func resolvedFrame(
        stored: CGRect?,
        visible: CGRect,
        presentation: TheaterPresentationStyle = .popup,
        keepUserSize: Bool = false
    ) -> CGRect {
        if presentation == .transparent {
            return Self.resolvedOverlayFrame(stored: stored, visible: visible)
        }
        return Self.resolvedPopupFrame(stored: stored, visible: visible, keepUserSize: keepUserSize)
    }

    static func resolvedPopupFrame(
        stored: CGRect?,
        visible: CGRect,
        keepUserSize: Bool = false,
        preset: TheaterPositionPreset? = nil
    ) -> CGRect {
        if let preset {
            return preset.resolved(for: .popup).frame(in: visible)
        }
        if keepUserSize, let stored, stored.width > 200, stored.height > 160 {
            return Self.clamped(stored, to: visible)
        }
        return visible
    }

    /// Overlay caption bar is ~180 tall. Pop-up fills the display so the board
    /// is not stuck as a thin leftover strip.
    static func isOverlayCaptionBar(_ stored: CGRect, visible: CGRect) -> Bool {
        stored.height > 80
            && stored.height < 220
            && stored.width >= visible.width * 0.6
    }

    /// Auto-converted Overlay leftovers used to land on lower-third. Fill those
    /// unless the presenter picked Lower third as a preset.
    static func isLowerThirdLeftover(_ stored: CGRect, visible: CGRect) -> Bool {
        Self.isClose(stored, TheaterPositionPreset.lowerThird.frame(in: visible))
    }

    static func resolvedOverlayFrame(stored: CGRect?, visible: CGRect) -> CGRect {
        let fallback = TheaterPositionPreset.captionBar.frame(in: visible)
        guard let stored, stored.width > 200, stored.height > 80 else {
            return fallback
        }
        if Self.isLegacyDefault(stored) || Self.isFillScreen(stored, visible: visible) {
            return fallback
        }
        return Self.clamped(stored, to: visible)
    }

    static func shouldFillScreen(
        stored: CGRect,
        visible: CGRect,
        presentation: TheaterPresentationStyle = .popup
    ) -> Bool {
        if presentation == .transparent { return false }
        if visible.width < 200 || visible.height < 160 { return false }
        if Self.isLegacyDefault(stored) { return true }
        if stored.width < 700 || stored.height < 220 { return true }
        return false
    }

    static func isLegacyDefault(_ stored: CGRect) -> Bool {
        abs(stored.width - Self.legacyDefaultSize.width) < 80
            && abs(stored.height - Self.legacyDefaultSize.height) < 80
    }

    static func isFillScreen(_ stored: CGRect, visible: CGRect) -> Bool {
        stored.width >= visible.width - 20 && stored.height >= visible.height - 20
    }

    static func isClose(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 4 && abs(lhs.minY - rhs.minY) < 4
            && abs(lhs.width - rhs.width) < 4 && abs(lhs.height - rhs.height) < 4
    }

    /// Keep the whole board on the visible display. A frame that hangs off a
    /// corner is pulled back in, so a caption is not drawn off-screen.
    static func clamped(_ stored: CGRect, to visible: CGRect) -> CGRect {
        var placed = stored
        placed.size.width = min(max(placed.width, 1), visible.width)
        placed.size.height = min(max(placed.height, 1), visible.height)
        if placed.maxX > visible.maxX {
            placed.origin.x = visible.maxX - placed.width
        }
        if placed.minX < visible.minX {
            placed.origin.x = visible.minX
        }
        if placed.maxY > visible.maxY {
            placed.origin.y = visible.maxY - placed.height
        }
        if placed.minY < visible.minY {
            placed.origin.y = visible.minY
        }
        return placed
    }
}

/// One-click board positions on the chosen display. Fill screen covers the
/// visible display. The other presets stay inside a 5% safe margin.
enum TheaterPositionPreset: String, CaseIterable, Identifiable {
    case fillScreen
    case lowerThird
    case topBand
    case sideColumn
    case captionBar

    static let safeMargin: CGFloat = 0.05
    static let sideColumnMinimumWidth: CGFloat = 480
    static let captionBarHeight: CGFloat = 180

    var id: String { self.rawValue }

    var displayName: String {
        switch self {
        case .fillScreen: "Fill screen"
        case .lowerThird: "Lower third"
        case .topBand: "Top band"
        case .sideColumn: "Side column"
        case .captionBar: "Caption bar"
        }
    }

    func isAvailable(for presentation: TheaterPresentationStyle) -> Bool {
        switch self {
        case .fillScreen: presentation == .popup
        case .captionBar: presentation == .transparent
        default: true
        }
    }

    /// Overlay caption bar becomes Fill screen on Pop-up, and the reverse.
    func resolved(for presentation: TheaterPresentationStyle) -> TheaterPositionPreset {
        switch (self, presentation) {
        case (.captionBar, .popup): .fillScreen
        case (.fillScreen, .transparent): .captionBar
        default: self
        }
    }

    static func available(for presentation: TheaterPresentationStyle) -> [Self] {
        Self.allCases.filter { $0.isAvailable(for: presentation) }
    }

    func frame(in visible: CGRect) -> CGRect {
        let safe = visible.insetBy(
            dx: visible.width * Self.safeMargin,
            dy: visible.height * Self.safeMargin
        )
        switch self {
        case .fillScreen:
            return visible
        case .lowerThird:
            return CGRect(x: safe.minX, y: safe.minY, width: safe.width, height: safe.height / 3)
        case .topBand:
            let height = safe.height / 3
            return CGRect(x: safe.minX, y: safe.maxY - height, width: safe.width, height: height)
        case .sideColumn:
            let width = min(safe.width, max(safe.width * 0.32, Self.sideColumnMinimumWidth))
            return CGRect(x: safe.maxX - width, y: safe.minY, width: width, height: safe.height)
        case .captionBar:
            let height = min(Self.captionBarHeight, safe.height)
            return CGRect(x: safe.minX, y: safe.minY, width: safe.width, height: height)
        }
    }
}

/// Grow captions with the board so a full-screen window is not stuck at 42 pt.
enum TheaterCaptionScale {
    static let referenceWidth: CGFloat = 1100
    static let maxPointSize: CGFloat = 160
    /// Show-as line relative to the caption setting.
    static let translatedMultiplier: CGFloat = 1.4
    /// Spoken undertone relative to the caption setting.
    static let spokenMultiplier: CGFloat = 0.7

    static func displaySize(setting: CGFloat, stageWidth: CGFloat) -> CGFloat {
        let base = max(setting, 1)
        guard stageWidth > Self.referenceWidth + 1 else { return base }
        return min(base * (stageWidth / Self.referenceWidth), Self.maxPointSize)
    }

    static func spokenSize(setting: CGFloat) -> CGFloat {
        max(setting * Self.spokenMultiplier, 1)
    }

    static func translatedSize(setting: CGFloat) -> CGFloat {
        min(max(setting, 1) * Self.translatedMultiplier, Self.maxPointSize)
    }

    static func sizes(setting: CGFloat, stageWidth: CGFloat) -> (spoken: CGFloat, translated: CGFloat) {
        let display = Self.displaySize(setting: setting, stageWidth: stageWidth)
        return (Self.spokenSize(setting: display), Self.translatedSize(setting: display))
    }

    /// Shrink a width-scaled size until `pairHeight` fits the stage. A wide,
    /// short board (the Overlay caption bar) was scaling type from the width
    /// until the title was taller than the window and the top was clipped.
    static func fittedDisplaySize(
        proposed: CGFloat,
        stageHeight: CGFloat,
        pairHeight: (CGFloat) -> CGFloat
    ) -> CGFloat {
        let proposed = min(max(proposed, 1), Self.maxPointSize)
        guard stageHeight > 1 else { return proposed }
        if pairHeight(proposed) <= stageHeight { return proposed }
        let floorSize: CGFloat = 8
        if pairHeight(floorSize) > stageHeight { return floorSize }
        var low = floorSize
        var high = proposed
        while high - low > 0.5 {
            let mid = (low + high) / 2
            if pairHeight(mid) <= stageHeight {
                low = mid
            } else {
                high = mid
            }
        }
        return floor(low)
    }

    /// Point-size change that is large enough to rewrap on purpose.
    /// Smaller ticks keep the size already on screen.
    static let displaySizeHysteresis: CGFloat = 4

    /// Keep the size the audience is already reading. A geometry tick must
    /// not rewrap every line. Shrink when the locked size no longer fits.
    /// Grow only when the board is meaningfully larger and that size fits.
    static func resolvedDisplaySize(
        proposed: CGFloat,
        locked: CGFloat,
        lockedFits: Bool
    ) -> CGFloat {
        let proposed = min(max(proposed, 1), Self.maxPointSize)
        guard locked >= 8 else { return proposed }
        if !lockedFits {
            return proposed
        }
        if proposed + 0.5 < locked {
            return proposed
        }
        if proposed > locked + Self.displaySizeHysteresis {
            return proposed
        }
        return locked
    }
}

/// Keep the live row on screen without flipping top/bottom every height tick.
enum TheaterBoardScroll {
    static let viewportSlop: CGFloat = 8

    static func pinsToBottom(boardHeight: CGFloat, viewportHeight: CGFloat) -> Bool {
        boardHeight + Self.viewportSlop > viewportHeight
    }

    /// A caption taller than the area under the buttons shows its opening
    /// line. Pinning that caption to the bottom would hide the top of the text.
    static func showsOpeningOfLine(lineHeight: CGFloat, viewportHeight: CGFloat) -> Bool {
        lineHeight + Self.viewportSlop > viewportHeight
    }

    static func shouldFollowReveal(from previous: CGFloat, to next: CGFloat) -> Bool {
        next > previous + 0.5
    }
}
