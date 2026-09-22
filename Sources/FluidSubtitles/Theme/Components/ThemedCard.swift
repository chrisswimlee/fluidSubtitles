import SwiftUI

enum ThemedCardStyle {
    case standard
    case prominent
    case subtle
}

struct ThemedCard<Content: View>: View {
    @Environment(\.theme) private var theme

    private let style: ThemedCardStyle
    private let padding: CGFloat?
    private let content: Content

    init(
        style: ThemedCardStyle = .standard,
        padding: CGFloat? = nil,
        hoverEffect: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.style = style
        self.padding = padding
        _ = hoverEffect
        self.content = content()
    }

    var body: some View {
        self.content
            .padding(self.padding ?? self.theme.metrics.cardSurface.defaultPadding)
            .padding(.top, self.style == .prominent ? 0 : 20)
            .padding(.bottom, self.style == .prominent ? 0 : 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) {
                if self.style != .prominent {
                    Rectangle()
                        .fill(self.theme.palette.separator)
                        .frame(height: 0.5)
                }
            }
    }
}
