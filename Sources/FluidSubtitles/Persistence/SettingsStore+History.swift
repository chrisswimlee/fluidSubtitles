//
//  SettingsStore+History.swift
//  Fluid
//
//  How long dictation history stays on this Mac.
//

import Combine
import Foundation

enum HistoryRetention: String, CaseIterable, Identifiable, Sendable {
    case days90
    case year
    case forever

    var id: String { self.rawValue }

    var displayName: String {
        switch self {
        case .days90: return "90 days"
        case .year: return "1 year"
        case .forever: return "Forever"
        }
    }

    var detail: String {
        switch self {
        case .days90:
            return "Drop rows older than 90 days. At most 20,000 rows stay."
        case .year:
            return "Drop rows older than a year. At most 20,000 rows stay."
        case .forever:
            return "Keep text until you clear History. A 50,000-row cap still bounds the database."
        }
    }

    var policy: HistoryRetentionPolicy {
        switch self {
        case .days90:
            return HistoryRetentionPolicy(maxAgeSeconds: 90 * 86_400, maxRows: 20_000)
        case .year:
            return HistoryRetentionPolicy(maxAgeSeconds: 365 * 86_400, maxRows: 20_000)
        case .forever:
            return HistoryRetentionPolicy(maxAgeSeconds: nil, maxRows: 50_000)
        }
    }

    static func resolved(_ raw: String?) -> HistoryRetention {
        guard let raw, let value = HistoryRetention(rawValue: raw) else {
            return .year
        }
        return value
    }
}

extension SettingsStore {
    var historyRetention: HistoryRetention {
        get {
            HistoryRetention.resolved(self.defaults.string(forKey: Keys.historyRetention))
        }
        set {
            self.objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.historyRetention)
        }
    }

    var historyRetentionPolicy: HistoryRetentionPolicy {
        self.historyRetention.policy
    }
}
