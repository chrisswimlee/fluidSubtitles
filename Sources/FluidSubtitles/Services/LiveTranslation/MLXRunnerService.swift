import Combine
import Foundation

struct MLXRunnerStatus: Equatable {
    var selected: String
    var port: Int
    var running: Bool
    var pid: Int?
    var runningModel: String?
    var missingDependency: String?
    var runtimeReady: Bool
    var installedIDs: Set<String>
    var modelsDir: String?
    var lmstudioDir: String?

    static let empty = MLXRunnerStatus(
        selected: MLXRunnerCatalog.defaultModelID,
        port: MLXRunnerCatalog.defaultPort,
        running: false,
        pid: nil,
        runningModel: nil,
        missingDependency: nil,
        runtimeReady: false,
        installedIDs: [],
        modelsDir: nil,
        lmstudioDir: nil
    )
}

@MainActor
final class MLXRunnerService: ObservableObject {
    static let shared = MLXRunnerService()

    @Published private(set) var status = MLXRunnerStatus.empty
    @Published private(set) var availableModels = MLXRunnerCatalog.models
    @Published private(set) var statusText = "Checking local MLX…"
    @Published private(set) var isBusy = false
    @Published private(set) var downloadFraction: Double?

    private var serveProcess: Process?
    private var commandProcess: Process?
    private var pythonPath: String?
    private(set) var lastSuccessfulCallAt: Date?

    private init() {
        let selected = SettingsStore.shared.mlxRunnerModelID
        var models = MLXRunnerCatalog.models
        if let extra = MLXRunnerCatalog.model(id: selected), !models.contains(where: { $0.id == extra.id }) {
            models.append(extra)
        }
        self.availableModels = models
    }

    var baseURL: String {
        "http://127.0.0.1:\(SettingsStore.shared.mlxRunnerPort)/v1"
    }

    var selectedModel: MLXRunnerModel {
        MLXRunnerCatalog.model(id: SettingsStore.shared.mlxRunnerModelID, extras: self.availableModels)
            ?? self.availableModels.first { $0.recommended }
            ?? MLXRunnerCatalog.bundled.models[0]
    }

    var needsRuntimeInstall: Bool {
        !self.status.runtimeReady
    }

    var canServe: Bool {
        self.status.running
    }

    /// Start the runner if it is enabled and installed, then health-ping it.
    /// First polish used to require `lastSuccessfulCallAt`, so cleanup never started.
    func prepareToPolish() async -> Bool {
        guard SettingsStore.shared.mlxRunnerEnabled else { return false }
        await self.ensureRunning()
        if self.status.running {
            if self.lastSuccessfulCallAt == nil {
                _ = await self.isHealthy()
            }
            return true
        }
        return await self.isHealthy()
    }

    func markSuccessfulCall() {
        self.lastSuccessfulCallAt = Date()
    }

    func isInstalled(_ modelID: String) -> Bool {
        if self.status.installedIDs.contains(modelID) {
            return true
        }
        if let extra = self.availableModels.first(where: { $0.id == modelID }), extra.isLocalFolder {
            return extra.localHints.contains { FileManager.default.fileExists(atPath: $0 + "/config.json") }
                || FileManager.default.fileExists(atPath: extra.repo + "/config.json")
        }
        return false
    }

    func refresh() async {
        do {
            let payload = try await self.run(arguments: ["status"])
            self.applyStatus(payload)
        } catch {
            self.statusText = error.localizedDescription
        }
    }

    func setupRuntime() async {
        self.isBusy = true
        self.statusText = "Installing the local MLX runtime…"
        defer { self.isBusy = false }
        do {
            let payload = try await self.run(arguments: ["setup"], useSetupPython: true)
            if payload["ok"] as? Bool == false {
                self.statusText = payload["error"] as? String ?? "Could not install MLX."
            } else {
                self.pythonPath = nil
                self.statusText = "MLX runtime is ready."
            }
            await self.refresh()
        } catch {
            self.statusText = error.localizedDescription
        }
    }

    func select(_ modelID: String) async {
        let resolved = MLXRunnerCatalog.resolvedModelID(modelID, extras: self.availableModels)
        SettingsStore.shared.mlxRunnerModelID = resolved
        _ = try? await self.run(arguments: ["select", resolved])
        if self.status.running, self.status.runningModel != resolved, self.status.selected != resolved {
            await self.stopAndWait()
        }
        await self.refresh()
    }

    func use(_ raw: String) async {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        self.isBusy = true
        self.statusText = "Using \(trimmed)…"
        defer { self.isBusy = false }
        do {
            let payload = try await self.run(arguments: ["use", trimmed])
            if payload["ok"] as? Bool == false {
                self.statusText = payload["error"] as? String ?? "Could not use that model."
                await self.refresh()
                return
            }
            let selected = payload["id"] as? String ?? MLXRunnerCatalog.resolvedModelID(trimmed, extras: self.availableModels)
            SettingsStore.shared.mlxRunnerModelID = selected
            let installed = payload["installed"] as? Bool ?? false
            let selectedKind = MLXRunnerCatalog.parseSpec(selected).kind
            let pastedKind = MLXRunnerCatalog.parseSpec(trimmed).kind
            let shouldDownload = !installed && (
                selectedKind == .huggingface
                    || selectedKind == .catalog
                    || pastedKind == .huggingface
                    || pastedKind == .catalog
            )
            if shouldDownload {
                await self.download(selected, force: false)
                return
            }
            self.statusText = installed
                ? "Using \(self.displayName(for: selected)). Press Start to load it."
                : "Selected \(self.displayName(for: selected)). Download it first."
            await self.refresh()
        } catch {
            self.statusText = error.localizedDescription
        }
    }

    func download(_ modelID: String, force: Bool = false) async {
        let resolved = MLXRunnerCatalog.resolvedModelID(modelID, extras: self.availableModels)
        self.isBusy = true
        self.downloadFraction = 0
        self.statusText = "Downloading \(self.displayName(for: resolved))…"
        defer {
            self.isBusy = false
            self.downloadFraction = nil
        }
        do {
            var arguments = ["download", resolved]
            if force {
                arguments.append("--force")
            }
            let payload = try await self.run(arguments: arguments) { event in
                if let fraction = event["fraction"] as? Double {
                    self.downloadFraction = fraction
                }
                if let message = event["message"] as? String, !message.isEmpty {
                    self.statusText = message
                }
            }
            if payload["ok"] as? Bool == false {
                self.statusText = payload["error"] as? String ?? "Download failed."
            } else {
                SettingsStore.shared.mlxRunnerModelID = resolved
                self.statusText = payload["reused"] as? Bool == true
                    ? "Already on disk: \(self.displayName(for: resolved))."
                    : "Downloaded \(self.displayName(for: resolved))."
            }
            await self.refresh()
        } catch {
            self.statusText = error.localizedDescription
        }
    }

    func start() async {
        let modelID = SettingsStore.shared.mlxRunnerModelID
        guard self.isInstalled(modelID) else {
            self.statusText = self.selectedModel.isLocalFolder
                ? "Choose an MLX folder from LM Studio first."
                : "Download \(self.selectedModel.name) first."
            return
        }
        if await self.isHealthy(), self.status.runningModel == modelID || self.status.selected == modelID {
            self.status.running = true
            self.statusText = "Running on port \(SettingsStore.shared.mlxRunnerPort)."
            return
        }

        self.isBusy = true
        self.statusText = "Starting \(self.selectedModel.name)…"
        defer { self.isBusy = false }

        if self.status.running || self.serveProcess != nil {
            await self.stopAndWait(refreshAfter: false)
        }

        do {
            let process = try self.makeProcess(
                arguments: ["serve", "--model", modelID, "--port", String(SettingsStore.shared.mlxRunnerPort)]
            )
            process.terminationHandler = { [weak self] finished in
                Task { @MainActor in
                    guard let self else { return }
                    if self.serveProcess == finished {
                        self.serveProcess = nil
                        await self.refresh()
                    }
                }
            }
            self.serveProcess = process
            try process.run()
            let ready = await self.waitUntilHealthy(timeout: 120)
            if ready {
                self.status.running = true
                self.statusText = "Running \(self.selectedModel.name) on port \(SettingsStore.shared.mlxRunnerPort)."
            } else if process.isRunning {
                self.statusText = "The runner started but is not answering yet. Wait a few seconds and try again."
            } else {
                self.statusText = "The runner exited before it was ready."
            }
            await self.refresh()
        } catch {
            self.statusText = error.localizedDescription
        }
    }

    func stop() {
        Task { await self.stopAndWait() }
    }

    func stopAndWait(refreshAfter: Bool = true) async {
        let markedBusy = !self.isBusy
        if markedBusy {
            self.isBusy = true
            self.statusText = "Stopping the MLX runner…"
        }
        defer {
            if markedBusy {
                self.isBusy = false
            }
        }
        self.commandProcess?.terminate()
        self.commandProcess = nil
        if let process = self.serveProcess, process.isRunning {
            process.terminate()
        }
        _ = try? await self.run(arguments: ["stop"])
        if let process = self.serveProcess, process.isRunning {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if process.isRunning {
                process.terminate()
            }
        }
        self.serveProcess = nil
        if refreshAfter {
            await self.refresh()
        }
    }

    func ensureRunning() async {
        guard SettingsStore.shared.mlxRunnerEnabled else { return }
        await self.refresh()
        if await self.isHealthy(),
           self.status.runningModel == SettingsStore.shared.mlxRunnerModelID
            || self.status.selected == SettingsStore.shared.mlxRunnerModelID
        {
            return
        }
        if self.isInstalled(SettingsStore.shared.mlxRunnerModelID) {
            await self.start()
        }
    }

    func isHealthy() async -> Bool {
        if await self.pingModels() {
            self.lastSuccessfulCallAt = Date()
            return true
        }
        if await self.pingChat() {
            self.lastSuccessfulCallAt = Date()
            return true
        }
        return false
    }

    private func pingModels() async -> Bool {
        guard let url = URL(string: "\(self.baseURL)/models") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func pingChat() async -> Bool {
        guard let url = URL(string: "\(self.baseURL)/chat/completions") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 2
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer mlx-runner", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": self.selectedModel.repo,
            "messages": [["role": "user", "content": "."]],
            "max_tokens": 1,
            "stream": false,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func waitUntilHealthy(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await self.isHealthy() {
                return true
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return await self.isHealthy()
    }

    private func displayName(for modelID: String) -> String {
        MLXRunnerCatalog.model(id: modelID, extras: self.availableModels)?.name ?? modelID
    }

    private func applyStatus(_ payload: [String: Any]) {
        let models = self.parseModels(payload["models"] as? [[String: Any]] ?? [])
        let installed = Set(models.compactMap { model -> String? in
            guard model.1 else { return nil }
            return model.0.id
        })
        self.availableModels = self.mergeModels(models.map(\.0))
        let selected = payload["selected"] as? String ?? SettingsStore.shared.mlxRunnerModelID
        self.status = MLXRunnerStatus(
            selected: selected,
            port: payload["port"] as? Int ?? SettingsStore.shared.mlxRunnerPort,
            running: payload["running"] as? Bool ?? false,
            pid: payload["pid"] as? Int,
            runningModel: payload["running_model"] as? String,
            missingDependency: payload["missing_dependency"] as? String,
            runtimeReady: payload["runtime_ready"] as? Bool ?? false,
            installedIDs: installed,
            modelsDir: payload["models_dir"] as? String,
            lmstudioDir: payload["lmstudio_dir"] as? String
        )
        if !self.status.runtimeReady {
            self.statusText = "Install the MLX runtime once. It uses Homebrew Python 3.12, not 3.14."
        } else if self.status.running {
            self.statusText = "Running \(self.displayName(for: self.status.runningModel ?? selected)) on port \(self.status.port)."
        } else if installed.contains(selected) {
            self.statusText = "\(self.displayName(for: selected)) is ready. Press Start to load it."
        } else {
            self.statusText = "Pick a catalog model, an LM Studio folder, or a built MLX directory."
        }
    }

    private func parseModels(_ rows: [[String: Any]]) -> [(MLXRunnerModel, Bool)] {
        rows.compactMap { row in
            guard let id = row["id"] as? String,
                  let name = row["name"] as? String,
                  let repo = row["repo"] as? String
            else {
                return nil
            }
            let model = MLXRunnerModel(
                id: id,
                name: name,
                repo: repo,
                size: row["size"] as? String ?? "On disk",
                ramGB: row["ram_gb"] as? Int ?? 0,
                quality: row["quality"] as? String ?? "local",
                languages: row["languages"] as? [String] ?? ["ko", "en", "ja", "th"],
                recommended: row["recommended"] as? Bool ?? false,
                detail: row["detail"] as? String ?? "",
                localHints: row["local_hints"] as? [String] ?? [],
                source: row["source"] as? String ?? "catalog"
            )
            return (model, row["installed"] as? Bool ?? false)
        }
    }

    private func mergeModels(_ incoming: [MLXRunnerModel]) -> [MLXRunnerModel] {
        var seen = Set<String>()
        var merged: [MLXRunnerModel] = []
        for model in incoming + MLXRunnerCatalog.models {
            if seen.contains(model.id) { continue }
            seen.insert(model.id)
            merged.append(model)
        }
        let selected = SettingsStore.shared.mlxRunnerModelID
        if !seen.contains(selected), let extra = MLXRunnerCatalog.model(id: selected, extras: incoming) {
            merged.append(extra)
        }
        return merged
    }

    private func run(
        arguments: [String],
        useSetupPython: Bool = false,
        onEvent: (([String: Any]) -> Void)? = nil
    ) async throws -> [String: Any] {
        let process = try self.makeProcess(arguments: arguments, useSetupPython: useSetupPython)
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        self.commandProcess = process

        return try await withCheckedThrowingContinuation { continuation in
            let collector = MLXRunnerJSONCollector()
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let events = collector.ingest(String(data: handle.availableData, encoding: .utf8) ?? "")
                if !events.isEmpty {
                    Task { @MainActor in
                        events.forEach { onEvent?($0) }
                    }
                }
            }
            process.terminationHandler = { finished in
                stdout.fileHandleForReading.readabilityHandler = nil
                collector.ingest(String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
                Task { @MainActor in
                    if self.commandProcess == finished {
                        self.commandProcess = nil
                    }
                }
                let lastObject = collector.snapshot()
                if lastObject.isEmpty {
                    let errorText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    continuation.resume(
                        throwing: MLXRunnerError(
                            message: errorText.isEmpty
                                ? "MLX runner exited with status \(finished.terminationStatus)."
                                : errorText
                        )
                    )
                    return
                }
                continuation.resume(returning: lastObject)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func makeProcess(arguments: [String], useSetupPython: Bool = false) throws -> Process {
        guard let script = MLXRunnerCatalog.runnerScriptURL else {
            throw MLXRunnerError(message: "mlx_runner.py is missing from the app resources.")
        }
        let python = try self.resolvePython(forSetup: useSetupPython)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [script.path] + arguments
        process.standardInput = FileHandle.nullDevice
        process.qualityOfService = .userInitiated
        var environment = ProcessInfo.processInfo.environment
        if let catalog = MLXRunnerCatalog.catalogURL {
            environment["FLUID_MLX_CATALOG"] = catalog.path
        }
        process.environment = environment
        return process
    }

    private func resolvePython(forSetup: Bool = false) throws -> String {
        let support = AppSupportDirectory.url().appendingPathComponent("MLXRunner", isDirectory: true)
        let venv = support.appendingPathComponent("venv/bin/python3").path
        if !forSetup, FileManager.default.isExecutableFile(atPath: venv) {
            self.pythonPath = venv
            return venv
        }
        if let discovered = Self.discoverPython312() {
            if forSetup || !FileManager.default.isExecutableFile(atPath: venv) {
                return discovered
            }
        }
        if let pythonPath, FileManager.default.isExecutableFile(atPath: pythonPath) {
            return pythonPath
        }
        throw MLXRunnerError(
            message: "Python 3.12 was not found. Install it with brew install python@3.12, or set FLUID_PYTHON."
        )
    }

    static func discoverPython312() -> String? {
        var candidates: [String] = []
        if let fluidPython = ProcessInfo.processInfo.environment["FLUID_PYTHON"], !fluidPython.isEmpty {
            candidates.append(fluidPython)
        }
        if let fromPath = Self.whichExecutable("python3.12") {
            candidates.append(fromPath)
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/python3.12",
            "/usr/local/bin/python3.12",
        ])
        var seen = Set<String>()
        for path in candidates where seen.insert(path).inserted {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    private static func whichExecutable(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path, !path.isEmpty else { return nil }
        return path
    }
}

struct MLXRunnerError: LocalizedError {
    let message: String
    var errorDescription: String? { self.message }
}

private nonisolated final class MLXRunnerJSONCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lastObject: [String: Any] = [:]

    @discardableResult
    func ingest(_ text: String) -> [[String: Any]] {
        self.lock.lock()
        defer { self.lock.unlock() }
        var events: [[String: Any]] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            self.lastObject = object
            if object["event"] != nil {
                events.append(object)
            }
        }
        return events
    }

    func snapshot() -> [String: Any] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.lastObject
    }
}
