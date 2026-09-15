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

    /// Next tick after what is already on screen. Slows at word and sentence edges.
    func printStepSeconds(
        printedSpoken: String,
        targetSpoken: String,
        printedTranslated: String,
        targetTranslated: String
    ) -> TimeInterval {
        if printedTranslated != targetTranslated {
            return self.printStepSeconds(after: printedTranslated, toward: targetTranslated)
        }
        if printedSpoken != targetSpoken {
            return self.printStepSeconds(after: printedSpoken, toward: targetSpoken)
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

/// Place Theater on the visible display. The old 1100×440 default left most of the screen unused.
enum TheaterWindowPlacement {
    static let legacyDefaultSize = CGSize(width: 1100, height: 440)

    static func resolvedFrame(stored: CGRect?, visible: CGRect) -> CGRect {
        guard let stored, stored.width > 200, stored.height > 160 else {
            return visible
        }
        if Self.shouldFillScreen(stored: stored, visible: visible) {
            return visible
        }
        var placed = stored
        if !visible.intersects(placed) {
            placed.size.width = min(placed.width, visible.width)
            placed.size.height = min(placed.height, visible.height)
            placed.origin.x = visible.midX - placed.width / 2
            placed.origin.y = visible.minY
        }
        return placed
    }

    static func shouldFillScreen(stored: CGRect, visible: CGRect) -> Bool {
        if visible.width < 200 || visible.height < 160 { return false }
        let legacyWidth = abs(stored.width - Self.legacyDefaultSize.width) < 80
        let legacyHeight = abs(stored.height - Self.legacyDefaultSize.height) < 80
        if legacyWidth && legacyHeight { return true }
        if stored.width < 700 || stored.height < 220 { return true }
        return false
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
