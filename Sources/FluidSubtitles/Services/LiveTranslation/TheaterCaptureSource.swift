import Foundation

enum TheaterSessionMode: String, CaseIterable, Identifiable {
    case transcription
    case translation

    var id: String { self.rawValue }

    var displayName: String {
        switch self {
        case .transcription: return "Voice"
        case .translation: return "Translate"
        }
    }

    var help: String {
        switch self {
        case .transcription:
            return "Voice writes what you say. Voice Engine sharpens that speech into text."
        case .translation:
            return "Translate after each sentence among Korean, English, Thai, and Japanese. Translation Engine is Apple Translation."
        }
    }

    var showsTranslation: Bool { self == .translation }

    static func resolved(_ stored: String?) -> TheaterSessionMode {
        switch stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" {
        case "transcription", "voice", "watch":
            return .transcription
        case "translation", "lectern", "":
            return .translation
        default:
            return Self(rawValue: stored ?? "") ?? .translation
        }
    }
}

enum TheaterWatchTarget: String, CaseIterable, Identifiable {
    case thisMac
    case app

    var id: String { self.rawValue }
}

enum TheaterCaptureSource: String, Sendable {
    case lecternMicrophone
    case watchThisMac
    case watchApp

    var isWatch: Bool {
        self != .lecternMicrophone
    }
}
