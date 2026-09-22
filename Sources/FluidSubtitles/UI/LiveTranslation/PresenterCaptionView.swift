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

/// Reserved chrome so hover tools and the titlebar do not collide with captions.
private enum TheaterChromeLayout {
    static let titlebarClearance: CGFloat = 36
    static let overlayIdleClearance: CGFloat = 10
    static let hoverToolsTop: CGFloat = 88
    static let overlayHoverToolsTop: CGFloat = 12
    static let languageHit: CGFloat = 32
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
    @State private var snappedNewRowThisTurn = false
    @State private var hoverBoardSize: CGSize = .zero
    @State private var copyShowsCopied = false
    @State private var copyBounceToken = 0
    @State private var pacePulseToken = 0
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
                if self.overlayHidesChrome { return }
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
        ZStack(alignment: .topLeading) {
            if !self.settings.theaterMinimized {
                self.boardFill
            }

            VStack(alignment: .leading, spacing: self.usesCaptionsOnlyChrome ? 8 : self.theme.metrics.spacing.md) {
                self.primaryChrome
                if !self.settings.theaterMinimized, self.showsExtendedChrome {
                    self.extendedChrome
                }
            }
            .padding(.horizontal, self.theme.metrics.spacing.xxl)
            .padding(.top, self.topChromeClearance)
            .frame(maxWidth: .infinity, alignment: .topLeading)

            if self.showsHoverTools {
                self.hoverTools
                    .padding(.horizontal, self.theme.metrics.spacing.xxl)
                    .padding(.top, self.hoverToolsTop)
                    .transition(.opacity)
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
        .animation(.easeOut(duration: 0.12), value: self.showsHoverTools)
        .coordinateSpace(name: TheaterHoverHelp.space)
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { self.hoverBoardSize = geo.size }
                    .onChange(of: geo.size) { _, size in
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

    /// Overlay idle hides every control. Pop-up captions-only keeps Listen in-flow.
    @ViewBuilder
    private var primaryChrome: some View {
        if self.overlayHidesChrome {
            EmptyView()
        } else if self.usesCaptionsOnlyChrome {
            self.captionsOnlyChrome
        } else {
            self.persistentChrome
        }
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

    private var showsExtendedChrome: Bool {
        !self.overlayHidesChrome && !self.usesCaptionsOnlyChrome
    }

    private var topChromeClearance: CGFloat {
        self.overlayHidesChrome
            ? TheaterChromeLayout.overlayIdleClearance
            : TheaterChromeLayout.titlebarClearance
    }

    /// Space so the first caption sits below Listen instead of under it.
    private var overlayChromeReserve: CGFloat {
        if self.overlayHidesChrome { return 0 }
        if self.showsExtendedChrome {
            return TheaterChromeLayout.hoverToolsTop + TheaterChromeLayout.languageHit
                - TheaterChromeLayout.titlebarClearance
        }
        return TheaterChromeLayout.hoverToolsTop - TheaterChromeLayout.titlebarClearance
    }

    private var boardFill: some View {
        Group {
            if self.model.isEditing {
                TheaterTextEditor(
                    text: self.$model.editedText,
                    typeface: self.typeface,
                    fontSize: CGFloat(self.settings.presenterFontSize),
                    textColor: self.translatedNS
                )
            } else {
                self.presentationStage
            }
        }
        .padding(.horizontal, self.theme.metrics.spacing.xxl)
        .padding(.top, self.topChromeClearance)
        .padding(.bottom, self.theme.metrics.spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var hoverToolsTop: CGFloat {
        self.presentationStyle == .transparent
            ? TheaterChromeLayout.overlayHoverToolsTop
            : TheaterChromeLayout.hoverToolsTop
    }

    private var showsHoverTools: Bool {
        self.usesCaptionsOnlyChrome
            && !self.settings.theaterMinimized
            && (self.chromeRevealed || self.chromePinned || self.model.isEditing)
    }

    private var presentationStyle: TheaterPresentationStyle {
        self.settings.theaterPresentation
    }

    private var talkPackMenuTitle: String {
        let name = self.settings.theaterTalkPackFileName.isEmpty ? "Notes" : self.settings.theaterTalkPackFileName
        return "Talk notes: \(name) · \(self.settings.theaterTalkPackTerms.count) names"
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
        ViewThatFits(in: .horizontal) {
            self.languagePairRow(showsLabels: true)
            self.languagePairRow(showsLabels: false)
        }
        .layoutPriority(2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("theater.window.languages")
    }

    private func languagePairRow(showsLabels: Bool) -> some View {
        HStack(spacing: self.theme.metrics.spacing.sm) {
            if showsLabels {
                Text("I speak")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.captionColors.chrome)
                    .lineLimit(1)
            }
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
                    Text("Swap")
                }
                .buttonStyle(.theaterTextCompact)
                .disabled(SpokenLanguageResolver.isSameLanguagePair())
                .theaterTag(TheaterChromeHelp.swapLanguages)
                .accessibilityLabel("Swap languages")

                if showsLabels {
                    Text("Show as")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.captionColors.chrome)
                        .lineLimit(1)
                }
                self.languageMenu(
                    title: "Show as",
                    selection: self.targetLanguageID,
                    languages: self.targetLanguages
                )
            }
        }
        .controlSize(.regular)
        .fixedSize(horizontal: true, vertical: false)
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

    /// Languages and Listen stay on the first row. Mode and appearance sit below.
    private var persistentChrome: some View {
        HStack(alignment: .center, spacing: self.theme.metrics.spacing.md) {
            self.languagePairControls
            Spacer(minLength: self.theme.metrics.spacing.sm)
            self.retryActions
            TheaterListenButton(
                usesChromeKey: true,
                listenIdentifier: "theater.window.listen",
                stopIdentifier: "theater.window.stop",
                pauseIdentifier: "theater.pause"
            )
            .layoutPriority(1)
            self.minimizeButton
        }
    }

    /// Extra chrome for captions-only: sits on top of captions instead of inserting a second row.
    private var hoverTools: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                self.languagePairControls
                Spacer(minLength: 8)
                self.retryActions
            }
            self.extendedChrome
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("theater.window.hoverTools")
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
            if !SpokenLanguageResolver.isSameLanguagePair() {
                Button(TheaterReadiness.downloadPack) {
                    PresenterCaptionController.shared.performChromeAction {
                        Task { await self.controller.requestNeededLanguagePackDownload() }
                    }
                }
                .buttonStyle(.theaterTextCompact)
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
                    .foregroundStyle(behind ? self.theme.palette.warning : self.theme.palette.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
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
    private var hiddenFromZoomBadge: some View {
        if self.settings.theaterHideFromScreenShare {
            Text(TheaterReadiness.hiddenFromZoomBadge)
                .font(self.theme.typography.caption)
                .foregroundStyle(self.captionColors.chrome)
                .lineLimit(1)
            .theaterTag(TheaterReadiness.hideFromScreenShare)
            .accessibilityIdentifier("theater.hiddenFromZoom")
        }
    }

    @ViewBuilder
    private var talkPackChip: some View {
        if self.settings.theaterSessionMode.showsTranslation, self.settings.hasTheaterTalkPack {
            let count = self.settings.theaterTalkPackTerms.count
            Text("\(count) names")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.captionColors.chrome)
                .lineLimit(1)
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

    private var captionsOnlyChrome: some View {
        HStack(alignment: .center, spacing: self.theme.metrics.spacing.sm) {
            self.paceCueReadout
            if !self.model.compactLatencyReadout.isEmpty {
                Text(self.model.compactLatencyReadout)
                    .font(self.theme.typography.codeCaption)
                    .foregroundStyle(self.captionColors.chrome)
                    .lineLimit(1)
                    .theaterTag(TheaterChromeHelp.latency)
            }
            Spacer(minLength: self.theme.metrics.spacing.sm)
            TheaterListenButton(
                usesChromeKey: true,
                listenIdentifier: "theater.window.listen",
                stopIdentifier: "theater.window.stop",
                pauseIdentifier: "theater.pause"
            )
            .layoutPriority(1)
            self.captionsOnlyButton
            self.minimizeButton
        }
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
            Text(self.settings.theaterSessionMode.displayName)
                .theaterButtonFace(compact: true)
                .fixedSize()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .theaterTag(TheaterChromeHelp.mode)
        .accessibilityLabel("Theater mode")
        .accessibilityIdentifier("theater.window.mode")
    }

    @ViewBuilder
    private var extendedChrome: some View {
        ViewThatFits(in: .horizontal) {
            self.extendedChromeRow(showsTheme: true, showsLatency: true)
            self.extendedChromeRow(showsTheme: false, showsLatency: true)
            self.extendedChromeRow(showsTheme: false, showsLatency: false)
        }
    }

    private func extendedChromeRow(showsTheme: Bool, showsLatency: Bool) -> some View {
        HStack(spacing: self.theme.metrics.spacing.sm) {
            self.windowModePicker
            if self.presentationStyle == .popup {
                self.captionsOnlyButton
            }
            self.paceCueReadout
            self.talkPackChip
            self.hiddenFromZoomBadge
            if showsLatency, !self.model.latencyReadout.isEmpty {
                Text(self.model.latencyReadout)
                    .font(self.theme.typography.codeCaption)
                    .foregroundStyle(self.captionColors.chrome)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .theaterTag(TheaterChromeHelp.latency)
            }
            if !self.model.status.isEmpty {
                Text(self.model.status)
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(
                        self.model.statusKind.usesWarningColor
                            ? self.theme.palette.warning
                            : self.captionColors.chrome
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .theaterTag(TheaterChromeHelp.status)
                    .accessibilityIdentifier("theater.status")
            }
            Spacer(minLength: self.theme.metrics.spacing.sm)
            if showsTheme {
                self.appearancePicker(compact: true)
            }
            self.typographyControls
                .layoutPriority(1)
        }
    }

    private var appearanceBinding: Binding<TheaterAppearance> {
        Binding(
            get: { self.appearance },
            set: { newValue in
                PresenterCaptionController.shared.performChromeAction {
                    self.settings.theaterAppearance = newValue.rawValue
                }
            }
        )
    }

    private func appearancePicker(compact: Bool) -> some View {
        HStack(spacing: self.theme.metrics.spacing.sm) {
            if !compact {
                Text("Theme")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.captionColors.chrome)
            }
            TheaterWordPicker(
                accessibilityLabel: "Theater theme",
                accessibilityIdentifier: "theater.appearance",
                options: Array(TheaterAppearance.allCases),
                title: { $0.displayName },
                selection: self.appearanceBinding
            )
            .theaterTag(TheaterChromeHelp.theme)
        }
        .controlSize(.regular)
        .fixedSize()
        .layoutPriority(0)
    }

    private var moreMenu: some View {
        Menu {
            Button(self.model.isEditing ? "Done" : "Edit captions") {
                self.toggleEditing()
            }
            .help(self.model.isEditing ? TheaterChromeHelp.doneEditing : TheaterChromeHelp.editCaptions)
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
            .disabled(self.model.committed.isEmpty)
            Divider()
            Button("Close Theater") {
                PresenterCaptionController.shared.requestClose()
            }
            .help(TheaterChromeHelp.closeTheater)
        } label: {
            self.chromeMenuWord(
                self.model.exportShowsSaved ? "Saved" : "More",
                systemImage: self.model.exportShowsSaved ? "checkmark" : "ellipsis"
            )
        }
        .theaterTag(TheaterChromeHelp.more)
        .accessibilityLabel("More")
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
    }

    private var minimizeButton: some View {
        Button {
            PresenterCaptionController.shared.performChromeAction {
                PresenterCaptionController.shared.toggleMinimized()
            }
        } label: {
            self.chromeWord(
                self.settings.theaterMinimized ? "Expand" : "Minimize",
                systemImage: self.settings.theaterMinimized
                    ? "arrow.up.left.and.arrow.down.right"
                    : "arrow.down.right.and.arrow.up.left"
            )
        }
        .buttonStyle(.theaterTextCompact)
        .theaterTag(self.settings.theaterMinimized ? TheaterChromeHelp.expand : TheaterChromeHelp.minimize)
        .accessibilityLabel(self.settings.theaterMinimized ? "Expand Theater" : "Minimize Theater")
        .accessibilityIdentifier("theater.minimize")
    }

    private var captionsOnlyButton: some View {
        Button {
            PresenterCaptionController.shared.performChromeAction {
                self.settings.theaterHideChrome.toggle()
            }
        } label: {
            self.chromeWord(
                self.settings.theaterHideChrome ? "Show tools" : "Captions only",
                systemImage: self.settings.theaterHideChrome ? "slider.horizontal.3" : "captions.bubble"
            )
        }
        .buttonStyle(.theaterTextCompact)
        .theaterTag(
            self.settings.theaterHideChrome
                ? TheaterChromeHelp.showAllControls
                : TheaterChromeHelp.captionsOnly
        )
        .accessibilityLabel(self.settings.theaterHideChrome ? "Show all controls" : "Captions only")
        .accessibilityIdentifier("theater.window.captionsOnly")
    }

    private var typographyControls: some View {
        HStack(spacing: self.theme.metrics.spacing.xs) {
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
                self.chromeMenuWord("Font", systemImage: "textformat")
            }
            .buttonStyle(.plain)
            .theaterTag(TheaterChromeHelp.captionFont(current: self.typeface.displayName))
            .accessibilityLabel("Caption font")
            .menuIndicator(.hidden)

            Button {
                self.nudgeFontSize(-2)
            } label: {
                self.chromeWord("Smaller", systemImage: "minus")
            }
            .buttonStyle(.theaterTextCompact)
            .disabled(self.settings.presenterFontSize <= SettingsStore.presenterFontSizeRange.lowerBound)
            .theaterTag(TheaterChromeHelp.smaller)
            .accessibilityLabel("Smaller captions")

            Button {
                self.nudgeFontSize(2)
            } label: {
                self.chromeWord("Larger", systemImage: "plus")
            }
            .buttonStyle(.theaterTextCompact)
            .disabled(self.settings.presenterFontSize >= SettingsStore.presenterFontSizeRange.upperBound)
            .theaterTag(TheaterChromeHelp.larger)
            .accessibilityLabel("Larger captions")

            Button {
                self.controller.copyCaptionText()
            } label: {
                self.chromeWord(
                    self.copyShowsCopied ? "Copied" : "Copy",
                    systemImage: "doc.on.doc",
                    symbolBounce: self.copyBounceToken
                )
            }
            .buttonStyle(.theaterTextCompact)
            .disabled(self.deliveryIsEmpty)
            .theaterTag(TheaterChromeHelp.copyAll)
            .accessibilityLabel(self.copyShowsCopied ? "Copied" : "Copy all")
            .accessibilityIdentifier("theater.window.copy")

            Button {
                self.controller.insertCaptionText()
            } label: {
                self.chromeWord("Type", systemImage: "text.cursor")
            }
            .buttonStyle(.theaterTextCompact)
            .disabled(self.insertIsEmpty)
            .theaterTag(
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
                self.chromeWord("Undo", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.theaterTextCompact)
            .disabled(!self.controller.hasUndoableCaption || self.model.isEditing)
            .theaterTag(TheaterChromeHelp.undo)
            .accessibilityLabel("Undo last caption")
            .accessibilityIdentifier("theater.window.undo")

            Button {
                self.showClearConfirmation = true
            } label: {
                self.chromeWord("Clear", systemImage: "trash")
            }
            .buttonStyle(.theaterTextCompact)
            .disabled(!self.controller.hasClearableBoard)
            .theaterTag(TheaterChromeHelp.clear)
            .accessibilityLabel("Clear captions")
            .accessibilityIdentifier("theater.window.clear")

            self.boardMenu
            self.moreMenu
        }
    }

    private func chromeWord(_ title: String, systemImage: String? = nil, symbolBounce: Int = 0) -> some View {
        TheaterActionLabel(
            title: title,
            systemImage: systemImage,
            compact: true,
            symbolBounce: symbolBounce,
            reduceMotion: self.reduceMotion
        )
    }

    private func chromeMenuWord(_ title: String, systemImage: String? = nil) -> some View {
        self.chromeWord(title, systemImage: systemImage)
            .theaterButtonFace(compact: true)
            .fixedSize()
    }

    private var boardMenu: some View {
        Menu {
            Menu("Spoken line") {
                ForEach(TheaterSpokenLineMode.allCases) { mode in
                    Button {
                        PresenterCaptionController.shared.performChromeAction {
                            self.settings.theaterSpokenLineMode = mode
                        }
                    } label: {
                        if mode == self.settings.theaterSpokenLineMode {
                            Label(mode.displayName, systemImage: "checkmark")
                        } else {
                            Text(mode.displayName)
                        }
                    }
                    .help(mode.help)
                }
            }
            .disabled(SpokenLanguageResolver.isSameLanguagePair())
            .help(
                SpokenLanguageResolver.isSameLanguagePair()
                    ? TheaterReadiness.spokenLineSameLanguage
                    : TheaterChromeHelp.spokenLine
            )

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

            Button {
                PresenterCaptionController.shared.performChromeAction {
                    self.settings.theaterHideFromScreenShare.toggle()
                }
            } label: {
                if self.settings.theaterHideFromScreenShare {
                    Label("Hide from screen share", systemImage: "checkmark")
                } else {
                    Text("Hide from screen share")
                }
            }
            .help(TheaterChromeHelp.hideFromScreenShare)
            .accessibilityIdentifier("theater.hideFromScreenShare")

            if self.presentationStyle == .transparent {
                Button {
                    PresenterCaptionController.shared.performChromeAction {
                        self.settings.theaterBackingBar.toggle()
                    }
                } label: {
                    if self.settings.theaterBackingBar {
                        Label("Caption plate", systemImage: "checkmark")
                    } else {
                        Text("Caption plate")
                    }
                }
                .help(TheaterChromeHelp.captionPlate)
                .accessibilityIdentifier("theater.backingBar")
            }

            Divider()

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
        } label: {
            self.chromeMenuWord("Board", systemImage: "rectangle.on.rectangle")
        }
        .theaterTag(TheaterChromeHelp.board)
        .accessibilityLabel("Settings")
        .accessibilityIdentifier("theater.presentationStyle")
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .controlSize(.regular)
    }

    private var presentationStage: some View {
        let settingSize = CGFloat(self.settings.presenterFontSize)
        let spokenDisplay = TheaterCaptionSpokenDisplay.resolved(
            mode: self.settings.theaterSpokenLineMode,
            sameLanguage: SpokenLanguageResolver.isSameLanguagePair()
        )
        let lines = TheaterCaptionFlow.lines(
            committed: self.model.committed,
            committedIDs: self.model.committedIDs,
            nextCaptionID: self.model.nextCaptionID,
            committedSources: self.model.committedSources,
            draft: self.model.draft,
            sourceDraft: self.model.source,
            pendingSources: self.model.pendingSources,
            inFlightCount: self.model.inFlightCount,
            liveRowID: self.model.liveRowID,
            spokenDisplay: spokenDisplay,
            makesRoomForLive: false
        )
        return GeometryReader { geometry in
            let sizes = TheaterCaptionScale.sizes(
                setting: settingSize,
                stageWidth: geometry.size.width
            )
            let spokenSize = sizes.spoken
            let translatedSize = sizes.translated
            let wrapWidth = TheaterBilingualWrap.resolvedWrapWidth(
                proposed: geometry.size.width,
                locked: self.lockedWrapWidth
            )
            let spokenFont = self.typeface.nsFont(size: spokenSize, weight: .semibold)
            let translatedFont = self.typeface.nsFont(size: translatedSize, weight: .semibold)
            let openingHeight = TheaterBilingualWrap.displayHeight(
                rows: [],
                spokenFont: spokenFont,
                translatedFont: translatedFont
            )
            let boardHeight = self.boardContentHeight(
                lines: lines,
                spokenFont: spokenFont,
                translatedFont: translatedFont,
                wrapWidth: wrapWidth,
                openingHeight: openingHeight
            )
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Spacer(minLength: 0)
                        if self.overlayChromeReserve > 0 {
                            Color.clear
                                .frame(height: self.overlayChromeReserve)
                                .accessibilityHidden(true)
                        }
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
                                spokenFont: self.typeface.font(size: spokenSize, weight: .semibold),
                                messageFont: self.theme.typography.body
                            )
                            .frame(minHeight: openingHeight, alignment: .topLeading)
                        } else {
                            ForEach(lines) { line in
                                let spokenBase = self.spokenLine(for: line)
                                let spoken = spokenBase
                                let wrapRows = TheaterBilingualWrap.rows(
                                    spoken: spoken,
                                    translated: line.text,
                                    spokenFont: spokenFont,
                                    translatedFont: translatedFont,
                                    width: wrapWidth
                                )
                                let captionHeight = TheaterBilingualWrap.displayHeight(
                                    rows: wrapRows,
                                    spokenFont: spokenFont,
                                    translatedFont: translatedFont
                                )
                                TheaterCaptionLineLabel(
                                    lineID: line.id,
                                    text: line.text,
                                    source: spokenBase,
                                    isCurrent: line.isCurrent,
                                    wrapWidth: wrapWidth,
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
                                    minHeight: captionHeight,
                                    idealHeight: captionHeight,
                                    alignment: .topLeading
                                )
                                .id(line.id)
                            }
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("theater-bottom")
                    }
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .bottom)
                    .padding(.top, 4)
                }
                // Growth and removals keep the newest line fixed at the bottom
                // instead of shifting the rows the audience is reading.
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .scrollIndicators(.hidden)
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
                        viewportHeight: geometry.size.height,
                        boardHeight: newHeight,
                        animated: true
                    )
                }
                .onAppear {
                    if geometry.size.width >= TheaterBilingualWrap.minimumWrapWidth {
                        self.lockedWrapWidth = geometry.size.width
                    }
                    self.scrollLiveCaption(
                        proxy: proxy,
                        lines: lines,
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
        viewportHeight: CGFloat,
        boardHeight: CGFloat,
        animated: Bool
    ) {
        guard let current = lines.last(where: \.isCurrent) ?? lines.last else { return }
        guard TheaterBoardScroll.pinsToBottom(
            boardHeight: boardHeight,
            viewportHeight: viewportHeight
        ) else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.35)) {
                proxy.scrollTo(current.id, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(current.id, anchor: .bottom)
        }
    }

    /// Mirrors the board's VStack(spacing: 14) exactly: a fixed gap follows
    /// every child, including the leading Spacer, the chrome reserve, and the
    /// trailing bottom marker. Undercounting those gaps understates the real
    /// content height, which makes `TheaterBoardScroll.pinsToBottom` miss the
    /// point where the live line has actually scrolled out of view.
    private func boardContentHeight(
        lines: [TheaterFlowLine],
        spokenFont: NSFont,
        translatedFont: NSFont,
        wrapWidth: CGFloat,
        openingHeight: CGFloat
    ) -> CGFloat {
        guard !lines.isEmpty else { return 0 }
        let rowSpacing: CGFloat = 14
        // padding(.top, 4) + gap after the leading Spacer + gap after the
        // chrome reserve box, when present.
        var height: CGFloat = 4 + rowSpacing + self.overlayChromeReserve
        if self.overlayChromeReserve > 0 {
            height += rowSpacing
        }
        for (index, line) in lines.enumerated() {
            if index > 0 {
                height += rowSpacing
            }
            let wrapRows = TheaterBilingualWrap.rows(
                spoken: self.spokenLine(for: line),
                translated: line.text,
                spokenFont: spokenFont,
                translatedFont: translatedFont,
                width: wrapWidth
            )
            height += TheaterBilingualWrap.displayHeight(
                rows: wrapRows,
                spokenFont: spokenFont,
                translatedFont: translatedFont
            )
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
        switch TheaterCaptionSpokenDisplay.resolved(
            mode: self.settings.theaterSpokenLineMode,
            sameLanguage: SpokenLanguageResolver.isSameLanguagePair()
        ) {
        case .paired, .pairedAfterPause:
            return line.source
        case .isTheCaption, .hidden:
            return ""
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
        if self.model.isEditing {
            return self.deliveryIsEmpty
        }
        return !self.controller.subscriber.hasPendingInsertText
    }

    private func toggleEditing() {
        if self.model.isEditing {
            PresenterCaptionController.shared.commitEdits()
            PresenterCaptionController.shared.scheduleReleaseKeyToExternalApp()
            return
        }
        PresenterCaptionController.shared.makeKeyForInteraction()
        self.model.editedText = PresenterCaptionController.shared.documentTextForDelivery()
        self.model.isEditing = true
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

private struct TheaterCaptionLineLabel: NSViewRepresentable {
    var lineID: String
    var text: String
    var source: String
    var isCurrent: Bool
    var wrapWidth: CGFloat = 0
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
        view.setCaption(
            lineID: self.lineID,
            spoken: self.source,
            translated: self.text,
            isCurrent: self.isCurrent,
            paint: self.paint
        )
    }
}

/// One committed clause. Spoken and Show-as appear together when the
/// subscriber accepts the clause — no letter clock or draft ink.
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
    private var isSyncingRows = false
    private var captionLineID = ""
    private var showsCaptionPlate = false
    private var plateLayers: [CALayer] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
        self.layer?.isGeometryFlipped = true
        self.clipsToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func adoptStageWrapWidth(_ width: CGFloat) {
        guard width >= TheaterBilingualWrap.minimumWrapWidth else { return }
        self.wrapWidth = width
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
        self.alphaValue = 1
        self.applyPrintedText()
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
        self.spokenFont = typeface.nsFont(size: spokenFontSize, weight: .semibold)
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

    private func syncRows(width: CGFloat) {
        guard !self.isSyncingRows else { return }
        self.isSyncingRows = true
        defer { self.isSyncingRows = false }

        guard let wrap = TheaterBilingualWrap.layoutWrapWidth(proposed: width, locked: self.wrapWidth) else {
            return
        }
        let rows = TheaterBilingualWrap.rows(
            spoken: self.spoken,
            translated: self.translated,
            spokenFont: self.spokenFont,
            translatedFont: self.translatedFont,
            width: wrap
        )
        self.wrapWidth = wrap
        self.displayRows = rows

        while self.lineViews.count < rows.count {
            let field = self.makeLineField()
            self.addSubview(field)
            self.lineViews.append(field)
        }
        while self.lineViews.count > rows.count {
            self.lineViews.removeLast().removeFromSuperview()
        }
        for (index, row) in rows.enumerated() {
            let field = self.lineViews[index]
            let visible = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
            field.font = row.isSpoken ? self.spokenFont : self.translatedFont
            let ink = visible.isEmpty
                ? NSColor.clear
                : (row.isSpoken ? self.spokenColor : self.translatedColor)
            field.stringValue = visible
            field.textColor = ink
            field.isSelectable = !row.isSpoken && !visible.isEmpty
            field.shadow = visible.isEmpty ? nil : self.captionShadow
        }
        self.needsLayout = true
        self.invalidateIntrinsicContentSize()
    }

    private func measuredHeight(width: CGFloat) -> CGFloat {
        _ = width
        return TheaterBilingualWrap.displayHeight(
            rows: self.displayRows,
            spokenFont: self.spokenFont,
            translatedFont: self.translatedFont
        )
    }

    override func layout() {
        super.layout()
        self.layer?.isGeometryFlipped = true
        if self.displayRows.isEmpty, self.wrapWidth >= TheaterBilingualWrap.minimumWrapWidth {
            self.syncRows(width: self.wrapWidth)
        }
        let width = max(self.bounds.width, 1)
        let frames = TheaterBilingualWrap.lineFrames(
            rows: self.displayRows,
            spokenFont: self.spokenFont,
            translatedFont: self.translatedFont,
            width: width
        )
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
            let frame = CGRect(
                x: target.frame.minX,
                y: target.frame.minY + max((target.frame.height - font.ascender - font.descender) / 2 - insetY, 0),
                width: width,
                height: min(target.frame.height, font.ascender + abs(font.descender) + insetY * 2)
            )
            plate.isHidden = false
            plate.frame = frame
            plate.backgroundColor = TheaterOverlayPolicy.plateColor().cgColor
        }
    }

    private func makeLineField() -> NSTextField {
        let label = TheaterCaptionInkField(labelWithString: "")
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = true
        label.textColor = .white
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        label.usesSingleLineMode = true
        label.cell?.isScrollable = true
        label.cell?.truncatesLastVisibleLine = false
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

/// AppKit editor so Theater can keep caption-colored text. SwiftUI TextEditor ignores foreground on macOS.
private struct TheaterTextEditor: NSViewRepresentable {
    @Binding var text: String
    var typeface: TheaterTypeface
    var fontSize: CGFloat
    var textColor: NSColor

    func makeCoordinator() -> Coordinator {
        Coordinator(text: self.$text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = self.textColor
        textView.insertionPointColor = self.textColor
        textView.font = self.typeface.nsFont(size: self.fontSize, weight: .semibold)
        textView.string = self.text
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineBreakMode = .byWordWrapping
        textView.textContainerInset = NSSize(width: 0, height: 4)

        scroll.documentView = textView
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        textView.font = self.typeface.nsFont(size: self.fontSize, weight: .semibold)
        textView.textColor = self.textColor
        textView.insertionPointColor = self.textColor
        if textView.string != self.text, context.coordinator.isEditing == false {
            textView.string = self.text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        weak var textView: NSTextView?
        var isEditing = false

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidBeginEditing(_ notification: Notification) {
            self.isEditing = true
        }

        func textDidEndEditing(_ notification: Notification) {
            self.isEditing = false
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            self.text.wrappedValue = textView.string
        }
    }
}
