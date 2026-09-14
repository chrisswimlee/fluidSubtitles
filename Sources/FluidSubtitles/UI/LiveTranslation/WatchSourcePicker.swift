import SwiftUI

struct WatchSourcePicker: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var controller = LiveTranslationController.shared
    var compact = false
    var showsCheckCapture = false
    var accessibilityIdentifier = "theater.watchSource"

    @State private var isProbing = false
    @State private var pendingBundleID: String?
    @State private var showSourceChangeConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: self.compact && !self.showsCheckCapture ? 0 : 6) {
            if !self.compact {
                Text("Capture")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
            Picker("Capture", selection: self.binding) {
                Text("This Mac").tag("")
                ForEach(self.options) { app in
                    Text(app.title).tag(app.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(self.compact ? .small : .regular)
            .accessibilityLabel("Watch capture source")
            .accessibilityIdentifier(self.accessibilityIdentifier)
            if !self.compact {
                Text(WatchCaptureStop.helperHonestyCopy)
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if self.showsCheckCapture {
                Button(self.isProbing ? "Checking…" : "Check capture") {
                    self.runProbe()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(self.isProbing || self.controller.isSessionActive)
                .help("Starts a short ScreenCaptureKit tap and reports whether audio arrived.")
                .accessibilityLabel("Check capture")
                .accessibilityIdentifier(
                    self.compact ? "theater.window.checkCapture" : "theater.checkCapture"
                )
            }
        }
        .alert("Change Watch source?", isPresented: self.$showSourceChangeConfirm) {
            Button("Cancel", role: .cancel) {
                self.pendingBundleID = nil
            }
            Button("Change and Stop", role: .destructive) {
                self.applyPendingSourceChange()
            }
        } message: {
            Text(TheaterReadiness.watchSourceStopsListen)
        }
    }

    private var options: [WatchCaptureApp] {
        let selectedID = WatchSourceSettings.selectedBundleID(self.settings)
        let including: WatchCaptureApp?
        if !selectedID.isEmpty {
            including = WatchCaptureApp(id: selectedID, title: WatchAppCatalog.title(for: selectedID))
        } else {
            including = nil
        }
        return WatchAppCatalog.apps(including: including)
    }

    private var binding: Binding<String> {
        Binding(
            get: { WatchSourceSettings.selectedBundleID(self.settings) },
            set: { bundleID in
                let current = WatchSourceSettings.selectedBundleID(self.settings)
                guard bundleID != current else { return }
                if self.controller.isSessionActive, self.controller.listenKind == .captions {
                    self.pendingBundleID = bundleID
                    self.showSourceChangeConfirm = true
                    return
                }
                _ = WatchSourceSettings.apply(bundleID, to: self.settings)
            }
        )
    }

    private func applyPendingSourceChange() {
        guard let bundleID = self.pendingBundleID else { return }
        self.pendingBundleID = nil
        let changed = WatchSourceSettings.apply(bundleID, to: self.settings)
        if changed {
            self.controller.stopListening()
        }
    }

    private func runProbe() {
        self.isProbing = true
        Task {
            let outcome = await WatchCaptureProbe.run()
            self.controller.reportListenStatus(
                WatchCaptureProbe.message(for: outcome),
                kind: WatchCaptureProbe.statusKind(for: outcome)
            )
            self.isProbing = false
        }
    }
}
