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
    @State private var liveRevealHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            .appTheme(self.theme)
            .preferredColorScheme(self.appearance.colorScheme)
            .tint(self.theme.palette.accent)
            .background(TranslationSessionHost())
            .background(TheaterWindowAppearanceBridge(appearance: self.appearance))
            .onHover { hovering in
                if self.overlayHidesChrome { return }
                self.chromeRevealed = hovering
            }
            .onChange(of: self.model.overlayToolsPinned) { _, pinned in
                if self.presentationStyle == .transparent, !pinned {
                    self.chromeRevealed = false
                }
            }
            .onChange(of: self.presentationStyle) { _, style in
                if style == .transparent, !self.model.overlayToolsPinned {
                    self.chromeRevealed = false
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
            VStack(alignment: .leading, spacing: self.usesCaptionsOnlyChrome ? 8 : self.theme.metrics.spacing.md) {
                self.primaryChrome
                if !self.settings.theaterMinimized {
                    if self.showsExtendedChrome {
                        self.extendedChrome
                    }
                    if self.model.isEditing {
                        TheaterTextEditor(
                            text: self.$model.editedText,
                            typeface: self.typeface,
                            fontSize: CGFloat(self.settings.presenterFontSize),
                            textColor: self.translatedNS
                        )
                        .padding(.top, self.theme.metrics.spacing.xs)
                    } else {
                        self.presentationStage
                    }
                }
            }
            .padding(.horizontal, self.theme.metrics.spacing.xxl)
            .padding(.top, self.topChromeClearance)
            .padding(.bottom, self.theme.metrics.spacing.md)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if self.showsHoverTools {
                self.hoverTools
                    .padding(.horizontal, self.theme.metrics.spacing.xxl)
                    .padding(.top, self.hoverToolsTop)
                    .transition(.opacity)
            }
        }
        .background(self.theaterFill)
        .background {
            if self.presentationStyle == .popup, !self.settings.theaterHighContrast {
                Rectangle().fill(self.theme.materials.window)
            }
        }
        .animation(.easeOut(duration: 0.12), value: self.showsHoverTools)
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
                languages: TranslationLanguageCatalog.all
            )

            if self.settings.theaterSessionMode == .translation {
                Button {
                    PresenterCaptionController.shared.performChromeAction {
                        self.controller.swapDirection()
                    }
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: TheaterChromeLayout.languageHit, height: TheaterChromeLayout.languageHit)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
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
        let selectedName = languages.first(where: { $0.id == selection.wrappedValue })?.displayName
            ?? TranslationLanguageCatalog.language(id: selection.wrappedValue)?.displayName
            ?? selection.wrappedValue
        return Menu {
            ForEach(languages) { language in
                Button(language.displayName) {
                    PresenterCaptionController.shared.performChromeAction {
                        selection.wrappedValue = language.id
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(selectedName)
                    .font(self.theme.typography.bodySmallStrong)
                    .foregroundStyle(self.captionColors.chrome)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(self.captionColors.chrome.opacity(0.8))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(minWidth: 108, minHeight: TheaterChromeLayout.languageHit, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm, style: .continuous)
                    .fill(self.languageMenuFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm, style: .continuous)
                            .stroke(self.languageMenuStroke, lineWidth: 1)
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .theaterTag(title == "I speak" ? TheaterChromeHelp.iSpeak : TheaterChromeHelp.showAs)
        .accessibilityLabel(title)
        .accessibilityValue(selectedName)
    }

    private var languageMenuFill: Color {
        self.captionColors.menuFill
    }

    private var languageMenuStroke: Color {
        self.captionColors.menuStroke
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
        TranslationLanguageCatalog.targets(excluding: SpokenLanguageResolver.sourceLanguage())
    }

    /// Languages stay on one line at 640pt. Mode drops first if the row is still tight.
    @ViewBuilder
    private var persistentChrome: some View {
        ViewThatFits(in: .horizontal) {
            self.persistentChromeRow(showsMode: true)
            self.persistentChromeRow(showsMode: false)
        }
    }

    private func persistentChromeRow(showsMode: Bool) -> some View {
        HStack(alignment: .center, spacing: self.theme.metrics.spacing.md) {
            self.languagePairControls
            if showsMode {
                self.windowModePicker
            }
            Spacer(minLength: self.theme.metrics.spacing.sm)
            self.retryActions
            TheaterListenButton(
                usesChromeKey: true,
                listenIdentifier: "theater.window.listen",
                stopIdentifier: "theater.window.stop",
                pauseIdentifier: "theater.pause"
            )
            .layoutPriority(1)
            if self.presentationStyle == .popup {
                self.captionsOnlyButton
            }
            self.minimizeButton
        }
    }

    /// Extra chrome for captions-only: sits on top of captions instead of inserting a second row.
    private var hoverTools: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                self.languagePairControls
                self.windowModePicker
                Spacer(minLength: 8)
                self.retryActions
            }
            self.extendedChrome
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.78))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                }
        }
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
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .theaterTag(TheaterChromeHelp.retry)
            if !SpokenLanguageResolver.isSameLanguagePair() {
                Button(TheaterReadiness.downloadPack) {
                    PresenterCaptionController.shared.performChromeAction {
                        Task { await self.controller.requestNeededLanguagePackDownload() }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
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
            HStack(spacing: 6) {
                Circle()
                    .fill(
                        self.model.paceCueKind == TheaterPaceCue.Kind.behind.rawValue
                            ? self.theme.palette.warning
                            : self.theme.palette.accent
                    )
                    .frame(width: 8, height: 8)
                Text(text)
                    .font(self.theme.typography.caption.monospacedDigit())
                    .foregroundStyle(self.captionColors.chrome)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .theaterTag(TheaterChromeHelp.paceCue)
            .accessibilityLabel(self.model.paceCueLabel)
            .accessibilityIdentifier("theater.paceCue")
        }
    }

    @ViewBuilder
    private var hiddenFromZoomBadge: some View {
        if self.settings.theaterHideFromScreenShare {
            Label(TheaterReadiness.hiddenFromZoomBadge, systemImage: "eye.slash")
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
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.regular)
        .frame(minWidth: 168, minHeight: TheaterChromeLayout.languageHit)
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
            Picker("Theme", selection: self.appearanceBinding) {
                ForEach(TheaterAppearance.allCases) { appearance in
                    Text(appearance.displayName).tag(appearance)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 140)
            .theaterTag(TheaterChromeHelp.theme)
            .accessibilityLabel("Theater theme")
            .accessibilityIdentifier("theater.appearance")
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
            Image(systemName: "ellipsis")
                                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40)
        }
        .theaterTag(TheaterChromeHelp.more)
        .accessibilityLabel("More")
        .menuIndicator(.hidden)
        .buttonStyle(SquareIconButtonStyle())
        .controlSize(.regular)
    }

    private var minimizeButton: some View {
        Button {
            PresenterCaptionController.shared.performChromeAction {
                PresenterCaptionController.shared.toggleMinimized()
            }
        } label: {
            Image(systemName: self.settings.theaterMinimized ? "arrow.up.left.and.arrow.down.right" : "minus")
                                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40)
        }
        .buttonStyle(SquareIconButtonStyle())
        .controlSize(.regular)
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
            Image(systemName: self.settings.theaterHideChrome ? "rectangle.inset.filled" : "rectangle")
                                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40)
        }
        .buttonStyle(SquareIconButtonStyle())
        .controlSize(.regular)
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
                Image(systemName: "textformat")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40)
            }
            .theaterTag(TheaterChromeHelp.tag("Caption font", does: "\(self.typeface.displayName)."))
            .accessibilityLabel("Caption font")
            .menuIndicator(.hidden)

            Button {
                self.nudgeFontSize(-2)
            } label: {
                Image(systemName: "textformat.size.smaller")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40)
            }
            .disabled(self.settings.presenterFontSize <= SettingsStore.presenterFontSizeRange.lowerBound)
            .theaterTag(TheaterChromeHelp.smaller)
            .accessibilityLabel("Smaller spoken line")

            Button {
                self.nudgeFontSize(2)
            } label: {
                Image(systemName: "textformat.size.larger")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40)
            }
            .disabled(self.settings.presenterFontSize >= SettingsStore.presenterFontSizeRange.upperBound)
            .theaterTag(TheaterChromeHelp.larger)
            .accessibilityLabel("Larger spoken line")

            Button {
                self.controller.copyCaptionText()
            } label: {
                Image(systemName: "doc.on.doc")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40)
            }
            .disabled(self.deliveryIsEmpty)
            .theaterTag(TheaterChromeHelp.copyAll)
            .accessibilityLabel("Copy all")
            .accessibilityIdentifier("theater.window.copy")

            Button {
                self.controller.insertCaptionText()
            } label: {
                Image(systemName: "text.insert")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40)
            }
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
                Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40)
            }
            .disabled(!self.controller.hasUndoableCaption || self.model.isEditing)
            .theaterTag(TheaterChromeHelp.undo)
            .accessibilityLabel("Undo last caption")
            .accessibilityIdentifier("theater.window.undo")

            Button {
                self.showClearConfirmation = true
            } label: {
                Image(systemName: "trash")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40)
            }
            .disabled(!self.controller.hasClearableBoard)
            .theaterTag(TheaterChromeHelp.clear)
            .accessibilityLabel("Clear captions")
            .accessibilityIdentifier("theater.window.clear")

            self.boardMenu
            self.moreMenu
        }
        .buttonStyle(SquareIconButtonStyle())
        .controlSize(.regular)
    }

    private var boardMenu: some View {
        Menu {
            Button {
                PresenterCaptionController.shared.performChromeAction {
                    self.settings.translationShowSource.toggle()
                }
            } label: {
                if self.settings.translationShowSource {
                    Label("Show the spoken line", systemImage: "checkmark")
                } else {
                    Text("Show the spoken line")
                }
            }
            .disabled(SpokenLanguageResolver.isSameLanguagePair())
            .help(
                SpokenLanguageResolver.isSameLanguagePair()
                    ? TheaterReadiness.spokenLineSameLanguage
                    : TheaterChromeHelp.spokenLine
            )

            Menu("Caption print-in") {
                ForEach(TheaterCaptionPrintStyle.allCases) { style in
                    Button {
                        PresenterCaptionController.shared.performChromeAction {
                            self.settings.theaterCaptionPrintStyle = style
                        }
                    } label: {
                        if style == self.settings.theaterCaptionPrintStyle {
                            Label(style.displayName, systemImage: "checkmark")
                        } else {
                            Text(style.displayName)
                        }
                    }
                    .help(style.help)
                }
            }
            .help(TheaterChromeHelp.printIn)

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
                ForEach(TheaterPositionPreset.allCases) { preset in
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
            Image(systemName: "rectangle.on.rectangle")
                                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40)
        }
        .theaterTag(TheaterChromeHelp.board)
        .accessibilityLabel("Board")
        .accessibilityIdentifier("theater.presentationStyle")
        .menuIndicator(.hidden)
        .buttonStyle(SquareIconButtonStyle())
        .controlSize(.regular)
    }

    private var presentationStage: some View {
        let settingSize = CGFloat(self.settings.presenterFontSize)
        let spokenSize = TheaterCaptionScale.spokenSize(setting: settingSize)
        let translatedSize = TheaterCaptionScale.translatedSize(setting: settingSize)
        let spokenDisplay = TheaterCaptionSpokenDisplay.resolved(
            showSpokenLine: self.settings.translationShowSource,
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
            spokenDisplay: spokenDisplay,
            makesRoomForLive: false
        )
        return GeometryReader { geometry in
            let wrapWidth = TheaterBilingualWrap.resolvedWrapWidth(
                proposed: geometry.size.width,
                locked: self.lockedWrapWidth
            )
            let spokenFont = self.typeface.nsFont(size: spokenSize, weight: .semibold)
            let translatedFont = self.typeface.nsFont(size: translatedSize, weight: .semibold)
            let openingHeight = TheaterBilingualWrap.reservedDisplayHeight(
                rows: [],
                spokenFont: spokenFont,
                translatedFont: translatedFont,
                width: wrapWidth
            )
            let boardHeight = self.boardContentHeight(
                lines: lines,
                spokenFont: spokenFont,
                translatedFont: translatedFont,
                wrapWidth: wrapWidth,
                liveRevealHeight: self.liveRevealHeight
            )
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if lines.isEmpty {
                            Text(self.emptyStateText)
                                .font(self.theme.typography.body)
                                .foregroundStyle(self.captionColors.empty)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            ForEach(lines) { line in
                                let spoken = self.spokenLine(for: line)
                                let wrapRows = TheaterBilingualWrap.rows(
                                    spoken: spoken,
                                    translated: line.text,
                                    spokenFont: spokenFont,
                                    translatedFont: translatedFont,
                                    width: wrapWidth
                                )
                                let captionHeight = line.isCurrent
                                    ? TheaterBilingualWrap.reservedDisplayHeight(
                                        rows: wrapRows,
                                        spokenFont: spokenFont,
                                        translatedFont: translatedFont,
                                        width: wrapWidth
                                    )
                                    : TheaterBilingualWrap.displayHeight(
                                        rows: wrapRows,
                                        spokenFont: spokenFont,
                                        translatedFont: translatedFont
                                    )
                                let tracksLiveHeight = line.isCurrent
                                TheaterCaptionLineLabel(
                                    lineID: line.id,
                                    text: line.text,
                                    source: spoken,
                                    isCurrent: line.isCurrent,
                                    prints: line.isDraft,
                                    printStyle: self.reduceMotion
                                        ? .instant
                                        : self.settings.theaterCaptionPrintStyle,
                                    paint: TheaterCaptionLinePaint(
                                        typeface: self.typeface,
                                        spokenFontSize: spokenSize,
                                        translatedFontSize: translatedSize,
                                        spokenColor: self.spokenNS,
                                        translatedColor: self.translatedNS,
                                        shadowColor: self.captionColors.shadowColor,
                                        shadowBlur: self.captionColors.shadowBlur,
                                        showsCaptionPlate: self.showsCaptionPlate
                                    ),
                                    onRevealedHeightChange: tracksLiveHeight
                                        ? { height in
                                            if abs(height - self.liveRevealHeight) >= 1 {
                                                self.liveRevealHeight = height
                                            }
                                        }
                                        : nil
                                )
                                .frame(
                                    maxWidth: .infinity,
                                    minHeight: tracksLiveHeight
                                        ? max(self.liveRevealHeight, openingHeight)
                                        : captionHeight,
                                    idealHeight: tracksLiveHeight
                                        ? max(self.liveRevealHeight, openingHeight)
                                        : captionHeight,
                                    alignment: .topLeading
                                )
                                .id(line.id)
                            }
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("theater-bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.top, 4)
                    .animation(.easeOut(duration: 0.3), value: lines.map(\.id))
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
                    if Set(newIDs).subtracting(oldIDs).isEmpty == false {
                        self.liveRevealHeight = openingHeight
                    }
                    guard Set(newIDs).subtracting(oldIDs).isEmpty == false else { return }
                    self.scrollLiveCaption(
                        proxy: proxy,
                        lines: lines,
                        viewportHeight: geometry.size.height,
                        boardHeight: boardHeight,
                        animated: true
                    )
                }
                .onChange(of: self.liveRevealHeight) { previous, height in
                    guard TheaterBoardScroll.shouldFollowReveal(from: previous, to: height) else { return }
                    self.scrollLiveCaption(
                        proxy: proxy,
                        lines: lines,
                        viewportHeight: geometry.size.height,
                        boardHeight: self.boardContentHeight(
                            lines: lines,
                            spokenFont: spokenFont,
                            translatedFont: translatedFont,
                            wrapWidth: wrapWidth,
                            liveRevealHeight: height
                        ),
                        animated: false
                    )
                }
                .onAppear {
                    if geometry.size.width >= TheaterBilingualWrap.minimumWrapWidth {
                        self.lockedWrapWidth = geometry.size.width
                    }
                    if self.liveRevealHeight < openingHeight {
                        self.liveRevealHeight = openingHeight
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

    private func boardContentHeight(
        lines: [TheaterFlowLine],
        spokenFont: NSFont,
        translatedFont: NSFont,
        wrapWidth: CGFloat,
        liveRevealHeight: CGFloat? = nil
    ) -> CGFloat {
        guard !lines.isEmpty else { return 0 }
        var height: CGFloat = 4
        for (index, line) in lines.enumerated() {
            if index > 0 {
                height += 14
            }
            if line.isCurrent, let liveRevealHeight {
                height += max(liveRevealHeight, 1)
                continue
            }
            let wrapRows = TheaterBilingualWrap.rows(
                spoken: self.spokenLine(for: line),
                translated: line.text,
                spokenFont: spokenFont,
                translatedFont: translatedFont,
                width: wrapWidth
            )
            if line.isCurrent {
                height += TheaterBilingualWrap.reservedDisplayHeight(
                    rows: wrapRows,
                    spokenFont: spokenFont,
                    translatedFont: translatedFont,
                    width: wrapWidth
                )
            } else {
                height += TheaterBilingualWrap.displayHeight(
                    rows: wrapRows,
                    spokenFont: spokenFont,
                    translatedFont: translatedFont
                )
            }
        }
        return height + 1
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
            return TheaterReadiness.listeningEmpty
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
        return TheaterReadiness.pressListen
    }

    private func spokenLine(for line: TheaterFlowLine) -> String {
        switch TheaterCaptionSpokenDisplay.resolved(
            showSpokenLine: self.settings.translationShowSource,
            sameLanguage: SpokenLanguageResolver.isSameLanguagePair()
        ) {
        case .paired:
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
    var prints: Bool
    var printStyle: TheaterCaptionPrintStyle
    var paint: TheaterCaptionLinePaint
    var onRevealedHeightChange: ((CGFloat) -> Void)?

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
        view.setCaption(
            lineID: self.lineID,
            spoken: self.source,
            translated: self.text,
            isCurrent: self.isCurrent,
            prints: self.prints,
            printStyle: self.printStyle,
            paint: self.paint
        )
        view.onRevealedHeightChange = self.onRevealedHeightChange
    }
}

private final class TheaterCaptionLineNSView: NSView {
    private var lineViews: [NSTextField] = []
    private var displayRows: [TheaterBilingualWrap.Row] = []
    private var targetSpoken = ""
    private var targetTranslated = ""
    private var printedSpoken = ""
    private var printedTranslated = ""
    private var printTimer: Timer?
    private var printStyle: TheaterCaptionPrintStyle = .flow
    private var isCurrent = true
    private var spokenFont = NSFont.systemFont(ofSize: 32, weight: .semibold)
    private var translatedFont = NSFont.systemFont(ofSize: 45, weight: .semibold)
    private var spokenColor = NSColor.white.withAlphaComponent(0.58)
    private var translatedColor = NSColor.white
    private var captionShadow: NSShadow?
    private var wrapWidth: CGFloat = 0
    private var lastReportedHeight: CGFloat = 0
    private var isSyncingRows = false
    private var captionLineID = ""
    private var showsCaptionPlate = false
    private var plateLayers: [CALayer] = []
    var onRevealedHeightChange: ((CGFloat) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
        self.clipsToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.printTimer?.invalidate()
    }

    func prepare(forWidth width: CGFloat) {
        guard let wrap = TheaterBilingualWrap.layoutWrapWidth(proposed: width, locked: self.wrapWidth) else {
            return
        }
        if abs(wrap - self.wrapWidth) > 1 || self.displayRows.isEmpty {
            self.syncRows(width: wrap)
        }
    }

    func captionHeight(forWidth width: CGFloat) -> CGFloat {
        guard let wrap = TheaterBilingualWrap.layoutWrapWidth(proposed: width, locked: self.wrapWidth) else {
            return TheaterBilingualWrap.reservedDisplayHeight(
                rows: [],
                spokenFont: self.spokenFont,
                translatedFont: self.translatedFont,
                width: max(width, 1)
            )
        }
        let rows = TheaterBilingualWrap.revealedRows(
            spoken: self.targetSpoken,
            translated: self.targetTranslated,
            printedSpoken: self.printedSpoken,
            printedTranslated: self.printedTranslated,
            spokenFont: self.spokenFont,
            translatedFont: self.translatedFont,
            width: wrap
        )
        return self.measuredHeight(rows: rows, width: wrap)
    }

    func setCaption(
        lineID: String,
        spoken: String,
        translated: String,
        isCurrent: Bool,
        prints: Bool,
        printStyle: TheaterCaptionPrintStyle,
        paint: TheaterCaptionLinePaint
    ) {
        let lineChanged = lineID != self.captionLineID
        if lineChanged {
            if TheaterLinePrinter.shouldResetPrintProgressOnLineChange(
                printedSpoken: self.printedSpoken,
                printedTranslated: self.printedTranslated,
                nextSpoken: spoken,
                nextTranslated: translated
            ) {
                self.resetPrintProgress()
            }
            self.captionLineID = lineID
        }

        // A committed row whose translation was replaced, not grown: the
        // newest line fixed after a restitch, or a presenter edit. Type the
        // new pair fresh instead of letting the only-grow rules freeze it.
        let replacesCommittedRow = !lineChanged && !prints
            && !translated.isEmpty && !self.printedTranslated.isEmpty
            && translated != self.targetTranslated
            && !translated.hasPrefix(self.printedTranslated)
        if replacesCommittedRow {
            self.resetPrintProgress()
        }

        if spoken.isEmpty, translated.isEmpty {
            self.printStyle = printStyle
            self.isCurrent = isCurrent
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
        if self.printedSpoken.isEmpty, self.printedTranslated.isEmpty {
                self.applyPrintedText()
            }
            return
        }

        let hasPrint = !self.printedSpoken.isEmpty || !self.printedTranslated.isEmpty
        let translationStarted = !self.printedTranslated.isEmpty
        let incoming = TheaterLinePrinter.resolveIncoming(
            currentSpoken: self.targetSpoken,
            currentTranslated: self.targetTranslated,
            nextSpoken: spoken,
            nextTranslated: translated,
            translationStarted: translationStarted
        )
        if lineChanged {
            self.targetSpoken = incoming.spoken
            self.targetTranslated = incoming.translated
        }
        let nextSpoken = incoming.spoken
        let nextTranslated = incoming.translated

        let adopts = TheaterLinePrinter.shouldAdoptPrintedCaption(
            currentSpoken: self.targetSpoken,
            currentTranslated: self.targetTranslated,
            nextSpoken: nextSpoken,
            nextTranslated: nextTranslated
        )
        self.printStyle = printStyle
        self.isCurrent = isCurrent
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
        if !hasPrint, printStyle.fadesIn, self.window != nil {
            self.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().alphaValue = 1
            }
        } else {
            self.alphaValue = 1
        }

        if lineChanged {
            // Targets already set. Type the new pair from a blank line.
        } else if !translationStarted {
            self.targetSpoken = nextSpoken
            self.targetTranslated = nextTranslated
        } else if adopts {
            if nextSpoken.hasPrefix(self.printedSpoken) || self.printedSpoken.hasPrefix(nextSpoken) {
                self.targetSpoken = nextSpoken
            }
            if nextTranslated.hasPrefix(self.printedTranslated)
                || self.printedTranslated.hasPrefix(nextTranslated)
                || nextTranslated.isEmpty
            {
                self.targetTranslated = nextTranslated
            }
        } else if !hasPrint {
            self.targetSpoken = nextSpoken
            self.targetTranslated = nextTranslated
        } else if nextSpoken.hasPrefix(self.printedSpoken), nextTranslated.hasPrefix(self.printedTranslated) {
            // shouldAdoptPrintedCaption rejected this update on a clause-boundary
            // heuristic, but it still contains everything already on screen, so
            // printing more of it is always safe. Without this, the target can
            // freeze indefinitely while speech keeps growing, and the whole
            // backlog only appears later, at once, when the line commits.
            self.targetSpoken = nextSpoken
            self.targetTranslated = nextTranslated
        }

        let unfinished = self.printedSpoken != self.targetSpoken
            || self.printedTranslated != self.targetTranslated
        let titleArrived = !self.targetTranslated.isEmpty && self.printedTranslated.isEmpty
        // Typing only ever continues on the current line. The moment a line
        // stops being current (the speaker has moved to the next sentence),
        // its translated text must be shown in full immediately rather than
        // left to finish typing on borrowed time — otherwise a slow-starting
        // translation (typed before spoken, see nextPrintStep) can get
        // orphaned mid-type when the next sentence takes over, and that
        // sentence's Korean never appears.
        let shouldType = isCurrent && printStyle.typesIn
            && (unfinished || (titleArrived && (prints || hasPrint)))

        if shouldType {
            self.startPrintIfNeeded()
        } else {
            self.printTimer?.invalidate()
            self.printTimer = nil
            self.printedSpoken = self.targetSpoken
            self.printedTranslated = self.targetTranslated
            self.applyPrintedText()
        }
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
            isCurrent: isCurrent
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

    private func resetPrintProgress() {
        self.printTimer?.invalidate()
        self.printTimer = nil
        self.targetSpoken = ""
        self.targetTranslated = ""
        self.printedSpoken = ""
        self.printedTranslated = ""
        self.lastReportedHeight = 0
    }

    private func startPrintIfNeeded() {
        let pending = self.printedSpoken != self.targetSpoken
            || self.printedTranslated != self.targetTranslated
        guard pending else {
            self.printTimer?.invalidate()
            self.printTimer = nil
            self.applyPrintedText()
            return
        }
        if self.printTimer == nil {
            self.advancePrint()
            self.scheduleNextPrintTick()
        }
    }

    private func scheduleNextPrintTick() {
        self.printTimer?.invalidate()
        self.printTimer = nil
        if self.printedSpoken == self.targetSpoken, self.printedTranslated == self.targetTranslated {
            return
        }
        let interval = self.printStyle.printStepSeconds(
            printedSpoken: self.printedSpoken,
            targetSpoken: self.targetSpoken,
            printedTranslated: self.printedTranslated,
            targetTranslated: self.targetTranslated
        )
        let timer = Timer(timeInterval: max(interval, 0.016), repeats: false) { [weak self] _ in
            guard let self else { return }
            self.printTimer = nil
            self.advancePrint()
            self.scheduleNextPrintTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.printTimer = timer
    }

    private func advancePrint() {
        let next = TheaterLinePrinter.nextPrintStep(
            printedSpoken: self.printedSpoken,
            targetSpoken: self.targetSpoken,
            printedTranslated: self.printedTranslated,
            targetTranslated: self.targetTranslated,
            style: self.printStyle
        )
        self.printedSpoken = next.spoken
        self.printedTranslated = next.translated
        self.applyPrintedText()
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
        let rows = TheaterBilingualWrap.revealedRows(
            spoken: self.targetSpoken,
            translated: self.targetTranslated,
            printedSpoken: self.printedSpoken,
            printedTranslated: self.printedTranslated,
            spokenFont: self.spokenFont,
            translatedFont: self.translatedFont,
            width: wrap
        )
        self.wrapWidth = wrap
        self.displayRows = rows
        self.reportRevealedHeight()

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
            if field.stringValue != visible {
                field.stringValue = visible
            }
            field.font = row.isSpoken ? self.spokenFont : self.translatedFont
            field.textColor = visible.isEmpty
                ? .clear
                : (row.isSpoken ? self.spokenColor : self.translatedColor)
            field.shadow = visible.isEmpty ? nil : self.captionShadow
            field.isSelectable = !row.isSpoken && !visible.isEmpty
        }
        self.needsLayout = true
        self.invalidateIntrinsicContentSize()
    }

    private func measuredHeight(rows: [TheaterBilingualWrap.Row], width: CGFloat) -> CGFloat {
        if self.isCurrent {
            return TheaterBilingualWrap.reservedDisplayHeight(
                rows: rows,
                spokenFont: self.spokenFont,
                translatedFont: self.translatedFont,
                width: width
            )
        }
        return TheaterBilingualWrap.displayHeight(
            rows: rows,
            spokenFont: self.spokenFont,
            translatedFont: self.translatedFont
        )
    }

    private func reportRevealedHeight() {
        let height = self.measuredHeight(rows: self.displayRows, width: self.wrapWidth)
        guard abs(height - self.lastReportedHeight) >= 1 else { return }
        self.lastReportedHeight = height
        let callback = self.onRevealedHeightChange
        DispatchQueue.main.async {
            callback?(height)
        }
    }

    override func layout() {
        super.layout()
        let width = max(self.bounds.width, 1)
        if let wrap = TheaterBilingualWrap.layoutWrapWidth(proposed: width, locked: self.wrapWidth),
           abs(wrap - self.wrapWidth) > 1 || self.displayRows.isEmpty
        {
            self.syncRows(width: wrap)
        }
        var y: CGFloat = TheaterBilingualWrap.boardTopClearance
        var targets: [(view: NSTextField, frame: NSRect)] = []
        targets.reserveCapacity(self.lineViews.count)
        for (index, view) in self.lineViews.enumerated() {
            let spoken = index < self.displayRows.count ? self.displayRows[index].isSpoken : false
            let lineHeight = TheaterBilingualWrap.lineHeight(
                for: spoken ? self.spokenFont : self.translatedFont
            )
            targets.append((view, NSRect(x: 0, y: y, width: width, height: lineHeight)))
            y += lineHeight + TheaterBilingualWrap.rowSpacing
        }
        self.syncCaptionPlates(rowFrames: targets)

        // Rows only ever grow or shift down as translated content streams in.
        // Animate only a row that already existed and is actually moving, so a
        // brand-new row (still at .zero) snaps straight into place instead of
        // sliding in from the corner, and an unmoved row does not restart an
        // animation on every print tick.
        var toAnimate: [(view: NSTextField, frame: NSRect)] = []
        for target in targets {
            let current = target.view.frame
            if current == target.frame {
                continue
            }
            if current == .zero {
                target.view.frame = target.frame
            } else {
                toAnimate.append(target)
            }
        }
        guard !toAnimate.isEmpty else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for target in toAnimate {
                target.view.animator().frame = target.frame
            }
        }
    }

    override var intrinsicContentSize: NSSize {
        let height = self.measuredHeight(rows: self.displayRows, width: self.wrapWidth)
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
        label.usesSingleLineMode = false
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
