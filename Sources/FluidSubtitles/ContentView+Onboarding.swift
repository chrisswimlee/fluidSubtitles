//
//  ContentView+Onboarding.swift
//  fluid
//
//  Onboarding completion and dictation recording start.
//

import AppKit
import AVFoundation
import Foundation
import SwiftUI

// MARK: - ContentView Playground & Onboarding Helpers

extension ContentView {
    func buildSystemPrompt(
        appInfo: (name: String, bundleId: String, windowTitle: String),
        dictationSlot: SettingsStore.DictationShortcutSlot? = nil
    ) -> String {
        if let slot = dictationSlot ?? self.currentDictationShortcutSlot(for: self.activeRecordingMode) {
            return SettingsStore.shared.effectiveDictationSystemPrompt(for: slot, appBundleID: appInfo.bundleId)
        }
        return SettingsStore.shared.effectiveSystemPrompt(for: .dictate, appBundleID: appInfo.bundleId)
    }

    var shouldTracePromptProcessing: Bool {
        self.forcePromptTraceToConsole ||
            UserDefaults.standard.bool(forKey: "EnableDebugLogs")
    }

    var forcePromptTraceToConsole: Bool {
        ProcessInfo.processInfo.environment["FLUID_PROMPT_TRACE"] == "1"
    }

    func logDictationPromptTrace(_ title: String, value: String) {
        let line = "[PromptTrace][Dictate] \(title):\n\(value)"
        if self.forcePromptTraceToConsole {
            print(line)
        }
        DebugLogger.shared.debug(line, source: "ContentView")
    }

    func customPromptAnalyticsProperties(promptSource: String, overrideEmpty: Bool?) -> [String: Any] {
        let providerID = SettingsStore.shared.selectedProviderID
        let providerKey = self.providerKey(for: providerID)
        let selectedModel = SettingsStore.shared.selectedModelByProvider[providerKey] ?? SettingsStore.shared.selectedModel ?? ""
        let isCustomProvider = !ModelRepository.shared.isBuiltIn(providerID)
        let providerName = isCustomProvider ? "Custom Provider" : ModelRepository.shared.displayName(for: providerID)

        var properties: [String: Any] = [
            "prompt_source": promptSource,
            "provider_id": isCustomProvider ? "custom" : providerID,
            "provider_name": providerName,
            "provider_type": isCustomProvider ? "custom" : "built_in",
        ]
        if !selectedModel.isEmpty {
            properties["model"] = isCustomProvider ? "custom" : selectedModel
        }
        if let overrideEmpty {
            properties["override_empty"] = overrideEmpty
        }
        return properties
    }

    func isLocalEndpoint(_ urlString: String) -> Bool {
        ModelRepository.shared.isLocalEndpoint(urlString)
    }

    func currentDictationShortcutSlot(for mode: ActiveRecordingMode) -> SettingsStore.DictationShortcutSlot? {
        switch mode {
        case .dictate:
            return self.activeDictationShortcutSlot ?? .primary
        case .promptMode:
            return self.activeDictationShortcutSlot ?? .secondary
        case .none:
            return nil
        }
    }

    func clearActiveDictationShortcutState() {
        self.activeDictationShortcutSlot = nil
        self.promptModeOverrideText = nil
        NotchContentState.shared.activeDictationShortcutSlot = nil
        NotchContentState.shared.promptModeOverrideProfileName = nil
        NotchContentState.shared.promptModeOverrideProfileID = nil
        NotchContentState.shared.isPromptModeActive = false
    }

    func applyDictationShortcutSelectionContext(for slot: SettingsStore.DictationShortcutSlot) {
        let settings = SettingsStore.shared
        self.activeDictationShortcutSlot = slot
        NotchContentState.shared.activeDictationShortcutSlot = slot
        NotchContentState.shared.isPromptModeActive = (slot == .secondary)

        switch settings.dictationPromptSelection(for: slot) {
        case .off, .default:
            self.promptModeOverrideText = nil
            NotchContentState.shared.promptModeOverrideProfileName = nil
            NotchContentState.shared.promptModeOverrideProfileID = nil
        case .privateAI:
            self.promptModeOverrideText = nil
            NotchContentState.shared.promptModeOverrideProfileName = PrivateAIProviderFeature.displayName
            NotchContentState.shared.promptModeOverrideProfileID = PrivateAIProviderPromptFormat.promptSelectionID
        case let .profile(profileID):
            guard let profile = settings.selectedDictationPromptProfile(for: slot) ?? settings.dictationPromptProfiles.first(where: {
                $0.id == profileID && $0.mode.normalized == .dictate
            }) else {
                settings.setDictationPromptSelection(.default, for: slot)
                self.promptModeOverrideText = nil
                NotchContentState.shared.promptModeOverrideProfileName = nil
                NotchContentState.shared.promptModeOverrideProfileID = nil
                return
            }

            self.promptModeOverrideText = settings.shortcutOverrideSystemPrompt(for: profile, mode: .dictate)
            NotchContentState.shared.promptModeOverrideProfileName = profile.name
            NotchContentState.shared.promptModeOverrideProfileID = profile.id
        }
    }

    func beginDictationRecording(
        for slot: SettingsStore.DictationShortcutSlot,
        mode: ActiveRecordingMode
    ) {
        DebugLogger.shared.debug("Begin dictation recording for slot \(slot.rawValue)", source: "ContentView")
        self.appBench("begin_recording slot=\(slot.rawValue) mode=\(mode.rawValue)")
        SpokenLanguageResolver.pinWhisperToSpokenSource()
        if self.isOnboardingVoicePlaygroundStepActive {
            self.asr.finalText = ""
            self.settings.onboardingPlaygroundValidated = false
            self.settings.onboardingPlaygroundSkipped = false
            self.settings.playgroundUsed = false
            self.playgroundUsed = false
        }
        self.applyDictationShortcutSelectionContext(for: slot)
        self.setActiveRecordingMode(mode)

        guard !self.asr.isRunningOrStarting else {
            self.appBench("asr_start_skipped reason=already_running_or_starting")
            return
        }
        self.advanceOverlayLifecycle()
        if self.asr.micStatus == .authorized {
            self.appBench("overlay_mode_request mode=Dictation")
            self.menuBarManager.setOverlayMode(.dictation)
            self.menuBarManager.showRecordingOverlayImmediately()
            self.appBench("overlay_mode_requested mode=Dictation")
            self.appBench("overlay_phase phase=connecting")
        }
        Task {
            let asrStartStartedAt = ProcessInfo.processInfo.systemUptime
            DebugLogger.shared.benchmark("APP_BENCH", message: "asr_start_call", source: "AppBenchmark")
            let startOutcome = await self.asr.start(onCaptureStarted: {
                if SettingsStore.shared.enableTranscriptionSounds {
                    TranscriptionSoundPlayer.shared.playStartSound()
                }
                self.captureRecordingContext()
                self.prewarmPrivateAIDictationIfNeeded(for: slot)
                self.appBench("overlay_phase phase=recording trigger=first_pcm")
            })
            if startOutcome == .failed {
                self.menuBarManager.hideRecordingOverlayImmediately(reason: "asr_start_failed")
            }
            DebugLogger.shared.benchmark(
                "APP_BENCH",
                message: "asr_start_return elapsedMs=\(Int(((ProcessInfo.processInfo.systemUptime - asrStartStartedAt) * 1000).rounded()))",
                source: "AppBenchmark"
            )
        }
    }

    func beginDictationRecording(for selection: SettingsStore.DictationPromptSelection, mode: ActiveRecordingMode) {
        let settings = SettingsStore.shared
        settings.setDictationPromptSelection(selection, for: .secondary)
        self.beginDictationRecording(for: .secondary, mode: mode)
    }

    func appBench(_ message: String) {
        DebugLogger.shared.benchmark("APP_BENCH", message: message, source: "AppBenchmark")
    }

    func logAIProcessCall(
        _ pipelineID: String,
        _ modelInfo: (provider: String?, model: String?),
        _ inputChars: Int
    ) {
        let provider = (modelInfo.provider ?? "unknown").replacingOccurrences(of: " ", with: "_")
        let model = (modelInfo.model ?? "unknown").replacingOccurrences(of: " ", with: "_")
        self.appBench(
            "ai_process_call id=\(pipelineID) provider=\(provider) model=\(model) inputChars=\(inputChars)"
        )
    }

    func callOpenAIChat() async {
        guard !self.isCallingAI else { return }
        await MainActor.run { self.isCallingAI = true }
        defer { Task { await MainActor.run { isCallingAI = false } } }

        do {
            let result = try await processTextWithAI(aiInputText)
            await MainActor.run { self.aiOutputText = result }
        } catch {
            DebugLogger.shared.error("callOpenAIChat failed: \(error.localizedDescription)", source: "ContentView")
            await MainActor.run { self.aiOutputText = "Error: \(error.localizedDescription)" }
        }
    }

    func getModelStatusText() -> String {
        if self.asr.isLoadingModel {
            return "Loading model into memory... (30-60 sec)"
        } else if self.asr.isDownloadingModel {
            return "Downloading model... Please wait."
        } else if self.asr.isAsrReady {
            return "Model is ready to use!"
        } else if self.asr.modelsExistOnDisk {
            return "Model cached. Will load on first use."
        } else {
            return "Model will download when needed."
        }
    }

    var onboardingVoiceModelReady: Bool {
        self.asr.isAsrReady
    }

    var onboardingMicrophoneReady: Bool {
        self.asr.micStatus == .authorized
    }

    var onboardingAccessibilityReady: Bool {
        self.accessibilityEnabled
    }

    var onboardingPlaygroundReady: Bool {
        self.settings.onboardingPlaygroundValidated || self.settings.onboardingPlaygroundSkipped
    }

    @MainActor
    func revealAppInFinder() {
        let appPath = Bundle.main.bundlePath
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: appPath)])
    }

    func openApplicationsFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
    }
}

// MARK: - ContentView Accessibility & Lifecycle Helpers

extension ContentView {
    func completeOnboardingIfPossible(selecting target: SidebarItem? = nil) {
        let missingRequirements = self.missingOnboardingCompletionRequirements()
        guard missingRequirements.isEmpty else {
            self.presentOnboardingCompletionBlocked(missingRequirements)
            return
        }

        self.completeOnboarding(selecting: target)
    }

    func completeOnboarding(selecting target: SidebarItem? = nil) {
        self.settings.onboardingCompleted = true
        self.navigateToApp(target ?? .liveTranslation)
    }

    func missingOnboardingCompletionRequirements() -> [String] {
        var missing: [String] = []

        if !self.onboardingVoiceModelReady {
            missing.append("voice model")
        }
        if !self.onboardingMicrophoneReady {
            missing.append("microphone access")
        }
        if !self.onboardingPlaygroundReady {
            missing.append("test or skip")
        }

        return missing
    }

    func presentOnboardingCompletionBlocked(_ missingRequirements: [String]) {
        let missingText = missingRequirements.joined(separator: ", ")
        DebugLogger.shared.warning(
            "Onboarding completion blocked; missing=\(missingText)",
            source: "ContentView"
        )
        self.asr.errorTitle = "Setup Isn't Complete"
        self.asr.errorMessage = "Finish \(missingText) to continue."
        self.asr.showError = true
    }

    func labelFor(status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "Microphone: Authorized"
        case .denied: return "Microphone: Denied"
        case .restricted: return "Microphone: Restricted"
        case .notDetermined: return "Microphone: Not Determined"
        @unknown default: return "Microphone: Unknown"
        }
    }

    func checkAccessibilityPermissions() -> Bool {
        return AXIsProcessTrusted()
    }

    @discardableResult
    func refreshAccessibilityPermissionState() -> Bool {
        let trusted = self.checkAccessibilityPermissions()
        if trusted != self.accessibilityEnabled {
            self.accessibilityEnabled = trusted
        }
        return trusted
    }

    func openAccessibilitySettings() {
        let requestID = UUID()
        self.accessibilityGuideRequestID = requestID

        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        self.didOpenAccessibilityPane = true
        UserDefaults.standard.set(true, forKey: self.accessibilityRestartFlagKey)
        self.startAccessibilityPolling()
        self.positionWindowBesideSystemSettings(requestID: requestID)
        self.showAccessibilityGuidePanel(requestID: requestID)
        self.activateSystemSettingsSoon(requestID: requestID)
    }

    func positionWindowBesideSystemSettings(requestID: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            guard self.accessibilityGuideRequestID == requestID else { return }
            guard let window = NSApp.windows.first(where: { $0.isVisible && ($0.title == FluidProduct.displayName || $0.title == "connectingCaptions" || $0.title == "Fluid Translate" || $0.title == "FluidVoice") }) ?? NSApp.keyWindow else {
                return
            }

            let screen = self.systemSettingsWindowFrame()
                .flatMap { settingsFrame in
                    NSScreen.screens.first { $0.frame.intersects(settingsFrame) }
                } ?? window.screen ?? NSScreen.main
            guard let screen else { return }

            let visibleFrame = screen.visibleFrame
            let currentSize = window.frame.size
            let guideWidth = min(currentSize.width, max(640, visibleFrame.width * 0.42))
            let guideHeight = min(currentSize.height, visibleFrame.height - 56)
            let targetSize = NSSize(width: guideWidth, height: guideHeight)

            let settingsFrame = self.systemSettingsWindowFrame()
            let gap: CGFloat = 20
            let targetX: CGFloat
            if let settingsFrame, settingsFrame.maxX + gap + targetSize.width <= visibleFrame.maxX {
                targetX = settingsFrame.maxX + gap
            } else if let settingsFrame, settingsFrame.minX - gap - targetSize.width >= visibleFrame.minX {
                targetX = settingsFrame.minX - gap - targetSize.width
            } else {
                targetX = visibleFrame.maxX - targetSize.width - 24
            }

            let targetY: CGFloat
            if let settingsFrame {
                targetY = min(
                    visibleFrame.maxY - targetSize.height - 16,
                    max(visibleFrame.minY + 16, settingsFrame.maxY - targetSize.height)
                )
            } else {
                targetY = visibleFrame.midY - (targetSize.height / 2)
            }

            window.setFrame(
                NSRect(origin: NSPoint(x: targetX, y: targetY), size: targetSize),
                display: true,
                animate: true
            )
            window.orderBack(nil)
        }
    }

    func systemSettingsWindowFrame() -> NSRect? {
        guard let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for info in windowList {
            guard (info[kCGWindowOwnerName as String] as? String) == "System Settings",
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? CGFloat,
                  let y = bounds["Y"] as? CGFloat,
                  let width = bounds["Width"] as? CGFloat,
                  let height = bounds["Height"] as? CGFloat,
                  width > 0,
                  height > 0
            else {
                continue
            }

            for screen in NSScreen.screens {
                let convertedFrame = NSRect(
                    x: x,
                    y: screen.frame.maxY - y - height,
                    width: width,
                    height: height
                )
                if screen.frame.intersects(convertedFrame) {
                    return convertedFrame
                }
            }

            let convertedY = (NSScreen.main?.frame.maxY ?? 0) - y - height
            return NSRect(x: x, y: convertedY, width: width, height: height)
        }

        return nil
    }

    func showAccessibilityGuidePanel(requestID: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
            guard self.accessibilityGuideRequestID == requestID else { return }
            guard !self.refreshAccessibilityPermissionState() else {
                self.finishAccessibilityPermissionFlow()
                return
            }

            let settingsFrame = self.systemSettingsWindowFrame()
            let screen = settingsFrame
                .flatMap { frame in NSScreen.screens.first { $0.frame.intersects(frame) } } ?? NSScreen.main
            guard let screen else { return }

            let visibleFrame = screen.visibleFrame
            let panelWidth = min(max((settingsFrame?.width ?? visibleFrame.width * 0.48) * 0.86, 520), 760)
            let panelHeight: CGFloat = 132
            let gap: CGFloat = 14

            let panelX: CGFloat
            let panelY: CGFloat
            if let settingsFrame {
                panelX = min(
                    visibleFrame.maxX - panelWidth - 16,
                    max(visibleFrame.minX + 16, settingsFrame.midX - (panelWidth / 2))
                )
                panelY = max(visibleFrame.minY + 16, settingsFrame.minY - panelHeight - gap)
            } else {
                panelX = visibleFrame.midX - (panelWidth / 2)
                panelY = visibleFrame.minY + 120
            }

            let frame = NSRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight)
            let panel = self.accessibilityGuidePanel ?? NSPanel(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )

            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.contentView = NSHostingView(
                rootView: AccessibilitySettingsFloatingGuideView(
                    appURL: self.draggableAccessibilityAppURL,
                    appName: self.accessibilityAppDisplayName,
                    onReturnToApp: {
                        self.cancelAccessibilityPermissionFlow()
                    },
                    onClose: {
                        self.cancelAccessibilityPermissionFlow()
                    }
                )
            )
            panel.setFrame(frame, display: true, animate: self.accessibilityGuidePanel != nil)
            panel.orderFrontRegardless()
            self.accessibilityGuidePanel = panel
            self.startAccessibilityGuidePanelMonitor()
            self.activateSystemSettingsSoon(requestID: requestID)
        }
    }

    func activateSystemSettingsSoon(requestID: UUID) {
        for delay in [0.25, 0.85, 1.45] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard self.accessibilityGuideRequestID == requestID else { return }
                self.activateSystemSettings()
            }
        }
    }

    func activateSystemSettings() {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.SystemSettings" }) ??
            NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.systempreferences" }) ??
            NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == "System Settings" })
        {
            app.activate(options: [])
        }
    }

    func cancelAccessibilityPermissionFlow() {
        self.finishAccessibilityPermissionFlow()
        NSApp.activate(ignoringOtherApps: true)
        (NSApp.windows.first { $0.isVisible && ($0.title == FluidProduct.displayName || $0.title == "connectingCaptions" || $0.title == "Fluid Translate" || $0.title == "FluidVoice") } ?? NSApp.keyWindow)?
            .makeKeyAndOrderFront(nil)
    }

    func finishAccessibilityPermissionFlow() {
        self.accessibilityGuideRequestID = nil
        self.didOpenAccessibilityPane = false
        self.showRestartPrompt = false
        UserDefaults.standard.set(false, forKey: self.accessibilityRestartFlagKey)
        self.closeAccessibilityGuidePanel()
        self.stopAccessibilityPolling()
    }

    func closeAccessibilityGuidePanel() {
        self.accessibilityGuideMonitorTask?.cancel()
        self.accessibilityGuideMonitorTask = nil
        self.accessibilityGuidePanel?.close()
        self.accessibilityGuidePanel = nil
    }

    func startAccessibilityGuidePanelMonitor() {
        self.accessibilityGuideMonitorTask?.cancel()
        self.accessibilityGuideMonitorTask = Task {
            var missingSettingsCount = 0

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 900_000_000)

                let isTrusted = AXIsProcessTrusted()
                let settingsFrame = await MainActor.run {
                    self.systemSettingsWindowFrame()
                }

                if isTrusted {
                    await MainActor.run {
                        self.refreshAccessibilityPermissionState()
                        self.finishAccessibilityPermissionFlow()
                    }
                    return
                }

                if settingsFrame == nil {
                    missingSettingsCount += 1
                } else {
                    missingSettingsCount = 0
                }

                if missingSettingsCount >= 3 {
                    await MainActor.run {
                        self.cancelAccessibilityPermissionFlow()
                    }
                    return
                }
            }
        }
    }

    var draggableAccessibilityAppURL: URL {
        let runningAppURL = Bundle.main.bundleURL
        if runningAppURL.pathExtension == "app",
           FileManager.default.fileExists(atPath: runningAppURL.path)
        {
            return runningAppURL
        }

        let installedCandidates = [
            "/Applications/fluidSubtitles.app",
            "/Applications/\(FluidProduct.displayName).app",
        ]
        for path in installedCandidates {
            let installedURL = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: installedURL.path) {
                return installedURL
            }
        }
        return Bundle.main.bundleURL
    }

    var accessibilityAppDisplayName: String {
        Bundle.main.fluidAppDisplayName
    }

    func restartApp() {
        let appPath = Bundle.main.bundlePath
        let process = Process()
        process.launchPath = "/usr/bin/open"
        process.arguments = ["-n", appPath]
        // Clear pending flag and hide prompt before restarting
        UserDefaults.standard.set(false, forKey: self.accessibilityRestartFlagKey)
        self.showRestartPrompt = false
        try? process.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.terminate(nil)
        }
    }

    func startAccessibilityPolling() {
        // Keep polling until macOS reports the current process is trusted. The restart guard
        // only prevents restart loops; it must not prevent the UI from noticing permission changes.
        guard !self.accessibilityEnabled else { return }

        // Cancel any existing polling task
        self.accessibilityPollingTask?.cancel()

        // Start background polling
        self.accessibilityPollingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000) // Poll every 2 seconds

                // Check if permission was granted
                let nowTrusted = AXIsProcessTrusted()
                if nowTrusted && !self.accessibilityEnabled {
                    await MainActor.run {
                        DebugLogger.shared.info("Accessibility permission granted", source: "ContentView")
                        self.refreshAccessibilityPermissionState()
                        self.finishAccessibilityPermissionFlow()

                        guard !UserDefaults.standard.bool(forKey: self.hasAutoRestartedForAccessibilityKey) else {
                            self.hotkeyManager?.reinitialize()
                            return
                        }

                        // Mark that we've auto-restarted to prevent loops.
                        UserDefaults.standard.set(true, forKey: self.hasAutoRestartedForAccessibilityKey)
                        DebugLogger.shared.info("Auto-restarting app after accessibility grant", source: "ContentView")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            self.restartApp()
                        }
                    }
                    break // Stop polling after triggering restart
                }
            }
        }
    }

    func stopAccessibilityPolling() {
        self.accessibilityPollingTask?.cancel()
        self.accessibilityPollingTask = nil
    }
}

// swiftlint:enable type_body_length

@MainActor
enum SidebarSymbolCache {
    static let symbolNames = [
        "waveform",
        "brain",
        "cpu",
        "wand.and.stars",
        "text.book.closed.fill",
        "terminal.fill",
        "doc.text.fill",
        "clock.arrow.circlepath",
        "chart.bar.fill",
        "house.fill",
        "doc.text.magnifyingglass",
        "envelope.fill",
    ]

    static let images: [String: NSImage] = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            .applying(.preferringHierarchical())
        var images: [String: NSImage] = [:]

        for name in symbolNames {
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
            else { continue }

            image.isTemplate = true
            image.cacheMode = .always
            images[name] = image
        }

        return images
    }()

    static func image(named name: String) -> NSImage {
        self.images[name] ?? NSImage(systemSymbolName: "questionmark", accessibilityDescription: nil) ?? NSImage()
    }
}

    struct SidebarChromeButtonStyle: ButtonStyle {
    let isHovered: Bool
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        let scale = self.reduceMotion || !configuration.isPressed ? 1 : 0.985

        configuration.label
            .foregroundStyle(.primary)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(self.backgroundOpacity(isPressed: configuration.isPressed)))
            )
            .scaleEffect(scale)
            .animation(.easeOut(duration: self.reduceMotion ? 0.08 : 0.1), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.1), value: self.isHovered)
    }

    func backgroundOpacity(isPressed: Bool) -> Double {
        if isPressed {
            return 0.12
        }
        return self.isHovered ? 0.08 : 0
    }
}

extension View {
    func sidebarOptionHover(isSelected: Bool, reduceMotion: Bool) -> some View {
        modifier(SidebarOptionHoverModifier(isSelected: isSelected, reduceMotion: reduceMotion))
    }
}

struct SidebarOptionHoverModifier: ViewModifier {
    let isSelected: Bool
    let reduceMotion: Bool

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(self.backgroundColor)
            )
            .padding(.horizontal, -5)
            .padding(.vertical, -3)
            .contentShape(Rectangle())
            .onHover { self.isHovered = $0 }
            .animation(.easeOut(duration: self.reduceMotion ? 0.08 : 0.12), value: self.isHovered)
    }

    var backgroundColor: Color {
        if self.isSelected {
            return self.theme.palette.accent
        }
        return Color.primary.opacity(self.isHovered ? 0.08 : 0)
    }
}

struct AccessibilitySettingsFloatingGuideView: View {
    let appURL: URL
    let appName: String
    let onReturnToApp: () -> Void
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isArrowRaised = false
    @State private var isTokenHovered = false

    var appIcon: NSImage {
        NSWorkspace.shared.icon(forFile: self.appURL.path)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(FluidOnboardingLandingColors.blue)
                    .offset(y: self.reduceMotion ? 0 : (self.isArrowRaised ? -8 : 4))
                    .animation(
                        self.reduceMotion ? nil : .easeInOut(duration: 0.85).repeatForever(autoreverses: true),
                        value: self.isArrowRaised
                    )

                Text("Drag \(self.appName) into the Accessibility apps list as shown")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)

                Spacer()

                Button {
                    self.onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.58))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white.opacity(0.075)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Close guide")
            }

            HStack(spacing: 12) {
                Button {
                    self.onReturnToApp()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.white.opacity(0.075)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Return to \(self.appName)")

                Image(nsImage: self.appIcon)
                    .resizable()
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Text(self.appName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))

                Spacer()

                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white.opacity(0.38))
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(self.isTokenHovered ? 0.095 : 0.055))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(self.isTokenHovered ? 0.16 : 0.08), lineWidth: 1)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onHover { isHovered in
                if self.reduceMotion {
                    self.isTokenHovered = isHovered
                } else {
                    withAnimation(.easeOut(duration: 0.14)) {
                        self.isTokenHovered = isHovered
                    }
                }
            }
            .onDrag {
                NSItemProvider(object: self.appURL as NSURL)
            }
            .accessibilityLabel("Drag \(self.appName) to the Accessibility list")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.11, green: 0.11, blue: 0.13).opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
        )
        .onAppear {
            guard !self.reduceMotion else { return }
            self.isArrowRaised = true
        }
    }
}

extension ContentView {
    func reloadSettingsStateAfterBackupRestore() {
        self.primaryDictationShortcuts = SettingsStore.shared.primaryDictationShortcuts
        self.promptModeHotkeyShortcut = SettingsStore.shared.promptModeHotkeyShortcut
        self.cancelRecordingHotkeyShortcut = SettingsStore.shared.cancelRecordingHotkeyShortcut
        self.isPromptModeShortcutEnabled = SettingsStore.shared.promptModeShortcutEnabled
        self.playgroundUsed = SettingsStore.shared.playgroundUsed
        self.visualizerNoiseThreshold = SettingsStore.shared.visualizerNoiseThreshold
        self.selectedOutputUID = SettingsStore.shared.preferredOutputDeviceUID ?? ""
        self.enableDebugLogs = SettingsStore.shared.enableDebugLogs
        self.hotkeyMode = SettingsStore.shared.hotkeyMode
        self.enableStreamingPreview = SettingsStore.shared.enableStreamingPreview
        self.copyToClipboard = SettingsStore.shared.copyTranscriptionToClipboard
        self.launchAtStartup = SettingsStore.shared.launchAtStartup
        self.showInDock = SettingsStore.shared.showInDock
        self.availableModelsByProvider = SettingsStore.shared.availableModelsByProvider
        self.selectedModelByProvider = SettingsStore.shared.selectedModelByProvider
        self.savedProviders = SettingsStore.shared.savedProviders
        self.selectedProviderID = SettingsStore.shared.selectedProviderID

        self.hotkeyManager?.updatePrimaryShortcuts(self.primaryDictationShortcuts)
        self.hotkeyManager?.updatePromptModeShortcut(self.promptModeHotkeyShortcut)
        self.hotkeyManager?.updatePromptModeShortcutEnabled(self.isPromptModeShortcutEnabled)
        self.hotkeyManager?.updatePromptShortcutAssignments(SettingsStore.shared.dictationPromptShortcutAssignments())
        self.translationInsertHotkeyShortcut = SettingsStore.shared.translationInsertHotkeyShortcut
        self.isTranslationInsertHotkeyEnabled = SettingsStore.shared.translationInsertHotkeyEnabled
        self.captionListenHotkeyShortcut = SettingsStore.shared.captionListenHotkeyShortcut
        self.isCaptionListenHotkeyEnabled = SettingsStore.shared.captionListenHotkeyEnabled
        LiveTranslationController.shared.restoreTheaterIfNeeded()

        self.currentProvider = self.providerKey(for: self.selectedProviderID)
        if let saved = self.savedProviders.first(where: { $0.id == self.selectedProviderID }) {
            self.availableModels = saved.models
            self.openAIBaseURL = saved.baseURL
        } else if let stored = self.availableModelsByProvider[self.currentProvider], !stored.isEmpty {
            self.availableModels = stored
            self.openAIBaseURL = ModelRepository.shared.defaultBaseURL(for: self.selectedProviderID)
        } else {
            self.availableModels = ModelRepository.shared.defaultModels(for: self.currentProvider)
            self.openAIBaseURL = ModelRepository.shared.defaultBaseURL(for: self.selectedProviderID)
        }

        if let restoredSelectedModel = self.selectedModelByProvider[self.currentProvider],
           self.availableModels.contains(restoredSelectedModel)
        {
            self.selectedModel = restoredSelectedModel
        } else if let firstModel = self.availableModels.first {
            self.selectedModel = firstModel
        }

        self.refreshDevices()
    }
}

struct TodayStatsToolbarButton: View {
    @ObservedObject private var historyStore = TranscriptionHistoryStore.shared

    let typingWPM: Int
    let action: () -> Void

    var body: some View {
        let summary = self.historyStore.todaySummary
        let timeSaved = summary.formattedTimeSaved(typingWPM: self.typingWPM)
        let hasActivity = summary.words > 0

        return Button(action: self.action) {
            HStack(spacing: 4) {
                Image(systemName: hasActivity ? "waveform" : "chart.bar.fill")
                if hasActivity {
                    Text("\(summary.words) words")
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(timeSaved)
                } else {
                    Text("Today")
                }
            }
            .font(.system(size: 12, weight: .medium))
        }
        .help(hasActivity ? "Today: \(summary.words) words · \(timeSaved) saved - view stats" : "View your stats")
        .accessibilityLabel("Today stats")
    }
}
