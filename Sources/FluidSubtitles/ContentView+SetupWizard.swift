import SwiftUI

extension ContentView {
    var rootChrome: some View {
        Group {
            if self.settings.shouldShowOnboarding {
                self.onboardingOnlyView
            } else if self.settings.shouldShowSetupWizard {
                self.setupWizardView
            } else {
                NavigationSplitView(columnVisibility: self.$columnVisibility) {
                    self.sidebarContent
                        .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
                } detail: {
                    self.detailView
                }
                .navigationSplitViewStyle(.balanced)
            }
        }
        .background(MainWindowMarker())
    }

    var setupWizardView: some View {
        TheaterSetupWizardView(
            finish: {
                self.finishSetupWizard(openTheater: false)
            },
            finishAndOpenTheater: {
                self.finishSetupWizard(openTheater: true)
            },
            openVoiceEngine: {
                self.settings.completeSetupWizard()
                self.navigateToApp(.voiceEngine)
            },
            openTranslationEngine: {
                self.settings.completeSetupWizard()
                self.navigateToApp(.translationEngine)
            }
        )
    }

    func finishSetupWizard(openTheater: Bool) {
        self.settings.completeSetupWizard()
        self.navigateToApp(.liveTranslation)
        if openTheater {
            PresenterCaptionController.shared.setVisible(true)
        }
    }
}
