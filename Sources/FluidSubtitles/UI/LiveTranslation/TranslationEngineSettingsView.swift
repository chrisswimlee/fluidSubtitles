import SwiftUI

/// Setup tab for Translation Engine. Apple Translation is the caption engine;
/// a local small LLM is optional first-print sharpening.
struct TranslationEngineSettingsScreen: View {
    let theme: AppTheme

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                TranslationEngineSettingsView(theme: self.theme)
                    .fluidPageContent()
                    .id(Self.pageTopID)
            }
            .defaultScrollAnchor(.top)
            .onAppear {
                proxy.scrollTo(Self.pageTopID, anchor: .top)
            }
        }
    }

    private static let pageTopID = "translation-engine-page-top"
}

struct TranslationEngineSettingsView: View {
    let theme: AppTheme
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var controller = LiveTranslationController.shared
    @ObservedObject private var runner = MLXRunnerService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            FluidPageHeader(
                systemImage: "translate",
                title: TheaterEngineCopy.translationTitle,
                subtitle: TheaterEngineCopy.translationPurpose
            )

            ThemedCard(style: .standard, hoverEffect: false) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Pick an engine")
                        .font(self.theme.typography.bodyStrong)
                        .foregroundStyle(self.theme.palette.primaryText)

                    ForEach(TheaterTranslationEngineKind.allCases) { kind in
                        self.engineRow(kind)
                    }
                }
            }

            if self.settings.theaterTranslationEngine == .apple {
                self.appleStatusCard
            } else {
                MLXRunnerSettingsCard(showsEnableToggle: false)
            }
        }
        .accessibilityIdentifier("translationEngine.setup")
        .task {
            await self.controller.refreshPackAvailability()
        }
    }

    private func engineRow(_ kind: TheaterTranslationEngineKind) -> some View {
        let selected = self.settings.theaterTranslationEngine == kind
        return Button {
            self.select(kind)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? self.theme.palette.accent : self.theme.palette.secondaryText)
                    .font(.system(size: 18, weight: .semibold))
                VStack(alignment: .leading, spacing: 4) {
                    Text(kind.displayName)
                        .font(self.theme.typography.bodyStrong)
                        .foregroundStyle(self.theme.palette.primaryText)
                    Text(kind.purpose)
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.theme.palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(self.theme.palette.contentBackground.opacity(selected ? 0.9 : 0.45))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("translationEngine.\(kind.rawValue)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var appleStatusCard: some View {
        ThemedCard(style: .standard, hoverEffect: false) {
            VStack(alignment: .leading, spacing: 8) {
                FluidSectionHeader(title: "Apple Translation", systemImage: "translate")
                Text(self.appleStatusLine)
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.appleStatusIsWarning ? self.theme.palette.warning : self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var appleStatusLine: String {
        TheaterEngineCopy.translationRunningLine(
            mode: self.settings.theaterSessionMode,
            sameLanguage: SpokenLanguageResolver.isSameLanguagePair(),
            pack: self.controller.packAvailability,
            engine: .apple
        )
    }

    private var appleStatusIsWarning: Bool {
        guard self.settings.theaterSessionMode == .translation,
              !SpokenLanguageResolver.isSameLanguagePair()
        else { return false }
        switch self.controller.packAvailability {
        case .supported, .unsupported, .unknown:
            return true
        case .installed:
            return false
        }
    }

    private func select(_ kind: TheaterTranslationEngineKind) {
        self.settings.theaterTranslationEngine = kind
        if kind == .apple {
            Task { await self.runner.stopAndWait() }
        } else {
            Task { await self.runner.refresh() }
        }
    }
}
