import AppKit
import SwiftUI

struct FluidOnboardingLandingHero<Actions: View>: View {
    @Environment(\.theme) private var theme

    let eyebrow: String
    let title: String
    let accentTitle: String
    let firstDetail: String
    let secondDetail: String
    let actions: Actions

    init(
        eyebrow: String,
        title: String,
        accentTitle: String,
        firstDetail: String,
        secondDetail: String,
        @ViewBuilder actions: () -> Actions
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.accentTitle = accentTitle
        self.firstDetail = firstDetail
        self.secondDetail = secondDetail
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 0) {
            FluidOnboardingAppIconMark()
                .padding(.bottom, self.eyebrow.isEmpty ? 40 : 26)

            if !self.eyebrow.isEmpty {
                Text(self.eyebrow)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .padding(.bottom, 16)
            }

            VStack(spacing: 4) {
                Text(self.title)
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(self.theme.palette.primaryText)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.82)

                Text(self.accentTitle)
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(self.theme.palette.accent)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.76)
            }
            .lineLimit(1)
            .padding(.bottom, 28)

            VStack(spacing: 8) {
                Text(self.firstDetail)
                Text(self.secondDetail)
            }
            .font(.system(size: 18, weight: .regular))
            .foregroundStyle(self.theme.palette.secondaryText)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .minimumScaleFactor(0.82)
            .padding(.bottom, 42)

            self.actions
        }
        .padding(.horizontal, self.theme.metrics.onboardingSurface.landing.heroPadding)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

struct FluidOnboardingLandingBackdrop: View {
    @Environment(\.theme) private var theme

    let glowCenter: UnitPoint

    init(glowCenter: UnitPoint = UnitPoint(x: 0.5, y: 0.18)) {
        self.glowCenter = glowCenter
    }

    var body: some View {
        self.theme.palette.windowBackground
            .ignoresSafeArea()
            .onAppear { _ = self.glowCenter }
    }
}

struct FluidOnboardingCompactProgress: View {
    let value: Double

    var body: some View {
        GeometryReader { proxy in
            let clampedValue = min(max(self.value, 0), 1)
            let width = proxy.size.width

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))

                Rectangle()
                    .fill(FluidOnboardingLandingColors.blue)
                    .frame(width: width * clampedValue)
            }
        }
        .frame(width: 292, height: 2)
        .accessibilityHidden(true)
    }
}

struct FluidOnboardingCompactAppIconMark: View {
    private static let appIconImage: NSImage = NSApplication.shared.applicationIconImage
        ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)

    let size: CGFloat

    init(size: CGFloat = 66) {
        self.size = size
    }

    var body: some View {
        Image(nsImage: Self.appIconImage)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: self.size, height: self.size)
            .accessibilityHidden(true)
    }
}

struct FluidOnboardingLandingHoverTracker: NSViewRepresentable {
    let onMove: (CGPoint, CGSize) -> Void
    let onExit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onMove: self.onMove, onExit: self.onExit)
    }

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        context.coordinator.onMove = self.onMove
        context.coordinator.onExit = self.onExit
        view.coordinator = context.coordinator
    }

    final class Coordinator {
        var onMove: (CGPoint, CGSize) -> Void
        var onExit: () -> Void

        init(onMove: @escaping (CGPoint, CGSize) -> Void, onExit: @escaping () -> Void) {
            self.onMove = onMove
            self.onExit = onExit
        }
    }

    final class TrackingView: NSView {
        weak var coordinator: Coordinator?
        private var trackingArea: NSTrackingArea?

        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()

            if let trackingArea {
                self.removeTrackingArea(trackingArea)
            }

            let options: NSTrackingArea.Options = [
                .activeInKeyWindow,
                .inVisibleRect,
                .mouseEnteredAndExited,
                .mouseMoved,
            ]
            let trackingArea = NSTrackingArea(rect: .zero, options: options, owner: self)
            self.addTrackingArea(trackingArea)
            self.trackingArea = trackingArea
        }

        override func mouseEntered(with event: NSEvent) {
            self.report(event)
        }

        override func mouseMoved(with event: NSEvent) {
            self.report(event)
        }

        override func mouseExited(with event: NSEvent) {
            self.coordinator?.onExit()
        }

        private func report(_ event: NSEvent) {
            let location = self.convert(event.locationInWindow, from: nil)
            self.coordinator?.onMove(location, self.bounds.size)
        }
    }
}

struct FluidOnboardingLandingPrimaryButton: NSViewRepresentable {
    static let size = CGSize(width: 236, height: 56)

    let title: String
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: self.action)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = LandingPrimaryNSButton()
        button.target = context.coordinator
        button.action = #selector(Coordinator.performAction)
        button.setButtonType(.momentaryPushIn)
        button.isBordered = false
        button.wantsLayer = true
        button.focusRingType = .none
        button.keyEquivalent = "\r"
        button.keyEquivalentModifierMask = []
        button.setAccessibilityLabel(self.title)
        button.update(title: self.title, isHighlighted: false)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = self.action

        guard let button = button as? LandingPrimaryNSButton else {
            button.title = self.title
            button.setAccessibilityLabel(self.title)
            return
        }

        button.setAccessibilityLabel(self.title)
        button.update(title: self.title, isHighlighted: button.isHighlighted)
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func performAction() {
            self.action()
        }
    }
}

private final class LandingPrimaryNSButton: NSButton {
    private var trackingArea: NSTrackingArea?

    override var isHighlighted: Bool {
        didSet {
            self.update(title: self.title, isHighlighted: self.isHighlighted)
        }
    }

    override var intrinsicContentSize: NSSize {
        FluidOnboardingLandingPrimaryButton.size
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard self.isEnabled, !self.isHidden, self.alphaValue > 0, self.bounds.contains(point) else {
            return nil
        }

        return self
    }

    override func layout() {
        super.layout()
        self.layer?.cornerRadius = 0
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            self.removeTrackingArea(trackingArea)
        }

        let options: NSTrackingArea.Options = [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect]
        let trackingArea = NSTrackingArea(rect: .zero, options: options, owner: self)
        self.addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        self.update(title: self.title, isHighlighted: self.isHighlighted)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        self.update(title: self.title, isHighlighted: self.isHighlighted)
    }

    func update(title: String, isHighlighted: Bool) {
        self.title = title
        let gold = NSColor(srgbRed: 0.910, green: 0.647, blue: 0.294, alpha: isHighlighted ? 0.55 : 1)
        self.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 18, weight: .medium),
                .foregroundColor: gold,
            ]
        )
        self.alignment = .center
        self.layer?.masksToBounds = false
        self.layer?.backgroundColor = NSColor.clear.cgColor
        self.layer?.cornerRadius = 0
        self.layer?.shadowOpacity = 0
    }
}

private struct FluidOnboardingAppIconMark: View {
    private static let appIconImage: NSImage = NSApplication.shared.applicationIconImage
        ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)

    var body: some View {
        ZStack {
            FluidOnboardingCaptionPlate()
                .offset(y: 78)

            Image(nsImage: Self.appIconImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 88, height: 88)
        }
        .frame(width: 360, height: 176)
        .accessibilityHidden(true)
    }
}

/// Sample board under the app icon. A caption plate, not a portal glow.
private struct FluidOnboardingCaptionPlate: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("오늘 모델을 학습했습니다")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
            Text("Today we trained the model.")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
        }
        .accessibilityHidden(true)
    }
}

enum FluidOnboardingLandingColors {
    /// Caption gold. The old landing blue matched a dictation app.
    static let blue = Color(red: 0.91, green: 0.65, blue: 0.29)
}

private struct OnboardingSelectableSurfaceModifier: ViewModifier {
    @Environment(\.theme) private var theme
    let isSelected: Bool
    let cornerRadius: CGFloat?
    let padding: CGFloat?
    let selectedBorderOpacity: Double?

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) {
                if self.isSelected {
                    Rectangle()
                        .fill(self.theme.palette.accent)
                        .frame(height: 1)
                }
            }
            .contentShape(Rectangle())
    }
}

private struct OnboardingEditorSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat?

    func body(content: Content) -> some View {
        content
    }
}

private struct OnboardingProminentButtonModifier: ViewModifier {
    let controlSize: ControlSize?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let controlSize {
            content
                .buttonStyle(.theaterTextProminent)
                .controlSize(controlSize)
        } else {
            content
                .buttonStyle(.theaterTextProminent)
        }
    }
}

private struct OnboardingSecondaryButtonModifier: ViewModifier {
    let controlSize: ControlSize?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let controlSize {
            content
                .buttonStyle(.theaterText)
                .controlSize(controlSize)
        } else {
            content
                .buttonStyle(.theaterText)
        }
    }
}

extension View {
    func fluidOnboardingSelectableSurface(
        isSelected: Bool,
        cornerRadius: CGFloat? = nil,
        padding: CGFloat? = nil,
        selectedBorderOpacity: Double? = nil
    ) -> some View {
        self.modifier(OnboardingSelectableSurfaceModifier(
            isSelected: isSelected,
            cornerRadius: cornerRadius,
            padding: padding,
            selectedBorderOpacity: selectedBorderOpacity
        ))
    }

    func fluidOnboardingEditorSurface(cornerRadius: CGFloat? = nil) -> some View {
        self.modifier(OnboardingEditorSurfaceModifier(cornerRadius: cornerRadius))
    }

    func fluidOnboardingProminentButton(controlSize: ControlSize? = nil) -> some View {
        self.modifier(OnboardingProminentButtonModifier(controlSize: controlSize))
    }

    func fluidOnboardingSecondaryButton(controlSize: ControlSize? = nil) -> some View {
        self.modifier(OnboardingSecondaryButtonModifier(controlSize: controlSize))
    }
}
