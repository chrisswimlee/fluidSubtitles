//
//  SettingsStore+Theater.swift
//  Fluid
//
//  Theater window and listen keys. New Theater settings belong here.
//

import Combine
import Foundation

extension SettingsStore {
    private enum TheaterDefaults {
        static let hideFromScreenShare = "TheaterHideFromScreenShare"
        static let presentationStyle = "TheaterPresentationStyle"
        static let alsoHearOtherLanguages = "TheaterAlsoHearOtherLanguages"
        static let dynamicPairing = "TheaterDynamicPairing"
        static let sessionMode = "TheaterSessionMode"
        static let minimized = "TheaterMinimized"
        static let expandedWindowFrame = "TheaterExpandedWindowFrame"
        static let spokenLineMode = "TheaterSpokenLineMode"
        static let lastTranslateTarget = "TheaterLastTranslateTargetLanguageID"
        static let backingBar = "TheaterBackingBar"
        static let positionPreset = "TheaterPositionPreset"
        static let presenterHotkeys = "TheaterPresenterHotkeys"
        static let overlayCoachSeen = "TheaterOverlayCoachSeen"
        static let setupWizardCompleted = "TheaterSetupWizardCompleted"
        static let setupWizardStep = "TheaterSetupWizardStep"
        static let setupWizardOpened = "TheaterSetupWizardOpened"
    }

    var theaterSessionMode: TheaterSessionMode {
        get {
            TheaterSessionMode.resolved(self.defaults.string(forKey: TheaterDefaults.sessionMode))
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: TheaterDefaults.sessionMode)
        }
    }

    var theaterLastTranslateTargetLanguageID: String {
        get { self.defaults.string(forKey: TheaterDefaults.lastTranslateTarget) ?? "" }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: TheaterDefaults.lastTranslateTarget)
        }
    }

    var theaterMinimized: Bool {
        get { self.defaults.bool(forKey: TheaterDefaults.minimized) }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: TheaterDefaults.minimized)
        }
    }

    var theaterExpandedWindowFrame: String {
        get { self.defaults.string(forKey: TheaterDefaults.expandedWindowFrame) ?? "" }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: TheaterDefaults.expandedWindowFrame)
        }
    }

    /// Pop-up is a solid board. Overlay (stored as transparent) lets slides show through.
    var theaterPresentationStyle: String {
        get {
            TheaterPresentationStyle.resolved(
                self.defaults.string(forKey: TheaterDefaults.presentationStyle)
            ).rawValue
        }
        set {
            objectWillChange.send()
            self.defaults.set(
                TheaterPresentationStyle.resolved(newValue).rawValue,
                forKey: TheaterDefaults.presentationStyle
            )
        }
    }

    var theaterPresentation: TheaterPresentationStyle {
        TheaterPresentationStyle.resolved(self.theaterPresentationStyle)
    }

    /// Keep Theater off Zoom, Keynote, and screen recordings. The window still
    /// draws on this Mac and on a wired projector.
    var theaterHideFromScreenShare: Bool {
        get { self.defaults.object(forKey: TheaterDefaults.hideFromScreenShare) as? Bool ?? true }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: TheaterDefaults.hideFromScreenShare)
        }
    }

    /// Off, after a pause, or while talking. Migrates the old Show the spoken line toggle.
    var theaterSpokenLineMode: TheaterSpokenLineMode {
        get {
            if let stored = self.defaults.string(forKey: TheaterDefaults.spokenLineMode)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !stored.isEmpty
            {
                return TheaterSpokenLineMode.resolved(stored)
            }
            let legacy = self.defaults.object(forKey: Keys.translationShowSource) as? Bool
            return TheaterSpokenLineMode.migrated(fromShowSource: legacy)
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: TheaterDefaults.spokenLineMode)
            self.defaults.set(newValue.showsSpokenLine, forKey: Keys.translationShowSource)
        }
    }

    /// Whisper auto-detects English, Korean, Japanese, and Thai for Q&A. Apple Speech stays on I speak.
    var theaterAlsoHearOtherLanguages: Bool {
        get { self.defaults.bool(forKey: TheaterDefaults.alsoHearOtherLanguages) }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: TheaterDefaults.alsoHearOtherLanguages)
        }
    }

    /// Either way: translate whichever language of the pair you speak. Kept
    /// for a later release; Listen ignores this until `dynamicPairingAvailable`.
    var theaterDynamicPairing: Bool {
        get { self.defaults.bool(forKey: TheaterDefaults.dynamicPairing) }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: TheaterDefaults.dynamicPairing)
        }
    }

    /// Overlay only: a dark plate behind each caption line so they read on white slides.
    var theaterBackingBar: Bool {
        get { self.defaults.bool(forKey: TheaterDefaults.backingBar) }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: TheaterDefaults.backingBar)
        }
    }

    /// Last position preset. Nil once the presenter drags the board somewhere else.
    var theaterPositionPreset: TheaterPositionPreset? {
        get { TheaterPositionPreset(rawValue: self.defaults.string(forKey: TheaterDefaults.positionPreset) ?? "") }
        set {
            objectWillChange.send()
            self.defaults.set(newValue?.rawValue ?? "", forKey: TheaterDefaults.positionPreset)
        }
    }

    /// Control+Option shortcuts that drive Theater while the slides keep focus.
    var theaterPresenterHotkeysEnabled: Bool {
        get { self.defaults.object(forKey: TheaterDefaults.presenterHotkeys) as? Bool ?? true }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: TheaterDefaults.presenterHotkeys)
        }
    }

    /// The one-time Overlay coach line was shown and the presenter used Overlay.
    var theaterOverlayCoachSeen: Bool {
        get { self.defaults.bool(forKey: TheaterDefaults.overlayCoachSeen) }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: TheaterDefaults.overlayCoachSeen)
        }
    }

    /// First run does not open this wizard. A missing flag counts as done once
    /// onboarding is done, so an older install is not dropped into setup again.
    var theaterSetupWizardCompleted: Bool {
        get {
            if self.defaults.object(forKey: TheaterDefaults.setupWizardCompleted) == nil {
                return self.onboardingCompleted
            }
            return self.defaults.bool(forKey: TheaterDefaults.setupWizardCompleted)
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: TheaterDefaults.setupWizardCompleted)
        }
    }

    var theaterSetupWizardStep: Int {
        get {
            TheaterSetupWizard.Step.resolved(self.defaults.integer(forKey: TheaterDefaults.setupWizardStep)).rawValue
        }
        set {
            objectWillChange.send()
            self.defaults.set(
                TheaterSetupWizard.Step.resolved(newValue).rawValue,
                forKey: TheaterDefaults.setupWizardStep
            )
        }
    }

    /// True only after the user opens Setup Wizard. First run does not set this.
    var theaterSetupWizardOpened: Bool {
        get { self.defaults.bool(forKey: TheaterDefaults.setupWizardOpened) }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: TheaterDefaults.setupWizardOpened)
        }
    }

    var shouldShowSetupWizard: Bool {
        !self.shouldShowOnboarding
            && self.theaterSetupWizardOpened
            && !self.theaterSetupWizardCompleted
    }

    func bootstrapSetupWizardState() {
        if self.defaults.object(forKey: TheaterDefaults.setupWizardCompleted) == nil {
            objectWillChange.send()
            self.defaults.set(true, forKey: TheaterDefaults.setupWizardCompleted)
            self.defaults.set(false, forKey: TheaterDefaults.setupWizardOpened)
            self.defaults.set(0, forKey: TheaterDefaults.setupWizardStep)
            return
        }
        // An incomplete wizard the user never opened was the old first-run handoff.
        if self.defaults.bool(forKey: TheaterDefaults.setupWizardCompleted) == false,
           self.defaults.bool(forKey: TheaterDefaults.setupWizardOpened) == false
        {
            objectWillChange.send()
            self.defaults.set(true, forKey: TheaterDefaults.setupWizardCompleted)
        }
    }

    func startSetupWizard() {
        objectWillChange.send()
        self.defaults.set(true, forKey: TheaterDefaults.setupWizardOpened)
        self.defaults.set(false, forKey: TheaterDefaults.setupWizardCompleted)
        self.defaults.set(0, forKey: TheaterDefaults.setupWizardStep)
    }

    func completeSetupWizard() {
        objectWillChange.send()
        self.defaults.set(true, forKey: TheaterDefaults.setupWizardCompleted)
        self.defaults.set(0, forKey: TheaterDefaults.setupWizardStep)
    }
}
