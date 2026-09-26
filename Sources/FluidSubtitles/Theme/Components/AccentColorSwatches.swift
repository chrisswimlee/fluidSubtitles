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
                    ZStack {
                        Circle()
                            .fill(Color(hex: option.hex) ?? .gray)
                            .frame(width: 18, height: 18)
                            .overlay {
                                Circle().strokeBorder(Color.primary.opacity(0.28), lineWidth: 1)
                            }
                        if selected {
                            Circle()
                                .strokeBorder(self.theme.palette.primaryText, lineWidth: 2)
                                .frame(width: 26, height: 26)
                        }
                    }
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
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
