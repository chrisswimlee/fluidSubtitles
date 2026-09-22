import AppKit
import Combine
import SwiftUI

enum TheaterExportFormat {
    case bilingualText
    case srt
    case vtt
}

@MainActor
final class PresenterCaptionModel: ObservableObject {
    @Published var committed: [String] = []
    @Published var committedIDs: [UInt64] = []
    @Published var nextCaptionID: UInt64 = 1
    @Published var committedSources: [String] = []
    @Published var pendingSources: [String] = []
    @Published var inFlightCount: Int = 0
    @Published var liveRowID: UInt64 = 0
    @Published var source: String = ""
    @Published var tentativeSpoken: String = ""
    @Published var draft: String = ""
    @Published var pairLabel: String = ""
    @Published var status: String = ""
    @Published var statusKind: TheaterStatusKind = .idle
    @Published var isListening: Bool = false
    @Published var isPaused: Bool = false
    @Published var isEditing: Bool = false
    @Published var editedText: String = ""
    @Published var canRetryTranslation: Bool = false
    @Published var approachingLineLimit: Bool = false
    @Published var latencyReadout: String = ""
    @Published var compactLatencyReadout: String = ""
    @Published var paceCueLabel: String = ""
    @Published var paceCueCompactLabel: String = ""
    @Published var paceCueKind: String = ""
    @Published var showCloseConfirmation: Bool = false
    /// True while the export save panel is open. The More button reads Saved.
    @Published var exportShowsSaved: Bool = false
    /// Session-only. Overlay starts unpinned (text only). Pop-up, minimize, and close clear it.
    @Published var overlayToolsPinned: Bool = false
}

enum TheaterTypeface: String, CaseIterable, Identifiable {
    case system
    case helveticaNeue = "Helvetica Neue"
    case avenirNext = "Avenir Next"
    case georgia = "Georgia"
    case palatino = "Palatino"
    case menlo = "Menlo"
    case gothicNeo = "Apple SD Gothic Neo"
    case thonburi = "Thonburi"

    var id: String { self.rawValue }

    var displayName: String {
        self == .system ? "System" : self.rawValue
    }

    static func resolved(_ stored: String) -> TheaterTypeface {
        Self(rawValue: stored.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .system
    }

    var postScriptName: String? {
        switch self {
        case .system:
            return nil
        case .helveticaNeue:
            return "HelveticaNeue"
        case .avenirNext:
            return "AvenirNext-DemiBold"
        case .georgia:
            return "Georgia"
        case .palatino:
            return "Palatino-Roman"
        case .menlo:
            return "Menlo-Regular"
        case .gothicNeo:
            return "AppleSDGothicNeo-SemiBold"
        case .thonburi:
            return "Thonburi"
        }
    }

    func font(size: CGFloat, weight: Font.Weight) -> Font {
        if let name = self.postScriptName {
            return .custom(name, size: size)
        }
        return .system(size: size, weight: weight)
    }

    func nsFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        if let name = self.postScriptName, let named = NSFont(name: name, size: size) {
            return named
        }
        if self != .system, let family = NSFontManager.shared.font(
            withFamily: self.rawValue,
            traits: [],
            weight: 7,
            size: size
        ) {
            return family
        }
        return .systemFont(ofSize: size, weight: weight)
    }
}

struct TheaterFlowLine: Equatable, Identifiable {
    let id: String
    let text: String
    let source: String
    let isCurrent: Bool
    let isDraft: Bool
}

enum TheaterPresentationStyle: String, CaseIterable, Identifiable {
    case popup
    case transparent

    var id: String { self.rawValue }

    var displayName: String {
        switch self {
        case .popup: return "Pop-up"
        case .transparent: return "Overlay"
        }
    }

    var symbol: String {
        switch self {
        case .popup: return "rectangle.on.rectangle"
        case .transparent: return "rectangle.dashed"
        }
    }

    var help: String {
        switch self {
        case .popup: return TheaterReadiness.popupStyle
        case .transparent: return TheaterReadiness.transparentStyle
        }
    }

    var toggled: TheaterPresentationStyle {
        self == .popup ? .transparent : .popup
    }

    static func resolved(_ stored: String?) -> TheaterPresentationStyle {
        let trimmed = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Self(rawValue: trimmed) ?? .popup
    }
}

enum TheaterAppearance: String, CaseIterable, Identifiable {
    case dark
    case light

    var id: String { self.rawValue }

    var displayName: String {
        switch self {
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }

    var toggleSymbol: String {
        switch self {
        case .dark: return "sun.max.fill"
        case .light: return "moon.fill"
        }
    }

    var toggleHelp: String {
        switch self {
        case .dark: return "Light mode"
        case .light: return "Dark mode"
        }
    }

    var colorScheme: ColorScheme {
        self == .light ? .light : .dark
    }

    var toggled: TheaterAppearance {
        self == .dark ? .light : .dark
    }

    static func resolved(_ stored: String?) -> TheaterAppearance {
        let trimmed = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Self(rawValue: trimmed) ?? .dark
    }
}
