import AppKit
import AVFoundation
import SwiftUI

struct LiveTranslationHomeView: View {
    @EnvironmentObject private var appServices: AppServices
    @Environment(\.theme) private var theme
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var controller = LiveTranslationController.shared

    var openVoiceEngine: (() -> Void)?

    private var asr: ASRService { self.appServices.asr }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                self.header
                if !TheaterAvailability.isSupported {
                    Text(TheaterAvailability.unsupportedCopy)
                        .font(self.theme.typography.body)
                        .foregroundStyle(self.theme.palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("theater.needsMacOS26")
                }
                if let status = self.theaterStatusText {
                    Text(status)
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theaterStatusColor)
                        .accessibilityIdentifier("theater.status")
                }
                if TheaterAvailability.isSupported {
                    self.modePicker
                    TranslationLanguagePairCard()
                    TheaterEngineCards(
                        openVoiceEngine: self.openVoiceEngine,
                        showsPurpose: false
                    )
                    if !self.readySnapshot.canListen || !self.readySnapshot.microphoneAllowed {
                        self.readinessCard
                    }
                }
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
        Picker("Theater mode", selection: Binding(
            get: { self.settings.theaterSessionMode },
            set: { self.controller.applyTheaterSessionMode($0) }
        )) {
            ForEach(TheaterSessionMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .help(TheaterReadiness.modeStopsListen)
        .accessibilityLabel("Theater mode")
        .accessibilityIdentifier("theater.mode")
    }

    private var header: some View {
        FluidPageHeader(
            systemImage: "rectangle.on.rectangle",
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
            return "Theater is open."
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
            VStack(alignment: .leading, spacing: 8) {
                FluidSectionHeader(title: "Before you Listen", systemImage: "checklist")
                self.readyRow(TheaterEngineCopy.voiceTitle, done: self.readySnapshot.voiceEngineReady)
                if self.settings.theaterSessionMode == .translation {
                    self.readyRow(TheaterEngineCopy.translationTitle, done: self.readySnapshot.languagePackReady)
                }
                self.readyRow("Microphone", done: self.readySnapshot.microphoneAllowed)
                Text(self.readySnapshot.nextAction)
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                if !self.readySnapshot.voiceEngineReady, let openVoiceEngine {
                    Button("Voice Engine", action: openVoiceEngine)
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                }
                if !self.readySnapshot.microphoneAllowed {
                    Button(self.asr.micStatus == .notDetermined ? "Allow" : "Open Settings") {
                        if self.asr.micStatus == .notDetermined {
                            self.asr.requestMicAccess()
                        } else {
                            self.asr.openSystemSettingsForMic()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
            }
        }
        .accessibilityIdentifier("theater.readiness")
        .task {
            await self.controller.refreshPackAvailability()
        }
    }

    private func readyRow(_ title: String, done: Bool) -> some View {
        Label(title, systemImage: done ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(done ? self.theme.palette.accent : self.theme.palette.secondaryText)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            self.theaterAppearanceCard
                .settingsSearchTarget(.theaterAppearance)

            TranslateListenShortcutCard(
                recordListenShortcut: self.recordListenShortcut,
                isRecordingListenShortcut: self.isRecordingListenShortcut,
                shortcutRecordingMessage: self.shortcutRecordingMessage
            )
            .settingsSearchTarget(.captionListenShortcut)

            if self.settings.theaterListenUsed {
                TranslateInsertShortcutCard(
                    recordTranslateShortcut: self.recordTranslateShortcut,
                    isRecordingTranslateShortcut: self.isRecordingTranslateShortcut,
                    shortcutRecordingMessage: self.shortcutRecordingMessage
                )
                .settingsSearchTarget(.translateInsertShortcut)
            } else {
                Text(TheaterReadiness.typeIntoAppLocked)
                    .font(self.theme.typography.caption)
                    .foregroundStyle(.secondary)
            }

            MLXRunnerSettingsCard()
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
                    Picker("Board", selection: Binding(
                        get: { self.settings.theaterPresentation },
                        set: { self.settings.theaterPresentationStyle = $0.rawValue }
                    )) {
                        ForEach(TheaterPresentationStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 220, alignment: .trailing)
                    .accessibilityLabel("Theater board")
                    .accessibilityIdentifier("theater.settings.presentationStyle")
                    .help(self.settings.theaterPresentation.help)
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(TheaterReadiness.howCaptionsAppear)
                            .font(self.theme.typography.bodyStrong)
                            .foregroundStyle(self.settingsTitleText)
                        Text(self.settings.theaterCaptionPrintStyle.help)
                            .font(self.theme.typography.bodySmall)
                            .foregroundStyle(self.settingsSecondaryText)
                    }
                    Spacer()
                    Picker(TheaterReadiness.howCaptionsAppear, selection: Binding(
                        get: { self.settings.theaterCaptionPrintStyle },
                        set: { self.settings.theaterCaptionPrintStyle = $0 }
                    )) {
                        ForEach(TheaterCaptionPrintStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .accessibilityLabel(TheaterReadiness.howCaptionsAppear)
                    .accessibilityIdentifier("theater.settings.printStyle")
                    .help(self.settings.theaterCaptionPrintStyle.help)
                }

                if self.settings.theaterSessionMode == .translation {
                    self.settingsToggleRow(
                        title: "Show the spoken line",
                        description: SpokenLanguageResolver.isSameLanguagePair()
                            ? TheaterReadiness.spokenLineSameLanguage
                            : TheaterReadiness.spokenLineTranslate
                    ) {
                        Toggle("Show the spoken line", isOn: self.$settings.translationShowSource)
                            .toggleStyle(.switch)
                            .tint(self.theme.palette.accent)
                            .labelsHidden()
                            .disabled(SpokenLanguageResolver.isSameLanguagePair())
                            .accessibilityLabel("Show the spoken line")
                    }
                }

                self.settingsToggleRow(
                    title: "Captions only",
                    description: TheaterReadiness.captionsOnlyWindow
                ) {
                    Toggle("Captions only", isOn: self.$settings.theaterHideChrome)
                        .toggleStyle(.switch)
                        .tint(self.theme.palette.accent)
                        .labelsHidden()
                        .accessibilityLabel("Captions only")
                }

                self.settingsToggleRow(
                    title: "Hide from screen share",
                    description: TheaterReadiness.hideFromScreenShare
                ) {
                    Toggle("Hide from screen share", isOn: self.$settings.theaterHideFromScreenShare)
                        .toggleStyle(.switch)
                        .tint(self.theme.palette.accent)
                        .labelsHidden()
                        .accessibilityLabel("Hide from screen share")
                        .accessibilityIdentifier("theater.settings.hideFromScreenShare")
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
                    Picker("Appearance", selection: Binding(
                        get: { TheaterAppearance.resolved(self.settings.theaterAppearance) },
                        set: { self.settings.theaterAppearance = $0.rawValue }
                    )) {
                        ForEach(TheaterAppearance.allCases) { appearance in
                            Text(appearance.displayName).tag(appearance)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 160, alignment: .trailing)
                    .accessibilityLabel("Theater theme")
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
                        Text("\(self.settings.presenterFontSize) pt")
                            .font(.caption.monospaced())
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
                    .buttonStyle(.bordered)
                    .tint(self.theme.palette.warning)
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
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(self.theme.typography.bodyStrong)
                    .foregroundStyle(self.settingsTitleText)
                Text(description)
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.settingsSecondaryText)
            }
            Spacer()
            accessory()
        }
    }

    private var canClearCaptions: Bool {
        self.controller.hasClearableBoard
            || self.subscriber.archivedLineCount > 0
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
    @Environment(\.theme) private var theme
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        Button {
            if self.settings.theaterWindowEnabled {
                PresenterCaptionController.shared.requestClose()
            } else {
                PresenterCaptionController.shared.setVisible(true)
            }
        } label: {
            Label(
                self.settings.theaterWindowEnabled ? "Close Theater" : "Open Theater",
                systemImage: self.settings.theaterWindowEnabled ? "rectangle.inset.filled" : "rectangle.on.rectangle"
            )
        }
        .buttonStyle(.borderedProminent)
        .tint(self.theme.palette.accent)
        .controlSize(.large)
        .disabled(!TheaterAvailability.isSupported)
        .help(
            TheaterAvailability.isSupported
                ? TheaterReadiness.openTheaterHelp
                : TheaterAvailability.unsupportedCopy
        )
        .accessibilityLabel(self.settings.theaterWindowEnabled ? "Close Theater" : "Open Theater")
        .accessibilityIdentifier("theater.open")
    }
}

struct TheaterListenButton: View {
    var usesChromeKey = false
    var listenIdentifier = "theater.listen"
    var stopIdentifier = "theater.listen"
    var pauseIdentifier = "theater.home.pause"

    @Environment(\.theme) private var theme
    @ObservedObject private var controller = LiveTranslationController.shared
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var asr = AppServices.shared.asr

    private var isListening: Bool {
        self.controller.isSessionActive && self.controller.listenKind == .captions
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

    private var listenSymbol: String {
        if self.isListening { return "stop.fill" }
        return "mic.fill"
    }

    private var listenHelp: String {
        if self.dictationBusy { return TheaterReadiness.dictationBusy }
        if self.isListening { return TheaterReadiness.stopHelp }
        if self.snapshot.canListen { return TheaterReadiness.pressListen }
        return self.snapshot.nextAction
    }

    var body: some View {
        HStack(spacing: self.usesChromeKey ? 6 : 8) {
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
                    Label(
                        self.controller.isPaused ? "Resume" : "Pause",
                        systemImage: self.controller.isPaused ? "play.fill" : "pause.fill"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help(self.controller.isPaused ? TheaterReadiness.resumeHelp : TheaterReadiness.pauseHelp)
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
                Label(self.isListening ? "Stop" : "Listen", systemImage: self.listenSymbol)
            }
            .buttonStyle(.borderedProminent)
            .tint(self.isListening ? Color(nsColor: .systemRed) : self.theme.palette.accent)
            .controlSize(.large)
            .disabled(!self.isListening && (!self.snapshot.canListen || self.dictationBusy))
            .help(self.listenHelp)
            .accessibilityLabel(self.isListening ? "Stop" : "Listen")
            .accessibilityIdentifier(self.isListening ? self.stopIdentifier : self.listenIdentifier)
        }
        .onAppear {
            MicrophoneAccess.refresh(self.asr)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            MicrophoneAccess.refresh(self.asr)
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

    var body: some View {
        ThemedCard(style: .standard, hoverEffect: false) {
            VStack(alignment: .leading, spacing: 14) {
                FluidSectionHeader(title: "Languages", systemImage: "globe")
                    .accessibilityIdentifier("theater.languages")
                self.languagePairRow
                self.engineHint
                self.packAction
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

    private var languagePairRow: some View {
        HStack(alignment: .bottom, spacing: 16) {
            self.languagePicker(
                title: "I speak",
                pickerTitle: "Source",
                selection: self.sourceLanguageID,
                languages: TranslationLanguageCatalog.all
            )
            if self.settings.theaterSessionMode == .translation {
                self.swapButton
                self.languagePicker(
                    title: "Show as",
                    pickerTitle: "Target",
                    selection: self.targetLanguageID,
                    languages: self.targetLanguages
                )
            }
        }
    }

    private func languagePicker(
        title: String,
        pickerTitle: String,
        selection: Binding<String>,
        languages: [TranslationLanguage]
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(self.theme.typography.caption)
                .foregroundStyle(.secondary)
            Picker(pickerTitle, selection: selection) {
                ForEach(languages) { language in
                    Text(language.displayName).tag(language.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.regular)
            .frame(maxWidth: 180, minHeight: 28)
        }
    }

    private var swapButton: some View {
        Button {
            self.controller.swapDirection()
        } label: {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .help("Swap spoken and translated languages")
        .accessibilityLabel("Swap languages")
        .padding(.bottom, 1)
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
            Button(TheaterReadiness.downloadPack) {
                Task {
                    let source = SpokenLanguageResolver.sourceLanguage()
                    let target = SpokenLanguageResolver.targetLanguage()
                    await AppleTranslationEngine.shared.warm(source: source, target: target)
                    AppleTranslationEngine.shared.requestLanguagePackDownload()
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    await self.prepareAndRefreshAvailability()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
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
        TranslationLanguageCatalog.targets(excluding: SpokenLanguageResolver.sourceLanguage())
    }

    private func prepareAndRefreshAvailability() async {
        let source = SpokenLanguageResolver.sourceLanguage()
        let target = SpokenLanguageResolver.targetLanguage()
        await AppleTranslationEngine.shared.warm(source: source, target: target)
        self.availabilityText = await AppleTranslationEngine.shared.checkAvailability(source: source, target: target)
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

                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Theater Listen shortcut")
                            .font(self.theme.typography.bodyStrong)
                        Text("Separate from dictation and Insert.")
                            .font(self.theme.typography.bodySmall)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
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

                HStack(spacing: 10) {
                    if self.isRecordingListenShortcut {
                        Text("Press shortcut…")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(.orange.opacity(0.2))
                            )
                    } else {
                        Text(self.settings.captionListenHotkeyShortcut?.displayString ?? "Not set")
                            .font(.caption.monospaced().weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(.quaternary.opacity(0.5))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .stroke(.primary.opacity(0.15), lineWidth: 1)
                                    )
                            )
                    }

                    if let recordListenShortcut {
                        Button(self.isRecordingListenShortcut ? "Cancel" : "Change") {
                            recordListenShortcut()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    }

                    if self.isRecordingListenShortcut, let shortcutRecordingMessage, !shortcutRecordingMessage.isEmpty {
                        Text(shortcutRecordingMessage)
                            .font(self.theme.typography.caption)
                            .foregroundStyle(self.theme.palette.warning)
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

    var body: some View {
        ThemedCard(style: .standard, hoverEffect: false) {
            VStack(alignment: .leading, spacing: 14) {
                FluidSectionHeader(title: "Type into an App", systemImage: "text.cursor")

                Text(TheaterReadiness.typeIntoAppBody)
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Type into app shortcut")
                            .font(self.theme.typography.bodyStrong)
                        Text(TheaterReadiness.typeIntoAppShortcutDetail)
                            .font(self.theme.typography.bodySmall)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Enable type into app shortcut", isOn: Binding(
                        get: { self.settings.translationInsertHotkeyEnabled },
                        set: { self.settings.translationInsertHotkeyEnabled = $0 }
                    ))
                    .toggleStyle(.switch)
                    .tint(self.theme.palette.accent)
                    .labelsHidden()
                    .disabled(self.settings.translationInsertHotkeyShortcut == nil && !self.settings.translationInsertHotkeyEnabled)
                    .accessibilityLabel("Enable type into app shortcut")
                }

                HStack(spacing: 10) {
                    if self.isRecordingTranslateShortcut {
                        Text("Press shortcut…")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(.orange.opacity(0.2))
                            )
                    } else {
                        Text(self.settings.translationInsertHotkeyShortcut?.displayString ?? "Not set")
                            .font(.caption.monospaced().weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(.quaternary.opacity(0.5))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .stroke(.primary.opacity(0.15), lineWidth: 1)
                                    )
                            )
                    }

                    if let recordTranslateShortcut {
                        Button(self.isRecordingTranslateShortcut ? "Cancel" : "Change") {
                            recordTranslateShortcut()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    }

                    if self.isRecordingTranslateShortcut, let shortcutRecordingMessage, !shortcutRecordingMessage.isEmpty {
                        Text(shortcutRecordingMessage)
                            .font(self.theme.typography.caption)
                            .foregroundStyle(self.theme.palette.warning)
                    }
                }
            }
        }
    }
}
