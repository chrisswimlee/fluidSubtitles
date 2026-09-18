import CoreGraphics
import Foundation

/// How the live Theater row appears. Flow and Word type the current title
/// through commit. Fade and Instant snap. History remounts snap.
enum TheaterCaptionPrintStyle: String, CaseIterable, Identifiable {
    case flow
    case word
    case fade
    case instant

    var id: String { self.rawValue }

    var displayName: String {
        switch self {
        case .flow: return "Flow"
        case .word: return "Word"
        case .fade: return "Fade"
        case .instant: return "Instant"
        }
    }

    var help: String {
        switch self {
        case .flow:
            return "Letters type in one at a time, with a short breath at commas and periods."
        case .word:
            return "One word, or a few Korean, Japanese, or Thai syllables, at a time."
        case .fade:
            return "The current caption fades in."
        case .instant:
            return "The current caption appears all at once."
        }
    }

    var typesIn: Bool {
        self == .flow || self == .word
    }

    var fadesIn: Bool {
        self == .fade
    }

    var printStepSeconds: TimeInterval {
        switch self {
        case .flow: return Self.latinFlowStepSeconds
        case .word: return Self.latinWordStepSeconds
        case .fade, .instant: return 0
        }
    }

    /// One Latin letter. Close to reading pace, not a four-letter dump.
    static let catchUpBacklogCharacters = 40
    static let catchUpSpeedFactor: TimeInterval = 0.35
    static let latinFlowStepSeconds: TimeInterval = 0.038
    /// Compact Show-as titles walk slower so Korean reads as a title, not a dump.
    static let compactFlowStepSeconds: TimeInterval = 0.068
    static let latinWordStepSeconds: TimeInterval = 0.22
    static let compactWordStepSeconds: TimeInterval = 0.16

    func printStepSeconds(forTitle title: String) -> TimeInterval {
        let compact = Self.titleUsesCompactScript(title)
        switch self {
        case .flow:
            return compact ? Self.compactFlowStepSeconds : Self.latinFlowStepSeconds
        case .word:
            return compact ? Self.compactWordStepSeconds : Self.latinWordStepSeconds
        case .fade, .instant:
            return 0
        }
    }

    /// Next tick after what is already on screen. Slows at word and sentence
    /// edges. Must check spoken before translated, matching the order
    /// TheaterLinePrinter.nextPrintStep advances (top row first) — otherwise
    /// this times the tick off a string that is not the one being typed.
    func printStepSeconds(
        printedSpoken: String,
        targetSpoken: String,
        printedTranslated: String,
        targetTranslated: String
    ) -> TimeInterval {
        if printedSpoken != targetSpoken {
            return self.printStepSeconds(after: printedSpoken, toward: targetSpoken)
        }
        if printedTranslated != targetTranslated {
            return self.printStepSeconds(after: printedTranslated, toward: targetTranslated)
        }
        return 0
    }

    func printStepSeconds(after printed: String, toward target: String) -> TimeInterval {
        var step = self.printStepSeconds(forTitle: target.isEmpty ? printed : target)
        guard self.typesIn else { return step }
        let rest: String
        if target.hasPrefix(printed) {
            rest = String(target.dropFirst(printed.count))
        } else {
            rest = target
        }
        guard let next = rest.first else { return step }
        // A big chunk landing at once (pause reveal, slow translation) must
        // not type for seconds behind the speaker's voice.
        if rest.count > Self.catchUpBacklogCharacters {
            return step * Self.catchUpSpeedFactor
        }
        if self == .flow {
            if next.isWhitespace {
                step += 0.028
            } else if Self.sentencePauseCharacters.contains(next) {
                step += 0.14
            } else if Self.commaPauseCharacters.contains(next) {
                step += 0.07
            }
        } else if self == .word, let last = printed.last, Self.sentencePauseCharacters.contains(last) {
            step += 0.12
        }
        return step
    }

    private static let sentencePauseCharacters: Set<Character> = [".", "!", "?", "。", "！", "？"]
    private static let commaPauseCharacters: Set<Character> = [",", ";", ":", "，", "、"]

    static func titleUsesCompactScript(_ text: String) -> Bool {
        text.contains { character in
            !character.isASCII && !character.isWhitespace && !character.isNewline
        }
    }

    static func resolved(_ stored: String?) -> TheaterCaptionPrintStyle {
        let trimmed = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Self(rawValue: trimmed) ?? .flow
    }
}

/// How the spoken line is placed on the live row.
enum TheaterCaptionSpokenDisplay: Equatable {
    /// Translation title on top; spoken undertone underneath.
    case paired
    /// Same-language: the spoken text is the caption.
    case isTheCaption
    /// Translation only. Spoken text must not flash.
    case hidden

    static func resolved(showSpokenLine: Bool, sameLanguage: Bool) -> TheaterCaptionSpokenDisplay {
        if sameLanguage { return .isTheCaption }
        return showSpokenLine ? .paired : .hidden
    }
}

/// Place Theater on the visible display. Pop-up still fills when there is no
/// useful stored frame. Overlay falls back to a caption bar and never upgrades
/// a thin frame to the whole screen.
enum TheaterWindowPlacement {
    static let legacyDefaultSize = CGSize(width: 1100, height: 440)

    static func resolvedFrame(
        stored: CGRect?,
        visible: CGRect,
        presentation: TheaterPresentationStyle = .popup
    ) -> CGRect {
        if presentation == .transparent {
            return Self.resolvedOverlayFrame(stored: stored, visible: visible)
        }
        return Self.resolvedPopupFrame(stored: stored, visible: visible)
    }

    static func resolvedPopupFrame(stored: CGRect?, visible: CGRect) -> CGRect {
        guard let stored, stored.width > 200, stored.height > 160 else {
            return visible
        }
        if Self.shouldFillScreen(stored: stored, visible: visible, presentation: .popup) {
            return visible
        }
        return Self.clamped(stored, to: visible)
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
        abs(stored.width - visible.width) < 20 && abs(stored.height - visible.height) < 20
    }

    private static func clamped(_ stored: CGRect, to visible: CGRect) -> CGRect {
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

/// One-click board positions on the chosen display, inside a 5% safe margin.
enum TheaterPositionPreset: String, CaseIterable, Identifiable {
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
        case .lowerThird: "Lower third"
        case .topBand: "Top band"
        case .sideColumn: "Side column"
        case .captionBar: "Caption bar"
        }
    }

    func frame(in visible: CGRect) -> CGRect {
        let safe = visible.insetBy(
            dx: visible.width * Self.safeMargin,
            dy: visible.height * Self.safeMargin
        )
        switch self {
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
