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
        TheaterSideBySide(spacing: self.theme.metrics.spacing.md) {
            self.titleBlock
        } trailing: {
            self.trailing
        }
        .accessibilityElement(children: .contain)
    }

    private var titleBlock: some View {
        HStack(alignment: .center, spacing: self.theme.metrics.spacing.sm) {
            SettingsIconTile(systemName: self.systemImage, size: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(self.title)
                    .font(self.theme.typography.title)
                    .foregroundStyle(self.theme.palette.primaryText)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.theme.palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
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

/// Title on the left, actions on the right. When both do not fit, the
/// actions move under the title instead of drawing through it.
struct TheaterSideBySide<Leading: View, Trailing: View>: View {
    var spacing: CGFloat
    var leading: Leading
    var trailing: Trailing

    init(
        spacing: CGFloat,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.spacing = spacing
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        TheaterSideBySideLayout(spacing: self.spacing) {
            self.leading
            self.trailing
        }
    }
}

private struct TheaterSideBySideLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count >= 2 else {
            return subviews.first?.sizeThatFits(proposal) ?? .zero
        }
        let lead = subviews[0].sizeThatFits(.unspecified)
        let trail = subviews[1].sizeThatFits(.unspecified)
        let sideBySide = lead.width + self.spacing + trail.width
        if self.stacks(sideBySide, in: proposal.width), let width = proposal.width, width.isFinite {
            let stackedLead = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
            let stackedTrail = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
            return CGSize(width: width, height: stackedLead.height + self.spacing + stackedTrail.height)
        }
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? sideBySide
        return CGSize(width: width, height: max(lead.height, trail.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count >= 2 else {
            subviews.first?.place(at: bounds.origin, proposal: proposal)
            return
        }
        let leadIdeal = subviews[0].sizeThatFits(.unspecified)
        let trailIdeal = subviews[1].sizeThatFits(.unspecified)
        let sideBySide = leadIdeal.width + self.spacing + trailIdeal.width
        if sideBySide > bounds.width + 0.5 {
            let lead = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subviews[0].place(
                at: bounds.origin,
                proposal: ProposedViewSize(width: bounds.width, height: lead.height)
            )
            subviews[1].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + lead.height + self.spacing),
                proposal: ProposedViewSize(width: bounds.width, height: nil)
            )
            return
        }
        let leadWidth = max(0, bounds.width - self.spacing - trailIdeal.width)
        let leadHeight = subviews[0].sizeThatFits(ProposedViewSize(width: leadWidth, height: nil)).height
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY + max(0, (bounds.height - leadHeight) / 2)),
            proposal: ProposedViewSize(width: leadWidth, height: leadHeight)
        )
        subviews[1].place(
            at: CGPoint(
                x: bounds.maxX - trailIdeal.width,
                y: bounds.minY + max(0, (bounds.height - trailIdeal.height) / 2)
            ),
            proposal: ProposedViewSize(width: trailIdeal.width, height: trailIdeal.height)
        )
    }

    private func stacks(_ sideBySide: CGFloat, in proposed: CGFloat?) -> Bool {
        guard let proposed, proposed.isFinite else { return false }
        return sideBySide > proposed + 0.5
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
