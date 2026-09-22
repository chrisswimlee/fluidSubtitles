import SwiftUI

/// Preset accent colors. Caption gold is the product default.
struct AccentColorSwatches: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var settings = SettingsStore.shared

    var accessibilityIdentifier = "accentColor"

    var body: some View {
        HStack(spacing: 8) {
            ForEach(SettingsStore.AccentColorOption.allCases) { option in
                let selected = self.settings.accentColorOption == option
                Button {
                    self.settings.accentColorOption = option
                } label: {
                    Circle()
                        .fill(Color(hex: option.hex) ?? .gray)
                        .frame(width: 16, height: 16)
                        .overlay(
                            Circle()
                                .strokeBorder(
                                    selected ? self.theme.palette.accent : self.theme.palette.separator,
                                    lineWidth: selected ? 2 : 1
                                )
                        )
                        .padding(4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.rawValue)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("\(self.accessibilityIdentifier).\(option.rawValue)")
                .help(option.rawValue)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(TheaterSetupWizard.accentTitle)
    }
}
