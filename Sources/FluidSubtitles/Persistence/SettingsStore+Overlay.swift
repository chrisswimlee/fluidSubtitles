//
//  SettingsStore+Overlay.swift
//  Fluid
//
//  Recording overlay size, position, and related chrome.
//

import Combine
import Foundation
import SwiftUI

extension SettingsStore {
    // MARK: - Overlay Position

    /// Size options for the recording overlay
    enum OverlaySize: String, CaseIterable, Codable {
        case pill
        case small
        case medium
        case large

        var displayName: String {
            switch self {
            case .pill: return "Pill"
            case .small: return "Small"
            case .medium: return "Medium"
            case .large: return "Large"
            }
        }
    }

    /// Position options for the recording overlay
    enum OverlayPosition: String, CaseIterable, Codable {
        case top // Top of screen (notch area or floating)
        case bottom // Bottom of screen

        var displayName: String {
            switch self {
            case .top: return "Top of Screen"
            case .bottom: return "Bottom of Screen"
            }
        }
    }

    /// Internal presentation modes for the top notch overlay.
    /// This is intentionally separate from bottom overlay sizing.
    enum NotchPresentationMode: String, CaseIterable, Codable {
        case standard
        case minimal

        var displayName: String {
            switch self {
            case .standard:
                return "Standard Notch"
            case .minimal:
                return "Compact"
            }
        }
    }

    /// Where the recording overlay appears (default: bottom)
    var overlayPosition: OverlayPosition {
        get {
            guard let raw = self.defaults.string(forKey: Keys.overlayPosition),
                  let position = OverlayPosition(rawValue: raw)
            else {
                return .bottom // Default to bottom (menu overlay)
            }
            return position
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.overlayPosition)
            NotificationCenter.default.post(name: NSNotification.Name("OverlayPositionChanged"), object: nil)
        }
    }

    /// Internal-only top notch presentation mode. No public settings UI yet.
    var notchPresentationMode: NotchPresentationMode {
        get {
            guard let raw = self.defaults.string(forKey: Keys.notchPresentationMode),
                  let mode = NotchPresentationMode(rawValue: raw)
            else {
                return .standard
            }
            return mode
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.notchPresentationMode)
        }
    }

    /// Vertical offset for the bottom overlay (distance from bottom of screen/dock)
    var overlayBottomOffset: Double {
        get {
            let value = self.defaults.double(forKey: Keys.overlayBottomOffset)
            return value == 0.0 ? 50.0 : value // Default to 50.0
        }
        set {
            objectWillChange.send()
            // Clamp between a safe range (20px to 1000px)
            // Even though slider is 20-500, we clamp for safety
            let clamped = max(min(newValue, 1000.0), 10.0)
            self.defaults.set(clamped, forKey: Keys.overlayBottomOffset)

            // Post notification for live update if overlay is visible
            NotificationCenter.default.post(name: NSNotification.Name("OverlayOffsetChanged"), object: nil)
        }
    }

    /// The size of the recording overlay (default: medium)
    var overlaySize: OverlaySize {
        get {
            guard let raw = self.defaults.string(forKey: Keys.overlaySize),
                  let size = OverlaySize(rawValue: raw)
            else {
                return .medium // Default to medium
            }
            return size
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.overlaySize)

            // Post notification for live update if overlay is visible
            NotificationCenter.default.post(name: NSNotification.Name("OverlaySizeChanged"), object: nil)
        }
    }

    /// How many recent transcription characters show in overlays (default: 150)
    var transcriptionPreviewCharLimit: Int {
        get {
            let stored = self.defaults.object(forKey: Keys.transcriptionPreviewCharLimit) as? NSNumber
            let value = stored?.intValue ?? Self.defaultTranscriptionPreviewCharLimit
            return Self.normalizedTranscriptionPreviewCharLimit(value)
        }
        set {
            let clamped = Self.normalizedTranscriptionPreviewCharLimit(newValue)
            guard clamped != self.transcriptionPreviewCharLimit else { return }

            objectWillChange.send()
            self.defaults.set(clamped, forKey: Keys.transcriptionPreviewCharLimit)
            NotificationCenter.default.post(
                name: NSNotification.Name("TranscriptionPreviewCharLimitChanged"),
                object: nil
            )
        }
    }

    static func normalizedTranscriptionPreviewCharLimit(_ value: Int) -> Int {
        let range = Self.transcriptionPreviewCharLimitRange
        let clamped = max(range.lowerBound, min(range.upperBound, value))
        let offset = clamped - range.lowerBound
        let snappedOffset = Int((Double(offset) / Double(Self.transcriptionPreviewCharLimitStep)).rounded())
            * Self.transcriptionPreviewCharLimitStep
        return max(range.lowerBound, min(range.upperBound, range.lowerBound + snappedOffset))
    }

    // MARK: - Preferences Settings

    enum AccentColorOption: String, CaseIterable, Identifiable, Codable {
        case caption = "Caption"
        case teal = "Teal"
        case cyan = "Cyan"
        case green = "Green"
        case blue = "Blue"
        case purple = "Purple"
        case orange = "Orange"

        var id: String {
            self.rawValue
        }

        var hex: String {
            switch self {
            case .caption: return "#E8A54B"
            case .teal: return "#2DD4BF"
            case .cyan: return "#3AC8C6"
            case .green: return "#22C55E"
            case .blue: return "#3B82F6"
            case .purple: return "#A855F7"
            case .orange: return "#F59E0B"
            }
        }
    }

    enum ThemePreference: String, CaseIterable, Identifiable, Codable {
        case system
        case light
        case dark

        var id: String {
            self.rawValue
        }

        var displayName: String {
            switch self {
            case .system: return "System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }

        var systemImageName: String {
            switch self {
            case .system: return "circle.lefthalf.filled"
            case .light: return "sun.max"
            case .dark: return "moon"
            }
        }

        var preferredColorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    enum TranscriptionStartSound: String, CaseIterable, Identifiable, Codable {
        case none
        case fluidSfx0 = "fluid_sfx_0"
        case fluidSfx1 = "fluid_sfx_1"
        case fluidSfx2 = "fluid_sfx_2"
        case fluidSfx3 = "fluid_sfx_3"
        case fluidSfx4 = "fluid_sfx_4"

        var id: String {
            self.rawValue
        }

        var displayName: String {
            switch self {
            case .none: return "None"
            case .fluidSfx0: return "Fluid SFX 0"
            case .fluidSfx1: return "Fluid SFX 1"
            case .fluidSfx2: return "Fluid SFX 2"
            case .fluidSfx3: return "Fluid SFX 3"
            case .fluidSfx4: return "Fluid SFX 4"
            }
        }

        var startSoundFileName: String? {
            switch self {
            case .none: return nil
            case .fluidSfx0: return "FV_start_0"
            case .fluidSfx1: return "FV_start"
            case .fluidSfx2: return "FV_start_2"
            case .fluidSfx3: return "sfx_3"
            case .fluidSfx4: return "sfx_4"
            }
        }

        var stopSoundFileName: String? {
            switch self {
            case .fluidSfx0: return "FV_end_0"
            case .none, .fluidSfx1, .fluidSfx2, .fluidSfx3, .fluidSfx4: return nil
            }
        }
    }

    /// One-time: the inherited teal default is FluidVoice. Caption gold is this product.
    /// A later choice of Teal stays put.
    func migrateCaptionAccentIfNeeded() {
        guard self.defaults.object(forKey: Keys.captionAccentMigration) == nil else { return }
        self.defaults.set(true, forKey: Keys.captionAccentMigration)
        let raw = self.defaults.string(forKey: Keys.accentColorOption)
        if raw == nil || raw == AccentColorOption.teal.rawValue {
            self.accentColorOption = .caption
        }
    }

    var accentColorOption: AccentColorOption {
        get {
            guard let raw = self.defaults.string(forKey: Keys.accentColorOption),
                  let option = AccentColorOption(rawValue: raw)
            else {
                return .caption
            }
            return option
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.accentColorOption)
        }
    }

    var accentColor: Color {
        Color(hex: self.accentColorOption.hex) ?? Color(red: 0.910, green: 0.647, blue: 0.294)
    }

    var themePreference: ThemePreference {
        get {
            guard let raw = self.defaults.string(forKey: Keys.themePreference),
                  let preference = ThemePreference(rawValue: raw)
            else {
                return .system
            }
            return preference
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.themePreference)
        }
    }

    var enableTranscriptionSounds: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.enableTranscriptionSounds)
            return value as? Bool ?? false
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.enableTranscriptionSounds)
        }
    }

    var transcriptionSoundVolume: Float {
        get {
            let value = self.defaults.object(forKey: Keys.transcriptionSoundVolume)
            return (value as? Float) ?? 1.0
        }
        set {
            objectWillChange.send()
            let clamped = max(0.0, min(1.0, newValue))
            self.defaults.set(clamped, forKey: Keys.transcriptionSoundVolume)
        }
    }

    var transcriptionSoundIndependentVolume: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.transcriptionSoundIndependentVolume)
            return value as? Bool ?? false
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.transcriptionSoundIndependentVolume)
        }
    }

    var transcriptionStartSound: TranscriptionStartSound {
        get {
            self.migrateTranscriptionStartSoundIfNeeded()
            guard let raw = self.defaults.string(forKey: Keys.transcriptionStartSound),
                  let option = TranscriptionStartSound(rawValue: raw)
            else {
                return .fluidSfx0
            }
            return option
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.transcriptionStartSound)
        }
    }

    var launchAtStartup: Bool {
        get { self.launchAtStartupEnabled }
        set {
            self.setLaunchAtStartup(newValue)
        }
    }
}
