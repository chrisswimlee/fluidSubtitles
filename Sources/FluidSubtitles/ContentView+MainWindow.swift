import AppKit
import SwiftUI

/// Tags the SwiftUI shell window so launch can find it after the title changes.
struct MainWindowMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            MainWindowReveal.mark(nsView.window)
        }
    }
}
