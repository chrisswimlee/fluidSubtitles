import SwiftUI

struct LiveTranslationHomeView: View {
    @EnvironmentObject private var appServices: AppServices
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var controller = LiveTranslationController.shared
    @State private var availabilityText = ""

    var recordTranslateShortcut: (() -> Void)?
    var isRecordingTranslateShortcut = false
    var shortcutRecordingMessage: String?

    private var asr: ASRService { self.appServices.asr }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                theaterCard
                pairCard
                insertCard
                theaterOptions
                MLXRunnerSettingsCard()
                nextSteps
                credit
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
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
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(FluidProduct.displayName)
                .font(.system(size: 28, weight: .semibold))
            Text(FluidProduct.tagline)
                .font(.title3.weight(.medium))
            Text(FluidProduct.manifesto)
                .foregroundStyle(.secondary)
            Text("Open Theater, then press Listen. Closing Theater clears the captions. The dictation shortcut still types what you said.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var theaterCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Theater")
                .font(.headline)
            Text("Presentation captions. Press Listen on Theater. Closing the window clears the board.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                PresenterCaptionController.shared.setVisible(!self.settings.theaterWindowEnabled)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: self.settings.theaterWindowEnabled ? "rectangle.inset.filled" : "rectangle")
                    Text(self.settings.theaterWindowEnabled ? "Close" : "Theater")
                }
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private var pairCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Languages")
                .font(.headline)
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("I speak")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Source", selection: self.sourceLanguageID) {
                        ForEach(TranslationLanguageCatalog.all) { language in
                            Text(language.displayName).tag(language.id)
                        }
                    }
                    .labelsHidden()
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
                .padding(.bottom, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Show on screen")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Target", selection: self.$settings.translationTargetLanguageID) {
                        ForEach(self.targetLanguages) { language in
                            Text(language.displayName).tag(language.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 180)
                }
            }
            if !self.availabilityText.isEmpty {
                Text(self.availabilityText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if self.availabilityText.localizedCaseInsensitiveContains("download") {
                Button("Download this language pack") {
                    Task {
                        let source = SpokenLanguageResolver.sourceLanguage()
                        let target = SpokenLanguageResolver.targetLanguage()
                        await AppleTranslationEngine.shared.warm(source: source, target: target)
                        AppleTranslationEngine.shared.requestLanguagePackDownload()
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private var insertCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Type the translation into an app")
                .font(.headline)
            Text("A separate shortcut from dictation. Click into an app, press the shortcut, talk, then stop. That types this listen only — not the whole Theater board. Theater’s Insert button does the same. Copy still takes everything on screen.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Enable translate-into-app shortcut", isOn: Binding(
                get: { self.settings.translationInsertHotkeyEnabled },
                set: { newValue in
                    self.settings.translationInsertHotkeyEnabled = newValue
                }
            ))
            .disabled(self.settings.translationInsertHotkeyShortcut == nil && !self.settings.translationInsertHotkeyEnabled)

            HStack {
                Text(self.isRecordingTranslateShortcut
                     ? "Press a key combination…"
                     : (self.settings.translationInsertHotkeyShortcut?.displayString ?? "Not set"))
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                if let recordTranslateShortcut {
                    Button(self.isRecordingTranslateShortcut ? "Cancel" : "Change") {
                        recordTranslateShortcut()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if let shortcutRecordingMessage, self.isRecordingTranslateShortcut, !shortcutRecordingMessage.isEmpty {
                Text(shortcutRecordingMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private var theaterOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Theater window")
                .font(.headline)
            Toggle("Show the spoken line under the translation", isOn: self.$settings.translationShowSource)
            Picker("Caption font", selection: Binding(
                get: { TheaterTypeface.resolved(self.settings.presenterFontFamily) },
                set: { self.settings.presenterFontFamily = $0.rawValue }
            )) {
                ForEach(TheaterTypeface.allCases) { face in
                    Text(face.displayName).tag(face)
                }
            }
            HStack {
                Text("Caption size")
                Slider(value: Binding(
                    get: { Double(self.settings.presenterFontSize) },
                    set: { self.settings.presenterFontSize = Int($0.rounded()) }
                ), in: Double(SettingsStore.presenterFontSizeRange.lowerBound)...Double(SettingsStore.presenterFontSizeRange.upperBound), step: 2)
                Text("\(self.settings.presenterFontSize) pt")
                    .monospacedDigit()
                    .frame(width: 56, alignment: .trailing)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private var nextSteps: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !self.asr.isAsrReady && !self.asr.modelsExistOnDisk {
                Text("Download a Voice Engine first. Open Voice Engine in the sidebar, then open Theater and press Listen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Korean, English, and Thai can go in either direction. Apple language packs are only for the translation.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var credit: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(FluidProduct.creditLine)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Link("\(FluidProduct.authorName) — \(FluidProduct.authorSiteHost)", destination: FluidProduct.authorURL)
                Link("FluidVoice on GitHub", destination: FluidProduct.upstreamURL)
            }
            .font(.system(size: 13, weight: .medium))
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private var sourceLanguageID: Binding<String> {
        Binding(
            get: { SpokenLanguageResolver.sourceLanguage().id },
            set: { id in
                guard let language = TranslationLanguageCatalog.language(id: id) else { return }
                SpokenLanguageResolver.setSourceLanguage(language)
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
