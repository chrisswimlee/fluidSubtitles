import Foundation

/// One accepted caption on the Theater board.
struct TheaterBoardRow: Equatable, Identifiable {
    var id: UInt64
    var source: String
    var translated: String
}

/// The only snapshot the presenter draws. Drafts, leftovers, and pending
/// translations are not rows.
struct TheaterBoardState: Equatable {
    var rows: [TheaterBoardRow] = []
    var nextID: UInt64 = 1
    var inFlightCount: Int = 0
    var oldestInFlightWaitMs: Int?

    var translatedLines: [String] { self.rows.map(\.translated) }
    var sourceLines: [String] { self.rows.map(\.source) }
    var lineIDs: [UInt64] { self.rows.map(\.id) }
    var isEmpty: Bool {
        !self.rows.contains {
            !$0.translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func make(
        translated: [String],
        sources: [String] = [],
        ids: [UInt64] = []
    ) -> TheaterBoardState {
        let rows = translated.enumerated().map { index, text in
            TheaterBoardRow(
                id: index < ids.count ? ids[index] : UInt64(index + 1),
                source: index < sources.count ? sources[index] : "",
                translated: text
            )
        }
        let next = (rows.map(\.id).max() ?? 0) + 1
        return TheaterBoardState(rows: rows, nextID: next)
    }
}
