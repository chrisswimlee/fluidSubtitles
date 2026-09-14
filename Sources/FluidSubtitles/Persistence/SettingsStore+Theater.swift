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
        static let sessionMode = "TheaterSessionMode"
        static let watchTarget = "TheaterWatchTarget"
        static let watchAppBundleID = "TheaterWatchAppBundleID"
        static let minimized = "TheaterMinimized"
        static let expandedWindowFrame = "TheaterExpandedWindowFrame"
    }

    var theaterSessionMode: TheaterSessionMode {
        get {
            TheaterSessionMode(
                rawValue: self.defaults.string(forKey: TheaterDefaults.sessionMode) ?? ""
            ) ?? .lectern
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: TheaterDefaults.sessionMode)
        }
    }

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
        switch self.theaterSessionMode {
        case .lectern:
            return .lecternMicrophone
        case .watch:
            if self.theaterWatchTarget == .app,
               !self.theaterWatchAppBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return .watchApp
            }
            return .watchThisMac
        }
    }

    /// Pop-up is a solid board. Transparent lets slides show through.
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

    /// Whisper auto-detects English, Korean, and Thai for Q&A. Apple Speech stays on I speak.
    var theaterAlsoHearOtherLanguages: Bool {
        get { self.defaults.bool(forKey: TheaterDefaults.alsoHearOtherLanguages) }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: TheaterDefaults.alsoHearOtherLanguages)
        }
    }
}
