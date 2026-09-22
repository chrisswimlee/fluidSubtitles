//
//  TheaterKeyPolicy.swift
//  fluid
//
//  When Theater should give key back to the app under the board.
//

import Foundation

/// Chrome may take key. Hold it only while the caption editor is open.
enum TheaterKeyPolicy {
    static func shouldRestoreExternalApp(isEditing: Bool) -> Bool {
        !isEditing
    }
}
