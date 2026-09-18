import Combine
import Foundation

extension SettingsStore {
    private enum TheaterTalkDefaults {
        static let fileName = "TheaterTalkPackFileName"
        static let terms = "TheaterTalkPackTerms"
    }

    /// File the presenter dropped for this talk. Clear wipes it.
    var theaterTalkPackFileName: String {
        get { self.defaults.string(forKey: TheaterTalkDefaults.fileName) ?? "" }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: TheaterTalkDefaults.fileName)
        }
    }

    /// Names from this talk's notes. Used by glossary lock and the local LLM.
    var theaterTalkPackTerms: [String] {
        get { self.defaults.stringArray(forKey: TheaterTalkDefaults.terms) ?? [] }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: TheaterTalkDefaults.terms)
        }
    }

    var hasTheaterTalkPack: Bool {
        !self.theaterTalkPackTerms.isEmpty || !self.theaterTalkPackFileName.isEmpty
    }

    func applyTheaterTalkPack(_ document: TheaterTalkPack.Document) {
        self.theaterTalkPackFileName = document.fileName
        self.theaterTalkPackTerms = document.terms
    }

    func clearTheaterTalkPack() {
        self.theaterTalkPackFileName = ""
        self.theaterTalkPackTerms = []
    }
}
