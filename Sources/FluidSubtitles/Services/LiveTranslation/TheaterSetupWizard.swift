import Foundation

/// First-run and re-runnable Theater setup. Voice Engine download stays in
/// onboarding; this wizard is languages, captions, and who sees the board.
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
                return "Set how Theater captions look before the first Listen."
            case .languages:
                return "I speak is what you say. Show as is the title. Both lists are languages Apple Translation and a Voice Engine share."
            case .captions:
                return "Choose whether the original language sits under each delivered sentence."
            case .audience:
                return TheaterReadiness.audienceTitle
            case .ready:
                return "Open Theater and press Listen. A real clause appears once when it is accepted."
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
        "A real clause appears once when it is accepted."

    static let welcomeDetail =
        "A real clause appears once when it is accepted. Caption Pause and Stop drop a leftover fragment. The original language can sit under that sentence."

    static let readyPrimary = "Open Theater"

    static let accentTitle = "Accent color"

    static let accentDetail = "Caption gold is the default. It tints buttons in this app."

    static let skipTitle = "Skip for now"

    static func progress(for step: Step) -> Double {
        Double(step.rawValue) / Double(Step.allCases.count - 1)
    }
}
