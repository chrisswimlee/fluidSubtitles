import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Notes, a PDF, or a JSON name list for Translate. Names stay on the Mac.
struct TheaterTalkPackCard: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var settings = SettingsStore.shared
    @State private var loadError: String?

    var body: some View {
        ThemedCard(style: .standard, hoverEffect: false) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "doc.text")
                        .font(.title3)
                        .foregroundStyle(self.theme.palette.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Talk notes")
                            .font(self.theme.typography.bodyStrong)
                        Text(self.statusLine)
                            .font(self.theme.typography.bodySmall)
                            .foregroundStyle(self.theme.palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        if let preview = self.termPreview {
                            Text(preview)
                                .font(self.theme.typography.caption)
                                .foregroundStyle(self.theme.palette.secondaryText)
                                .lineLimit(1)
                                .accessibilityIdentifier("theater.talkPack.preview")
                        }
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 8) {
                        Button(self.settings.hasTheaterTalkPack ? "Replace" : "Import") {
                            self.importNotes()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .accessibilityIdentifier("theater.talkPack.import")
                        if self.settings.hasTheaterTalkPack {
                            Button("Remove") {
                                self.settings.clearTheaterTalkPack()
                                self.loadError = nil
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                            .accessibilityIdentifier("theater.talkPack.remove")
                        }
                    }
                }
                if let loadError {
                    Text(loadError)
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("theater.talkPack.error")
                }
            }
        }
        .help(TheaterReadiness.talkPack)
        .accessibilityIdentifier("theater.talkPack")
    }

    private var statusLine: String {
        if self.settings.hasTheaterTalkPack {
            let name = self.settings.theaterTalkPackFileName.isEmpty
                ? "Notes"
                : self.settings.theaterTalkPackFileName
            let count = self.settings.theaterTalkPackTerms.count
            return "\(name) · \(count) names locked on this Mac."
        }
        return TheaterReadiness.talkPack
    }

    private var termPreview: String? {
        let terms = self.settings.theaterTalkPackTerms.prefix(3)
        guard !terms.isEmpty else { return nil }
        return terms.joined(separator: " · ")
    }

    private func importNotes() {
        let panel = NSOpenPanel()
        panel.title = "Import talk notes"
        panel.message = TheaterReadiness.talkPack
        panel.prompt = "Use File"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            .plainText,
            UTType(filenameExtension: "md") ?? .plainText,
            .pdf,
            .json,
            .rtf,
        ]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let document = try TheaterTalkPack.load(from: url)
            self.settings.applyTheaterTalkPack(document)
            self.loadError = nil
        } catch {
            self.loadError = error.localizedDescription
        }
    }
}
