import SwiftUI

/// Application menu for the chords Overlay already uses.
struct TheaterAppCommands: Commands {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var controller = LiveTranslationController.shared
    @ObservedObject private var asr = AppServices.shared.asr

    private var isCaptionListening: Bool {
        self.controller.isSessionActive && self.controller.listenKind == .captions
    }

    private var listenTitle: String {
        if self.controller.isFinishingSession { return "Stopping…" }
        return self.isCaptionListening ? "Stop" : "Listen"
    }

    private var canStartListen: Bool {
        let ready = TheaterReadyGate.liveSnapshot(
            pack: self.controller.packAvailability,
            microphone: self.asr.micStatus,
            firstCaptionPrinted: self.settings.theaterListenUsed
        )
        let dictationBusy = self.asr.isRunningOrStarting && !self.isCaptionListening
        return ready.canListen && !dictationBusy
    }

    var body: some Commands {
        CommandMenu("Theater") {
            Button(self.listenTitle) {
                self.controller.toggleCaptionListening()
            }
            .keyboardShortcut(self.shortcut(.listen), modifiers: self.presenterModifiers)
            .disabled(self.controller.isFinishingSession || (!self.isCaptionListening && !self.canStartListen))

            Button(self.controller.isPaused ? "Resume" : "Pause") {
                if self.controller.isPaused {
                    self.controller.resumeListening()
                } else {
                    self.controller.pauseListening()
                }
            }
            .keyboardShortcut(self.shortcut(.togglePause), modifiers: self.presenterModifiers)
            .disabled(!self.isCaptionListening)

            Button("Show Overlay Tools") {
                PresenterCaptionController.shared.toggleOverlayToolsPinned()
            }
            .keyboardShortcut(self.shortcut(.toggleTools), modifiers: self.presenterModifiers)

            Divider()

            Button(self.settings.theaterMinimized ? "Expand Theater" : "Minimize Theater") {
                if self.settings.theaterMinimized {
                    PresenterCaptionController.shared.show()
                } else {
                    PresenterCaptionController.shared.toggleMinimized()
                }
            }
            .keyboardShortcut(self.shortcut(.toggleVisible), modifiers: self.presenterModifiers)

            Button("Larger Captions") {
                self.settings.presenterFontSize += TheaterPresenterHotkey.fontStep
            }
            .keyboardShortcut(self.shortcut(.fontLarger), modifiers: self.presenterModifiers)

            Button("Smaller Captions") {
                self.settings.presenterFontSize -= TheaterPresenterHotkey.fontStep
            }
            .keyboardShortcut(self.shortcut(.fontSmaller), modifiers: self.presenterModifiers)

            Divider()

            Button("Copy All") {
                self.controller.copyCaptionText()
            }
            .keyboardShortcut(self.shortcut(.copy), modifiers: self.presenterModifiers)
            .disabled(!PresenterCaptionController.shared.hasDeliverableText)

            Button("Undo Last Caption") {
                self.controller.undoLastCaption()
            }
            .keyboardShortcut(self.shortcut(.undo), modifiers: self.presenterModifiers)
            .disabled(!self.controller.hasUndoableCaption)

            Button("Retry Translation") {
                self.controller.retryFailedTranslation()
            }
            .keyboardShortcut(self.shortcut(.retry), modifiers: self.presenterModifiers)
            .disabled(!self.controller.subscriber.canRetryTranslation)

            Button("Clear Captions") {
                self.controller.clearBoard()
            }
            .keyboardShortcut(self.shortcut(.clear), modifiers: self.presenterModifiers)
            .disabled(!self.controller.hasClearableBoard)
        }
    }

    private var presenterModifiers: EventModifiers {
        [.control, .option]
    }

    private func shortcut(_ action: TheaterPresenterHotkey.Action) -> KeyEquivalent {
        KeyEquivalent(Character(TheaterPresenterHotkey.keyEquivalent(for: action)))
    }
}
