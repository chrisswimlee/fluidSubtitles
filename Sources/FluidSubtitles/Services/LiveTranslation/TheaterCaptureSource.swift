import Foundation

enum TheaterSessionMode: String, CaseIterable, Identifiable {
    case lectern
    case watch

    var id: String { self.rawValue }

    var displayName: String {
        switch self {
        case .lectern: return "Lectern"
        case .watch: return "Watch"
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
