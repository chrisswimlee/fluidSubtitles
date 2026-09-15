import AppKit
import SwiftUI

/// Caption and chrome colors that stay readable on the Theater board.
/// Transparent Light used to paint black text with a black halo, so captions vanished on slides.
enum TheaterCaptionVisibility {
    struct Colors {
        let spoken: NSColor
        let translated: NSColor
        let empty: Color
        let chrome: Color
        let menuFill: Color
        let menuStroke: Color
        let shadowColor: NSColor?
        let shadowBlur: CGFloat
    }

    static func colors(
        appearance: TheaterAppearance,
        presentation: TheaterPresentationStyle,
        highContrast: Bool
    ) -> Colors {
        switch presentation {
        case .transparent:
            return Colors(
                spoken: NSColor.white.withAlphaComponent(highContrast ? 0.78 : 0.58),
                translated: .white,
                empty: Color.white.opacity(0.92),
                chrome: Color.white.opacity(0.90),
                menuFill: Color.black.opacity(0.62),
                menuStroke: Color.white.opacity(0.55),
                shadowColor: NSColor.black.withAlphaComponent(highContrast ? 0.96 : 0.90),
                shadowBlur: highContrast ? 6 : 4
            )
        case .popup:
            if appearance == .light {
                return Colors(
                    spoken: NSColor.black.withAlphaComponent(highContrast ? 0.72 : 0.50),
                    translated: .black,
                    empty: Color.black.opacity(0.72),
                    chrome: Color.black.opacity(0.78),
                    menuFill: Color.white.opacity(0.96),
                    menuStroke: Color.black.opacity(0.28),
                    shadowColor: highContrast ? NSColor.white.withAlphaComponent(0.85) : nil,
                    shadowBlur: highContrast ? 2 : 0
                )
            }
            return Colors(
                spoken: NSColor.white.withAlphaComponent(highContrast ? 0.78 : 0.58),
                translated: .white,
                empty: Color.white.opacity(0.82),
                chrome: Color.white.opacity(0.86),
                menuFill: Color.white.opacity(0.16),
                menuStroke: Color.white.opacity(0.42),
                shadowColor: highContrast ? NSColor.black.withAlphaComponent(0.85) : nil,
                shadowBlur: highContrast ? 3 : 0
            )
        }
    }

    /// Printed translations stay fully opaque. Older spoken lines stay just under full.
    static func appliedAlphas(
        spoken: NSColor,
        translated: NSColor,
        isCurrent: Bool
    ) -> (spoken: NSColor, translated: NSColor) {
        if isCurrent {
            return (spoken, translated)
        }
        return (spoken.withAlphaComponent(0.92), translated.withAlphaComponent(1))
    }
}
