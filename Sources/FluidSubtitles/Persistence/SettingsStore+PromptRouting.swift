import Combine
import Foundation

extension SettingsStore {
    enum PromptRoutingScope: String, Codable, CaseIterable, Identifiable {
        case allApps
        case selectedAppsOnly

        var id: String { self.rawValue }
    }

    var dictationPromptRoutingScope: PromptRoutingScope {
        get {
            guard let rawValue = self.defaults.string(forKey: PromptRoutingKeys.dictation),
                  let scope = PromptRoutingScope(rawValue: rawValue)
            else {
                return .allApps
            }
            return scope
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: PromptRoutingKeys.dictation)
        }
    }

    func promptRoutingScope(for _: PromptMode) -> PromptRoutingScope {
        self.dictationPromptRoutingScope
    }

    func setPromptRoutingScope(_ scope: PromptRoutingScope, for _: PromptMode) {
        self.dictationPromptRoutingScope = scope
    }
}

private enum PromptRoutingKeys {
    static let dictation = "DictationPromptRoutingScope"
}
