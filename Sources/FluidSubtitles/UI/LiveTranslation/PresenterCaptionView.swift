import AppKit
import Combine
import QuartzCore
import SwiftUI

private struct TheaterWindowAppearanceBridge: NSViewRepresentable {
    var appearance: TheaterAppearance

    func makeNSView(context: Context) -> TheaterAppearanceHostView {
        let view = TheaterAppearanceHostView()
        view.apply(self.appearance)
        return view
    }

    func updateNSView(_ view: TheaterAppearanceHostView, context: Context) {
        view.apply(self.appearance)
    }
}

private final class TheaterAppearanceHostView: NSView {
    private var appearanceName: NSAppearance.Name = .darkAqua

    func apply(_ appearance: TheaterAppearance) {
        self.appearanceName = appearance == .light ? .aqua : .darkAqua
        self.applyToWindow()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.applyToWindow()
    }

    private func applyToWindow() {
        self.window?.appearance = NSAppearance(named: self.appearanceName)
        self.window?.isOpaque = false
        self.window?.backgroundColor = .clear
    }
}

/// Reserved chrome so the tool bar and the titlebar do not sit on the captions.
private enum TheaterChromeLayout {
    /// Room for the hidden-titlebar traffic lights. The shelf starts under them.
    static let titlebarClearance: CGFloat = 46
    /// Captions-only and idle Overlay hide those buttons, so the text can sit higher.
    static let overlayIdleClearance: CGFloat = 12
    /// Compact buttons are 24pt. The shelf is taller so the stroke is not clipped.
    static let barHeight: CGFloat = 36
    static let barGap: CGFloat = 20
    static let barInset: CGFloat = 16
}

struct PresenterCaptionView: View {
    @ObservedObject var model: PresenterCaptionModel
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var controller = LiveTranslationController.shared
    @ObservedObject private var asr = AppServices.shared.asr
    @State private var chromeRevealed = false
    @State private var chromePinned = false
    @State private var showClearConfirmation = false
    @State private var lockedWrapWidth: CGFloat = 0
    @State private var lockedDisplaySize: CGFloat = 0
    /// True when a short stage (an Overlay bar) shrinks captions below the
    /// setting the user actually chose, so the board menu can say so.
    @State private var isCaptionSizeFitted: Bool = false
    @State private var snappedNewRowThisTurn = false
    @State private var hoverBoardSize: CGSize = .zero
    @State private var copyShowsCopied = false
    @State private var copyBounceToken = 0
    @State private var pacePulseToken = 0
    @State private var isRequestingPack = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var hoverHelp = TheaterHoverHelpBroker()

    private var appearance: TheaterAppearance {
        TheaterAppearance.resolved(self.settings.theaterAppearance)
    }

    private var theme: AppTheme {
        AppTheme.adaptive(accent: self.settings.accentColor, colorScheme: self.appearance.colorScheme)
    }

    private var captionColors: TheaterCaptionVisibility.Colors {
        TheaterCaptionVisibility.colors(
            appearance: self.appearance,
            presentation: self.presentationStyle,
            highContrast: self.settings.theaterHighContrast
        )
    }

    private var spokenNS: NSColor {
        self.captionColors.spoken
    }

    private var translatedNS: NSColor {
        self.captionColors.translated
    }

    var body: some View {
        self.theaterContent
            .onChange(of: self.controller.copyFlashToken) { _, token in
                guard token > 0 else { return }
                self.copyShowsCopied = true
                self.copyBounceToken = token
                let seen = token
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if self.copyBounceToken == seen {
                        self.copyShowsCopied = false
                    }
                }
            }
            .onChange(of: self.model.paceCueKind) { _, kind in
                guard !kind.isEmpty else { return }
                self.pacePulseToken += 1
            }
            .environment(\.theaterHoverHelp, self.hoverHelp)
            .appTheme(self.theme)
            .preferredColorScheme(self.appearance.colorScheme)
            .tint(self.theme.palette.accent)
            .background(TheaterWindowAppearanceBridge(appearance: self.appearance))
            .onHover { hovering in
                if self.overlayHidesChrome || self.chromeRevealed == hovering { return }
                self.chromeRevealed = hovering
                if !hovering {
                    self.hoverHelp.clear()
                }
            }
            .onChange(of: self.model.overlayToolsPinned) { _, pinned in
                if self.presentationStyle == .transparent, !pinned {
                    self.chromeRevealed = false
                    self.hoverHelp.clear()
                }
            }
            .onChange(of: self.presentationStyle) { _, style in
                if style == .transparent, !self.model.overlayToolsPinned {
                    self.chromeRevealed = false
                    self.hoverHelp.clear()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
                self.chromePinned = true
            }
            .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
                self.chromePinned = false
                PresenterCaptionController.shared.releaseKeyToExternalApp()
            }
            .alert("Clear captions?", isPresented: self.$showClearConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Clear", role: .destructive) {
                    self.controller.clearBoard()
                }
            } message: {
                Text(TheaterReadiness.clearCaptionsConfirm)
            }
            .alert(
                TheaterReadiness.closeWhileListeningTitle,
                isPresented: self.$model.showCloseConfirmation
            ) {
                Button("Cancel", role: .cancel) {
                    PresenterCaptionController.shared.cancelCloseWhileListening()
                }
                Button(TheaterReadiness.closeWhileListeningButton, role: .destructive) {
                    PresenterCaptionController.shared.confirmCloseWhileListening()
                }
            } message: {
                Text(TheaterReadiness.closeWhileListeningConfirm)
            }
    }

    private var theaterContent: some View {
        Group {
            if !self.settings.theaterMinimized {
                self.boardFill
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The shelf is an inset, not a layer on the captions. A hover shelf
        // used to paint over the first line.
        .safeAreaInset(edge: .top, spacing: self.showsToolShelf ? TheaterChromeLayout.barGap : 0) {
            if self.showsToolShelf {
                self.toolBarBand
                    .padding(.top, self.topChromeClearance)
            } else {
                Color.clear
                    .frame(height: self.topChromeClearance)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .background(self.theaterFill)
        .background {
            if self.presentationStyle == .popup, !self.settings.theaterHighContrast {
                Rectangle().fill(self.theme.materials.window)
            }
        }
        .coordinateSpace(name: TheaterHoverHelp.space)
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { self.hoverBoardSize = geo.size }
                    .onChange(of: geo.size) { _, size in
                        guard abs(size.width - self.hoverBoardSize.width) > 1
                            || abs(size.height - self.hoverBoardSize.height) > 1
                        else { return }
                        self.hoverBoardSize = size
                    }
            }
        }
        .overlay(alignment: .topLeading) {
            if let help = self.hoverHelp.value, self.hoverBoardSize.width > 1 {
                TheaterHoverHelpBubble(
                    text: help.text,
                    anchor: help.anchor,
                    container: self.hoverBoardSize
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .environment(\.theaterButtonColors, TheaterButtonColors(
            fill: self.captionColors.menuFill,
            stroke: self.captionColors.menuStroke,
            foreground: self.captionColors.chrome
        ))
    }

    /// Languages, how words arrive, and Listen stay on the shelf. The shelf
    /// keeps a slot above the captions, including while hover tools are up,
    /// so the first line cannot draw under the buttons.
    private var toolBarBand: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                self.shelfPrimaryRow
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 8) {
                        self.languagePairControls
                        Spacer(minLength: 8)
                        self.windowModePicker
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    HStack(alignment: .center, spacing: 8) {
                        Spacer(minLength: 8)
                        self.trailingChrome
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }

            if self.showsFlowChoices || self.showsStatusCluster {
                HStack(alignment: .center, spacing: 8) {
                    if self.showsFlowChoices {
                        self.flowChoices
                            .layoutPriority(1)
                    }
                    if self.showsStatusCluster {
                        self.paceCueReadout
                        self.talkPackChip
                        self.statusSlot
                    }
                }
            }
        }
        .padding(.horizontal, TheaterChromeLayout.barInset)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { self.toolShelf }
    }

    /// One row when the board is wide. Theater mode stays with the languages
    /// and the tools drop to the next line when that row would overlap.
    private var shelfPrimaryRow: some View {
        HStack(alignment: .center, spacing: 8) {
            self.languagePairControls
                .layoutPriority(1)
            self.chromeRule
            self.windowModePicker
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 8)
            self.trailingChrome
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var showsStatusCluster: Bool {
        !self.model.paceCueLabel.isEmpty
            || !self.model.latencyReadout.isEmpty
            || !self.model.status.isEmpty
            || (self.settings.theaterSessionMode.showsTranslation && self.settings.hasTheaterTalkPack)
    }

    private var chromeRule: some View {
        Rectangle()
            .fill(self.captionColors.chrome.opacity(0.28))
            .frame(width: 1, height: 16)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var toolShelf: some View {
        if self.presentationStyle == .popup {
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
            shape
                .fill(self.captionColors.menuFill)
                .overlay(shape.strokeBorder(self.captionColors.menuStroke, lineWidth: 1))
        }
    }

    private var trailingChrome: some View {
        HStack(alignment: .center, spacing: 6) {
            self.retryActions
            TheaterListenButton(
                usesChromeKey: true,
                listenIdentifier: "theater.window.listen",
                stopIdentifier: "theater.window.stop",
                pauseIdentifier: "theater.pause"
            )
            self.chromeRule
            self.sizeMenu
            self.chromeRule
            self.fontMenu
            self.chromeRule
            self.clearCaptionButton
            self.chromeRule
            self.boardMenu
        }
        .lineLimit(1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("theater.window.hoverTools")
    }

    private var statusSlot: some View {
        HStack(spacing: 6) {
            if !self.model.latencyReadout.isEmpty {
                Text(self.model.latencyReadout)
                    .theaterReadoutPlate()
                    .font(self.theme.typography.codeCaption)
                    .theaterTag(TheaterChromeHelp.latency)
            }
            if !self.model.status.isEmpty {
                Text(self.model.status)
                    .lineLimit(self.model.statusKind.usesWarningColor ? 2 : 1)
                    .theaterReadoutPlate(
                        tint: self.model.statusKind.usesWarningColor ? self.theme.palette.warning : nil
                    )
                    .theaterTag(TheaterChromeHelp.status)
                    .accessibilityIdentifier("theater.status")
            }
        }
        .lineLimit(1)
    }

    private var overlayHidesChrome: Bool {
        TheaterOverlayPolicy.hidesAllChrome(
            presentation: self.presentationStyle,
            toolsPinned: self.model.overlayToolsPinned
        )
    }

    private var usesCaptionsOnlyChrome: Bool {
        TheaterOverlayPolicy.usesCaptionsOnlyChrome(
            presentation: self.presentationStyle,
            hideChrome: self.settings.theaterHideChrome
        )
    }

    /// Traffic lights stay visible whenever the window buttons are showing.
    /// Captions-only and idle Overlay hide those buttons, so the board can use the top.
    private var topChromeClearance: CGFloat {
        let showsWindowButtons = !TheaterOverlayPolicy.hidesTitlebarButtons(
            presentation: self.presentationStyle,
            toolsPinned: self.model.overlayToolsPinned,
            hideChrome: self.settings.theaterHideChrome
        )
        return showsWindowButtons
            ? TheaterChromeLayout.titlebarClearance
            : TheaterChromeLayout.overlayIdleClearance
    }

    private var showsToolShelf: Bool {
        if self.settings.theaterMinimized || self.overlayHidesChrome {
            return false
        }
        if self.usesCaptionsOnlyChrome {
            return self.showsHoverTools
        }
        return true
    }

    private var showsFlowChoices: Bool {
        self.settings.theaterSessionMode.showsTranslation
            && !SpokenLanguageResolver.isSameLanguagePair()
    }

    private var boardFill: some View {
        self.presentationStage
            .padding(.horizontal, self.theme.metrics.spacing.xxl)
            .padding(.bottom, self.theme.metrics.spacing.md)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
    }

    private var showsHoverTools: Bool {
        self.usesCaptionsOnlyChrome
            && !self.settings.theaterMinimized
            && (self.chromeRevealed || self.chromePinned)
    }

    private var presentationStyle: TheaterPresentationStyle {
        self.settings.theaterPresentation
    }

    private var talkPackMenuTitle: String {
        let name = self.settings.theaterTalkPackFileName.isEmpty ? "Notes" : self.settings.theaterTalkPackFileName
        return "Talk notes: \(name) · \(self.settings.theaterTalkPackTerms.count) names"
    }

    private var boardButtonTitle: String {
        if self.model.exportShowsSaved { return "Saved" }
        if self.copyShowsCopied { return "Copied" }
        return "Settings"
    }

    private var boardButtonSymbol: String {
        (self.model.exportShowsSaved || self.copyShowsCopied) ? "checkmark" : "gearshape"
    }

    private var theaterFill: Color {
        switch self.presentationStyle {
        case .transparent:
            return Color.clear
        case .popup:
            return self.theme.palette.windowBackground.opacity(self.settings.theaterHighContrast ? 1 : 0.94)
        }
    }

    private var showsCaptionPlate: Bool {
        TheaterOverlayPolicy.showsCaptionPlate(
            presentation: self.presentationStyle,
            backingBar: self.settings.theaterBackingBar
        )
    }

    private var typeface: TheaterTypeface {
        TheaterTypeface.resolved(self.settings.presenterFontFamily)
    }

    private var languagePairControls: some View {
        HStack(spacing: 4) {
            self.languageMenu(
                title: "I speak",
                selection: self.sourceLanguageID,
                languages: TranslationLanguageCatalog.menuOrder
            )

            if self.settings.theaterSessionMode == .translation {
                Button {
                    PresenterCaptionController.shared.performChromeAction {
                        self.controller.swapDirection()
                    }
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                        .accessibilityHidden(true)
                }
                .buttonStyle(.theaterTextCompactIcon)
                .disabled(SpokenLanguageResolver.isSameLanguagePair())
                .theaterTag(TheaterChromeHelp.swapLanguages)
                .accessibilityLabel("Swap languages")

                self.languageMenu(
                    title: "Show as",
                    selection: self.targetLanguageID,
                    languages: self.targetLanguages
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("theater.window.languages")
    }

    private func languageMenu(
        title: String,
        selection: Binding<String>,
        languages: [TranslationLanguage]
    ) -> some View {
        TheaterLanguageMenu(
            title: title,
            selection: selection,
            languages: languages,
            compactChrome: true
        )
        .theaterTag(title == "I speak" ? TheaterChromeHelp.iSpeak : TheaterChromeHelp.showAs)
    }

    private var sourceLanguageID: Binding<String> {
        Binding(
            get: { SpokenLanguageResolver.sourceLanguage().id },
            set: { id in
                PresenterCaptionController.shared.performChromeAction {
                    self.controller.applySourceLanguage(id)
                }
            }
        )
    }

    private var targetLanguageID: Binding<String> {
        Binding(
            get: { SpokenLanguageResolver.targetLanguage().id },
            set: { id in
                PresenterCaptionController.shared.performChromeAction {
                    self.controller.applyTargetLanguage(id)
                }
            }
        )
    }

    private var targetLanguages: [TranslationLanguage] {
        TranslationLanguageCatalog.menuOrder
    }

    @ViewBuilder
    private var retryActions: some View {
        if self.model.canRetryTranslation {
            Button("Retry") {
                PresenterCaptionController.shared.performChromeAction {
                    self.controller.retryFailedTranslation()
                }
            }
            .buttonStyle(.theaterTextCompact)
            .theaterTag(TheaterChromeHelp.retry)
            .accessibilityIdentifier("theater.retry")
            if !SpokenLanguageResolver.isSameLanguagePair() {
                Button(self.isRequestingPack ? TheaterReadiness.downloadPackBusy : TheaterReadiness.downloadPack) {
                    self.isRequestingPack = true
                    PresenterCaptionController.shared.performChromeAction {
                        Task {
                            await self.controller.requestNeededLanguagePackDownload()
                            self.isRequestingPack = false
                        }
                    }
                }
                .buttonStyle(.theaterTextCompact)
                .disabled(self.isRequestingPack)
                .theaterTag(TheaterChromeHelp.downloadPack)
            }
        }
    }

    @ViewBuilder
    private var paceCueReadout: some View {
        if !self.model.paceCueLabel.isEmpty {
            let text = self.usesCaptionsOnlyChrome
                ? self.model.paceCueCompactLabel
                : self.model.paceCueLabel
            let behind = self.model.paceCueKind == TheaterPaceCue.Kind.behind.rawValue
            HStack(spacing: 4) {
                self.paceSymbol(behind: behind)
                Text(text)
                    .font(self.theme.typography.caption.monospacedDigit())
                    .lineLimit(1)
            }
            .theaterReadoutPlate(tint: behind ? self.theme.palette.warning : self.theme.palette.accent)
            .theaterTag(TheaterChromeHelp.paceCue)
            .accessibilityLabel(self.model.paceCueLabel)
            .accessibilityIdentifier("theater.paceCue")
        }
    }

    @ViewBuilder
    private func paceSymbol(behind: Bool) -> some View {
        let image = Image(systemName: behind ? "hourglass" : "checkmark")
            .font(self.theme.typography.caption)
            .foregroundStyle(behind ? self.theme.palette.warning : self.theme.palette.accent)
            .accessibilityHidden(true)
        if self.reduceMotion {
            image
        } else {
            image.symbolEffect(.pulse, options: .nonRepeating, value: self.pacePulseToken)
        }
    }

    @ViewBuilder
    private var talkPackChip: some View {
        if self.settings.theaterSessionMode.showsTranslation, self.settings.hasTheaterTalkPack {
            let count = self.settings.theaterTalkPackTerms.count
            Text("\(count) names")
                .theaterReadoutPlate()
            .theaterTag(
                self.settings.theaterTalkPackFileName.isEmpty
                    ? TheaterChromeHelp.talkNotes
                    : TheaterChromeHelp.tag(
                        self.settings.theaterTalkPackFileName,
                        does: TheaterReadiness.talkPack
                    )
            )
            .accessibilityIdentifier("theater.talkPack.chip")
        }
    }

    private var flowChoices: some View {
        TheaterSpokenLinePicker(
            accessibilityIdentifier: "theater.window.arrival",
            compact: true,
            apply: { mode in
                PresenterCaptionController.shared.performChromeAction {
                    self.settings.theaterSpokenLineMode = mode
                }
            }
        )
        .help(self.settings.theaterSpokenLineMode.help)
        .theaterTag(
            "\(TheaterReadiness.spokenLineTitle). \(self.settings.theaterSpokenLineMode.help)"
        )
    }

    private var windowModePicker: some View {
        Menu {
            Picker("Theater mode", selection: Binding(
                get: { self.settings.theaterSessionMode },
                set: { newMode in
                    PresenterCaptionController.shared.performChromeAction {
                        self.controller.applyTheaterSessionMode(newMode)
                    }
                }
            )) {
                ForEach(TheaterSessionMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            TheaterMenuLabel(
                title: self.settings.theaterSessionMode.displayName,
                systemImage: self.settings.theaterSessionMode == .translation ? "translate" : "waveform",
                role: "Mode",
                compact: true
            )
        }
        .theaterBarMenu()
        .theaterTag(TheaterChromeHelp.mode)
        .accessibilityLabel("Theater mode")
        .accessibilityIdentifier("theater.window.mode")
    }

    private var captionPointSize: Int {
        Int(TheaterCaptionScale.translatedSize(setting: CGFloat(self.settings.presenterFontSize)).rounded())
    }

    private var sizeMenu: some View {
        Menu {
            HStack {
                Text("Size")
                TheaterPointField(
                    label: "Caption size",
                    range: SettingsStore.presenterFontSizeRange,
                    value: Binding(
                        get: { self.settings.presenterFontSize },
                        set: { self.settings.presenterFontSize = $0 }
                    ),
                    accessibilityIdentifier: "theater.window.captionSize"
                )
                Text("pt")
            }
            HStack {
                Text("Spacing")
                TheaterPointField(
                    label: "Spacing",
                    range: TheaterCaptionSpacing.range,
                    value: self.$settings.theaterCaptionSpacing,
                    accessibilityIdentifier: "theater.window.captionSpacing"
                )
                Text("pt")
            }
            Divider()
            Button("\(self.captionPointSize) pt") {}
                .disabled(true)
            if self.isCaptionSizeFitted {
                let fittedSize = Int(TheaterCaptionScale.translatedSize(setting: self.lockedDisplaySize).rounded())
                Button("Fitted to \(fittedSize) pt") {}
                    .disabled(true)
                    .accessibilityIdentifier("theater.window.sizeFitted")
            }
            Button {
                self.nudgeFontSize(-2)
            } label: {
                Label("Smaller captions", systemImage: "minus")
            }
            .disabled(self.settings.presenterFontSize <= SettingsStore.presenterFontSizeRange.lowerBound)
            .help(TheaterChromeHelp.smaller)
            .accessibilityLabel("Smaller captions")
            Button {
                self.nudgeFontSize(2)
            } label: {
                Label("Larger captions", systemImage: "plus")
            }
            .disabled(self.settings.presenterFontSize >= SettingsStore.presenterFontSizeRange.upperBound)
            .help(TheaterChromeHelp.larger)
            .accessibilityLabel("Larger captions")
        } label: {
            TheaterMenuLabel(title: "Size", systemImage: "textformat.size", compact: true)
        }
        .theaterBarMenu()
        .theaterTag(TheaterChromeHelp.captionSize)
        .accessibilityLabel("Size \(self.captionPointSize)")
        .accessibilityIdentifier("theater.window.size")
    }

    private var fontMenu: some View {
        Menu {
            ForEach(TheaterTypeface.allCases) { face in
                Button {
                    PresenterCaptionController.shared.performChromeAction {
                        self.settings.presenterFontFamily = face.rawValue
                    }
                } label: {
                    if face == self.typeface {
                        Label(face.displayName, systemImage: "checkmark")
                    } else {
                        Text(face.displayName)
                    }
                }
            }
        } label: {
            TheaterMenuLabel(title: "Font", systemImage: "textformat", compact: true)
        }
        .theaterBarMenu()
        .theaterTag(TheaterChromeHelp.captionFont(current: self.typeface.displayName))
        .accessibilityLabel("Font")
        .accessibilityIdentifier("theater.window.font")
    }

    private var clearCaptionButton: some View {
        Button("Clear") {
            self.showClearConfirmation = true
        }
        .buttonStyle(TheaterTextButtonStyle(compact: true, destructive: true))
        .disabled(!self.controller.hasClearableBoard)
        .theaterTag(TheaterChromeHelp.clear)
        .accessibilityLabel("Clear captions")
        .accessibilityIdentifier("theater.window.clear")
    }

    private var boardMenu: some View {
        Menu {
            Button {
                self.controller.copyCaptionText()
            } label: {
                Label(
                    self.copyShowsCopied ? "Copied" : "Copy all",
                    systemImage: self.copyShowsCopied ? "checkmark" : "doc.on.doc"
                )
            }
            .disabled(self.deliveryIsEmpty)
            .help(TheaterChromeHelp.copyAll)
            .accessibilityLabel(self.copyShowsCopied ? "Copied" : "Copy all")
            .accessibilityIdentifier("theater.window.copy")

            Button {
                self.controller.insertCaptionText()
            } label: {
                Label("Type into app", systemImage: "text.cursor")
            }
            .disabled(self.insertIsEmpty)
            .help(
                self.insertIsEmpty && !self.deliveryIsEmpty
                    ? TheaterChromeHelp.tag("Type into app", does: TheaterReadiness.insertAlreadyTyped)
                    : TheaterChromeHelp.insert
            )
            .accessibilityLabel("Type into app")
            .accessibilityIdentifier("theater.window.insert")

            Button {
                PresenterCaptionController.shared.performChromeAction {
                    self.controller.undoLastCaption()
                }
            } label: {
                Label("Undo last caption", systemImage: "arrow.uturn.backward")
            }
            .disabled(!self.controller.hasUndoableCaption)
            .help(TheaterChromeHelp.undo)
            .accessibilityLabel("Undo last caption")
            .accessibilityIdentifier("theater.window.undo")

            Divider()

            Button {
                PresenterCaptionController.shared.performChromeAction {
                    PresenterCaptionController.shared.toggleMinimized()
                }
            } label: {
                Label(
                    self.settings.theaterMinimized ? "Expand Theater" : "Minimize Theater",
                    systemImage: self.settings.theaterMinimized
                        ? "arrow.up.left.and.arrow.down.right"
                        : "arrow.down.right.and.arrow.up.left"
                )
            }
            .help(self.settings.theaterMinimized ? TheaterChromeHelp.expand : TheaterChromeHelp.minimize)
            .accessibilityLabel(self.settings.theaterMinimized ? "Expand Theater" : "Minimize Theater")
            .accessibilityIdentifier("theater.minimize")

            Divider()

            Menu("Theme") {
                ForEach(TheaterAppearance.allCases) { appearance in
                    Button {
                        PresenterCaptionController.shared.performChromeAction {
                            self.settings.theaterAppearance = appearance.rawValue
                        }
                    } label: {
                        if appearance == self.appearance {
                            Label(appearance.displayName, systemImage: "checkmark")
                        } else {
                            Text(appearance.displayName)
                        }
                    }
                }
            }
            .help(TheaterChromeHelp.theme)

            Button {
                PresenterCaptionController.shared.performChromeAction {
                    self.settings.theaterHighContrast.toggle()
                }
            } label: {
                if self.settings.theaterHighContrast {
                    Label("High contrast", systemImage: "checkmark")
                } else {
                    Text("High contrast")
                }
            }
            .help(TheaterChromeHelp.highContrast)

            Divider()

            Button {
                PresenterCaptionController.shared.performChromeAction {
                    self.settings.theaterPresentationStyle = TheaterPresentationStyle.popup.rawValue
                }
            } label: {
                if self.presentationStyle == .popup {
                    Label(TheaterPresentationStyle.popup.displayName, systemImage: "checkmark")
                } else {
                    Text(TheaterPresentationStyle.popup.displayName)
                }
            }
            .help(TheaterChromeHelp.popup)

            Button {
                PresenterCaptionController.shared.performChromeAction {
                    self.settings.theaterPresentationStyle = TheaterPresentationStyle.transparent.rawValue
                }
            } label: {
                if self.presentationStyle == .transparent {
                    Label(TheaterPresentationStyle.transparent.displayName, systemImage: "checkmark")
                } else {
                    Text(TheaterPresentationStyle.transparent.displayName)
                }
            }
            .help(TheaterChromeHelp.overlay)

            Divider()

            Section(TheaterReadiness.linePrintTitle) {
                ForEach(TheaterLinePrint.allCases) { style in
                    Button {
                        PresenterCaptionController.shared.performChromeAction {
                            self.settings.theaterLinePrint = style
                        }
                    } label: {
                        if self.settings.theaterLinePrint == style {
                            Label(style.displayName, systemImage: "checkmark")
                        } else {
                            Text(style.displayName)
                        }
                    }
                    .help(style.help)
                }
            }

            Section(TheaterReadiness.printGapTitle) {
                ForEach(TheaterPrintGap.allCases) { gap in
                    Button {
                        PresenterCaptionController.shared.performChromeAction {
                            self.settings.theaterPrintGap = gap
                        }
                    } label: {
                        if self.settings.theaterPrintGap == gap {
                            Label(gap.displayName, systemImage: "checkmark")
                        } else {
                            Text(gap.displayName)
                        }
                    }
                    .help(TheaterChromeHelp.printGap)
                }
            }
            .disabled(self.settings.theaterLinePrint == .atOnce)

            Section("Position") {
                ForEach(TheaterPositionPreset.available(for: self.presentationStyle)) { preset in
                    Button {
                        PresenterCaptionController.shared.performChromeAction {
                            PresenterCaptionController.shared.applyPositionPreset(preset)
                        }
                    } label: {
                        if self.settings.theaterPositionPreset == preset {
                            Label(preset.displayName, systemImage: "checkmark")
                        } else {
                            Text(preset.displayName)
                        }
                    }
                    .help(TheaterChromeHelp.position(preset))
                    .accessibilityIdentifier("theater.position.\(preset.rawValue)")
                }
            }

            if self.settings.hasTheaterTalkPack {
                Divider()
                Section(self.talkPackMenuTitle) {
                    Button("Clear talk notes") {
                        PresenterCaptionController.shared.performChromeAction {
                            self.settings.clearTheaterTalkPack()
                        }
                    }
                    .help(TheaterChromeHelp.clearTalkNotes)
                    .accessibilityIdentifier("theater.talkPack.clear")
                }
            }

            Divider()

            Menu("Export") {
                Button("Bilingual text") {
                    PresenterCaptionController.shared.exportCaptions(format: .bilingualText)
                }
                .help(TheaterChromeHelp.exportBilingual)
                Button("SRT") {
                    PresenterCaptionController.shared.exportCaptions(format: .srt)
                }
                .help(TheaterChromeHelp.exportSRT)
                Button("VTT") {
                    PresenterCaptionController.shared.exportCaptions(format: .vtt)
                }
                .help(TheaterChromeHelp.exportVTT)
            }
            .disabled(self.model.board.isEmpty)

            Button("Close Theater") {
                PresenterCaptionController.shared.requestClose()
            }
            .help(TheaterChromeHelp.closeTheater)
        } label: {
            TheaterMenuLabel(
                title: self.boardButtonTitle,
                systemImage: self.boardButtonSymbol,
                compact: true
            )
        }
        .theaterBarMenu()
        .theaterTag(TheaterChromeHelp.board)
        .accessibilityLabel(self.boardButtonTitle)
        .accessibilityIdentifier("theater.presentationStyle")
    }

    private var presentationStage: some View {
        let settingSize = CGFloat(self.settings.presenterFontSize)
        let lines = TheaterCaptionFlow.lines(board: self.model.board)
        return GeometryReader { geometry in
            let proposed = TheaterCaptionScale.displaySize(
                setting: settingSize,
                stageWidth: geometry.size.width
            )
            // The button bar is already outside this viewport. Padding, the
            // gap before the bottom marker, and the marker sit outside the line.
            let captionBudget = geometry.size.height - 24
            let fitted = TheaterCaptionScale.fittedDisplaySize(
                proposed: proposed,
                stageHeight: captionBudget,
                pairHeight: self.captionPairHeight(typeface: self.typeface)
            )
            let display = TheaterCaptionScale.resolvedDisplaySize(
                proposed: fitted,
                locked: self.lockedDisplaySize,
                lockedFits: self.lockedDisplaySize >= 8
                    && self.captionPairHeight(typeface: self.typeface)(self.lockedDisplaySize) <= captionBudget
            )
            let spokenSize = TheaterCaptionScale.spokenSize(setting: display)
            let translatedSize = TheaterCaptionScale.translatedSize(setting: display)
            let wrapWidth = TheaterBilingualWrap.resolvedWrapWidth(
                proposed: geometry.size.width,
                locked: self.lockedWrapWidth
            )
            let spokenFont = self.typeface.nsFont(size: spokenSize, weight: .medium)
            let translatedFont = self.typeface.nsFont(size: translatedSize, weight: .semibold)
            let openingHeight = TheaterBilingualWrap.displayHeight(
                rows: [],
                spokenFont: spokenFont,
                translatedFont: translatedFont
            )
            let layouts = lines.map { line in
                let spoken = self.spokenLine(for: line)
                let rows = TheaterBilingualWrap.rows(
                    spoken: spoken,
                    translated: line.text,
                    spokenFont: spokenFont,
                    translatedFont: translatedFont,
                    width: wrapWidth
                )
                let realHeight = TheaterBilingualWrap.displayHeight(
                    rows: rows,
                    spokenFont: spokenFont,
                    translatedFont: translatedFont
                )
                // The wrap-ahead slot is real content for the scroll budget, but
                // it must not be part of the box `scrollLiveCaption` anchors to.
                // Anchoring the padded box to the viewport bottom pushed the
                // real ink up by a full slot and clipped the line above it.
                let reservedExtra: CGFloat = line.isCurrent
                    ? max(0, TheaterBilingualWrap.reservedDisplayHeight(
                        rows: rows,
                        spokenFont: spokenFont,
                        translatedFont: translatedFont,
                        width: wrapWidth
                    ) - realHeight)
                    : 0
                return TheaterLineLayout(
                    line: line,
                    spoken: spoken,
                    rows: rows,
                    height: realHeight,
                    reservedExtra: reservedExtra
                )
            }
            let boardHeight = self.boardContentHeight(
                lineHeights: layouts.flatMap { layout in
                    layout.reservedExtra > 0 ? [layout.height, layout.reservedExtra] : [layout.height]
                }
            )
            let pinsToBottom = TheaterBoardScroll.pinsToBottom(
                boardHeight: boardHeight,
                viewportHeight: geometry.size.height
            )
            // Scrolling to keep the live line at the bottom lands mid-line at
            // the top whenever the board height is not an exact multiple of
            // the line height. Fading that sliver instead of leaving it a
            // hard crop reads as an edge, not a clipped word.
            let topFadeHeight = min(TheaterBilingualWrap.lineHeight(for: translatedFont), geometry.size.height / 4)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: CGFloat(self.settings.theaterCaptionSpacing)) {
                        if lines.isEmpty {
                            let preview = TheaterBoardPreview.current(
                                session: self.settings.theaterSessionMode,
                                spokenMode: self.settings.theaterSpokenLineMode
                            )
                            TheaterBoardEmptyState(
                                message: self.emptyStateText,
                                titlePreview: preview.title,
                                spokenPreview: preview.spoken,
                                titleColor: Color(nsColor: self.translatedNS),
                                spokenColor: Color(nsColor: self.spokenNS),
                                messageColor: self.captionColors.empty,
                                titleFont: self.typeface.font(size: translatedSize, weight: .semibold),
                                spokenFont: self.typeface.font(size: spokenSize, weight: .medium),
                                messageFont: self.theme.typography.body,
                                isWarning: self.model.statusKind.usesWarningColor
                            )
                            .frame(minHeight: openingHeight, alignment: .topLeading)
                        } else {
                            ForEach(layouts) { layout in
                                TheaterCaptionLineLabel(
                                    lineID: layout.line.id,
                                    text: layout.line.text,
                                    source: layout.spoken,
                                    isCurrent: layout.line.isCurrent,
                                    wrapWidth: wrapWidth,
                                    rows: layout.rows,
                                    paint: TheaterCaptionLinePaint(
                                        typeface: self.typeface,
                                        spokenFontSize: spokenSize,
                                        translatedFontSize: translatedSize,
                                        spokenColor: self.spokenNS,
                                        translatedColor: self.translatedNS,
                                        shadowColor: self.captionColors.shadowColor,
                                        shadowBlur: self.captionColors.shadowBlur,
                                        showsCaptionPlate: self.showsCaptionPlate
                                    )
                                )
                                .frame(
                                    maxWidth: .infinity,
                                    minHeight: layout.height,
                                    idealHeight: layout.height,
                                    alignment: .topLeading
                                )
                                .id(layout.line.id)

                                if layout.reservedExtra > 0 {
                                    Color.clear
                                        .frame(height: layout.reservedExtra)
                                        .accessibilityHidden(true)
                                }
                            }
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("theater-bottom")
                    }
                    .frame(
                        maxWidth: .infinity,
                        minHeight: geometry.size.height,
                        alignment: pinsToBottom ? .bottom : .top
                    )
                    .padding(.top, TheaterBilingualWrap.boardTopClearance + 8)
                }
                // While the area under the buttons has room, new text grows
                // downward and lines already printed stay put. Once the area
                // is full, the newest line stays at the bottom and older lines
                // slide up.
                .defaultScrollAnchor(pinsToBottom ? .bottom : .top, for: .sizeChanges)
                .scrollIndicators(.hidden)
                .contentMargins(.top, 8, for: .scrollContent)
                .mask(alignment: .top) {
                    // Nothing sits above the first line until the board has
                    // scrolled, so only fade the top edge once pinning to the
                    // bottom can leave an older line's opening half-visible.
                    VStack(spacing: 0) {
                        if pinsToBottom {
                            LinearGradient(
                                colors: [Color.black.opacity(0), Color.black],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: topFadeHeight)
                        }
                        Color.black
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .onChange(of: display) { _, next in
                    if abs(next - self.lockedDisplaySize) > 0.5 {
                        self.lockedDisplaySize = next
                    }
                }
                .onChange(of: fitted) { _, next in
                    self.isCaptionSizeFitted = next < proposed - 0.5
                }
                .onChange(of: geometry.size.width) { _, width in
                    let locked = self.lockedWrapWidth
                    if width >= TheaterBilingualWrap.minimumWrapWidth, locked > width {
                        self.lockedWrapWidth = width
                        return
                    }
                    if locked < TheaterBilingualWrap.minimumWrapWidth
                        || width - locked >= TheaterBilingualWrap.wrapWidthHysteresis
                    {
                        self.lockedWrapWidth = width
                    }
                }
                .onChange(of: lines.map(\.id)) { oldIDs, newIDs in
                    guard Set(newIDs).subtracting(oldIDs).isEmpty == false else { return }
                    self.snappedNewRowThisTurn = true
                    self.scrollLiveCaption(
                        proxy: proxy,
                        lines: lines,
                        layouts: layouts,
                        viewportHeight: geometry.size.height,
                        boardHeight: boardHeight,
                        animated: false
                    )
                }
                .onChange(of: boardHeight) { oldHeight, newHeight in
                    if self.snappedNewRowThisTurn {
                        self.snappedNewRowThisTurn = false
                        return
                    }
                    guard TheaterBoardScroll.shouldFollowReveal(from: oldHeight, to: newHeight) else {
                        return
                    }
                    self.scrollLiveCaption(
                        proxy: proxy,
                        lines: lines,
                        layouts: layouts,
                        viewportHeight: geometry.size.height,
                        boardHeight: newHeight,
                        animated: false
                    )
                }
                .onAppear {
                    if geometry.size.width >= TheaterBilingualWrap.minimumWrapWidth {
                        self.lockedWrapWidth = geometry.size.width
                    }
                    self.scrollLiveCaption(
                        proxy: proxy,
                        lines: lines,
                        layouts: layouts,
                        viewportHeight: geometry.size.height,
                        boardHeight: boardHeight,
                        animated: false
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func scrollLiveCaption(
        proxy: ScrollViewProxy,
        lines: [TheaterFlowLine],
        layouts: [TheaterLineLayout],
        viewportHeight: CGFloat,
        boardHeight: CGFloat,
        animated: Bool
    ) {
        guard let current = lines.last(where: \.isCurrent) ?? lines.last else { return }
        let lineHeight = layouts.first(where: { $0.line.id == current.id })?.height ?? 0
        let showOpening = TheaterBoardScroll.showsOpeningOfLine(
            lineHeight: lineHeight,
            viewportHeight: viewportHeight
        )
        guard showOpening || TheaterBoardScroll.pinsToBottom(
            boardHeight: boardHeight,
            viewportHeight: viewportHeight
        ) else { return }
        let anchor: UnitPoint = showOpening ? .top : .bottom
        if animated {
            withAnimation(.easeOut(duration: 0.35)) {
                proxy.scrollTo(current.id, anchor: anchor)
            }
        } else {
            proxy.scrollTo(current.id, anchor: anchor)
        }
    }

    /// Mirrors the board's VStack spacing: a gap follows every child
    /// except the first, including the trailing marker. The tool bar sits
    /// above this viewport, so it is not part of the scrolled height.
    /// Undercounting those gaps understates the real content height, which
    /// makes `TheaterBoardScroll.pinsToBottom` miss the point where the live
    /// line has actually scrolled out of view.
    private func boardContentHeight(lineHeights: [CGFloat]) -> CGFloat {
        guard !lineHeights.isEmpty else { return 0 }
        let rowSpacing = CGFloat(self.settings.theaterCaptionSpacing)
        var height: CGFloat = 4
        for (index, lineHeight) in lineHeights.enumerated() {
            if index > 0 {
                height += rowSpacing
            }
            height += lineHeight
        }
        // Gap before, plus the height of, the trailing bottom marker.
        return height + rowSpacing + 1
    }

    private var readySnapshot: TheaterReadyGate.Snapshot {
        TheaterReadyGate.liveSnapshot(
            pack: self.controller.packAvailability,
            microphone: self.asr.micStatus,
            firstCaptionPrinted: self.settings.theaterListenUsed
        )
    }

    private var emptyStateText: String {
        if !self.model.status.isEmpty { return self.model.status }
        if self.model.isPaused {
            return TheaterReadiness.pausedStatus
        }
        if self.model.isListening {
            return TheaterReadiness.boardListening
        }
        if !self.readySnapshot.canListen {
            return self.readySnapshot.nextAction
        }
        // Idle Overlay has no Listen button to press.
        if self.presentationStyle == .transparent, !self.model.overlayToolsPinned {
            if !self.settings.theaterPresenterHotkeysEnabled {
                return TheaterReadiness.overlayIdleMenuBarHint
            }
            return self.settings.theaterOverlayCoachSeen
                ? TheaterReadiness.overlayIdleHint
                : TheaterReadiness.overlayIdleCoach
        }
        return TheaterReadiness.boardIdle
    }

    private func spokenLine(for line: TheaterFlowLine) -> String {
        let display = TheaterCaptionSpokenDisplay.resolved(
            mode: self.settings.theaterSpokenLineMode,
            sameLanguage: SpokenLanguageResolver.isSameLanguagePair()
        )
        guard display.printsSpokenOnCommitted else { return "" }
        return line.source
    }

    private func captionPairHeight(typeface: TheaterTypeface) -> (CGFloat) -> CGFloat {
        { display in
            let spoken = TheaterCaptionScale.spokenSize(setting: display)
            let translated = TheaterCaptionScale.translatedSize(setting: display)
            return TheaterBilingualWrap.boardHeight(
                rows: [
                    TheaterBilingualWrap.Row(text: " ", isSpoken: false),
                    TheaterBilingualWrap.Row(text: " ", isSpoken: true)
                ],
                spokenFont: typeface.nsFont(size: spoken, weight: .medium),
                translatedFont: typeface.nsFont(size: translated, weight: .semibold)
            )
        }
    }

    private func nudgeFontSize(_ delta: Int) {
        PresenterCaptionController.shared.performChromeAction {
            self.settings.presenterFontSize += delta
        }
    }

    // Both run on every body pass, so they must not rebuild the whole document.
    private var deliveryIsEmpty: Bool {
        !PresenterCaptionController.shared.hasDeliverableText
    }

    private var insertIsEmpty: Bool {
        !self.controller.subscriber.hasPendingInsertText
    }
}

private struct TheaterCaptionLinePaint {
    var typeface: TheaterTypeface
    var spokenFontSize: CGFloat
    var translatedFontSize: CGFloat
    var spokenColor: NSColor
    var translatedColor: NSColor
    var shadowColor: NSColor?
    var shadowBlur: CGFloat
    var showsCaptionPlate: Bool = false
}

private struct TheaterLineLayout: Identifiable {
    var id: String { self.line.id }
    let line: TheaterFlowLine
    let spoken: String
    let rows: [TheaterBilingualWrap.Row]
    /// Real content height, with no wrap-ahead reservation.
    let height: CGFloat
    /// Wrap-ahead slot for the live line. Rendered as a separate, unanchored
    /// sibling so `scrollLiveCaption` never anchors to it.
    let reservedExtra: CGFloat
}

private struct TheaterCaptionLineLabel: NSViewRepresentable {
    var lineID: String
    var text: String
    var source: String
    var isCurrent: Bool
    var wrapWidth: CGFloat = 0
    var rows: [TheaterBilingualWrap.Row] = []
    var paint: TheaterCaptionLinePaint

    func makeNSView(context: Context) -> TheaterCaptionLineNSView {
        let view = TheaterCaptionLineNSView()
        self.apply(to: view)
        return view
    }

    func updateNSView(_ view: TheaterCaptionLineNSView, context: Context) {
        self.apply(to: view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TheaterCaptionLineNSView, context: Context) -> CGSize {
        let proposed = max(proposal.width ?? nsView.bounds.width, 1)
        nsView.prepare(forWidth: proposed)
        return CGSize(width: proposed, height: nsView.captionHeight(forWidth: proposed))
    }

    private func apply(to view: TheaterCaptionLineNSView) {
        view.adoptStageWrapWidth(self.wrapWidth)
        view.adoptLaidOutRows(self.rows, width: self.wrapWidth)
        view.setCaption(
            lineID: self.lineID,
            spoken: self.source,
            translated: self.text,
            isCurrent: self.isCurrent,
            paint: self.paint
        )
    }
}

/// One committed clause. A new line prints in. A later growth continues
/// from the letters already on screen. Reduce Motion shows the line at once.
private final class TheaterCaptionLineNSView: NSView {
    private var lineViews: [NSTextField] = []
    private var displayRows: [TheaterBilingualWrap.Row] = []
    private var spoken = ""
    private var translated = ""
    private var spokenFont = NSFont.systemFont(ofSize: 32, weight: .semibold)
    private var translatedFont = NSFont.systemFont(ofSize: 45, weight: .semibold)
    private var spokenColor = NSColor.white.withAlphaComponent(0.58)
    private var translatedColor = NSColor.white
    private var captionShadow: NSShadow?
    private var wrapWidth: CGFloat = 0
    private var rowsLaidOutWidth: CGFloat = 0
    private var stagedRows: [TheaterBilingualWrap.Row] = []
    private var stagedWidth: CGFloat = 0
    private var isSyncingRows = false
    private var captionLineID = ""
    private var showsCaptionPlate = false
    private var plateLayers: [CALayer] = []
    /// `.max` means the whole line is already on screen.
    private var revealedSpoken = Int.max
    private var revealedTranslated = Int.max
    private var fadeStart: TimeInterval?
    private var revealWait: TimeInterval = 0
    private var revealTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
        self.layer?.isGeometryFlipped = true
        self.clipsToBounds = false
    }

    deinit {
        self.revealTimer?.invalidate()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func adoptStageWrapWidth(_ width: CGFloat) {
        guard width >= TheaterBilingualWrap.minimumWrapWidth else { return }
        self.wrapWidth = width
    }

    /// Rows already measured for this width. Layout reuses them instead of
    /// wrapping the same caption a second time.
    func adoptLaidOutRows(_ rows: [TheaterBilingualWrap.Row], width: CGFloat) {
        guard width >= TheaterBilingualWrap.minimumWrapWidth else { return }
        self.stagedRows = rows
        self.stagedWidth = width
    }

    func prepare(forWidth width: CGFloat) {
        let stage = self.wrapWidth
        let wrap: CGFloat
        if stage >= TheaterBilingualWrap.minimumWrapWidth {
            wrap = stage
        } else if let resolved = TheaterBilingualWrap.layoutWrapWidth(proposed: width, locked: stage) {
            wrap = resolved
        } else {
            return
        }
        if self.displayRows.isEmpty {
            self.syncRows(width: wrap)
        }
    }

    private var isCurrentLine = false

    func captionHeight(forWidth width: CGFloat) -> CGFloat {
        guard let wrap = TheaterBilingualWrap.layoutWrapWidth(proposed: width, locked: self.wrapWidth) else {
            return TheaterBilingualWrap.displayHeight(
                rows: [],
                spokenFont: self.spokenFont,
                translatedFont: self.translatedFont
            )
        }
        return self.measuredHeight(width: wrap)
    }

    func setCaption(
        lineID: String,
        spoken: String,
        translated: String,
        isCurrent: Bool,
        paint: TheaterCaptionLinePaint
    ) {
        let previousID = self.captionLineID
        let previousSpoken = self.spoken
        let previousTranslated = self.translated
        self.captionLineID = lineID
        self.applyChrome(
            typeface: paint.typeface,
            spokenFontSize: paint.spokenFontSize,
            translatedFontSize: paint.translatedFontSize,
            spokenColor: paint.spokenColor,
            translatedColor: paint.translatedColor,
            isCurrent: isCurrent,
            shadowColor: paint.shadowColor,
            shadowBlur: paint.shadowBlur,
            showsCaptionPlate: paint.showsCaptionPlate
        )
        self.spoken = spoken
        self.translated = translated
        self.isCurrentLine = isCurrent
        self.alphaValue = 1
        self.noteReveal(
            lineID: lineID,
            previousID: previousID,
            previousSpoken: previousSpoken,
            previousTranslated: previousTranslated,
            spoken: spoken,
            translated: translated
        )
        self.applyPrintedText()
    }

    private func noteReveal(
        lineID: String,
        previousID: String,
        previousSpoken: String,
        previousTranslated: String,
        spoken: String,
        translated: String
    ) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || SettingsStore.shared.theaterLinePrint == .atOnce
        {
            self.alphaValue = 1
            self.finishReveal()
            return
        }
        let sameLine = lineID == previousID && !previousID.isEmpty
        let sameText = spoken == previousSpoken && translated == previousTranslated
        if sameLine && sameText {
            return
        }
        if !sameLine {
            let style = SettingsStore.shared.theaterLinePrint
            if style == .fade {
                self.revealedSpoken = .max
                self.revealedTranslated = .max
                self.alphaValue = 0
                self.fadeStart = CACurrentMediaTime()
            } else {
                self.alphaValue = 1
                self.fadeStart = nil
                self.revealedSpoken = spoken.isEmpty ? .max : 0
                self.revealedTranslated = translated.isEmpty ? .max : 0
            }
            self.revealWait = 0
        } else {
            if self.revealedSpoken == .max {
                self.revealedSpoken = previousSpoken.count
            }
            if self.revealedTranslated == .max {
                self.revealedTranslated = previousTranslated.count
            }
        }
        self.scheduleReveal()
    }

    private func scheduleReveal() {
        guard self.revealTimer == nil else { return }
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            self.stepReveal()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.revealTimer = timer
    }

    private func stepReveal() {
        let style = SettingsStore.shared.theaterLinePrint
        if style == .atOnce {
            self.alphaValue = 1
            self.finishReveal()
            self.applyPrintedText()
            return
        }
        if style == .fade {
            let start = self.fadeStart ?? CACurrentMediaTime()
            self.fadeStart = start
            self.revealedSpoken = .max
            self.revealedTranslated = .max
            let duration = max(SettingsStore.shared.theaterPrintGap.fadeSeconds, 0.05)
            let fraction = min(1, (CACurrentMediaTime() - start) / duration)
            self.alphaValue = CGFloat(fraction)
            self.applyPrintedText()
            if fraction >= 1 {
                self.alphaValue = 1
                self.finishReveal()
            }
            return
        }
        self.alphaValue = 1
        self.revealWait += 0.02
        guard self.revealWait + 0.001 >= SettingsStore.shared.theaterPrintGap.stepSeconds else { return }
        self.revealWait = 0
        let byLetter = style == .letter
        self.revealedSpoken = Self.advance(self.spoken, from: self.revealedSpoken, byLetter: byLetter)
        self.revealedTranslated = Self.advance(self.translated, from: self.revealedTranslated, byLetter: byLetter)
        self.applyPrintedText()
        if self.revealedSpoken >= self.spoken.count, self.revealedTranslated >= self.translated.count {
            self.finishReveal()
        }
    }

    private func finishReveal() {
        self.revealTimer?.invalidate()
        self.revealTimer = nil
        self.fadeStart = nil
        self.revealWait = 0
        self.revealedSpoken = .max
        self.revealedTranslated = .max
    }

    private static func advance(_ text: String, from count: Int, byLetter: Bool) -> Int {
        if count >= text.count { return text.count }
        if byLetter { return min(text.count, count + 1) }
        let start = text.index(text.startIndex, offsetBy: min(count, text.count))
        let rest = text[start...]
        if let space = rest.firstIndex(where: \.isWhitespace) {
            return text.distance(from: text.startIndex, to: text.index(after: space))
        }
        return min(text.count, count + 2)
    }

    private static func prefix(_ text: String, count: Int) -> String {
        if count >= text.count { return text }
        if count <= 0 { return "" }
        return String(text.prefix(count))
    }

    private func take(_ text: String, budget: inout Int) -> String {
        if budget == .max { return text }
        let shown = Self.prefix(text, count: budget)
        budget = max(0, budget - text.count)
        return shown
    }

    private func applyChrome(
        typeface: TheaterTypeface,
        spokenFontSize: CGFloat,
        translatedFontSize: CGFloat,
        spokenColor: NSColor,
        translatedColor: NSColor,
        isCurrent: Bool,
        shadowColor: NSColor?,
        shadowBlur: CGFloat,
        showsCaptionPlate: Bool
    ) {
        self.spokenFont = typeface.nsFont(size: spokenFontSize, weight: .medium)
        self.translatedFont = typeface.nsFont(size: translatedFontSize, weight: .semibold)
        self.showsCaptionPlate = showsCaptionPlate
        let visible = TheaterCaptionVisibility.appliedAlphas(
            spoken: spokenColor,
            translated: translatedColor,
            isCurrent: isCurrent,
            isDraft: false
        )
        self.spokenColor = visible.spoken
        self.translatedColor = visible.translated
        if let shadowColor, shadowBlur > 0 {
            let shadow = NSShadow()
            shadow.shadowColor = shadowColor
            shadow.shadowBlurRadius = shadowBlur
            shadow.shadowOffset = .zero
            self.captionShadow = shadow
        } else {
            self.captionShadow = nil
        }
        self.needsLayout = true
    }

    private func applyPrintedText() {
        guard let wrap = TheaterBilingualWrap.layoutWrapWidth(
            proposed: self.bounds.width,
            locked: self.wrapWidth
        ) else {
            return
        }
        self.syncRows(width: wrap)
    }

    private func rowsForLayout(width: CGFloat) -> [TheaterBilingualWrap.Row] {
        if !self.stagedRows.isEmpty, abs(self.stagedWidth - width) < 0.5 {
            return self.stagedRows
        }
        return TheaterBilingualWrap.rows(
            spoken: self.spoken,
            translated: self.translated,
            spokenFont: self.spokenFont,
            translatedFont: self.translatedFont,
            width: width
        )
    }

    private func syncRows(width: CGFloat) {
        guard !self.isSyncingRows else { return }
        self.isSyncingRows = true
        defer { self.isSyncingRows = false }

        guard let wrap = TheaterBilingualWrap.layoutWrapWidth(proposed: width, locked: self.wrapWidth) else {
            return
        }
        let rows = self.rowsForLayout(width: wrap)
        self.wrapWidth = wrap
        self.rowsLaidOutWidth = wrap
        self.displayRows = rows

        while self.lineViews.count < rows.count {
            let field = self.makeLineField()
            self.addSubview(field)
            self.lineViews.append(field)
        }
        while self.lineViews.count > rows.count {
            self.lineViews.removeLast().removeFromSuperview()
        }
        var spokenLeft = self.revealedSpoken
        var translatedLeft = self.revealedTranslated
        for (index, row) in rows.enumerated() {
            let field = self.lineViews[index]
            let full = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let shown: String
            if row.isSpoken {
                shown = self.take(full, budget: &spokenLeft)
            } else {
                shown = self.take(full, budget: &translatedLeft)
            }
            field.font = row.isSpoken ? self.spokenFont : self.translatedFont
            let ink = shown.isEmpty
                ? NSColor.clear
                : (row.isSpoken ? self.spokenColor : self.translatedColor)
            field.stringValue = shown
            field.setAccessibilityLabel(full.isEmpty ? nil : full)
            field.textColor = ink
            field.isSelectable = !row.isSpoken && shown == full && !shown.isEmpty
            field.shadow = shown.isEmpty ? nil : self.captionShadow
        }
        self.needsLayout = true
        self.invalidateIntrinsicContentSize()
    }

    private func measuredHeight(width: CGFloat) -> CGFloat {
        _ = width
        return TheaterBilingualWrap.placedFrames(
            rows: self.displayRows,
            spokenFont: self.spokenFont,
            translatedFont: self.translatedFont,
            width: width,
            reserveGrowth: self.isCurrentLine
        ).height
    }

    override func layout() {
        super.layout()
        self.layer?.isGeometryFlipped = true
        let width = max(self.bounds.width, 1)
        if let wrap = TheaterBilingualWrap.layoutWrapWidth(proposed: width, locked: self.wrapWidth),
           self.displayRows.isEmpty || abs(self.rowsLaidOutWidth - wrap) > 0.5
        {
            self.syncRows(width: wrap)
        }
        let placed = TheaterBilingualWrap.placedFrames(
            rows: self.displayRows,
            spokenFont: self.spokenFont,
            translatedFont: self.translatedFont,
            width: width,
            reserveGrowth: self.isCurrentLine
        )
        let frames = placed.frames
        var targets: [(view: NSTextField, frame: NSRect)] = []
        targets.reserveCapacity(min(self.lineViews.count, frames.count))
        for (index, frame) in frames.enumerated() where index < self.lineViews.count {
            targets.append((self.lineViews[index], frame))
        }
        self.syncCaptionPlates(rowFrames: targets)
        for target in targets {
            target.view.frame = target.frame
        }
    }

    override var intrinsicContentSize: NSSize {
        let height = self.measuredHeight(width: self.wrapWidth)
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    override var isFlipped: Bool { true }

    private func syncCaptionPlates(rowFrames: [(view: NSTextField, frame: NSRect)]) {
        guard self.showsCaptionPlate else {
            for layer in self.plateLayers {
                layer.removeFromSuperlayer()
            }
            self.plateLayers.removeAll()
            return
        }
        self.wantsLayer = true
        guard let host = self.layer else { return }
        while self.plateLayers.count < rowFrames.count {
            let plate = CALayer()
            plate.backgroundColor = TheaterOverlayPolicy.plateColor().cgColor
            plate.cornerRadius = TheaterOverlayPolicy.plateCornerRadius
            plate.zPosition = -1
            host.insertSublayer(plate, at: 0)
            self.plateLayers.append(plate)
        }
        while self.plateLayers.count > rowFrames.count {
            self.plateLayers.removeLast().removeFromSuperlayer()
        }
        for (index, target) in rowFrames.enumerated() {
            let plate = self.plateLayers[index]
            let visible = target.view.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !visible.isEmpty else {
                plate.isHidden = true
                continue
            }
            let font = target.view.font ?? self.translatedFont
            let textWidth = ceil((visible as NSString).size(withAttributes: [.font: font]).width)
            let insetX = TheaterOverlayPolicy.plateHorizontalInset
            let insetY = TheaterOverlayPolicy.plateVerticalInset
            let width = min(target.frame.width, textWidth + insetX * 2)
            let textHeight = TheaterBilingualWrap.inkHeight(for: visible, font: font)
            let frame = CGRect(
                x: target.frame.minX,
                y: target.frame.minY,
                width: width,
                height: min(target.frame.height, textHeight + insetY * 2)
            )
            plate.isHidden = false
            plate.frame = frame
            plate.backgroundColor = TheaterOverlayPolicy.plateColor().cgColor
        }
    }

    private func makeLineField() -> NSTextField {
        let label = TheaterCaptionInkField(frame: .zero)
        let cell = TheaterCaptionInkCell(textCell: "")
        cell.isBordered = false
        cell.isBezeled = false
        cell.usesSingleLineMode = true
        cell.isScrollable = false
        cell.lineBreakMode = .byClipping
        cell.truncatesLastVisibleLine = false
        label.cell = cell
        label.drawsBackground = false
        label.isBezeled = false
        label.isBordered = false
        label.isEditable = false
        label.isSelectable = true
        label.textColor = .white
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        label.usesSingleLineMode = true
        label.clipsToBounds = false
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
}

/// Flipped so the line sits in the same top-down space as the caption board.
/// A non-flipped label inside the flipped board draws from the baseline and
/// loses the top half of the first spoken sentence.
private final class TheaterCaptionInkField: NSTextField {
    override var isFlipped: Bool { true }
}

