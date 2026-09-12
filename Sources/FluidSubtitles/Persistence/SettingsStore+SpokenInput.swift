//
//  SettingsStore+SpokenInput.swift
//  Fluid
//
//  Spoken send, insert mode, and legacy Whisper size keys.
//

import Combine
import CoreGraphics
import Foundation

extension SettingsStore {
    enum SpokenSendKey: String, CaseIterable, Identifiable, Codable {
        case enter
        case shiftEnter
        case commandEnter

        var id: String {
            self.rawValue
        }

        var displayName: String {
            switch self {
            case .enter:
                return "Enter"
            case .shiftEnter:
                return "Shift + Enter"
            case .commandEnter:
                return "Command + Enter"
            }
        }

        var eventFlags: CGEventFlags {
            switch self {
            case .enter:
                return []
            case .shiftEnter:
                return .maskShift
            case .commandEnter:
                return .maskCommand
            }
        }
    }

    var spokenSendEnabled: Bool {
        get { self.defaults.object(forKey: Keys.spokenSendEnabled) as? Bool ?? false }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.spokenSendEnabled)
        }
    }

    var spokenSendImmediatelyEnabled: Bool {
        get { self.defaults.object(forKey: Keys.spokenSendImmediatelyEnabled) as? Bool ?? true }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.spokenSendImmediatelyEnabled)
        }
    }

    var spokenSendPhrase: String {
        get { self.defaults.string(forKey: Keys.spokenSendPhrase) ?? "send it" }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.spokenSendPhrase)
        }
    }

    var spokenSendKey: SpokenSendKey {
        get {
            guard let raw = self.defaults.string(forKey: Keys.spokenSendKey),
                  let key = SpokenSendKey(rawValue: raw)
            else {
                return .enter
            }
            return key
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.spokenSendKey)
        }
    }

    enum TextInsertionMode: String, CaseIterable, Identifiable, Codable {
        case standard
        case reliablePaste

        var id: String {
            self.rawValue
        }

        var displayName: String {
            switch self {
            case .standard:
                return "Clipboard Free Insert"
            case .reliablePaste:
                return "Clipboard Paste"
            }
        }

        var description: String {
            switch self {
            case .standard:
                return "Fastest path. Inserts text without changing the clipboard, with paste fallback if direct insertion is unavailable."
            case .reliablePaste:
                return "Compatibility path. Uses a temporary clipboard paste and restores your previous clipboard after insertion."
            }
        }
    }

    var textInsertionMode: TextInsertionMode {
        get {
            guard let raw = self.defaults.string(forKey: Keys.textInsertionMode),
                  let mode = TextInsertionMode(rawValue: raw)
            else {
                return .standard
            }
            return mode
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.textInsertionMode)
        }
    }

    var betaReleasesEnabled: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.betaReleasesEnabled)
            return value as? Bool ?? false // Default to stable-only updates
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.betaReleasesEnabled)
            self.lastUpdateCheckDate = nil
            self.clearUpdateSnooze()
        }
    }

    /// Available Whisper model sizes
    enum WhisperModelSize: String, CaseIterable, Identifiable {
        case tiny = "ggml-tiny.bin"
        case base = "ggml-base.bin"
        case small = "ggml-small.bin"
        case medium = "ggml-medium.bin"
        case large = "ggml-large-v3.bin"

        var id: String {
            rawValue
        }

        var displayName: String {
            switch self {
            case .tiny: return "Tiny (~75 MB)"
            case .base: return "Base (~142 MB)"
            case .small: return "Small (~466 MB)"
            case .medium: return "Medium (~1.5 GB)"
            case .large: return "Large (~2.9 GB)"
            }
        }

        var description: String {
            switch self {
            case .tiny: return "Fastest, lower accuracy"
            case .base: return "Good balance of speed and accuracy"
            case .small: return "Better accuracy, slower"
            case .medium: return "High accuracy, requires more memory"
            case .large: return "Best accuracy, large download"
            }
        }
    }
}

