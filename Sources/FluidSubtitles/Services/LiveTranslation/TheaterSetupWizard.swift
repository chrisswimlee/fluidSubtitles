import Foundation

/// Optional Theater setup from the sidebar. First run ends on a caption.
/// Voice Engine download stays in onboarding.
enum TheaterSetupWizard {
    enum Step: Int, CaseIterable, Identifiable {
        case welcome = 0
        case languages = 1
        case captions = 2
        case audience = 3
        case ready = 4

        var id: Int { self.rawValue }

        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .languages: return "Languages"
            case .captions: return "Captions"
            case .audience: return "Audience"
            case .ready: return "Ready"
            }
        }

        var subtitle: String {
            switch self {
            case .welcome:
                return "Choose how captions look."
            case .languages:
                return "I speak is what you say. Show as is the caption."
            case .captions:
                return "Choose whether the original language sits under each sentence."
            case .audience:
                return TheaterReadiness.audienceTitle
            case .ready:
                return "Open Theater and press Listen."
            }
        }

        var systemImage: String {
            switch self {
            case .welcome: return "rectangle.on.rectangle"
            case .languages: return "globe"
            case .captions: return "text.alignleft"
            case .audience: return "person.2"
            case .ready: return "checkmark.circle"
            }
        }

        var continueTitle: String {
            self == .ready ? "Finish" : "Continue"
        }

        var next: Step? {
            Step(rawValue: self.rawValue + 1)
        }

        var previous: Step? {
            Step(rawValue: self.rawValue - 1)
        }

        static func resolved(_ raw: Int) -> Step {
            Step(rawValue: raw) ?? .welcome
        }
    }

    static let title = "Setup Wizard"

    static let welcomeTitle = "Set up Theater"

    static let welcomeBody =
        "Each sentence appears when it is ready."

    static let welcomeDetail =
        "The original language can sit under each sentence. Choose that here, then who sees the board."

    static let readyPrimary = "Open Theater"

    static let accentTitle = "Accent color"

    static let accentDetail = "Caption gold is the default. It tints buttons in this app."

    static let skipTitle = "Skip for now"

    static func progress(for step: Step) -> Double {
        Double(step.rawValue) / Double(Step.allCases.count - 1)
    }
}
