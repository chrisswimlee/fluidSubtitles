//
//  SettingsStore+Theater.swift
//  Fluid
//
//  Theater capture and Q&A keys. New Theater settings belong here.
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
        /// Leftover Watch keys. Theater Listen is the microphone.
        static let watchTarget = "TheaterWatchTarget"
        static let watchAppBundleID = "TheaterWatchAppBundleID"
        static let minimized = "TheaterMinimized"
        static let expandedWindowFrame = "TheaterExpandedWindowFrame"
        static let captionPrintStyle = "TheaterCaptionPrintStyle"
        static let lastTranslateTarget = "TheaterLastTranslateTargetLanguageID"
        static let backingBar = "TheaterBackingBar"
        static let positionPreset = "TheaterPositionPreset"
        static let presenterHotkeys = "TheaterPresenterHotkeys"
        static let overlayCoachSeen = "TheaterOverlayCoachSeen"
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

    /// Leftover Watch setting. Theater Listen ignores this and uses the microphone.
    var theaterWatchTarget: TheaterWatchTarget {
        get {
            TheaterWatchTarget(
                rawValue: self.defaults.string(forKey: TheaterDefaults.watchTarget) ?? ""
            ) ?? .thisMac
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: TheaterDefaults.watchTarget)
        }
    }

    /// Leftover Watch setting. Theater Listen ignores this and uses the microphone.
    var theaterWatchAppBundleID: String {
        get { self.defaults.string(forKey: TheaterDefaults.watchAppBundleID) ?? "" }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: TheaterDefaults.watchAppBundleID)
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

    var theaterCaptureSource: TheaterCaptureSource {
        .lecternMicrophone
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

    /// How the live Theater row appears. Flow and Word type the current title through commit.
    var theaterCaptionPrintStyle: TheaterCaptionPrintStyle {
        get {
            TheaterCaptionPrintStyle.resolved(
                self.defaults.string(forKey: TheaterDefaults.captionPrintStyle)
            )
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: TheaterDefaults.captionPrintStyle)
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
}
