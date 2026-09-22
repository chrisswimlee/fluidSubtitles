import SwiftUI

/// Empty Theater board: faint Show-as / spoken ghosts plus the live hint.
struct TheaterBoardEmptyState: View {
    let message: String
    let titlePreview: String
    let spokenPreview: String?
    let titleColor: Color
    let spokenColor: Color
    let messageColor: Color
    var titleFont: Font = .system(size: 36, weight: .semibold)
    var spokenFont: Font = .system(size: 18, weight: .semibold)
    var messageFont: Font = .body
    var accessibilityIdentifier: String = "theater.board.empty"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(self.titlePreview)
                .font(self.titleFont)
                .foregroundStyle(self.titleColor.opacity(0.34))
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .accessibilityHidden(true)
            if let spokenPreview, !spokenPreview.isEmpty {
                Text(spokenPreview)
                    .font(self.spokenFont)
                    .foregroundStyle(self.spokenColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .accessibilityHidden(true)
            }
            Text(self.message)
                .font(self.messageFont)
                .foregroundStyle(self.messageColor)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
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
            titleFont: .system(size: self.titleSize, weight: .regular),
            spokenFont: .system(size: self.spokenSize, weight: .regular),
            messageFont: self.messageFont,
            accessibilityIdentifier: self.accessibilityIdentifier
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
