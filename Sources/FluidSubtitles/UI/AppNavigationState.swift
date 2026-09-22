//
//  AppNavigationState.swift
//  fluid
//
//  Navigation state shared by the main app and settings sidebars.
//

import Foundation

enum SidebarItem: Hashable {
    case liveTranslation
    case welcome
    case voiceEngine
    case translationEngine
    case aiEnhancements
    case cleanupStyles
    case customDictionary
    case stats
    case history
    case changelog
    case feedback

    var accessibilityIdentifier: String {
        switch self {
        case .liveTranslation: return "sidebar.theater"
        case .welcome: return "sidebar.welcome"
        case .voiceEngine: return "sidebar.voiceEngine"
        case .translationEngine: return "sidebar.translationEngine"
        case .aiEnhancements: return "sidebar.aiProviders"
        case .cleanupStyles: return "sidebar.cleanupStyles"
        case .customDictionary: return "sidebar.customDictionary"
        case .stats: return "sidebar.stats"
        case .history: return "sidebar.history"
        case .changelog: return "sidebar.changelog"
        case .feedback: return "sidebar.feedback"
        }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case translation
    case general
    case dictation
    case aiProviders
    case notifications
    case audio
    case dataAndDiagnostics
    case experimental

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .translation: return "Theater"
        case .general: return "General"
        case .dictation: return "Dictation"
        case .aiProviders: return "AI Providers"
        case .notifications: return "Notifications"
        case .audio: return "Audio"
        case .dataAndDiagnostics: return "Data & Diagnostics"
        case .experimental: return "Experimental"
        }
    }

    /// Settings this product advertises. Dictation leftovers stay in the
    /// enum for search and backups but are not a sidebar destination.
    static var productSections: [SettingsSection] {
        Self.allCases.filter { $0 != .dictation && $0 != .aiProviders }
    }

    var systemImage: String {
        switch self {
        case .translation: return "captions.bubble"
        case .general: return "gearshape"
        case .dictation: return "keyboard"
        case .aiProviders: return "cpu"
        case .notifications: return "bell"
        case .audio: return "mic"
        case .dataAndDiagnostics: return "wrench.and.screwdriver"
        case .experimental: return "flask"
        }
    }
}

struct SettingsNavigationState: Equatable {
    var selectedSection: SettingsSection?
    private(set) var returnDestination: SidebarItem = .welcome

    var isPresented: Bool {
        self.selectedSection != nil
    }

    func isLeaving(_ section: SettingsSection, for destination: SettingsSection?) -> Bool {
        self.selectedSection == section && destination != section
    }

    mutating func present(_ section: SettingsSection, returningTo currentDestination: SidebarItem?) {
        if !self.isPresented {
            self.returnDestination = currentDestination ?? .welcome
        }
        self.selectedSection = section
    }

    mutating func dismiss() -> SidebarItem {
        self.selectedSection = nil
        return self.returnDestination
    }

    mutating func leaveForApp() {
        self.selectedSection = nil
    }
}
