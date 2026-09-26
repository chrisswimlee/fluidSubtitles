import SwiftUI

/// Empty Theater board: faint Show-as / spoken ghosts plus the live hint.
/// `isWarning` marks the hint as a failure, not the ordinary idle state, so a
/// broken board doesn't read identically to one that's simply waiting.
struct TheaterBoardEmptyState: View {
    @Environment(\.theme) private var theme

    let message: String
    let titlePreview: String
    let spokenPreview: String?
    let titleColor: Color
    let spokenColor: Color
    let messageColor: Color
    var titleFont: Font = .system(size: 36, weight: .semibold)
    var spokenFont: Font = .system(size: 18, weight: .medium)
    var messageFont: Font = .body
    /// Show-as stays the line you read. Spoken stays quieter, on the board and in samples.
    var titleOpacity: Double = 0.4
    var spokenOpacity: Double = 0.5
    var isWarning: Bool = false
    var accessibilityIdentifier: String = "theater.board.empty"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(self.titlePreview)
                .font(self.titleFont)
                .foregroundStyle(self.titleColor.opacity(self.titleOpacity))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .accessibilityHidden(true)
            if let spokenPreview, !spokenPreview.isEmpty {
                Text(spokenPreview)
                    .font(self.spokenFont)
                    .foregroundStyle(self.spokenColor.opacity(self.spokenOpacity))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .accessibilityHidden(true)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if self.isWarning {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(self.theme.palette.warning)
                        .accessibilityHidden(true)
                }
                Text(self.message)
                    .font(self.messageFont)
                    .foregroundStyle(self.isWarning ? self.theme.palette.warning : self.messageColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(self.accessibilityIdentifier)
        .accessibilityLabel(self.message)
    }
}

/// Dark caption-stack sample for Home and Setup Wizard.
struct TheaterCaptionStackPreview: View {
    @Environment(\.theme) private var theme

    let message: String
    let lines: TheaterBoardPreview.Lines
    var titleSize: CGFloat = 26
    var spokenSize: CGFloat = 14
    var titleOpacity: Double = 0.55
    var spokenOpacity: Double = 0.45
    var messageFont: Font = .caption
    var accessibilityIdentifier: String = "theater.home.preview"

    var body: some View {
        TheaterBoardEmptyState(
            message: self.message,
            titlePreview: self.lines.title,
            spokenPreview: self.lines.spoken,
            titleColor: self.theme.palette.primaryText,
            spokenColor: self.theme.palette.secondaryText,
            messageColor: self.theme.palette.tertiaryText,
            titleFont: .system(size: self.titleSize, weight: .semibold),
            spokenFont: .system(size: self.spokenSize, weight: .medium),
            messageFont: self.messageFont,
            titleOpacity: self.titleOpacity,
            spokenOpacity: self.spokenOpacity,
            accessibilityIdentifier: self.accessibilityIdentifier
        )
        .padding(self.theme.metrics.spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                .fill(self.theme.palette.primaryText.opacity(0.045))
                .overlay {
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                        .strokeBorder(self.theme.palette.separator, lineWidth: 1)
                }
        }
    }
}
