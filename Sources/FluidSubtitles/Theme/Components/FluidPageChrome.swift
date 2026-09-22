import SwiftUI

/// Quiet symbol kept for section rows that still pass an image. No plate, stroke, or fill.
struct SettingsIconTile: View {
    @Environment(\.theme) private var theme

    let systemName: String
    var size: CGFloat = 16
    var emphasized = false
    var tint: Color? = nil

    var body: some View {
        Image(systemName: self.systemName)
            .font(.system(size: self.size * 0.72, weight: self.emphasized ? .semibold : .medium))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(
                self.tint ?? (self.emphasized ? self.theme.palette.primaryText : self.theme.palette.secondaryText)
            )
            .frame(width: self.size, height: self.size)
            .accessibilityHidden(true)
    }
}

/// Shared page title: title, optional subtitle, optional trailing actions.
struct FluidPageHeader<Trailing: View>: View {
    @Environment(\.theme) private var theme

    let systemImage: String
    let title: String
    var subtitle: String?
    var trailing: Trailing

    init(
        systemImage: String,
        title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.systemImage = systemImage
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: self.theme.metrics.spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: self.theme.metrics.spacing.sm) {
                SettingsIconTile(systemName: self.systemImage, size: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(self.title)
                        .font(self.theme.typography.title)
                        .foregroundStyle(self.theme.palette.primaryText)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(self.theme.typography.bodySmall)
                            .foregroundStyle(self.theme.palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Spacer(minLength: self.theme.metrics.spacing.md)

            self.trailing
        }
        .accessibilityElement(children: .contain)
    }
}

extension FluidPageHeader where Trailing == EmptyView {
    init(systemImage: String, title: String, subtitle: String? = nil) {
        self.init(systemImage: systemImage, title: title, subtitle: subtitle) {
            EmptyView()
        }
    }
}

/// Shared section label inside cards and forms.
struct FluidSectionHeader: View {
    @Environment(\.theme) private var theme

    let title: String
    var systemImage: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: self.theme.metrics.spacing.sm) {
            if let systemImage {
                SettingsIconTile(systemName: systemImage, size: 18)
            }
            Text(self.title)
                .font(self.theme.typography.sectionTitle)
                .foregroundStyle(self.theme.palette.primaryText)
        }
    }
}

extension View {
    /// Standard settings/app page inset and content width.
    func fluidPageContent() -> some View {
        self.modifier(FluidPageContentModifier())
    }
}

private struct FluidPageContentModifier: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .padding(self.theme.metrics.spacing.xl)
            .frame(maxWidth: 880, alignment: .leading)
    }
}
