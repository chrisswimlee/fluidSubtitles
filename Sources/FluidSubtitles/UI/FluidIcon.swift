import SwiftUI

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
            let padding = max(1, self.lineWidth * 0.35)
            let rect = CGRect(origin: .zero, size: canvasSize).insetBy(dx: padding, dy: padding)
            let bubbleHeight = rect.height * 0.38
            let bubbleWidth = rect.width * 0.78
            let radius = bubbleHeight * 0.42

            let top = CGRect(
                x: rect.minX,
                y: rect.minY,
                width: bubbleWidth,
                height: bubbleHeight
            )
            let bottom = CGRect(
                x: rect.maxX - bubbleWidth,
                y: rect.maxY - bubbleHeight,
                width: bubbleWidth,
                height: bubbleHeight
            )

            context.fill(
                Path(roundedRect: top, cornerRadius: radius),
                with: .color(self.color.opacity(0.92))
            )
            context.fill(
                Path(roundedRect: bottom, cornerRadius: radius),
                with: .color(self.color.opacity(0.58))
            )
        }
        .frame(width: self.size, height: self.size)
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
            RoundedRectangle(cornerRadius: self.cornerRadius)
                .fill(self.backgroundColor)
                .frame(width: self.size, height: self.size)

            FluidIcon(size: self.size * 0.62, lineWidth: self.size * 0.08, color: self.color)
        }
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
            FluidIconFilled(size: 32, backgroundColor: Color(red: 0.18, green: 0.83, blue: 0.75))
            FluidIconFilled(size: 48, backgroundColor: Color(red: 0.04, green: 0.09, blue: 0.14), cornerRadius: 12)
            FluidIconFilled(size: 80, backgroundColor: .black, cornerRadius: 16)
        }
    }
    .padding()
    .background(Color.gray.opacity(0.1))
}
