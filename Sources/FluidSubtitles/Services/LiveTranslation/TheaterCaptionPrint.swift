import CoreGraphics
import Foundation

/// When the original language prints under Show-as.
enum TheaterSpokenLineMode: String, CaseIterable, Identifiable {
    case off
    case afterPause
    case whileTalking

    var id: String { self.rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .afterPause: return "After a pause"
        case .whileTalking: return "While talking"
        }
    }

    var help: String {
        switch self {
        case .off:
            return "Translation only. The original language stays off the board."
        case .afterPause:
            return "The original language prints under the sentence after you pause."
        case .whileTalking:
            return "The original language grows under the title while you talk."
        }
    }

    var printsLiveSpoken: Bool { self == .whileTalking }

    /// Prefetch Show-as as the leftover grows. No prior-clause window.
    var translatesLive: Bool { self == .whileTalking }

    /// Hold Apple Translation until a pause, then send the whole leftover.
    var holdsTranslationUntilPause: Bool { self == .afterPause }

    var showsSpokenLine: Bool { self != .off }

    static func resolved(_ stored: String?) -> TheaterSpokenLineMode {
        let trimmed = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Self(rawValue: trimmed) ?? .afterPause
    }

    /// Old Show the spoken line toggle. On becomes After a pause.
    static func migrated(fromShowSource show: Bool?) -> TheaterSpokenLineMode {
        show == false ? .off : .afterPause
    }
}

/// How the spoken line is placed on the live row.
enum TheaterCaptionSpokenDisplay: Equatable {
    /// Translation title on top; spoken undertone underneath, including live leftover.
    case paired
    /// Spoken waits for a settled clause. Pending and committed rows still pair.
    case pairedAfterPause
    /// Same-language: the spoken text is the caption.
    case isTheCaption
    /// Translation only. Spoken text must not flash.
    case hidden

    var queuesSpokenPending: Bool {
        self == .paired || self == .pairedAfterPause
    }

    var printsSpokenOnLive: Bool {
        self == .paired
    }

    var printsSpokenOnCommitted: Bool {
        self == .paired || self == .pairedAfterPause
    }

    static func resolved(mode: TheaterSpokenLineMode, sameLanguage: Bool) -> TheaterCaptionSpokenDisplay {
        if sameLanguage { return .isTheCaption }
        switch mode {
        case .off: return .hidden
        case .afterPause: return .pairedAfterPause
        case .whileTalking: return .paired
        }
    }

    static func resolved(showSpokenLine: Bool, sameLanguage: Bool) -> TheaterCaptionSpokenDisplay {
        self.resolved(mode: showSpokenLine ? .whileTalking : .off, sameLanguage: sameLanguage)
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

/// Place Theater on the visible display. Pop-up fills that display on Open.
/// A resized frame is kept only when asked (Minimize). Overlay falls back to
/// a caption bar and never upgrades a thin frame to the whole screen.
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
        keepUserSize: Bool = false
    ) -> CGRect {
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

    static func clamped(_ stored: CGRect, to visible: CGRect) -> CGRect {
        var placed = stored
        if !visible.intersects(placed) {
            placed.size.width = min(placed.width, visible.width)
            placed.size.height = min(placed.height, visible.height)
            placed.origin.x = visible.midX - placed.width / 2
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
}

/// Keep the live row on screen without flipping top/bottom every height tick.
enum TheaterBoardScroll {
    static let viewportSlop: CGFloat = 8

    static func pinsToBottom(boardHeight: CGFloat, viewportHeight: CGFloat) -> Bool {
        boardHeight + Self.viewportSlop > viewportHeight
    }

    static func shouldFollowReveal(from previous: CGFloat, to next: CGFloat) -> Bool {
        next > previous + 0.5
    }
}
