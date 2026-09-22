import SwiftUI

struct TheaterSetupWizardView: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var controller = LiveTranslationController.shared

    let finish: () -> Void
    let finishAndOpenTheater: () -> Void

    private var step: TheaterSetupWizard.Step {
        TheaterSetupWizard.Step.resolved(self.settings.theaterSetupWizardStep)
    }

    var body: some View {
        VStack(spacing: 0) {
            self.header
            ScrollView {
                self.stepContent
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
            }
            self.footer
        }
        .background(self.theme.palette.windowBackground.ignoresSafeArea())
        .accessibilityIdentifier("theater.setupWizard")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            FluidPageHeader(
                systemImage: self.step.systemImage,
                title: TheaterSetupWizard.title,
                subtitle: "Step \(self.step.rawValue + 1) of \(TheaterSetupWizard.Step.allCases.count) · \(self.step.title)"
            )
            Text(self.step.subtitle)
                .font(self.theme.typography.bodySmall)
                .foregroundStyle(self.theme.palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(self.theme.palette.separator)
                    Rectangle()
                        .fill(self.theme.palette.accent)
                        .frame(width: proxy.size.width * TheaterSetupWizard.progress(for: self.step))
                }
            }
            .frame(height: 2)
            .accessibilityLabel("Setup progress")
            .accessibilityValue("\(self.step.rawValue + 1) of \(TheaterSetupWizard.Step.allCases.count)")
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch self.step {
        case .welcome:
            self.welcomeStep
        case .languages:
            self.languagesStep
        case .captions:
            self.captionsStep
        case .audience:
            TheaterAudienceCard()
        case .ready:
            self.readyStep
        }
    }

    private var welcomeStep: some View {
        ThemedCard(style: .prominent, hoverEffect: false) {
            VStack(alignment: .leading, spacing: 12) {
                Text(TheaterSetupWizard.welcomeTitle)
                    .font(self.theme.typography.title)
                    .foregroundStyle(self.theme.palette.primaryText)
                Text(TheaterSetupWizard.welcomeBody)
                    .font(self.theme.typography.body)
                    .foregroundStyle(self.theme.palette.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(TheaterSetupWizard.welcomeDetail)
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("theater.setupWizard.spokenNote")
                TheaterCaptionStackPreview(
                    message: TheaterReadiness.spokenLineSetupNote,
                    lines: TheaterBoardPreview.current(
                        session: self.settings.theaterSessionMode,
                        spokenMode: self.settings.theaterSpokenLineMode
                    ),
                    accessibilityIdentifier: "theater.setupWizard.preview"
                )
            }
        }
    }

    private var languagesStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            ThemedCard(style: .standard, hoverEffect: false) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Theater mode")
                        .font(self.theme.typography.bodyStrong)
                    TheaterWordPicker(
                        accessibilityLabel: "Theater mode",
                        options: Array(TheaterSessionMode.allCases),
                        title: { $0.displayName },
                        selection: Binding(
                            get: { self.settings.theaterSessionMode },
                            set: { self.controller.applyTheaterSessionMode($0) }
                        )
                    )
                    Text(self.settings.theaterSessionMode.help)
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.theme.palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            TranslationLanguagePairCard()
        }
    }

    private var captionsStep: some View {
        ThemedCard(style: .standard, hoverEffect: false) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Each sentence appears when it is ready. Nothing shows while it is still being heard.")
                    .font(self.theme.typography.body)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if self.settings.theaterSessionMode == .translation {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(TheaterReadiness.spokenLineTitle)
                                .font(self.theme.typography.bodyStrong)
                            Text(
                                SpokenLanguageResolver.isSameLanguagePair()
                                    ? TheaterReadiness.spokenLineSameLanguage
                                    : self.settings.theaterSpokenLineMode.help
                            )
                            .font(self.theme.typography.bodySmall)
                            .foregroundStyle(self.theme.palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        TheaterSpokenLinePicker(accessibilityIdentifier: "theater.setupWizard.spokenLine")
                    }
                    TheaterCaptionStackPreview(
                        message: SpokenLanguageResolver.isSameLanguagePair()
                            ? TheaterReadiness.spokenLineSameLanguage
                            : self.settings.theaterSpokenLineMode.help,
                        lines: TheaterBoardPreview.current(
                            session: self.settings.theaterSessionMode,
                            spokenMode: self.settings.theaterSpokenLineMode
                        ),
                        accessibilityIdentifier: "theater.setupWizard.captionPreview"
                    )
                }

                self.accentColorRow(identifier: "theater.setupWizard.accentColor")
            }
        }
    }

    private var readyStep: some View {
        ThemedCard(style: .standard, hoverEffect: false) {
            VStack(alignment: .leading, spacing: 10) {
                TheaterCaptionStackPreview(
                    message: TheaterReadiness.boardIdle,
                    lines: TheaterBoardPreview.current(
                        session: self.settings.theaterSessionMode,
                        spokenMode: self.settings.theaterSpokenLineMode
                    ),
                    accessibilityIdentifier: "theater.setupWizard.readyPreview"
                )
                self.readyRow(
                    title: "Mode",
                    detail: self.settings.theaterSessionMode.displayName
                )
                self.readyRow(
                    title: "I speak",
                    detail: SpokenLanguageResolver.sourceLanguage().displayName
                )
                if self.settings.theaterSessionMode.showsTranslation {
                    self.readyRow(
                        title: "Show as",
                        detail: SpokenLanguageResolver.targetLanguage().displayName
                    )
                    self.readyRow(
                        title: TheaterReadiness.spokenLineTitle,
                        detail: SpokenLanguageResolver.isSameLanguagePair()
                            ? "Same language"
                            : self.settings.theaterSpokenLineMode.displayName
                    )
                }
                self.readyRow(
                    title: TheaterSetupWizard.accentTitle,
                    detail: self.settings.accentColorOption.rawValue
                )
                self.readyRow(
                    title: "Who sees captions",
                    detail: self.settings.theaterHideFromScreenShare
                        ? TheaterReadiness.audienceSlides
                        : TheaterReadiness.audienceZoom
                )
            }
        }
    }

    private func accentColorRow(identifier: String) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(TheaterSetupWizard.accentTitle)
                    .font(self.theme.typography.bodyStrong)
                Text(TheaterSetupWizard.accentDetail)
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            AccentColorSwatches(accessibilityIdentifier: identifier)
        }
    }

    private func readyRow(title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(self.theme.typography.bodySmall)
                .foregroundStyle(self.theme.palette.secondaryText)
            Spacer()
            Text(detail)
                .font(self.theme.typography.bodyStrong)
                .foregroundStyle(self.theme.palette.primaryText)
                .multilineTextAlignment(.trailing)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if self.step.previous != nil {
                Button("Back") {
                    self.goBack()
                }
                .buttonStyle(.theaterText)
                .accessibilityIdentifier("theater.setupWizard.back")
            }
            if self.step != .ready {
                Button(TheaterSetupWizard.skipTitle) {
                    self.finish()
                }
                .buttonStyle(.theaterText)
                .accessibilityIdentifier("theater.setupWizard.skip")
            }
            Spacer()
            if self.step == .ready {
                Button(self.step.continueTitle) {
                    self.goNext()
                }
                .buttonStyle(.theaterText)
                .accessibilityIdentifier("theater.setupWizard.continue")
                Button(TheaterSetupWizard.readyPrimary) {
                    self.finishAndOpenTheater()
                }
                .buttonStyle(.theaterTextProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("theater.setupWizard.openTheater")
            } else {
                Button(self.step.continueTitle) {
                    self.goNext()
                }
                .buttonStyle(.theaterTextProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("theater.setupWizard.continue")
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
    }

    private func goBack() {
        if let previous = self.step.previous {
            self.settings.theaterSetupWizardStep = previous.rawValue
        }
    }

    private func goNext() {
        if let next = self.step.next {
            self.settings.theaterSetupWizardStep = next.rawValue
        } else {
            self.finish()
        }
    }
}
