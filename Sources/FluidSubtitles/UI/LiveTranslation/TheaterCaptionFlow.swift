import Foundation

/// Maps an accepted board onto presenter rows. Caption decisions live on
/// `LiveTranslationSubscriber.advance`. This type does not peel or admit.
enum TheaterCaptionFlow {
    /// One row per accepted Show-as line. The view decides whether `source` is drawn.
    static func lines(board: TheaterBoardState) -> [TheaterFlowLine] {
        let history = board.rows.enumerated().filter {
            !$0.element.translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return history.map { index, row in
            TheaterFlowLine(
                id: "c-\(row.id)",
                text: row.translated.trimmingCharacters(in: .whitespacesAndNewlines),
                source: row.source.trimmingCharacters(in: .whitespacesAndNewlines),
                isCurrent: index == history.last?.offset,
                isDraft: false
            )
        }
    }
}
