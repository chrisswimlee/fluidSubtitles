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
        static let alsoHearOtherLanguages = "TheaterAlsoHearOtherLanguages"
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
