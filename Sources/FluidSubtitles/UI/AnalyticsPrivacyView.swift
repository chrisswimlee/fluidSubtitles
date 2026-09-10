import SwiftUI

struct AnalyticsPrivacyView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Anonymous Analytics")
                        .font(.system(size: 18, weight: .semibold))
                    Text("This release does not send analytics")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Done") { self.dismiss() }
                    .buttonStyle(.bordered)
            }

            Divider().opacity(0.4)

            self.contactInfoView

            Divider().opacity(0.4)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    self.sectionTitle("This release")
                    self.bullet("\(FluidProduct.displayName) ships without an analytics endpoint. Nothing is sent to \(FluidProduct.authorName), FluidVoice, or a third-party analytics host.")
                    self.bullet("The optional detailed-analytics toggle is reserved for a future build that publishes an endpoint. Turning it on does not transmit data today.")

                    self.sectionTitle("We do NOT collect")
                    self.bullet("Any transcription text or audio.")
                    self.bullet("Selected text, rewrite prompts, or AI responses.")
                    self.bullet("Window titles, app names, file names/paths, clipboard contents, or anything you type.")
                    self.bullet("Hardware serial numbers or other unique device identifiers.")

                    self.sectionTitle("Local-first")
                    self.bullet("Voice, captions, and history stay on this Mac unless you opt in to a cloud AI provider.")
                    self.bullet("Optional cloud providers only receive what you send them after you add your own API key.")

                    self.sectionTitle("Questions")
                    self.bullet("Open a private security report or an issue if you think this policy is wrong. See SECURITY.md in the repository.")
                }
                .padding(.vertical, 6)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(self.theme.palette.contentBackground)
    }

    private var contactInfoView: some View {
        Text(self.contactInfoText)
            .font(.system(size: 13))
            .foregroundStyle(.primary)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(self.theme.palette.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(self.theme.palette.cardBorder.opacity(0.6), lineWidth: 1)
            )
    }

    private var contactInfoText: AttributedString {
        AttributedString(
            "\(FluidProduct.displayName) is local-first. This release does not send analytics."
        )
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(self.theme.palette.accent)
            .padding(.top, 4)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
    }
}
