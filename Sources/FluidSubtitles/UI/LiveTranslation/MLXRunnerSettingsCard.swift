import AppKit
import SwiftUI

struct MLXRunnerSettingsCard: View {
    var showsEnableToggle = true
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var runner = MLXRunnerService.shared
    @State private var pastedSpec = ""

    var body: some View {
        ThemedCard(style: .standard, hoverEffect: false) {
            VStack(alignment: .leading, spacing: 12) {
            FluidSectionHeader(title: "Local small LLM (experimental)")
            Text("Experimental. Plug in a downloaded MLX model or an LM Studio folder. A running model can sharpen the first print. It does not change a line already on Theater. Apple Translation stays the fallback.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if self.showsEnableToggle {
                Toggle("Use experimental local LLM", isOn: self.$settings.mlxRunnerEnabled)
                    .onChange(of: self.settings.mlxRunnerEnabled) { _, enabled in
                        if enabled {
                            Task { await self.runner.refresh() }
                        } else {
                            Task { await self.runner.stopAndWait() }
                        }
                    }
            }

            if self.settings.mlxRunnerEnabled {
                if self.runner.needsRuntimeInstall {
                    Text(self.runner.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Install MLX runtime") {
                        Task { await self.runner.setupRuntime() }
                    }
                    .disabled(self.runner.isBusy)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Picker("Model", selection: self.modelBinding) {
                    ForEach(self.runner.availableModels) { model in
                        Text(self.pickerLabel(for: model)).tag(model.id)
                    }
                }
                .labelsHidden()

                Text(self.runner.selectedModel.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                self.metadataLine

                VStack(alignment: .leading, spacing: 6) {
                    Text("LM Studio or a built MLX folder")
                        .font(.caption.weight(.medium))
                    TextField("Paste a folder path or org/model", text: self.$pastedSpec)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            Task { await self.usePasted() }
                        }
                    HStack {
                        Button("Use this") {
                            Task { await self.usePasted() }
                        }
                        .disabled(self.runner.isBusy || self.pastedSpec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Choose folder…") {
                            self.chooseFolder()
                        }
                        .disabled(self.runner.isBusy)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if let fraction = self.runner.downloadFraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                }

                Text(self.runner.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    if self.runner.selectedModel.isDownloadable {
                        Button(self.runner.isInstalled(self.settings.mlxRunnerModelID) ? "Re-download" : "Download") {
                            Task { await self.runner.download(self.settings.mlxRunnerModelID, force: true) }
                        }
                        .disabled(self.runner.isBusy)
                    }

                    if self.runner.status.running {
                        Button("Stop") {
                            Task { await self.runner.stopAndWait() }
                        }
                        .disabled(self.runner.isBusy)
                    } else {
                        Button("Start") {
                            Task { await self.runner.start() }
                        }
                        .disabled(self.runner.isBusy || !self.runner.isInstalled(self.settings.mlxRunnerModelID))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            }
        }
        .task {
            await self.runner.refresh()
        }
    }

    @ViewBuilder
    private var metadataLine: some View {
        let model = self.runner.selectedModel
        let ram = model.ramGB > 0 ? " · \(model.ramGB) GB RAM" : ""
        Text("\(model.languageLabel) · \(model.qualityLabel) · \(model.size)\(ram)")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { self.settings.mlxRunnerModelID },
            set: { newValue in
                Task { await self.runner.select(newValue) }
            }
        )
    }

    private func pickerLabel(for model: MLXRunnerModel) -> String {
        let installed = self.runner.isInstalled(model.id) ? " · Ready" : ""
        return "\(model.pickerTitle)\(installed)"
    }

    private func usePasted() async {
        let spec = self.pastedSpec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spec.isEmpty else { return }
        await self.runner.use(spec)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose an MLX model"
        panel.message = "Pick an LM Studio model folder or any built MLX directory. It should contain config.json."
        panel.prompt = "Use Folder"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        let lmstudio = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".lmstudio/models", isDirectory: true)
        if FileManager.default.fileExists(atPath: lmstudio.path) {
            panel.directoryURL = lmstudio
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        self.pastedSpec = url.path
        Task { await self.runner.use(url.path) }
    }
}
