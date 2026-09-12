import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
                if let status = self.theaterStatusText {
                    Text(status)
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }
                TranslationLanguagePairCard()
                if !self.readySnapshot.canListen {
                    self.readinessCard
                }
            }
            .fluidPageContent()
            .accessibilityIdentifier("theater.home")
        }
    }

    private var header: some View {
        FluidPageHeader(
            systemImage: "rectangle.on.rectangle",
            title: "Theater",
            subtitle: FluidProduct.tagline
        ) {
            HStack(spacing: 8) {
                OpenTheaterButton()
                TheaterListenButton()
            }
        }
    }

    private var theaterStatusText: String? {
        if self.controller.isSessionActive, self.controller.listenKind == .captions {
            return "Listening. Captions print after each sentence."
        }
        if self.settings.theaterWindowEnabled {
            return "Theater is open."
        }
        return nil
    }

    private var readySnapshot: TheaterReadyGate.Snapshot {
        TheaterReadyGate.snapshot(
            engineSupportsSource: SpokenLanguageResolver.voiceEngineSupportsSource(),
            modelInstalled: SettingsStore.shared.selectedSpeechModel.isInstalled,
            sameLanguagePair: SpokenLanguageResolver.isSameLanguagePair(),
            pack: self.controller.packAvailability,
            microphone: self.asr.micStatus,
            firstCaptionPrinted: self.settings.theaterListenUsed
        )
    }

    private var readinessCard: some View {
        ThemedCard(style: .standard, hoverEffect: false) {
            VStack(alignment: .leading, spacing: 8) {
                FluidSectionHeader(title: "To listen", systemImage: "checklist")
                self.readyRow("Voice Engine", done: self.readySnapshot.voiceEngineReady)
                self.readyRow("Translation pack", done: self.readySnapshot.languagePackReady)
                self.readyRow("Microphone", done: self.readySnapshot.microphoneAllowed)
                Text(self.readySnapshot.nextAction)
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                if !self.readySnapshot.voiceEngineReady, let openVoiceEngine {
                    Button("Open Voice Engine", action: openVoiceEngine)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
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
                Text("Type into app unlocks after the first Theater caption.")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(.secondary)
            }

            MLXRunnerSettingsCard()
        }
    }

    private var theaterAppearanceCard: some View {
        ThemedCard(style: .standard, hoverEffect: false) {
            VStack(alignment: .leading, spacing: 14) {
                FluidSectionHeader(title: "Theater Window", systemImage: "rectangle.on.rectangle")

                self.settingsToggleRow(
                    title: "Show the spoken line",
                    description: "Show what you said first. The translation prints under it on the same line."
                ) {
                    Toggle("Show the spoken line", isOn: self.$settings.translationShowSource)
                        .toggleStyle(.switch)
                        .tint(self.theme.palette.accent)
                        .labelsHidden()
                        .accessibilityLabel("Show the spoken line")
                }

                self.settingsToggleRow(
                    title: "Captions only",
                    description: "Show only captions. Move the pointer over Theater to reveal the rest. Languages and Listen stay visible."
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
                    title: "Also hear English, Korean, and Thai questions",
                    description: TheaterReadiness.alsoHearOtherLanguages
                ) {
                    Toggle(
                        "Also hear English, Korean, and Thai questions",
                        isOn: self.$settings.theaterAlsoHearOtherLanguages
                    )
                    .toggleStyle(.switch)
                    .tint(self.theme.palette.accent)
                    .labelsHidden()
                    .accessibilityLabel("Also hear English, Korean, and Thai questions")
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
                            Text("How large captions appear on Theater")
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
                Text(TheaterReadiness.oneSpeakerCloseMic)
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
            PresenterCaptionController.shared.setVisible(!self.settings.theaterWindowEnabled)
        } label: {
            Label(
                self.settings.theaterWindowEnabled ? "Close Theater" : "Open Theater",
                systemImage: self.settings.theaterWindowEnabled ? "rectangle.inset.filled" : "rectangle.on.rectangle"
            )
        }
        .buttonStyle(.borderedProminent)
        .tint(self.theme.palette.accent)
        .controlSize(.regular)
        .accessibilityLabel(self.settings.theaterWindowEnabled ? "Close Theater" : "Open Theater")
        .accessibilityIdentifier("theater.open")
    }
}

struct TheaterListenButton: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var controller = LiveTranslationController.shared
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var asr = AppServices.shared.asr

    private var isListening: Bool {
        self.controller.isSessionActive && self.controller.listenKind == .captions
    }

    private var snapshot: TheaterReadyGate.Snapshot {
        TheaterReadyGate.snapshot(
            engineSupportsSource: SpokenLanguageResolver.voiceEngineSupportsSource(),
            modelInstalled: self.settings.selectedSpeechModel.isInstalled,
            sameLanguagePair: SpokenLanguageResolver.isSameLanguagePair(),
            pack: self.controller.packAvailability,
            microphone: self.asr.micStatus,
            firstCaptionPrinted: self.settings.theaterListenUsed
        )
    }

    var body: some View {
        Button {
            LiveTranslationController.shared.toggleCaptionListening()
        } label: {
            Label(
                self.isListening ? "Stop" : "Listen",
                systemImage: self.isListening ? "stop.fill" : "mic.fill"
            )
        }
        .buttonStyle(.borderedProminent)
        .tint(self.isListening ? self.theme.palette.warning : self.theme.palette.accent)
        .controlSize(.regular)
        .disabled(!self.isListening && !self.snapshot.canListen)
        .help(self.isListening ? "Stop. Captions print after each sentence." : self.snapshot.nextAction)
        .accessibilityLabel(self.isListening ? "Stop Listen" : "Listen")
        .accessibilityIdentifier("theater.listen")
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

                HStack(alignment: .bottom, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("I speak")
                            .font(self.theme.typography.caption)
                            .foregroundStyle(.secondary)
                        Picker("Source", selection: self.sourceLanguageID) {
                            ForEach(TranslationLanguageCatalog.all) { language in
                                Text(language.displayName).tag(language.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 180)
                    }

                    Button {
                        self.controller.swapDirection()
                    } label: {
                        Image(systemName: "arrow.left.arrow.right")
                    }
                    .buttonStyle(.bordered)
                    .help("Swap spoken and translated languages")
                    .accessibilityLabel("Swap languages")
                    .padding(.bottom, 1)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Show as")
                            .font(self.theme.typography.caption)
                            .foregroundStyle(.secondary)
                        Picker("Target", selection: self.targetLanguageID) {
                            ForEach(self.targetLanguages) { language in
                                Text(language.displayName).tag(language.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 180)
                    }
                }

                if let hint = SpokenLanguageResolver.theaterEngineHint() {
                    Text(hint)
                        .font(self.theme.typography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(SpokenLanguageResolver.stageEngineSummary())
                    .font(self.theme.typography.caption)
                    .foregroundStyle(
                        SpokenLanguageResolver.voiceEngineMismatchMessage() == nil
                            ? self.theme.palette.secondaryText
                            : self.theme.palette.warning
                    )
                    .fixedSize(horizontal: false, vertical: true)

                if !self.availabilityText.isEmpty {
                    Text(self.availabilityText)
                        .font(self.theme.typography.caption)
                        .foregroundStyle(.secondary)
                }

                if !SpokenLanguageResolver.isSameLanguagePair(),
                   self.availabilityText.localizedCaseInsensitiveContains("download")
                {
                    Button("Download this language pack") {
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
                    .controlSize(.small)
                }
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
                        .controlSize(.small)
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

                Text("Click into an app, then use this shortcut to type the current translation. \(TheaterReadiness.insertIMECaveat) Copy still takes everything on screen.")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Type into app shortcut")
                            .font(self.theme.typography.bodyStrong)
                        Text("Separate from dictation. Types the current translation only.")
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
                        .controlSize(.small)
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

struct LectureTermPackImportButton: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: self.importPack) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Import lecture terms", systemImage: "square.and.arrow.down")
                    .font(self.theme.typography.bodyStrong)
                Text("JSON names, this app’s dictionary file, or a terms/corrections pack.")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("theater.importLectureTerms")
    }

    private func importPack() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let document = try DictionaryTransferService.shared.decode(data)
            guard let mode = Self.confirmImport(document) else { return }
            let summary = try DictionaryTransferService.shared.restore(document, mode: mode)
            let alert = NSAlert()
            alert.messageText = "Lecture terms imported"
            alert.informativeText =
                "Now using \(summary.replacementCount) replacements and \(summary.customWordCount) terms."
            alert.runModal()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not import lecture terms"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private static func confirmImport(_ document: DictionaryTransferDocument) -> DictionaryTransferImportMode? {
        let confirm = NSAlert()
        confirm.messageText = "Import these lecture terms?"
        confirm.informativeText = """
        Found \(document.replacements.count) replacements and \(document.customWords.count) terms.

        Merge adds them to Custom Dictionary. Replace clears the current dictionary first.
        """
        confirm.addButton(withTitle: "Merge")
        confirm.addButton(withTitle: "Replace")
        confirm.addButton(withTitle: "Cancel")
        switch confirm.runModal() {
        case .alertFirstButtonReturn:
            return .merge
        case .alertSecondButtonReturn:
            return .replace
        default:
            return nil
        }
    }
}
