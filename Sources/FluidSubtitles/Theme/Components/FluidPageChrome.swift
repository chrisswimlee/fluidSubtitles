import SwiftUI

/// Accent-stroked icon tile used by page and section headers.
struct SettingsIconTile: View {
    @Environment(\.theme) private var theme

    let systemName: String
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.82))
                .overlay(
                    LinearGradient(
                        colors: [.white.opacity(0.1), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                        .stroke(self.theme.palette.accent.opacity(0.35), lineWidth: 1)
                )

            Image(systemName: self.systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(self.theme.palette.accent)
        }
        .frame(width: self.size, height: self.size)
        .accessibilityHidden(true)
    }
}

/// Shared page title: icon tile, title, optional subtitle, optional trailing actions.
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
        HStack(alignment: .center, spacing: self.theme.metrics.spacing.md) {
            SettingsIconTile(systemName: self.systemImage)

            VStack(alignment: .leading, spacing: 2) {
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

            Spacer(minLength: self.theme.metrics.spacing.md)

            self.trailing
        }
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
        Group {
            if let systemImage {
                Label(self.title, systemImage: systemImage)
            } else {
                Text(self.title)
            }
        }
        .font(self.theme.typography.sectionTitle)
        .foregroundStyle(self.theme.palette.primaryText)
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
