import SwiftUI

/// Caption-window plates. Home and settings leave this unset and use the app theme.
struct TheaterButtonColors: Equatable {
    var fill: Color
    var stroke: Color
    var foreground: Color
}

private struct TheaterButtonColorsKey: EnvironmentKey {
    static let defaultValue: TheaterButtonColors? = nil
}

extension EnvironmentValues {
    var theaterButtonColors: TheaterButtonColors? {
        get { self[TheaterButtonColorsKey.self] }
        set { self[TheaterButtonColorsKey.self] = newValue }
    }
}

/// Dark ink on caption gold. White on the accent fails contrast.
enum TheaterButtonInk {
    static let onAccent = Color(red: 0.11, green: 0.08, blue: 0.05)
}

private struct TheaterButtonPaint {
    var fill: Color
    var stroke: Color
    var foreground: Color

    static func resolve(
        theme: AppTheme,
        chrome: TheaterButtonColors?,
        prominent: Bool,
        hovered: Bool,
        pressed: Bool,
        enabled: Bool
    ) -> TheaterButtonPaint {
        if prominent {
            let ink = TheaterButtonInk.onAccent
            return TheaterButtonPaint(
                fill: theme.palette.accent.opacity(enabled ? (pressed ? 0.82 : (hovered ? 1 : 0.94)) : 0.38),
                stroke: Color.black.opacity(enabled ? (hovered ? 0.28 : 0.16) : 0.08),
                foreground: enabled ? ink : ink.opacity(0.55)
            )
        }

        if let chrome {
            return TheaterButtonPaint(
                fill: chrome.fill.opacity(enabled ? (hovered ? 1 : 0.94) : 0.45),
                stroke: chrome.stroke.opacity(enabled ? (hovered ? 1 : 0.8) : 0.28),
                foreground: enabled ? chrome.foreground : chrome.foreground.opacity(0.4)
            )
        }

        let accent = theme.palette.accent
        return TheaterButtonPaint(
            fill: accent.opacity(enabled ? (hovered || pressed ? 0.22 : 0.14) : 0.06),
            stroke: accent.opacity(enabled ? (hovered ? 0.8 : 0.55) : 0.22),
            foreground: enabled ? theme.palette.primaryText : theme.palette.tertiaryText
        )
    }
}

/// Rounded control with a fill and a stroke. Prominent actions use the accent fill.
struct TheaterButtonFace: ViewModifier {
    var prominent = false
    var compact = false
    var pressed = false

    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.theaterButtonColors) private var chromeColors
    @State private var hovered = false

    func body(content: Content) -> some View {
        let paint = TheaterButtonPaint.resolve(
            theme: self.theme,
            chrome: self.chromeColors,
            prominent: self.prominent,
            hovered: self.hovered,
            pressed: self.pressed,
            enabled: self.isEnabled
        )
        let corner: CGFloat = self.compact ? 6 : 8
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)

        content
            .font(self.compact ? self.theme.typography.captionStrong : self.theme.typography.bodyStrong)
            .lineLimit(1)
            .padding(.horizontal, self.compact ? 8 : 12)
            .padding(.vertical, self.compact ? 4 : 6)
            .frame(minHeight: self.compact ? 26 : 32)
            .foregroundStyle(paint.foreground)
            .background(shape.fill(paint.fill))
            .overlay(shape.strokeBorder(paint.stroke, lineWidth: 1))
            .contentShape(shape)
            .animation(.easeOut(duration: 0.12), value: self.hovered)
            .animation(.easeOut(duration: 0.1), value: self.pressed)
            .onHover { self.hovered = $0 }
    }
}

/// Word plus the symbol for that action. The word stays; the symbol says which control it is.
struct TheaterActionLabel: View {
    let title: String
    var systemImage: String?
    var compact = false
    /// Bumps once when Copy lands on the pasteboard.
    var symbolBounce = 0
    var reduceMotion = false

    var body: some View {
        HStack(spacing: self.compact ? 4 : 6) {
            if let systemImage {
                self.symbol(systemImage)
            }
            Text(self.title)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func symbol(_ name: String) -> some View {
        let image = Image(systemName: name)
            .font(.system(size: self.compact ? 11 : 13, weight: .semibold))
            .accessibilityHidden(true)
        if self.reduceMotion {
            image
        } else {
            image.symbolEffect(.bounce, value: self.symbolBounce)
        }
    }
}

extension View {
    func theaterButtonFace(prominent: Bool = false, compact: Bool = false) -> some View {
        self.modifier(TheaterButtonFace(prominent: prominent, compact: compact))
    }
}

/// A pressable control. `prominent` is the accent action (Listen, Continue).
struct TheaterTextButtonStyle: ButtonStyle {
    var prominent = false
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(TheaterButtonFace(
                prominent: self.prominent,
                compact: self.compact,
                pressed: configuration.isPressed
            ))
    }
}

extension ButtonStyle where Self == TheaterTextButtonStyle {
    static var theaterText: TheaterTextButtonStyle { TheaterTextButtonStyle() }
    static var theaterTextProminent: TheaterTextButtonStyle { TheaterTextButtonStyle(prominent: true) }
    static var theaterTextCompact: TheaterTextButtonStyle { TheaterTextButtonStyle(compact: true) }
    static var theaterTextCompactProminent: TheaterTextButtonStyle {
        TheaterTextButtonStyle(prominent: true, compact: true)
    }
}

/// Active option is an accent button. The others stay outlined.
struct TheaterWordPicker<Option: Hashable>: View {
    var accessibilityLabel: String
    var accessibilityIdentifier: String?
    let options: [Option]
    let title: (Option) -> String
    @Binding var selection: Option

    @Environment(\.theaterButtonColors) private var chromeColors

    var body: some View {
        HStack(spacing: 4) {
            ForEach(self.options, id: \.self) { option in
                let selected = option == self.selection
                Button(self.title(option)) {
                    self.selection = option
                }
                .buttonStyle(TheaterTextButtonStyle(
                    prominent: selected,
                    compact: self.chromeColors != nil
                ))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(self.accessibilityLabel)
        .modifier(TheaterOptionalIdentifier(identifier: self.accessibilityIdentifier))
    }
}

private struct TheaterOptionalIdentifier: ViewModifier {
    let identifier: String?

    func body(content: Content) -> some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}
