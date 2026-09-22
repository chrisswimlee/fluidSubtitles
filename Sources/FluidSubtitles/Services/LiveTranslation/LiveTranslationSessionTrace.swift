import Foundation

/// One Listen, described without the words that were said.
struct LiveTranslationSessionTrace: Equatable {
    var token: UInt64
    var kind: String
    var startedUptime: TimeInterval
    var partials = 0
    var silenceHolds = 0
    var utteranceEnds = 0
    var loggedFirstBuffer = false
    var loggedSpeechStart = false

    func beginLine(mode: String, pair: String, model: String, thermal: String) -> String {
        "session begin kind=\(self.kind) token=\(self.token) mode=\(mode) pair=\(pair) model=\(model) thermal=\(thermal)"
    }

    func endLine(outcome: String, now: TimeInterval, lines: Int) -> String {
        let elapsedMs = Int((max(0, now - self.startedUptime) * 1000).rounded())
        return "session \(outcome) kind=\(self.kind) token=\(self.token) elapsedMs=\(elapsedMs) partials=\(self.partials) silenceHolds=\(self.silenceHolds) utteranceEnds=\(self.utteranceEnds) lines=\(lines)"
    }
}

enum LiveTranslationTrace {
    static let source = "LiveTranslationController"

    static func event(_ name: String, token: UInt64? = nil, _ fields: String = "") -> String {
        var line = name
        if let token {
            line += " token=\(token)"
        }
        if !fields.isEmpty {
            line += " \(fields)"
        }
        return line
    }

    static func packLabel(_ availability: TranslationPackAvailability) -> String {
        switch availability {
        case .installed: return "installed"
        case .supported: return "supported"
        case .unsupported: return "unsupported"
        case .unknown: return "unknown"
        }
    }
}
