//
//  FeedbackView.swift
//  fluid
//
//  Extracted from ContentView.swift to reduce monolithic architecture.
//  Created: 2025-12-14
//

import AppKit
import SwiftUI

struct FeedbackView: View {
    @Environment(\.theme) private var theme

    // MARK: - State Variables (moved from ContentView)

    @State private var feedbackText: String = ""
    @State private var feedbackEmail: String = ""
    @State private var includeDebugLogs: Bool = false
    @State private var isSendingFeedback: Bool = false
    @State private var showFeedbackConfirmation: Bool = false
    @State private var showFeedbackError: Bool = false
    @State private var feedbackErrorMessage: String = ""
    @State private var appear: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                FluidPageHeader(
                    systemImage: "envelope.fill",
                    title: "Feedback",
                    subtitle: "Report a problem or suggest a change."
                )

                // Friendly Message & GitHub CTA
                ThemedCard(style: .prominent, hoverEffect: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(.pink)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("What should change?")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(self.theme.palette.primaryText)

                                Text("A short note is enough. It stays on this Mac until you paste it into GitHub.")
                                    .font(.system(size: 14))
                                    .foregroundStyle(self.theme.palette.secondaryText)
                            }
                        }

                        Divider()
                            .padding(.vertical, 4)

                        HStack(spacing: 12) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(.yellow)

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Loving \(FluidProduct.displayName)?")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(self.theme.palette.primaryText)

                                Text("\(FluidProduct.displayName) is by \(FluidProduct.authorName). The speech engine comes from FluidVoice. Star or sponsor that project if you want to support the upstream work.")
                                    .font(.system(size: 13))
                                    .foregroundStyle(self.theme.palette.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 8) {
                                Link(destination: FluidProduct.authorURL) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "globe")
                                        Text(FluidProduct.authorSiteHost)
                                            .fontWeight(.semibold)
                                    }
                                    .font(.system(size: 14))
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 10)
                                }
                                .fluidButton(.glass, size: .medium)
                                .buttonHoverEffect()

                                Link(destination: FluidProduct.upstreamURL) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "star.fill")
                                        Text("FluidVoice on GitHub")
                                            .fontWeight(.semibold)
                                    }
                                    .font(.system(size: 14))
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 10)
                                }
                                .fluidButton(.glass, size: .medium)
                                .buttonHoverEffect()
                            }
                        }
                    }
                }

                CommercialLicenseStatusCard()

                // Feedback Form
                ThemedCard(style: .standard, hoverEffect: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Email (optional)")
                                .font(.headline)
                                .fontWeight(.semibold)

                            TextField("your.email@example.com", text: self.$feedbackEmail)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 14))

                            Text("Feedback")
                                .font(.headline)
                                .fontWeight(.semibold)
                                .padding(.top, 8)

                            TextEditor(text: self.$feedbackText)
                                .font(.system(size: 14))
                                .frame(height: 120)
                                .padding(12)
                                .background(RoundedRectangle(cornerRadius: 8)
                                    .fill(self.theme.palette.contentBackground)
                                    .overlay(RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(self.theme.palette.cardBorder.opacity(0.45), lineWidth: 1.2)))
                                .scrollContentBackground(.hidden)
                                .overlay(
                                    Group {
                                        if self.feedbackText.isEmpty {
                                            Text("Share your thoughts, report bugs, or suggest features...")
                                                .font(.subheadline)
                                                .foregroundStyle(.secondary)
                                                .padding(.leading, 4)
                                        }
                                    }
                                    .allowsHitTesting(false)
                                )

                            // Debug logs option
                            Toggle("Include debug logs", isOn: self.$includeDebugLogs)
                                .toggleStyle(GlassToggleStyle())

                            // Send Button
                            HStack {
                                Spacer()

                                Button(action: {
                                    Task {
                                        await self.sendFeedback()
                                    }
                                }) {
                                    HStack(spacing: 8) {
                                        if self.isSendingFeedback {
                                            ProgressView()
                                                .fixedSize()
                                                .scaleEffect(0.8)
                                        } else {
                                            Image(systemName: "paperplane.fill")
                                        }
                                        Text(self.isSendingFeedback ? "Opening GitHub..." : "Open GitHub Issue")
                                            .fontWeight(.semibold)
                                    }
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 10)
                                }
                                .fluidButton(.glass, size: .medium)
                                .disabled(self.feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                    self.isSendingFeedback)
                                .buttonHoverEffect()
                            }
                        }
                    }
                }
                .modifier(CardAppearAnimation(delay: 0.1, appear: self.$appear))
            }
            .fluidPageContent()
        }
        .onAppear {
            self.appear = true
        }
        .alert("Draft Ready", isPresented: self.$showFeedbackConfirmation) {
            Button("OK") {}
        } message: {
            Text("The note is on your clipboard and in Application Support. GitHub is open so you can paste it. Nothing was uploaded.")
        }
        .alert("Could Not Open GitHub", isPresented: self.$showFeedbackError) {
            Button("Try Again") {
                Task {
                    await self.sendFeedback()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(self.feedbackErrorMessage)
        }
    }

    // MARK: - Feedback Functions

    private func sendFeedback() async {
        guard !self.feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        self.isSendingFeedback = true
        defer { self.isSendingFeedback = false }

        do {
            _ = try LocalFeedbackDraft.share(title: "\(FluidProduct.displayName) feedback", body: self.feedbackBody())
            self.showFeedbackConfirmation = true
            self.feedbackText = ""
            self.feedbackEmail = ""
            self.includeDebugLogs = false
        } catch {
            self.feedbackErrorMessage = error.localizedDescription
            self.showFeedbackError = true
        }
    }

    private func feedbackBody() -> String {
        var feedbackContent = self.feedbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = self.feedbackEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !email.isEmpty {
            feedbackContent += "\n\nContact: \(email)"
        }

        if self.includeDebugLogs {
            feedbackContent += "\n\n--- Debug Information ---\n"
            feedbackContent += "App Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")\n"
            feedbackContent += "Build: \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown")\n"
            feedbackContent += "macOS Version: \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
            feedbackContent += "Date: \(Date().formatted())\n\n"

            let logFileURL = FileLogger.shared.currentLogFileURL()
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                do {
                    let logContent = try String(contentsOf: logFileURL, encoding: .utf8)
                    let lines = logContent.components(separatedBy: .newlines)
                    let recentLines = Array(lines.suffix(30))
                    feedbackContent += "Recent Log Entries:\n"
                    feedbackContent += recentLines.joined(separator: "\n")
                } catch {
                    feedbackContent += "Could not read log file: \(error.localizedDescription)\n"
                }
            }
        }

        return feedbackContent
    }
}

#Preview {
    FeedbackView()
}
