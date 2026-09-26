import AppKit
import AVFoundation
import SwiftUI

struct LiveTranslationHomeView: View {
    @EnvironmentObject private var appServices: AppServices
    @Environment(\.theme) private var theme
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var controller = LiveTranslationController.shared

    var openVoiceEngine: (() -> Void)?
    var openTranslationEngine: (() -> Void)?

    private var asr: ASRService { self.appServices.asr }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                self.header
                    .padding(.bottom, 8)
                if !TheaterAvailability.isSupported {
                    Text(TheaterAvailability.unsupportedCopy)
                        .font(self.theme.typography.body)
                        .foregroundStyle(self.theme.palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("theater.needsMacOS26")
                }
                if self.theaterStatusText != nil {
                    self.statusRow
                }
                if TheaterAvailability.isSupported {
                    self.stageCard
                    if self.settings.theaterListenUsed {
                        TheaterEngineCards(
                            openVoiceEngine: self.openVoiceEngine,
                            openTranslationEngine: self.openTranslationEngine,
                            showsPurpose: false
                        )
                        if self.settings.theaterSessionMode.showsTranslation {
                            TheaterTalkPackCard()
                        }
                    }
                    if self.readySnapshot.needsAttention {
                        self.readinessCard
                    }
                }
                CommercialLicenseStatusCard(compact: true)
            }
            .fluidPageContent()
            .accessibilityIdentifier("theater.home")
            .onAppear {
                self.controller.alignSpokenEngineWithTheater()
                MicrophoneAccess.refresh(self.asr)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                MicrophoneAccess.refresh(self.asr)
            }
            .onChange(of: self.settings.theaterSessionMode) { _, _ in
                MicrophoneAccess.refresh(self.asr)
            }
        }
    }

    private var modePicker: some View {
        TheaterModeSection(accessibilityIdentifier: "theater.mode")
    }

    private var stageCard: some View {
        ThemedCard(style: .prominent, hoverEffect: false) {
            VStack(alignment: .leading, spacing: 16) {
                TheaterCaptionStackPreview(
                    message: TheaterReadiness.boardIdle,
                    lines: TheaterBoardPreview.current(
                        session: self.settings.theaterSessionMode,
                        spokenMode: self.settings.theaterSpokenLineMode
                    ),
                    titleSize: 22,
                    spokenSize: 13
                )
                self.modePicker
                self.sectionRule
                TranslationLanguagePairCard(showsCard: false)
                if self.settings.theaterSessionMode.showsTranslation {
                    self.sectionRule
                    self.spokenLineRow
                }
                self.sectionRule
                TheaterAudienceCard(showsCard: false)
                DisclosureGroup("Adjust") {
                    self.linePrintRow
                        .padding(.top, 12)
                }
            }
        }
        .accessibilityIdentifier("theater.stage")
    }

    private var sectionRule: some View {
        Rectangle()
            .fill(self.theme.palette.separator)
            .frame(height: 1)
            .accessibilityHidden(true)
    }

    private var linePrintRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            TheaterSettingRow(
                title: TheaterReadiness.linePrintTitle,
                detail: self.settings.theaterLinePrint.help
            ) {
                TheaterWordPicker(
                    accessibilityLabel: TheaterReadiness.linePrintTitle,
                    accessibilityIdentifier: "theater.home.linePrint",
                    options: Array(TheaterLinePrint.allCases),
                    title: { $0.displayName },
                    selection: Binding(
                        get: { self.settings.theaterLinePrint },
                        set: { self.settings.theaterLinePrint = $0 }
                    )
                )
            }
            TheaterSettingRow(
                title: TheaterReadiness.printGapTitle,
                detail: "The pause between each word or letter. Fade uses this as how long the line takes to arrive."
            ) {
                TheaterWordPicker(
                    accessibilityLabel: TheaterReadiness.printGapTitle,
                    accessibilityIdentifier: "theater.home.printGap",
                    options: Array(TheaterPrintGap.allCases),
                    title: { $0.displayName },
                    selection: Binding(
                        get: { self.settings.theaterPrintGap },
                        set: { self.settings.theaterPrintGap = $0 }
                    )
                )
                .disabled(self.settings.theaterLinePrint == .atOnce)
                .opacity(self.settings.theaterLinePrint == .atOnce ? 0.45 : 1)
            }
        }
    }

    private var spokenLineRow: some View {
        TheaterSpokenLineSection(accessibilityIdentifier: "theater.home.spokenLine")
    }

    private var statusRow: some View {
        Group {
            if let status = self.theaterStatusText {
                HStack(spacing: 8) {
                    Text(status)
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theaterStatusColor)
                        .accessibilityIdentifier("theater.status")
                    if self.controller.subscriber.canRetryTranslation {
                        Button("Retry") {
                            self.controller.retryFailedTranslation()
                        }
                        .buttonStyle(.theaterTextCompact)
                        .help(TheaterChromeHelp.retry)
                        .accessibilityIdentifier("theater.home.retry")
                    }
                }
            }
        }
    }

    private var header: some View {
        FluidPageHeader(
            systemImage: "captions.bubble",
            title: "Theater",
            subtitle: FluidProduct.tagline
        ) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    OpenTheaterButton()
                    TheaterListenButton()
                }
                VStack(alignment: .trailing, spacing: 6) {
                    OpenTheaterButton()
                    TheaterListenButton()
                }
            }
        }
    }

    private var theaterStatusColor: Color {
        if self.controller.subscriber.statusKind.usesWarningColor {
            return self.theme.palette.warning
        }
        if self.controller.subscriber.statusKind == .success {
            return self.theme.palette.accent
        }
        return self.theme.palette.secondaryText
    }

    private var theaterStatusText: String? {
        if self.controller.isPaused {
            return TheaterReadiness.pausedStatus
        }
        if self.controller.isSessionActive, self.controller.listenKind == .captions {
            return TheaterReadiness.listeningStatus
        }
        let failure = self.controller.subscriber.statusText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !failure.isEmpty, failure != "Listening…" {
            if failure == SpokenLanguageResolver.voiceEngineMismatchMessage() {
                return nil
            }
            return failure
        }
        if self.settings.theaterWindowEnabled {
            return self.settings.theaterMinimized
                ? TheaterReadiness.theaterMinimizedStatus
                : TheaterReadiness.theaterOpenStatus
        }
        return nil
    }

    private var readySnapshot: TheaterReadyGate.Snapshot {
        TheaterReadyGate.liveSnapshot(
            pack: self.controller.packAvailability,
            microphone: self.asr.micStatus,
            firstCaptionPrinted: self.settings.theaterListenUsed
        )
    }

    private var readinessCard: some View {
        ThemedCard(style: .standard, hoverEffect: false) {
            TheaterReadinessChecklist(
                openVoiceEngine: self.openVoiceEngine,
                openTranslationEngine: self.openTranslationEngine
            )
        }
        .accessibilityIdentifier("theater.readiness")
    }
}

struct LiveTranslationSettingsView: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var controller = LiveTranslationController.shared
    @ObservedObject private var subscriber = LiveTranslationController.shared.subscriber
    @State private var showClearConfirmation = false

    var recordTranslateShortcut: (() -> Void)?
    var isRecordingTranslateShortcut = false
    var recordListenShortcut: (() -> Void)?
    var isRecordingListenShortcut = false
    var shortcutRecordingMessage: String?
    var accessibilityTrusted = true
    var openAccessibility: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            self.theaterAppearanceCard
                .settingsSearchTarget(.theaterAppearance)
                .settingsSearchTarget(.setupWizard)

            TranslateListenShortcutCard(
                recordListenShortcut: self.recordListenShortcut,
                isRecordingListenShortcut: self.isRecordingListenShortcut,
                shortcutRecordingMessage: self.shortcutRecordingMessage
            )
            .settingsSearchTarget(.captionListenShortcut)

            TranslateInsertShortcutCard(
                recordTranslateShortcut: self.recordTranslateShortcut,
                isRecordingTranslateShortcut: self.isRecordingTranslateShortcut,
                shortcutRecordingMessage: self.shortcutRecordingMessage,
                accessibilityTrusted: self.accessibilityTrusted,
                openAccessibility: self.openAccessibility
            )
            .settingsSearchTarget(.translateInsertShortcut)

            ThemedCard(style: .standard, hoverEffect: false) {
                VStack(alignment: .leading, spacing: 8) {
                    FluidSectionHeader(title: TheaterEngineCopy.translationTitle, systemImage: "translate")
                    Text(TheaterEngineCopy.translationPurpose)
                        .font(self.theme.typography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Open Setup → Translation Engine to pick Apple Translation or try the experimental local LLM.")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .alert("Clear captions?", isPresented: self.$showClearConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                self.controller.clearBoard()
            }
        } message: {
            Text(TheaterReadiness.clearCaptionsConfirm)
        }
    }

    private var theaterAppearanceCard: some View {
        ThemedCard(style: .standard, hoverEffect: false) {
            VStack(alignment: .leading, spacing: 14) {
                FluidSectionHeader(title: "Theater Window", systemImage: "rectangle.on.rectangle")

                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(TheaterSetupWizard.title)
                            .font(self.theme.typography.bodyStrong)
                            .foregroundStyle(self.settingsTitleText)
                        Text(TheaterSetupWizard.welcomeDetail)
                            .font(self.theme.typography.bodySmall)
                            .foregroundStyle(self.settingsSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Open") {
                        self.settings.startSetupWizard()
                    }
                    .buttonStyle(.theaterText)
                    .controlSize(.small)
                    .accessibilityIdentifier("theater.settings.setupWizard")
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Board")
                            .font(self.theme.typography.bodyStrong)
                            .foregroundStyle(self.settingsTitleText)
                        Text(TheaterReadiness.presentationStyle)
                            .font(self.theme.typography.bodySmall)
                            .foregroundStyle(self.settingsSecondaryText)
                    }
                    Spacer()
                    TheaterWordPicker(
                        accessibilityLabel: "Theater board",
                        accessibilityIdentifier: "theater.settings.presentationStyle",
                        options: Array(TheaterPresentationStyle.allCases),
                        title: { $0.displayName },
                        selection: Binding(
                            get: { self.settings.theaterPresentation },
                            set: { self.settings.theaterPresentationStyle = $0.rawValue }
                        )
                    )
                    .help(self.settings.theaterPresentation.help)
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Each sentence appears when it is ready.")
                            .font(self.theme.typography.bodyStrong)
                            .foregroundStyle(self.settingsTitleText)
                        Text("Nothing shows while it is still being heard.")
                            .font(self.theme.typography.bodySmall)
                            .foregroundStyle(self.settingsSecondaryText)
                    }
                    Spacer()
                }

                if self.settings.theaterSessionMode == .translation {
                    TheaterSpokenLineSection(accessibilityIdentifier: "theater.settings.spokenLine")
                    Text(TheaterReadiness.spokenLineSetupNote)
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.settingsSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("theater.settings.spokenLineNote")
                }

                self.settingsToggleRow(
                    title: "Captions only",
                    description: self.settings.theaterPresentation == .transparent
                        ? TheaterReadiness.captionsOnlyPopupOnly
                        : TheaterReadiness.captionsOnlyWindow
                ) {
                    Toggle("Captions only", isOn: self.$settings.theaterHideChrome)
                        .toggleStyle(.switch)
                        .tint(self.theme.palette.accent)
                        .labelsHidden()
                        .disabled(self.settings.theaterPresentation == .transparent)
                        .accessibilityLabel("Captions only")
                }

                Text(TheaterReadiness.screenShare)
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.settingsSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("theater.settings.screenShare")

                self.settingsToggleRow(
                    title: "Caption plate",
                    description: TheaterReadiness.backingBar
                ) {
                    Toggle("Caption plate", isOn: self.$settings.theaterBackingBar)
                        .toggleStyle(.switch)
                        .tint(self.theme.palette.accent)
                        .labelsHidden()
                        .disabled(self.settings.theaterPresentation != .transparent)
                        .accessibilityLabel("Caption plate")
                        .accessibilityIdentifier("theater.settings.backingBar")
                }

                self.settingsToggleRow(
                    title: "Presenter shortcuts",
                    description: TheaterReadiness.presenterHotkeys
                ) {
                    Toggle("Presenter shortcuts", isOn: self.$settings.theaterPresenterHotkeysEnabled)
                        .toggleStyle(.switch)
                        .tint(self.theme.palette.accent)
                        .labelsHidden()
                        .accessibilityLabel("Presenter shortcuts")
                        .accessibilityIdentifier("theater.settings.presenterHotkeys")
                }

                self.settingsToggleRow(
                    title: "Also hear English, Korean, Japanese, and Thai questions",
                    description: TheaterReadiness.alsoHearOtherLanguages
                ) {
                    Toggle(
                        "Also hear English, Korean, Japanese, and Thai questions",
                        isOn: self.$settings.theaterAlsoHearOtherLanguages
                    )
                    .toggleStyle(.switch)
                    .tint(self.theme.palette.accent)
                    .labelsHidden()
                    .disabled(!self.settings.selectedSpeechModel.isWhisperModel)
                    .accessibilityLabel("Also hear English, Korean, Japanese, and Thai questions")
                }

                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(TheaterSetupWizard.accentTitle)
                            .font(self.theme.typography.bodyStrong)
                            .foregroundStyle(self.settingsTitleText)
                        Text(TheaterSetupWizard.accentDetail)
                            .font(self.theme.typography.bodySmall)
                            .foregroundStyle(self.settingsSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    AccentColorSwatches(accessibilityIdentifier: "theater.settings.accentColor")
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Theme")
                            .font(self.theme.typography.bodyStrong)
                            .foregroundStyle(self.settingsTitleText)
                        Text("Choose Dark or Light for Theater. This does not change the main window.")
                            .font(self.theme.typography.bodySmall)
                            .foregroundStyle(self.settingsSecondaryText)
                    }
                    Spacer()
                    TheaterWordPicker(
                        accessibilityLabel: "Theater theme",
                        options: Array(TheaterAppearance.allCases),
                        title: { $0.displayName },
                        selection: Binding(
                            get: { TheaterAppearance.resolved(self.settings.theaterAppearance) },
                            set: { self.settings.theaterAppearance = $0.rawValue }
                        )
                    )
                }

                self.settingsToggleRow(
                    title: "High contrast",
                    description: "Stronger background and a stroke on caption text."
                ) {
                    Toggle("High contrast", isOn: self.$settings.theaterHighContrast)
                        .toggleStyle(.switch)
                        .tint(self.theme.palette.accent)
                        .labelsHidden()
                        .accessibilityLabel("High contrast")
                }

                Divider().opacity(0.2)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Caption Font")
                            .font(self.theme.typography.bodyStrong)
                            .foregroundStyle(self.settingsTitleText)
                        Text("Typeface used for Theater captions")
                            .font(self.theme.typography.bodySmall)
                            .foregroundStyle(self.settingsSecondaryText)
                    }
                    Spacer()
                    Picker("Caption font", selection: Binding(
                        get: { TheaterTypeface.resolved(self.settings.presenterFontFamily) },
                        set: { self.settings.presenterFontFamily = $0.rawValue }
                    )) {
                        ForEach(TheaterTypeface.allCases) { face in
                            Text(face.displayName).tag(face)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 170, alignment: .trailing)
                }

                Divider().opacity(0.2)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Caption Size")
                                .font(self.theme.typography.bodyStrong)
                                .foregroundStyle(self.settingsTitleText)
                            Text(
                                self.settings.theaterSessionMode == .translation
                                    ? TheaterReadiness.captionSizeSpoken
                                    : TheaterReadiness.captionSize
                            )
                                .font(self.theme.typography.bodySmall)
                                .foregroundStyle(self.settingsSecondaryText)
                        }
                        Spacer()
                        TheaterPointField(
                            label: "Caption size",
                            range: SettingsStore.presenterFontSizeRange,
                            value: Binding(
                                get: { self.settings.presenterFontSize },
                                set: { self.settings.presenterFontSize = $0 }
                            ),
                            accessibilityIdentifier: "theater.settings.captionSize"
                        )
                        Text("pt")
                            .font(self.theme.typography.bodySmall)
                            .foregroundStyle(self.settingsSecondaryText)
                    }

                    Slider(
                        value: Binding(
                            get: { Double(self.settings.presenterFontSize) },
                            set: { self.settings.presenterFontSize = Int($0.rounded()) }
                        ),
                        in: Double(SettingsStore.presenterFontSizeRange.lowerBound)...Double(SettingsStore.presenterFontSizeRange.upperBound),
                        step: 2
                    )
                    .controlSize(.regular)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Spacing")
                                .font(self.theme.typography.bodyStrong)
                                .foregroundStyle(self.settingsTitleText)
                            Text("Points between caption lines.")
                                .font(self.theme.typography.bodySmall)
                                .foregroundStyle(self.settingsSecondaryText)
                        }
                        Spacer()
                        TheaterPointField(
                            label: "Spacing",
                            range: TheaterCaptionSpacing.range,
                            value: self.$settings.theaterCaptionSpacing,
                            accessibilityIdentifier: "theater.settings.captionSpacing"
                        )
                        Text("pt")
                            .font(self.theme.typography.bodySmall)
                            .foregroundStyle(self.settingsSecondaryText)
                    }
                }

                Text(TheaterReadiness.printedLinesStay)
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.settingsSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                self.settingsToggleRow(
                    title: "Clear captions",
                    description: TheaterReadiness.clearCaptions
                ) {
                    Button("Clear") {
                        self.showClearConfirmation = true
                    }
                    .buttonStyle(.theaterTextDestructive)
                    .disabled(!self.canClearCaptions)
                    .accessibilityLabel("Clear captions")
                    .accessibilityIdentifier("theater.settings.clear")
                }

                Text(
                    self.settings.theaterSessionMode == .transcription
                        ? TheaterReadiness.transcriptionCopy
                        : TheaterReadiness.oneSpeakerCloseMic
                )
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.settingsSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func settingsToggleRow<Accessory: View>(
        title: String,
        description: String,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) -> some View {
        TheaterSettingRow(title: title, detail: description, control: accessory)
    }

    /// What the caption title line actually renders at, before the window's
    /// width grows it further or a short Overlay bar shrinks it to fit.
    private var renderedCaptionSize: Int {
        Int(TheaterCaptionScale.translatedSize(setting: CGFloat(self.settings.presenterFontSize)).rounded())
    }

    private var canClearCaptions: Bool {
        self.controller.hasClearableBoard
            || self.subscriber.committedLines.contains {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
    }

    private var settingsTitleText: Color {
        Color(nsColor: .labelColor)
    }

    private var settingsSecondaryText: Color {
        self.colorScheme == .light ? Color(nsColor: .labelColor).opacity(0.90) : self.theme.palette.primaryText.opacity(0.82)
    }
}

struct OpenTheaterButton: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var controller = LiveTranslationController.shared

    private var homeAction: TheaterMinimize.HomeAction {
        TheaterMinimize.homeAction(
            windowEnabled: self.settings.theaterWindowEnabled,
            minimized: self.settings.theaterMinimized
        )
    }

    var body: some View {
        Button {
            switch self.homeAction {
            case .close:
                PresenterCaptionController.shared.requestClose()
            case .open, .show:
                PresenterCaptionController.shared.setVisible(true)
            }
        } label: {
            TheaterActionLabel(
                title: TheaterMinimize.homeTitle(for: self.homeAction),
                systemImage: TheaterMinimize.homeSystemImage(for: self.homeAction)
            )
        }
        .buttonStyle(.theaterText)
        .disabled(!TheaterAvailability.isSupported)
        .help(
            TheaterAvailability.isSupported
                ? TheaterMinimize.homeHelp(
                    for: self.homeAction,
                    listening: self.controller.isSessionActive && self.controller.listenKind == .captions
                )
                : TheaterAvailability.unsupportedCopy
        )
        .accessibilityLabel(TheaterMinimize.homeTitle(for: self.homeAction))
        .accessibilityIdentifier("theater.open")
    }
}

struct TheaterListenButton: View {
    var usesChromeKey = false
    var listenIdentifier = "theater.listen"
    var stopIdentifier = "theater.listen"
    var pauseIdentifier = "theater.home.pause"

    @ObservedObject private var controller = LiveTranslationController.shared
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var asr = AppServices.shared.asr
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isListening: Bool {
        self.controller.isSessionActive && self.controller.listenKind == .captions
    }

    private var listenTitle: String {
        if self.controller.isFinishingSession { return "Stopping…" }
        return self.isListening ? "Stop" : "Listen"
    }

    private var snapshot: TheaterReadyGate.Snapshot {
        TheaterReadyGate.liveSnapshot(
            pack: self.controller.packAvailability,
            microphone: self.asr.micStatus,
            firstCaptionPrinted: self.settings.theaterListenUsed
        )
    }

    private var dictationBusy: Bool {
        !self.isListening && self.asr.isRunningOrStarting
    }

    private var listenHelp: String {
        if self.dictationBusy { return TheaterReadiness.dictationBusy }
        if self.isListening { return TheaterReadiness.stopHelp }
        if self.snapshot.canListen { return TheaterReadiness.pressListen }
        return self.snapshot.nextAction
    }

    private var listenButtonStyle: TheaterTextButtonStyle {
        if self.isListening || self.controller.isFinishingSession {
            return self.usesChromeKey ? .theaterTextCompactStop : .theaterTextStop
        }
        return self.usesChromeKey ? .theaterTextCompactProminent : .theaterTextProminent
    }

    var body: some View {
        HStack(spacing: self.usesChromeKey ? 4 : 8) {
            if self.isListening, !self.usesChromeKey {
                self.listeningWaveform
            }
            if self.isListening {
                Button {
                    self.run {
                        if self.controller.isPaused {
                            self.controller.resumeListening()
                        } else {
                            self.controller.pauseListening()
                        }
                    }
                } label: {
                    TheaterActionLabel(
                        title: self.controller.isPaused ? "Resume" : "Pause",
                        systemImage: self.usesChromeKey
                            ? nil
                            : (self.controller.isPaused ? "play.fill" : "pause.fill"),
                        compact: self.usesChromeKey
                    )
                }
                .buttonStyle(self.usesChromeKey ? .theaterTextCompact : .theaterText)
                .theaterTag(
                    self.usesChromeKey
                        ? (self.controller.isPaused ? TheaterChromeHelp.resume : TheaterChromeHelp.pause)
                        : (self.controller.isPaused ? TheaterReadiness.resumeHelp : TheaterReadiness.pauseHelp),
                    paints: self.usesChromeKey
                )
                .accessibilityLabel(self.controller.isPaused ? "Resume" : "Pause")
                .accessibilityIdentifier(self.pauseIdentifier)
            }

            Button {
                self.run {
                    if self.isListening {
                        self.controller.stopListening()
                    } else if self.usesChromeKey {
                        self.controller.startCaptionListening()
                    } else {
                        LiveTranslationController.shared.toggleCaptionListening()
                    }
                }
            } label: {
                TheaterActionLabel(
                    title: self.listenTitle,
                    systemImage: self.usesChromeKey
                        ? nil
                        : (self.isListening || self.controller.isFinishingSession ? "stop.fill" : "mic.fill"),
                    compact: self.usesChromeKey
                )
            }
            .buttonStyle(self.listenButtonStyle)
            .disabled(
                self.controller.isFinishingSession
                    || (!self.isListening && (!self.snapshot.canListen || self.dictationBusy))
            )
            .theaterTag(
                self.usesChromeKey
                    ? (self.isListening ? TheaterChromeHelp.stop : TheaterChromeHelp.listen)
                    : self.listenHelp,
                paints: self.usesChromeKey
            )
            .accessibilityLabel(self.listenTitle)
            .accessibilityIdentifier(self.isListening ? self.stopIdentifier : self.listenIdentifier)
        }
        .onAppear {
            MicrophoneAccess.refresh(self.asr)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            MicrophoneAccess.refresh(self.asr)
        }
    }

    @ViewBuilder
    private var listeningWaveform: some View {
        let image = Image(systemName: "waveform")
            .font(.system(size: self.usesChromeKey ? 12 : 15, weight: .semibold))
            .foregroundStyle(self.theme.palette.accent)
            .accessibilityHidden(true)
        if self.reduceMotion {
            image
        } else {
            image.symbolEffect(.variableColor.iterative, isActive: true)
        }
    }

    private func run(_ action: () -> Void) {
        if self.usesChromeKey {
            PresenterCaptionController.shared.performChromeAction(action)
        } else {
            action()
        }
    }
}

struct TranslationLanguagePairCard: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var controller = LiveTranslationController.shared
    @State private var availabilityText = ""
    @State private var isRequestingPack = false
    var showsCard = true

    var body: some View {
        Group {
            if self.showsCard {
                ThemedCard(style: .standard, hoverEffect: false) {
                    self.cardBody
                }
            } else {
                self.cardBody
            }
        }
        .task {
            await self.prepareAndRefreshAvailability()
        }
        .onChange(of: self.settings.translationSourceLanguageID) { _, _ in
            Task { await self.prepareAndRefreshAvailability() }
        }
        .onChange(of: self.settings.translationTargetLanguageID) { _, _ in
            Task { await self.prepareAndRefreshAvailability() }
        }
        .onChange(of: self.settings.selectedSpeechModel) { _, _ in
            Task { await self.prepareAndRefreshAvailability() }
        }
        .onChange(of: self.settings.selectedAppleSpeechLocaleIdentifier) { _, _ in
            Task { await self.prepareAndRefreshAvailability() }
        }
        .onChange(of: self.settings.selectedWhisperLanguageCode) { _, _ in
            Task { await self.prepareAndRefreshAvailability() }
        }
        .onChange(of: self.settings.selectedNemotronLanguage) { _, _ in
            Task { await self.prepareAndRefreshAvailability() }
        }
        .onChange(of: self.settings.selectedCohereLanguage) { _, _ in
            Task { await self.prepareAndRefreshAvailability() }
        }
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            FluidSectionHeader(title: "Languages", systemImage: "globe")
                .accessibilityIdentifier("theater.languages")
            self.languagePairRow
            self.engineHint
            self.packAction
        }
    }

    private var languagePairRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                self.iSpeakPicker
                if self.settings.theaterSessionMode == .translation {
                    self.swapButton
                    self.showAsPicker
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                self.iSpeakPicker
                if self.settings.theaterSessionMode == .translation {
                    HStack(alignment: .center, spacing: 10) {
                        self.swapButton
                        self.showAsPicker
                    }
                }
            }
        }
    }

    private var iSpeakPicker: some View {
        self.languagePicker(
            title: "I speak",
            selection: self.sourceLanguageID,
            languages: TranslationLanguageCatalog.menuOrder
        )
    }

    private var showAsPicker: some View {
        self.languagePicker(
            title: "Show as",
            selection: self.targetLanguageID,
            languages: self.targetLanguages
        )
    }

    private func languagePicker(
        title: String,
        selection: Binding<String>,
        languages: [TranslationLanguage]
    ) -> some View {
        TheaterLanguageMenu(
            title: title,
            selection: selection,
            languages: languages
        )
    }

    private var swapButton: some View {
        Button {
            self.controller.swapDirection()
        } label: {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 12, weight: .semibold))
                .accessibilityHidden(true)
        }
        .buttonStyle(.theaterTextIcon)
        .disabled(SpokenLanguageResolver.isSameLanguagePair())
        .help(TheaterChromeHelp.swapLanguages)
        .accessibilityLabel("Swap languages")
    }

    @ViewBuilder
    private var engineHint: some View {
        if let mismatch = SpokenLanguageResolver.voiceEngineMismatchMessage() {
            Text(mismatch)
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.warning)
                .fixedSize(horizontal: false, vertical: true)
        } else if let hint = SpokenLanguageResolver.theaterEngineHint() {
            Text(hint)
                .font(self.theme.typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var packAction: some View {
        if self.showsPackAction {
            Text(self.availabilityText)
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.warning)
                .fixedSize(horizontal: false, vertical: true)
            Button(self.isRequestingPack ? TheaterReadiness.downloadPackBusy : TheaterReadiness.downloadPack) {
                self.isRequestingPack = true
                Task {
                    await self.controller.requestNeededLanguagePackDownload()
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    await self.prepareAndRefreshAvailability()
                    self.isRequestingPack = false
                }
            }
            .buttonStyle(.theaterText)
            .disabled(self.isRequestingPack)
            .help(TheaterChromeHelp.downloadPack)
        }
    }

    private var showsPackAction: Bool {
        guard !SpokenLanguageResolver.isSameLanguagePair() else { return false }
        let text = self.availabilityText.lowercased()
        return text.contains("download")
            || text.contains("not supported")
            || text.contains("not ready")
    }

    private var sourceLanguageID: Binding<String> {
        Binding(
            get: { SpokenLanguageResolver.sourceLanguage().id },
            set: { id in
                self.controller.applySourceLanguage(id)
            }
        )
    }

    private var targetLanguageID: Binding<String> {
        Binding(
            get: { SpokenLanguageResolver.targetLanguage().id },
            set: { id in
                self.controller.applyTargetLanguage(id)
            }
        )
    }

    private var targetLanguages: [TranslationLanguage] {
        TranslationLanguageCatalog.menuOrder
    }

    private func prepareAndRefreshAvailability() async {
        self.availabilityText = await self.controller.pairAvailabilityCopy()
    }
}

/// Shortcut key shown the same way on Listen and Listen and type.
struct TheaterShortcutBadge: View {
    @Environment(\.theme) private var theme

    var text: String
    var isRecording: Bool

    var body: some View {
        Text(self.text)
            .font(self.theme.typography.caption.monospaced().weight(.medium))
            .foregroundStyle(self.isRecording ? self.theme.palette.warning : self.theme.palette.primaryText)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        self.isRecording
                            ? self.theme.palette.warning.opacity(0.16)
                            : self.theme.palette.separator.opacity(0.45)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(
                                self.isRecording
                                    ? self.theme.palette.warning.opacity(0.5)
                                    : self.theme.palette.separator,
                                lineWidth: 1
                            )
                    }
            }
    }
}

struct TranslateListenShortcutCard: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var settings = SettingsStore.shared

    var recordListenShortcut: (() -> Void)?
    var isRecordingListenShortcut = false
    var shortcutRecordingMessage: String?

    var body: some View {
        ThemedCard(style: .standard, hoverEffect: false) {
            VStack(alignment: .leading, spacing: 14) {
                FluidSectionHeader(title: "Listen Shortcut", systemImage: "mic.fill")
                    .accessibilityIdentifier("theater.listenShortcut")

                Text("Starts or stops Theater Listen. It does not type into another app.")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                TheaterSettingRow(
                    title: "Theater Listen shortcut",
                    detail: "Separate from dictation and Insert."
                ) {
                    Toggle("Enable Theater Listen shortcut", isOn: Binding(
                        get: { self.settings.captionListenHotkeyEnabled },
                        set: { self.settings.captionListenHotkeyEnabled = $0 }
                    ))
                    .toggleStyle(.switch)
                    .tint(self.theme.palette.accent)
                    .labelsHidden()
                    .disabled(self.settings.captionListenHotkeyShortcut == nil && !self.settings.captionListenHotkeyEnabled)
                    .accessibilityLabel("Enable Theater Listen shortcut")
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        TheaterShortcutBadge(
                            text: self.isRecordingListenShortcut
                                ? "Press shortcut…"
                                : (self.settings.captionListenHotkeyShortcut?.displayString ?? "Not set"),
                            isRecording: self.isRecordingListenShortcut
                        )

                        if let recordListenShortcut {
                            Button(self.isRecordingListenShortcut ? "Cancel" : "Change") {
                                recordListenShortcut()
                            }
                            .buttonStyle(.theaterText)
                        }
                    }

                    if self.isRecordingListenShortcut, let shortcutRecordingMessage, !shortcutRecordingMessage.isEmpty {
                        Text(shortcutRecordingMessage)
                            .font(self.theme.typography.caption)
                            .foregroundStyle(self.theme.palette.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

struct TranslateInsertShortcutCard: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var settings = SettingsStore.shared

    var recordTranslateShortcut: (() -> Void)?
    var isRecordingTranslateShortcut = false
    var shortcutRecordingMessage: String?
    var accessibilityTrusted = true
    var openAccessibility: () -> Void = {}

    var body: some View {
        ThemedCard(style: .standard, hoverEffect: false) {
            VStack(alignment: .leading, spacing: 14) {
                FluidSectionHeader(title: "Listen and Type", systemImage: "text.cursor")

                Text(TheaterReadiness.typeIntoAppBody)
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !self.settings.theaterListenUsed {
                    Text(TheaterReadiness.typeIntoAppLocked)
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.warning)
                        .accessibilityIdentifier("theater.listenAndType.locked")
                }

                if DictationHotkeyCaptureStart.blocksListenAndType(
                    enabled: self.settings.translationInsertHotkeyEnabled,
                    accessibilityTrusted: self.accessibilityTrusted
                ) {
                    Text(TheaterReadiness.typeIntoAppNeedsAccessibility)
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("theater.listenAndType.accessibility")
                    Button("Allow Accessibility", action: self.openAccessibility)
                        .buttonStyle(.theaterText)
                        .controlSize(.regular)
                }

                TheaterSettingRow(
                    title: "Listen and type shortcut",
                    detail: TheaterReadiness.typeIntoAppShortcutDetail
                ) {
                    Toggle("Enable listen and type shortcut", isOn: Binding(
                        get: { self.settings.translationInsertHotkeyEnabled },
                        set: { enabled in
                            self.settings.translationInsertHotkeyEnabled = enabled
                            if DictationHotkeyCaptureStart.blocksListenAndType(
                                enabled: enabled,
                                accessibilityTrusted: self.accessibilityTrusted
                            ) {
                                self.openAccessibility()
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                    .tint(self.theme.palette.accent)
                    .labelsHidden()
                    .disabled(
                        !self.settings.theaterListenUsed
                            || (self.settings.translationInsertHotkeyShortcut == nil
                                && !self.settings.translationInsertHotkeyEnabled)
                    )
                    .accessibilityLabel("Enable listen and type shortcut")
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        TheaterShortcutBadge(
                            text: self.isRecordingTranslateShortcut
                                ? "Press shortcut…"
                                : (self.settings.translationInsertHotkeyShortcut?.displayString ?? "Not set"),
                            isRecording: self.isRecordingTranslateShortcut
                        )

                        if let recordTranslateShortcut {
                            Button(self.isRecordingTranslateShortcut ? "Cancel" : "Change") {
                                recordTranslateShortcut()
                            }
                            .buttonStyle(.theaterText)
                            .disabled(!self.settings.theaterListenUsed)
                        }
                    }

                    if self.isRecordingTranslateShortcut, let shortcutRecordingMessage, !shortcutRecordingMessage.isEmpty {
                        Text(shortcutRecordingMessage)
                            .font(self.theme.typography.caption)
                            .foregroundStyle(self.theme.palette.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

/// One instruction: share the slides window. A whole-screen share includes the captions.
struct TheaterAudienceCard: View {
    @Environment(\.theme) private var theme
    var showsCard = true

    var body: some View {
        Group {
            if self.showsCard {
                ThemedCard(style: .standard, hoverEffect: false) {
                    self.cardBody
                }
            } else {
                self.cardBody
            }
        }
    }

    private var cardBody: some View {
        Text(TheaterReadiness.screenShare)
            .font(self.theme.typography.bodySmall)
            .foregroundStyle(self.theme.palette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("theater.audience")
            .help(TheaterChromeHelp.screenShare)
    }
}
