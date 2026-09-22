import AppKit
import SwiftUI

/// Menu bar mark, 22×18pt. The rounded FS, with the caption pills underneath.
/// Matches `drawMenuBarIcon` in `scripts/generate_fluidsubtitles_brand.swift`.
enum TheaterMenuBarMark {
    static let pointSize = NSSize(width: 22, height: 18)

    static func draw(in rect: CGRect, color: NSColor) {
        let height = rect.height
        let fontSize = height * 0.58
        let base = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let rounded = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
        let font = NSFont(descriptor: rounded, size: fontSize) ?? base
        let letters = NSAttributedString(
            string: "FS",
            attributes: [
                .font: font,
                .foregroundColor: color,
                .kern: -0.5,
            ]
        )
        let box = letters.size()
        let bar = height * 0.12
        let gap = height * 0.05
        let spoken = bar * 0.78
        let stack = bar + gap + spoken
        let bottom = rect.minY + height * 0.02
        let originX = rect.midX - box.width / 2
        letters.draw(at: CGPoint(x: originX, y: bottom + stack + height * 0.03))

        color.setFill()
        NSBezierPath(
            roundedRect: CGRect(x: originX, y: bottom + spoken + gap, width: box.width, height: bar),
            xRadius: bar / 2,
            yRadius: bar / 2
        ).fill()
        NSBezierPath(
            roundedRect: CGRect(x: originX, y: bottom, width: box.width * 0.58, height: spoken),
            xRadius: spoken / 2,
            yRadius: spoken / 2
        ).fill()
    }
}

struct FluidIcon: View {
    let size: CGFloat
    let lineWidth: CGFloat
    let color: Color

    init(size: CGFloat = 24, lineWidth: CGFloat = 2.5, color: Color = .white) {
        self.size = size
        self.lineWidth = lineWidth
        self.color = color
    }

    var body: some View {
        Canvas { context, canvasSize in
            let padding = max(1, self.lineWidth * 0.2)
            let rect = CGRect(origin: .zero, size: canvasSize).insetBy(dx: padding, dy: padding)
            let barHeight = max(2, rect.height * 0.16)
            let gap = max(2, rect.height * 0.12)
            let stack = barHeight * 2 + gap
            let originY = rect.minY + (rect.height - stack) / 2
            let show = CGRect(x: rect.minX, y: originY, width: rect.width * 0.86, height: barHeight)
            let spoken = CGRect(
                x: rect.minX,
                y: originY + barHeight + gap,
                width: rect.width * 0.52,
                height: barHeight * 0.82
            )
            context.fill(Path(roundedRect: show, cornerRadius: barHeight / 2), with: .color(self.color))
            context.fill(
                Path(roundedRect: spoken, cornerRadius: barHeight / 2),
                with: .color(self.color.opacity(0.55))
            )
        }
        .frame(width: self.size, height: self.size)
        .accessibilityHidden(true)
    }
}

struct FluidIconFilled: View {
    let size: CGFloat
    let color: Color
    let backgroundColor: Color
    let cornerRadius: CGFloat

    init(size: CGFloat = 32, color: Color = .white, backgroundColor: Color = .blue, cornerRadius: CGFloat = 8) {
        self.size = size
        self.color = color
        self.backgroundColor = backgroundColor
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: self.cornerRadius, style: .continuous)
                .fill(self.backgroundColor)
                .frame(width: self.size, height: self.size)

            FluidIcon(size: self.size * 0.62, lineWidth: self.size * 0.08, color: self.color)
        }
        .accessibilityHidden(true)
    }
}

/// Sidebar identity. The caption mark is the product, not a dictation waveform.
struct TheaterSidebarIdentity: View {
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            FluidIcon(size: 22, lineWidth: 1.6, color: self.theme.palette.accent)
            VStack(alignment: .leading, spacing: 0) {
                Text(FluidProduct.displayName)
                    .font(self.theme.typography.sidebarItem)
                    .foregroundStyle(self.theme.palette.primaryText)
                Text("Live captions")
                    .font(self.theme.typography.sidebarSection)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(FluidProduct.displayName), live captions")
    }
}

#Preview("fluidSubtitles mark") {
    VStack(spacing: 20) {
        HStack(spacing: 20) {
            FluidIcon(size: 24, color: .white)
                .background(Color.black.opacity(0.3))
            FluidIcon(size: 32, color: .blue)
            FluidIcon(size: 48, color: .primary)
        }
        HStack(spacing: 20) {
            FluidIconFilled(size: 32, backgroundColor: Color(red: 0.91, green: 0.65, blue: 0.29))
            FluidIconFilled(size: 48, backgroundColor: Color(red: 0.04, green: 0.09, blue: 0.14), cornerRadius: 12)
            FluidIconFilled(size: 80, backgroundColor: .black, cornerRadius: 16)
        }
    }
    .padding()
    .background(Color.gray.opacity(0.1))
}
