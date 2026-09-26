import AppKit
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

/// Dark ink on caption gold. White on gold fails contrast. Stop uses white on system red.
enum TheaterButtonInk {
    static let onAccent = Color(red: 0.11, green: 0.08, blue: 0.05)
    static let onStop = Color.white
}

private struct TheaterButtonPaint {
    var fill: Color
    var stroke: Color
    var foreground: Color

    static func resolve(
        theme: AppTheme,
        chrome: TheaterButtonColors?,
        prominent: Bool,
        stop: Bool,
        destructive: Bool,
        hovered: Bool,
        pressed: Bool,
        enabled: Bool
    ) -> TheaterButtonPaint {
        if stop {
            let red = Color(nsColor: .systemRed)
            return TheaterButtonPaint(
                fill: red.opacity(enabled ? (pressed ? 0.82 : 1) : 0.38),
                stroke: Color.black.opacity(enabled ? (pressed ? 0.34 : 0.18) : 0.08),
                foreground: enabled ? TheaterButtonInk.onStop : TheaterButtonInk.onStop.opacity(0.7)
            )
        }

        if prominent {
            let ink = TheaterButtonInk.onAccent
            return TheaterButtonPaint(
                fill: theme.palette.accent.opacity(enabled ? (pressed ? 0.82 : 1) : 0.38),
                stroke: Color.black.opacity(enabled ? (pressed ? 0.34 : (hovered ? 0.28 : 0.16)) : 0.08),
                foreground: enabled ? ink : ink.opacity(0.55)
            )
        }

        if destructive {
            let red = Color(nsColor: .systemRed)
            return TheaterButtonPaint(
                fill: red.opacity(enabled ? (pressed ? 0.22 : (hovered ? 0.14 : 0.08)) : 0.04),
                stroke: red.opacity(enabled ? (pressed ? 1 : (hovered ? 0.9 : 0.65)) : 0.28),
                foreground: enabled ? red : red.opacity(0.45)
            )
        }

        if let chrome {
            return TheaterButtonPaint(
                fill: chrome.fill.opacity(enabled ? (pressed ? 0.72 : (hovered ? 1 : 0.94)) : 0.45),
                stroke: chrome.stroke.opacity(enabled ? (pressed ? 1 : (hovered ? 1 : 0.8)) : 0.28),
                foreground: enabled ? chrome.foreground : chrome.foreground.opacity(0.4)
            )
        }

        let accent = theme.palette.accent
        return TheaterButtonPaint(
            fill: accent.opacity(enabled ? (pressed ? 0.34 : (hovered ? 0.22 : 0.14)) : 0.06),
            stroke: accent.opacity(enabled ? (pressed ? 0.95 : (hovered ? 0.8 : 0.55)) : 0.22),
            foreground: enabled ? theme.palette.primaryText : theme.palette.tertiaryText
        )
    }
}

/// Rounded control with a fill and a stroke. Prominent actions use the accent fill.
struct TheaterButtonFace: ViewModifier {
    var prominent = false
    var compact = false
    /// Square plate for a symbol with no word. Same height as a compact word button.
    var iconOnly = false
    var stop = false
    var destructive = false
    var pressed = false

    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.theaterButtonColors) private var chromeColors
    @State private var hovered = false

    func body(content: Content) -> some View {
        let paint = TheaterButtonPaint.resolve(
            theme: self.theme,
            chrome: self.chromeColors,
            prominent: self.prominent,
            stop: self.stop,
            destructive: self.destructive,
            hovered: self.hovered && self.isEnabled,
            pressed: self.pressed && self.isEnabled,
            enabled: self.isEnabled
        )
        let corner: CGFloat = self.compact ? 6 : 8
        let minHeight: CGFloat = self.compact ? 24 : 32
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        let motion: Animation? = self.reduceMotion ? nil : .easeOut(duration: 0.12)

        content
            .font(self.compact ? self.theme.typography.captionStrong : self.theme.typography.bodyStrong)
            .lineLimit(1)
            .padding(.horizontal, self.iconOnly ? 0 : (self.compact ? 8 : 12))
            .padding(.vertical, self.compact ? 2 : 6)
            .frame(minWidth: self.iconOnly ? minHeight : nil, minHeight: minHeight)
            .foregroundStyle(paint.foreground)
            .background(shape.fill(paint.fill))
            .overlay(shape.strokeBorder(paint.stroke, lineWidth: 1))
            .overlay {
                RoundedRectangle(cornerRadius: corner + 3, style: .continuous)
                    .strokeBorder(self.theme.palette.primaryText.opacity(self.isFocused ? 1 : 0), lineWidth: 2)
                    .padding(-4)
            }
            .contentShape(shape)
            .animation(motion, value: self.hovered)
            .animation(self.reduceMotion ? nil : .easeOut(duration: 0.1), value: self.pressed)
            .animation(motion, value: self.isFocused)
            .onContinuousHover { phase in
                let next: Bool
                switch phase {
                case .active:
                    next = self.isEnabled
                case .ended:
                    next = false
                }
                if next != self.hovered {
                    self.hovered = next
                }
            }
            .onChange(of: self.isEnabled) { _, enabled in
                if !enabled {
                    self.hovered = false
                }
            }
    }
}

/// Word, symbol, or both. Caption-bar utilities keep the word in the hover tag.
struct TheaterActionLabel: View {
    let title: String
    var systemImage: String?
    var compact = false
    var showsTitle = true

    var body: some View {
        HStack(spacing: self.compact ? 4 : 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: self.compact ? 11 : 13, weight: .semibold))
                    .accessibilityHidden(true)
            }
            if self.showsTitle {
                Text(self.title)
                    .lineLimit(1)
            }
        }
    }
}

extension View {
    func theaterButtonFace(
        prominent: Bool = false,
        compact: Bool = false,
        iconOnly: Bool = false,
        stop: Bool = false,
        destructive: Bool = false
    ) -> some View {
        self.modifier(TheaterButtonFace(
            prominent: prominent,
            compact: compact,
            iconOnly: iconOnly,
            stop: stop,
            destructive: destructive
        ))
    }

    /// Caption-bar menu. The label draws the chevron so it sits inside the plate.
    func theaterBarMenu() -> some View {
        self
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize(horizontal: true, vertical: true)
            .controlSize(.small)
    }
}

/// A pressable control. `prominent` is the accent action (Listen, Continue).
struct TheaterTextButtonStyle: ButtonStyle {
    var prominent = false
    var compact = false
    var iconOnly = false
    var stop = false
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(TheaterButtonFace(
                prominent: self.prominent,
                compact: self.compact,
                iconOnly: self.iconOnly,
                stop: self.stop,
                destructive: self.destructive,
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

    static var theaterTextCompactIcon: TheaterTextButtonStyle {
        TheaterTextButtonStyle(compact: true, iconOnly: true)
    }

    static var theaterTextIcon: TheaterTextButtonStyle {
        TheaterTextButtonStyle(iconOnly: true)
    }

    /// Filled red. Stop stays findable while Listen is on.
    static var theaterTextStop: TheaterTextButtonStyle { TheaterTextButtonStyle(stop: true) }
    static var theaterTextCompactStop: TheaterTextButtonStyle {
        TheaterTextButtonStyle(compact: true, stop: true)
    }

    /// Red outline. Remove and Clear stay quieter than Listen and Stop.
    static var theaterTextDestructive: TheaterTextButtonStyle {
        TheaterTextButtonStyle(destructive: true)
    }
}

/// Menu title with the chevron inside the same plate as word buttons.
/// `role` is the quiet name of the control ("I speak"). The title is the value.
struct TheaterMenuLabel: View {
    var title: String
    var systemImage: String?
    var role: String?
    var compact = false
    var minWidth: CGFloat?

    var body: some View {
        HStack(spacing: self.compact ? 5 : 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: self.compact ? 11 : 13, weight: .semibold))
                    .accessibilityHidden(true)
            }
            if let role, !role.isEmpty {
                Text(role)
                    .font(.system(size: self.compact ? 10 : 12, weight: .semibold))
                    .opacity(0.58)
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }
            Text(self.title)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: self.compact ? 8 : 9, weight: .bold))
                .opacity(0.72)
                .accessibilityHidden(true)
        }
        .frame(minWidth: self.minWidth, alignment: .leading)
        .theaterButtonFace(compact: self.compact)
    }
}

/// Status, pace, and notes. Same height family as a compact button, no chevron,
/// so a readout is not mistaken for a menu.
struct TheaterReadoutPlate: ViewModifier {
    var tint: Color?

    @Environment(\.theme) private var theme
    @Environment(\.theaterButtonColors) private var chrome

    func body(content: Content) -> some View {
        let ink = self.tint ?? self.chrome?.foreground ?? self.theme.palette.secondaryText
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        content
            .font(self.theme.typography.caption)
            .foregroundStyle(ink)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background {
                shape.fill((self.chrome?.fill ?? self.theme.palette.accent).opacity(self.tint == nil ? 0.42 : 0.18))
            }
            .overlay {
                shape.strokeBorder((self.tint ?? self.chrome?.stroke ?? self.theme.palette.separator).opacity(0.55), lineWidth: 1)
            }
            .fixedSize(horizontal: true, vertical: true)
    }
}

extension View {
    func theaterReadoutPlate(tint: Color? = nil) -> some View {
        self.modifier(TheaterReadoutPlate(tint: tint))
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
        TheaterChoiceFlow(spacing: 4) {
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

/// Choice chips wrap onto the next line instead of drawing through each other.
private struct TheaterChoiceFlow: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width: CGFloat
        if let proposed = proposal.width, proposed.isFinite, proposed > 0 {
            width = proposed
        } else {
            width = self.idealWidth(subviews)
        }
        return self.place(subviews, width: width, proposal: proposal).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let laid = self.place(subviews, width: bounds.width, proposal: proposal)
        for (index, point) in laid.origins.enumerated() where index < subviews.count {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                proposal: ProposedViewSize(subviews[index].sizeThatFits(.unspecified))
            )
        }
    }

    private func idealWidth(_ subviews: Subviews) -> CGFloat {
        let widths = subviews.map { $0.sizeThatFits(.unspecified).width }
        let gaps = self.spacing * CGFloat(max(subviews.count - 1, 0))
        return widths.reduce(0, +) + gaps
    }

    private func place(
        _ subviews: Subviews,
        width: CGFloat,
        proposal _: ProposedViewSize
    ) -> (size: CGSize, origins: [CGPoint]) {
        let limit = max(width, 1)
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > limit {
                x = 0
                y += rowHeight + self.spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + self.spacing
            usedWidth = max(usedWidth, x - self.spacing)
        }
        return (CGSize(width: min(usedWidth, limit), height: y + rowHeight), origins)
    }
}

/// Language menu for I speak and Show as.
struct TheaterLanguageMenu: View {
    var title: String
    @Binding var selection: String
    var languages: [TranslationLanguage] = TranslationLanguageCatalog.menuOrder
    var compactChrome = false

    private var selectedName: String {
        self.languages.first(where: { $0.id == self.selection })?.displayName
            ?? TranslationLanguageCatalog.language(id: self.selection)?.displayName
            ?? self.selection
    }

    var body: some View {
        self.styledMenu
            .accessibilityLabel(self.title)
            .accessibilityValue(self.selectedName)
    }

    private var menu: some View {
        Menu {
            Picker(self.title, selection: self.$selection) {
                ForEach(self.languages) { language in
                    Text(language.displayName).tag(language.id)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            self.label
        }
    }

    @ViewBuilder
    private var styledMenu: some View {
        let menu = self.menu.theaterBarMenu()
        if self.compactChrome {
            menu
        } else {
            menu.help("Languages Apple Translation and the Voice Engine both support.")
        }
    }

    private var label: some View {
        TheaterMenuLabel(
            title: self.selectedName,
            role: self.title,
            compact: self.compactChrome,
            minWidth: self.compactChrome ? nil : 168
        )
    }
}

/// Spoken line is the same menu on Home, Settings, Setup, and the caption bar.
struct TheaterSpokenLinePicker: View {
    var accessibilityIdentifier: String
    /// Caption bar. The role sits inside the plate, the same way I speak does.
    var compact = false
    var apply: ((TheaterSpokenLineMode) -> Void)?

    @ObservedObject private var settings = SettingsStore.shared

    private var selection: Binding<TheaterSpokenLineMode> {
        Binding(
            get: { self.settings.theaterSpokenLineMode },
            set: { mode in
                if let apply = self.apply {
                    apply(mode)
                } else {
                    self.settings.theaterSpokenLineMode = mode
                }
            }
        )
    }

    var body: some View {
        Menu {
            Picker(TheaterReadiness.spokenLineTitle, selection: self.selection) {
                ForEach(TheaterSpokenLineMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            TheaterMenuLabel(
                title: self.settings.theaterSpokenLineMode.displayName,
                systemImage: self.compact ? nil : "text.alignleft",
                role: self.compact ? TheaterReadiness.spokenLineTitle : nil,
                compact: self.compact
            )
        }
        .theaterBarMenu()
        .disabled(SpokenLanguageResolver.isSameLanguagePair())
        .accessibilityLabel(TheaterReadiness.spokenLineTitle)
        .accessibilityValue(self.settings.theaterSpokenLineMode.displayName)
        .accessibilityIdentifier(self.accessibilityIdentifier)
    }
}

/// Title and detail on the left, control on the right. Stacks when the row is too narrow
/// so the control does not cover the description.
struct TheaterSettingRow<Control: View>: View {
    @Environment(\.theme) private var theme

    var title: String
    var detail: String
    @ViewBuilder var control: () -> Control

    var body: some View {
        TheaterSideBySide(spacing: 16) {
            self.copy
        } trailing: {
            self.control()
        }
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(self.title)
                .font(self.theme.typography.bodyStrong)
                .foregroundStyle(self.theme.palette.primaryText)
            Text(self.detail)
                .font(self.theme.typography.bodySmall)
                .foregroundStyle(self.theme.palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A point value you can type. Commits when you leave the field or press Return.
struct TheaterPointField: View {
    var label: String
    var range: ClosedRange<Int>
    @Binding var value: Int
    var accessibilityIdentifier: String

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(label, text: self.$draft)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 52)
            .focused(self.$focused)
            .onAppear { self.draft = "\(self.value)" }
            .onChange(of: self.value) { _, newValue in
                if !self.focused { self.draft = "\(newValue)" }
            }
            .onSubmit { self.commit() }
            .onChange(of: self.focused) { _, isFocused in
                if !isFocused { self.commit() }
            }
            .accessibilityLabel(label)
            .accessibilityIdentifier(self.accessibilityIdentifier)
    }

    private func commit() {
        let digits = self.draft.filter(\.isNumber)
        let parsed = Int(digits) ?? self.value
        let clamped = min(self.range.upperBound, max(self.range.lowerBound, parsed))
        self.value = clamped
        self.draft = "\(clamped)"
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
