//
//  BottomOverlayWindowController.swift
//  Fluid
//
//  Window controller for the dictation overlay.
//
// swiftlint:disable file_length type_body_length function_body_length cyclomatic_complexity
// Tracked grandfather: extracted from BottomOverlayView. Do not add new product surfaces here.

import AppKit
import Combine
import QuartzCore
import SwiftUI

private enum OverlayShortcutResolver {
    static func shortcutDisplay(for _: OverlayMode, settings: SettingsStore = .shared) -> String {
        settings.primaryDictationShortcutDisplayString
    }
}

enum RecordingOverlayHideOutcome: Equatable {
    case hidden
    case superseded
}

private final class BottomOverlayPanel: NSPanel {
    var allowsOffscreenParking = false

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        self.allowsOffscreenParking ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
}

// MARK: - Bottom Overlay Window Controller

@MainActor
final class BottomOverlayWindowController {
    static let shared = BottomOverlayWindowController()

    private var window: NSPanel?
    private var audioSubscription: AnyCancellable?
    private var pendingResizeWorkItem: DispatchWorkItem?
    private var pendingReleaseTransitionResetWorkItem: DispatchWorkItem?
    private var localMouseDownMonitor: Any?
    private var globalMouseDownMonitor: Any?
    private var targetScreen: NSScreen?
    private var releaseTransitionActiveUntil: Date?
    private var deferredResizePending = false
    private var presentationGeneration: UInt64 = 0
    private let dismissalDuration: TimeInterval = 0.02
    private var isHideInProgress = false
    private var activeHideGeneration: UInt64?
    private var hideWaiters: [CheckedContinuation<RecordingOverlayHideOutcome, Never>] = []
    var isVisuallyHiddenForTests: Bool {
        self.window?.isVisible != true || self.window?.alphaValue == 0
    }

    private init() {
        NotificationCenter.default.addObserver(forName: NSNotification.Name("OverlayOffsetChanged"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.positionWindow()
            }
        }
        NotificationCenter.default.addObserver(forName: NSNotification.Name("OverlaySizeChanged"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleSizeAndPositionUpdate(after: 0)
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.targetScreen = OverlayScreenResolver.screenForCurrentPointer()
                if NotchContentState.shared.isBottomOverlayPresented {
                    self.positionWindow()
                } else {
                    self.parkWindowOffscreen()
                }
            }
        }
    }

    /// Pay the one-time SwiftUI/WindowServer surface cost after launch and keep
    /// the static panel outside the entire desktop so its surface is not evicted.
    func prepare() {
        guard self.window == nil else { return }
        self.createWindow()
        self.targetScreen = OverlayScreenResolver.screenForCurrentPointer()
        guard let window else { return }

        self.parkWindowOffscreen()
        window.alphaValue = 1
        window.orderFrontRegardless()
        CATransaction.flush()
        Self.overlayBench("bottom_prepared")
    }

    func show(audioPublisher: AnyPublisher<CGFloat, Never>, mode: OverlayMode) {
        let startedAt = ProcessInfo.processInfo.systemUptime
        Self.overlayBench("bottom_show_start mode=\(mode.rawValue) windowExists=\(self.window != nil)")
        self.cancelInFlightHideForNewPresentation()
        self.presentationGeneration &+= 1

        self.endReleaseTransition(flushDeferredUpdate: false)
        self.pendingResizeWorkItem?.cancel()
        self.pendingResizeWorkItem = nil
        BottomOverlayPromptMenuController.shared.hide()
        BottomOverlayModeMenuController.shared.hide()
        BottomOverlayActionsMenuController.shared.hide()
        self.ensureMouseDownMonitors()

        // Create window if needed
        if self.window == nil {
            self.createWindow()
        }

        // Prepare the complete first frame while the cached panel is still
        // offscreen. Revealing the neutral shell first causes a visible flash
        // that reads as the overlay appearing twice.
        NotchContentState.shared.setBottomOverlayPresented(true)
        NotchContentState.shared.setSpokenSendIndicatorState(.hidden)
        NotchContentState.shared.mode = .dictation
        NotchContentState.shared.promptPickerMode = .dictate
        NotchContentState.shared.updateTranscription("")
        NotchContentState.shared.bottomOverlayAudioLevel = 0
        NotchContentState.shared.setBottomOverlayDismissOffsetY(8)
        NotchContentState.shared.setBottomOverlayDismissing(false)

        self.targetScreen = OverlayScreenResolver.screenForCurrentPointer()
        self.positionWindow()

        // Submit one complete frame to WindowServer.
        self.window?.setAccessibilityChildren(nil)
        self.window?.setAccessibilityElement(true)
        self.window?.alphaValue = 1
        self.window?.orderFrontRegardless()
        self.window?.contentView?.displayIfNeeded()
        self.window?.displayIfNeeded()
        CATransaction.flush()
        Self.overlayBench("bottom_order_front elapsedMs=\(Self.elapsedMs(since: startedAt))")
        Self.overlayBench("bottom_visible elapsedMs=\(Self.elapsedMs(since: startedAt))")

        self.audioSubscription?.cancel()
        self.audioSubscription = audioPublisher
            .receive(on: DispatchQueue.main)
            .sink { level in
                NotchContentState.shared.bottomOverlayAudioLevel = level
            }
    }

    func hide() {
        guard !self.isHideInProgress else { return }
        self.isHideInProgress = true
        self.presentationGeneration &+= 1
        let currentGeneration = self.presentationGeneration
        self.activeHideGeneration = currentGeneration
        self.beginDismissalVisualIfPresented(generation: currentGeneration)
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.performHideAndWait(generation: currentGeneration)
            self.completeHideOperation(generation: currentGeneration, outcome: outcome)
        }
    }

    /// Removes the completed-dictation overlay before returning. The panel is
    /// parked rather than destroyed so the next presentation keeps its warm
    /// SwiftUI and WindowServer surface.
    func hideImmediately() {
        let startedAt = ProcessInfo.processInfo.systemUptime
        self.presentationGeneration &+= 1
        let currentGeneration = self.presentationGeneration

        self.activeHideGeneration = nil
        self.isHideInProgress = false
        let waiters = self.hideWaiters
        self.hideWaiters.removeAll(keepingCapacity: true)

        // Remove the panel from WindowServer before any SwiftUI state update can
        // delay paste. Opacity alone is not committed until the next frame.
        self.window?.alphaValue = 0
        Self.overlayBench("bottom_hide_alpha_return elapsedMs=\(Self.elapsedMs(since: startedAt))")
        self.window?.orderOut(nil)
        Self.overlayBench("bottom_hide_order_out_return elapsedMs=\(Self.elapsedMs(since: startedAt))")
        waiters.forEach { $0.resume(returning: .hidden) }

        Self.overlayBench(
            "bottom_hide_immediate_complete elapsedMs=\(Self.elapsedMs(since: startedAt)) visible=\(self.window?.isVisible == true)"
        )

        // Cleanup is not user-visible and must not hold up text insertion.
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.presentationGeneration == currentGeneration else { return }
            self.clearPresentationStateAfterImmediateHide()
            self.parkWindowOffscreen()
            self.window?.alphaValue = 1
            self.window?.orderFrontRegardless()
        }
    }

    private func clearPresentationStateAfterImmediateHide() {
        NotchContentState.shared.setBottomOverlayPresented(false)
        self.endReleaseTransition(flushDeferredUpdate: false)
        NotchContentState.shared.setBottomOverlayDismissing(false)
        NotchContentState.shared.targetAppIcon = nil
        self.clearPresentationResources()
        Self.overlayBench("bottom_hide_immediate_cleanup_complete")
    }

    /// Returns whether the panel finished hiding or a newer presentation
    /// superseded this request.
    func hideAndWait() async -> RecordingOverlayHideOutcome {
        if self.isHideInProgress {
            return await withCheckedContinuation { continuation in
                self.hideWaiters.append(continuation)
            }
        }

        self.isHideInProgress = true
        self.presentationGeneration &+= 1
        let currentGeneration = self.presentationGeneration
        self.activeHideGeneration = currentGeneration
        self.beginDismissalVisualIfPresented(generation: currentGeneration)
        let outcome = await self.performHideAndWait(generation: currentGeneration)
        self.completeHideOperation(generation: currentGeneration, outcome: outcome)
        return outcome
    }

    private func completeHideOperation(generation: UInt64, outcome: RecordingOverlayHideOutcome) {
        guard self.activeHideGeneration == generation else { return }
        self.activeHideGeneration = nil
        self.isHideInProgress = false
        let waiters = self.hideWaiters
        self.hideWaiters.removeAll(keepingCapacity: true)
        waiters.forEach { $0.resume(returning: outcome) }
    }

    private func cancelInFlightHideForNewPresentation() {
        guard self.isHideInProgress else { return }
        self.activeHideGeneration = nil
        self.isHideInProgress = false
        let waiters = self.hideWaiters
        self.hideWaiters.removeAll(keepingCapacity: true)
        waiters.forEach { $0.resume(returning: .superseded) }
        Self.overlayBench("bottom_hide_cancelled_for_new_presentation")
    }

    private func performHideAndWait(generation currentGeneration: UInt64) async -> RecordingOverlayHideOutcome {
        let startedAt = ProcessInfo.processInfo.systemUptime
        Self.overlayBench("bottom_hide_start windowExists=\(self.window != nil)")
        guard self.presentationGeneration == currentGeneration else {
            Self.overlayBench("bottom_hide_return reason=stale_generation")
            return .superseded
        }

        guard let window = self.window, NotchContentState.shared.isBottomOverlayPresented else {
            self.clearPresentationResources()
            self.endReleaseTransition(flushDeferredUpdate: false)
            NotchContentState.shared.setBottomOverlayDismissing(false)
            NotchContentState.shared.targetAppIcon = nil
            Self.overlayBench("bottom_hide_return reason=no_window")
            return .hidden
        }

        // SwiftUI owns the dismissal animation. Keeping AppKit alpha at 1
        // prevents an old implicit window animation from hiding a rapid restart.
        Self.overlayBench("bottom_hide_animation_start")
        await Task.yield()
        guard self.presentationGeneration == currentGeneration else {
            Self.overlayBench("bottom_hide_return reason=stale_generation")
            return .superseded
        }
        self.clearPresentationResources()

        try? await Task.sleep(nanoseconds: UInt64(self.dismissalDuration * 1_000_000_000))

        guard self.presentationGeneration == currentGeneration else {
            Self.overlayBench("bottom_hide_return reason=stale_generation")
            return .superseded
        }

        self.parkWindowOffscreen()
        window.alphaValue = 1
        NotchContentState.shared.setBottomOverlayPresented(false)
        self.endReleaseTransition(flushDeferredUpdate: false)
        NotchContentState.shared.setBottomOverlayDismissing(false)
        NotchContentState.shared.targetAppIcon = nil
        Self.overlayBench("bottom_hide_complete elapsedMs=\(Self.elapsedMs(since: startedAt))")
        return .hidden
    }

    private func beginDismissalVisualIfPresented(generation: UInt64) {
        guard self.presentationGeneration == generation,
              self.window != nil,
              NotchContentState.shared.isBottomOverlayPresented
        else { return }

        NotchContentState.shared.setBottomOverlayReleaseTransitioning(true)
        NotchContentState.shared.setBottomOverlayDismissOffsetY(8)
        NotchContentState.shared.setBottomOverlayDismissing(true)
        Self.overlayBench("bottom_hide_visual_requested")
    }

    private func clearPresentationResources() {
        self.audioSubscription?.cancel()
        self.audioSubscription = nil
        self.pendingResizeWorkItem?.cancel()
        self.pendingResizeWorkItem = nil
        self.pendingReleaseTransitionResetWorkItem?.cancel()
        self.targetScreen = nil
        self.removeMouseDownMonitors()
        BottomOverlayPromptMenuController.shared.hide()
        BottomOverlayModeMenuController.shared.hide()
        BottomOverlayActionsMenuController.shared.hide()
        NotchContentState.shared.setProcessing(false)
        NotchContentState.shared.bottomOverlayAudioLevel = 0
    }

    func setProcessing(_ processing: Bool) {
        Self.overlayBench("bottom_set_processing processing=\(processing)")
        NotchContentState.shared.setProcessing(processing)
    }

    func refreshSizeForContent() {
        self.scheduleSizeAndPositionUpdate()
    }

    func beginReleaseTransition(duration: TimeInterval = 0.28) {
        let now = Date()
        let deadline = now.addingTimeInterval(max(duration, 0.12))
        if let existingDeadline = self.releaseTransitionActiveUntil, existingDeadline > deadline {
            self.releaseTransitionActiveUntil = existingDeadline
        } else {
            self.releaseTransitionActiveUntil = deadline
        }

        self.pendingReleaseTransitionResetWorkItem?.cancel()

        guard let activeDeadline = self.releaseTransitionActiveUntil else { return }
        let resetWorkItem = DispatchWorkItem { [weak self] in
            self?.endReleaseTransition()
        }
        self.pendingReleaseTransitionResetWorkItem = resetWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + max(activeDeadline.timeIntervalSince(now), 0), execute: resetWorkItem)

        self.audioSubscription?.cancel()
        self.audioSubscription = nil
        NotchContentState.shared.bottomOverlayAudioLevel = 0
        NotchContentState.shared.setBottomOverlayReleaseTransitioning(true)
    }

    func endReleaseTransition(flushDeferredUpdate: Bool = true) {
        self.pendingReleaseTransitionResetWorkItem?.cancel()
        self.pendingReleaseTransitionResetWorkItem = nil
        self.releaseTransitionActiveUntil = nil
        NotchContentState.shared.setBottomOverlayReleaseTransitioning(false)

        let shouldFlush = flushDeferredUpdate && self.deferredResizePending
        self.deferredResizePending = false

        if shouldFlush, self.window?.isVisible == true {
            self.scheduleSizeAndPositionUpdate(after: 0)
        }
    }

    private static func overlayBench(_ message: String) {
        DebugLogger.shared.benchmark("OVERLAY_BENCH", message: message, source: "OverlayBenchmark")
    }

    private static func elapsedMs(since start: TimeInterval) -> Int {
        Int(((ProcessInfo.processInfo.systemUptime - start) * 1000).rounded())
    }

    private func scheduleSizeAndPositionUpdate(after delay: TimeInterval = 0.08) {
        if self.isReleaseTransitionActive {
            self.deferredResizePending = true
            return
        }

        self.pendingResizeWorkItem?.cancel()

        // Debounce rapid streaming updates to avoid resize thrash.
        let resizeWorkItem = DispatchWorkItem { [weak self] in
            self?.updateSizeAndPosition()
        }
        self.pendingResizeWorkItem = resizeWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: resizeWorkItem)
    }

    /// Update window size based on current SwiftUI content and re-position
    private func updateSizeAndPosition() {
        if self.isReleaseTransitionActive {
            self.deferredResizePending = true
            return
        }

        guard let window = window, let hostingView = window.contentView as? NSHostingView<BottomOverlayView> else { return }

        // Re-calculate fitting size for the new layout constants
        let newSize = hostingView.fittingSize

        // Avoid redundant content-size updates while AppKit is already resolving constraints.
        // Re-applying the same size can trigger unnecessary update-constraints churn.
        let currentSize = window.contentView?.frame.size ?? window.frame.size
        let widthChanged = abs(currentSize.width - newSize.width) > 0.5
        let heightChanged = abs(currentSize.height - newSize.height) > 0.5

        if widthChanged || heightChanged {
            // Resize from the current origin to avoid AppKit's default top-left anchoring,
            // which can visually push the overlay down before we re-position it.
            let currentOrigin = window.frame.origin
            let resizedFrame = NSRect(origin: currentOrigin, size: newSize)
            window.setFrame(resizedFrame, display: false)
        }

        // Re-position
        self.positionWindow()
    }

    private func createWindow() {
        let panel = BottomOverlayPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // SwiftUI handles shadow
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        let contentView = BottomOverlayView()
        let hostingView = BottomOverlayHostingView(rootView: contentView)

        // Let SwiftUI determine the size
        let fittingSize = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)

        // Make hosting view fully transparent
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        panel.setContentSize(fittingSize)
        panel.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        hostingView.display()

        self.window = panel
    }

    private var isReleaseTransitionActive: Bool {
        guard let deadline = self.releaseTransitionActiveUntil else { return false }
        if deadline > Date() {
            return true
        }

        self.releaseTransitionActiveUntil = nil
        return false
    }

    private func ensureMouseDownMonitors() {
        if self.localMouseDownMonitor == nil {
            self.localMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                let clickPoint: NSPoint
                if let window = event.window {
                    clickPoint = window.convertPoint(toScreen: event.locationInWindow)
                } else {
                    clickPoint = NSEvent.mouseLocation
                }

                Task { @MainActor [weak self] in
                    self?.dismissMenusForClick(screenPoint: clickPoint)
                }
                return event
            }
        }

        if self.globalMouseDownMonitor == nil {
            self.globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                let clickPoint = NSEvent.mouseLocation
                Task { @MainActor [weak self] in
                    self?.dismissMenusForClick(screenPoint: clickPoint)
                }
            }
        }
    }

    private func removeMouseDownMonitors() {
        if let monitor = self.localMouseDownMonitor {
            NSEvent.removeMonitor(monitor)
            self.localMouseDownMonitor = nil
        }
        if let monitor = self.globalMouseDownMonitor {
            NSEvent.removeMonitor(monitor)
            self.globalMouseDownMonitor = nil
        }
    }

    @MainActor
    private func dismissMenusForClick(screenPoint: NSPoint) {
        guard self.window?.isVisible == true else { return }
        BottomOverlayPromptMenuController.shared.dismissIfNeeded(for: screenPoint)
        BottomOverlayModeMenuController.shared.dismissIfNeeded(for: screenPoint)
        BottomOverlayActionsMenuController.shared.dismissIfNeeded(for: screenPoint)
    }

    private func positionWindow() {
        // Safe check for window and screen availability
        guard let window = window else { return }
        guard NotchContentState.shared.isBottomOverlayPresented else {
            self.parkWindowOffscreen()
            return
        }
        (window as? BottomOverlayPanel)?.allowsOffscreenParking = false

        let screen = self.targetScreen ?? window.screen ?? OverlayScreenResolver.screenForCurrentPointer()
        guard let screen = screen else { return }

        let fullFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let windowSize = window.frame.size

        // Horizontal centering
        let x = fullFrame.midX - windowSize.width / 2

        // Vertical positioning with safety clamping
        let offset = SettingsStore.shared.overlayBottomOffset

        // Calculate raw position
        var y = visibleFrame.minY + CGFloat(offset)

        // Safety Clamping:
        // 1. Min: Ensure it's at least visibleFrame.minY (not below the dock/visible area)
        // 2. Max: Ensure it doesn't cross the top of the visible frame minus its own height
        let minY = visibleFrame.minY + 10 // Small buffer from absolute bottom
        let maxY = visibleFrame.maxY - windowSize.height - 40 // Buffer from top

        y = max(min(y, maxY), minY)

        // Apply position directly to avoid implicit frame animations during hover-driven resizes.
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func parkWindowOffscreen() {
        guard let window else { return }
        window.setAccessibilityChildren([])
        window.setAccessibilityElement(false)
        (window as? BottomOverlayPanel)?.allowsOffscreenParking = true
        let desktopFrame = NSScreen.screens.reduce(NSRect.null) { partial, screen in
            partial.union(screen.frame)
        }
        let edge = desktopFrame.isNull ? NSPoint(x: 100_000, y: 100_000) : NSPoint(
            x: desktopFrame.maxX + window.frame.width + 1024,
            y: desktopFrame.maxY + window.frame.height + 1024
        )
        window.setFrameOrigin(edge)
    }
}

@MainActor
final class BottomOverlayPromptMenuController {
    static let shared = BottomOverlayPromptMenuController()

    private var menuWindow: NSPanel?
    private var hostingView: NSHostingView<BottomOverlayPromptMenuView>?
    private var selectorFrameInScreen: CGRect = .zero
    private weak var parentWindow: NSWindow?
    private var menuMaxWidth: CGFloat = 220
    private var menuGap: CGFloat = 6

    private var isHoveringSelector = false
    private var isHoveringMenu = false
    private var pendingShowWorkItem: DispatchWorkItem?
    private var pendingHideWorkItem: DispatchWorkItem?
    private var pendingPositionWorkItem: DispatchWorkItem?

    private init() {}

    func updateAnchor(selectorFrameInScreen: CGRect, parentWindow: NSWindow?, maxWidth: CGFloat, menuGap: CGFloat) {
        guard selectorFrameInScreen.width > 0, selectorFrameInScreen.height > 0 else { return }

        let resolvedMaxWidth = max(maxWidth, 120)
        let widthChanged = abs(self.menuMaxWidth - resolvedMaxWidth) > 0.5

        self.selectorFrameInScreen = selectorFrameInScreen
        self.parentWindow = parentWindow
        self.menuMaxWidth = resolvedMaxWidth
        self.menuGap = max(menuGap, 0)

        if self.menuWindow?.isVisible == true {
            if widthChanged {
                self.updateMenuContent()
            }
            self.attachToParentWindowIfNeeded()
            self.scheduleMenuPositionUpdate()
        }
    }

    func selectorHoverChanged(_ hovering: Bool) {
        // Hover-open disabled: menu is click/tap driven.
    }

    func menuHoverChanged(_ hovering: Bool) {
        // Hover-open disabled: menu is click/tap driven.
    }

    func toggleFromTap() {
        if self.menuWindow?.isVisible == true {
            self.hide()
            return
        }
        self.showMenuIfPossible()
    }

    func hide() {
        self.pendingShowWorkItem?.cancel()
        self.pendingShowWorkItem = nil
        self.pendingHideWorkItem?.cancel()
        self.pendingHideWorkItem = nil
        self.pendingPositionWorkItem?.cancel()
        self.pendingPositionWorkItem = nil

        self.isHoveringSelector = false
        self.isHoveringMenu = false

        if let menuWindow = self.menuWindow, let parent = menuWindow.parent {
            parent.removeChildWindow(menuWindow)
        }
        self.menuWindow?.orderOut(nil)
    }

    func dismissIfNeeded(for screenPoint: NSPoint) {
        guard self.menuWindow?.isVisible == true else { return }
        let insideMenu = self.menuWindow?.frame.contains(screenPoint) ?? false
        let insideSelector = self.selectorFrameInScreen.contains(screenPoint)
        if !insideMenu, !insideSelector {
            self.hide()
        }
    }

    private func updateVisibility() {
        let shouldShow = self.isHoveringSelector || self.isHoveringMenu

        if shouldShow {
            self.pendingHideWorkItem?.cancel()
            self.pendingHideWorkItem = nil

            if self.menuWindow?.isVisible == true {
                self.scheduleMenuPositionUpdate()
                return
            }

            self.pendingShowWorkItem?.cancel()
            let showTask = DispatchWorkItem { [weak self] in
                self?.showMenuIfPossible()
            }
            self.pendingShowWorkItem = showTask
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: showTask)
            return
        }

        self.pendingShowWorkItem?.cancel()
        self.pendingShowWorkItem = nil

        self.pendingHideWorkItem?.cancel()
        let hideTask = DispatchWorkItem { [weak self] in
            self?.hideIfNotHovered()
        }
        self.pendingHideWorkItem = hideTask
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: hideTask)
    }

    private func hideIfNotHovered() {
        guard !self.isHoveringSelector, !self.isHoveringMenu else { return }
        self.pendingPositionWorkItem?.cancel()
        self.pendingPositionWorkItem = nil
        if let menuWindow = self.menuWindow, let parent = menuWindow.parent {
            parent.removeChildWindow(menuWindow)
        }
        self.menuWindow?.orderOut(nil)
    }

    private func scheduleMenuPositionUpdate() {
        guard self.pendingPositionWorkItem == nil else { return }

        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingPositionWorkItem = nil
            self.updateMenuSizeAndPosition()
        }

        self.pendingPositionWorkItem = task
        DispatchQueue.main.async(execute: task)
    }

    private func showMenuIfPossible() {
        guard self.selectorFrameInScreen.width > 0, self.selectorFrameInScreen.height > 0 else { return }

        self.createWindowIfNeeded()
        self.updateMenuContent()
        self.attachToParentWindowIfNeeded()
        self.updateMenuSizeAndPosition()
        self.menuWindow?.orderFrontRegardless()
    }

    private func createWindowIfNeeded() {
        guard self.menuWindow == nil else { return }

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        let contentView = BottomOverlayPromptMenuView(
            promptMode: self.resolvedPromptMode(),
            maxWidth: self.menuMaxWidth,
            onHoverChanged: { [weak self] hovering in
                self?.menuHoverChanged(hovering)
            },
            onDismissRequested: { [weak self] in
                self?.hide()
            }
        )

        let hostingView = NSHostingView(rootView: contentView)
        let fittingSize = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        panel.setContentSize(fittingSize)
        panel.contentView = hostingView

        self.hostingView = hostingView
        self.menuWindow = panel
    }

    private func updateMenuContent() {
        let rootView = BottomOverlayPromptMenuView(
            promptMode: self.resolvedPromptMode(),
            maxWidth: self.menuMaxWidth,
            onHoverChanged: { [weak self] hovering in
                self?.menuHoverChanged(hovering)
            },
            onDismissRequested: { [weak self] in
                self?.hide()
            }
        )
        self.hostingView?.rootView = rootView
    }

    private func resolvedPromptMode() -> SettingsStore.PromptMode {
        .dictate
    }

    private func attachToParentWindowIfNeeded() {
        guard let menuWindow = self.menuWindow else { return }

        if let currentParent = menuWindow.parent, currentParent !== self.parentWindow {
            currentParent.removeChildWindow(menuWindow)
        }

        if let parentWindow = self.parentWindow, menuWindow.parent !== parentWindow {
            parentWindow.addChildWindow(menuWindow, ordered: .above)
        }
    }

    private func updateMenuSizeAndPosition() {
        guard let menuWindow = self.menuWindow, let hostingView = self.hostingView else { return }
        guard self.selectorFrameInScreen.width > 0, self.selectorFrameInScreen.height > 0 else { return }

        let fittingSize = hostingView.fittingSize
        guard fittingSize.width > 0, fittingSize.height > 0 else { return }

        let preferredX = self.selectorFrameInScreen.midX - (fittingSize.width / 2)
        let preferredY = self.selectorFrameInScreen.maxY + self.menuGap

        let screen = self.parentWindow?.screen
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: self.selectorFrameInScreen.midX, y: self.selectorFrameInScreen.midY)) })
            ?? NSScreen.main

        var targetX = preferredX
        var targetY = preferredY

        if let screen {
            let visible = screen.visibleFrame
            let horizontalInset: CGFloat = 8
            let verticalInset: CGFloat = 8

            if fittingSize.width < visible.width - (horizontalInset * 2) {
                targetX = max(visible.minX + horizontalInset, min(preferredX, visible.maxX - fittingSize.width - horizontalInset))
            } else {
                targetX = visible.minX + horizontalInset
            }

            if fittingSize.height < visible.height - (verticalInset * 2) {
                targetY = max(visible.minY + verticalInset, min(preferredY, visible.maxY - fittingSize.height - verticalInset))
            } else {
                targetY = visible.minY + verticalInset
            }
        }

        let targetFrame = NSRect(x: targetX, y: targetY, width: fittingSize.width, height: fittingSize.height)
        let currentFrame = menuWindow.frame
        let frameTolerance: CGFloat = 0.5
        let isSameFrame =
            abs(currentFrame.origin.x - targetFrame.origin.x) <= frameTolerance &&
            abs(currentFrame.origin.y - targetFrame.origin.y) <= frameTolerance &&
            abs(currentFrame.size.width - targetFrame.size.width) <= frameTolerance &&
            abs(currentFrame.size.height - targetFrame.size.height) <= frameTolerance

        if !isSameFrame {
            menuWindow.setFrame(targetFrame, display: false)
        }
    }
}

@MainActor
final class BottomOverlayModeMenuController {
    static let shared = BottomOverlayModeMenuController()

    private var menuWindow: NSPanel?
    private var hostingView: NSHostingView<BottomOverlayModeMenuView>?
    private var selectorFrameInScreen: CGRect = .zero
    private weak var parentWindow: NSWindow?
    private var menuMaxWidth: CGFloat = 220
    private var menuGap: CGFloat = 6

    private var isHoveringSelector = false
    private var isHoveringMenu = false
    private var pendingShowWorkItem: DispatchWorkItem?
    private var pendingHideWorkItem: DispatchWorkItem?
    private var pendingPositionWorkItem: DispatchWorkItem?

    private init() {}

    func updateAnchor(selectorFrameInScreen: CGRect, parentWindow: NSWindow?, maxWidth: CGFloat, menuGap: CGFloat) {
        guard selectorFrameInScreen.width > 0, selectorFrameInScreen.height > 0 else { return }

        let resolvedMaxWidth = max(maxWidth, 120)
        let widthChanged = abs(self.menuMaxWidth - resolvedMaxWidth) > 0.5

        self.selectorFrameInScreen = selectorFrameInScreen
        self.parentWindow = parentWindow
        self.menuMaxWidth = resolvedMaxWidth
        self.menuGap = max(menuGap, 0)

        if self.menuWindow?.isVisible == true {
            if widthChanged {
                self.updateMenuContent()
            }
            self.attachToParentWindowIfNeeded()
            self.scheduleMenuPositionUpdate()
        }
    }

    func selectorHoverChanged(_ hovering: Bool) {
        // Hover-open disabled: menu is click/tap driven.
    }

    func menuHoverChanged(_ hovering: Bool) {
        // Hover-open disabled: menu is click/tap driven.
    }

    func toggleFromTap() {
        if self.menuWindow?.isVisible == true {
            self.hide()
            return
        }
        self.showMenuIfPossible()
    }

    func hide() {
        self.pendingShowWorkItem?.cancel()
        self.pendingShowWorkItem = nil
        self.pendingHideWorkItem?.cancel()
        self.pendingHideWorkItem = nil
        self.pendingPositionWorkItem?.cancel()
        self.pendingPositionWorkItem = nil

        self.isHoveringSelector = false
        self.isHoveringMenu = false

        if let menuWindow = self.menuWindow, let parent = menuWindow.parent {
            parent.removeChildWindow(menuWindow)
        }
        self.menuWindow?.orderOut(nil)
    }

    func dismissIfNeeded(for screenPoint: NSPoint) {
        guard self.menuWindow?.isVisible == true else { return }
        let insideMenu = self.menuWindow?.frame.contains(screenPoint) ?? false
        let insideSelector = self.selectorFrameInScreen.contains(screenPoint)
        if !insideMenu, !insideSelector {
            self.hide()
        }
    }

    private func updateVisibility() {
        let shouldShow = self.isHoveringSelector || self.isHoveringMenu

        if shouldShow {
            self.pendingHideWorkItem?.cancel()
            self.pendingHideWorkItem = nil

            if self.menuWindow?.isVisible == true {
                self.scheduleMenuPositionUpdate()
                return
            }

            self.pendingShowWorkItem?.cancel()
            let showTask = DispatchWorkItem { [weak self] in
                self?.showMenuIfPossible()
            }
            self.pendingShowWorkItem = showTask
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: showTask)
            return
        }

        self.pendingShowWorkItem?.cancel()
        self.pendingShowWorkItem = nil

        self.pendingHideWorkItem?.cancel()
        let hideTask = DispatchWorkItem { [weak self] in
            self?.hideIfNotHovered()
        }
        self.pendingHideWorkItem = hideTask
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: hideTask)
    }

    private func hideIfNotHovered() {
        guard !self.isHoveringSelector, !self.isHoveringMenu else { return }
        self.pendingPositionWorkItem?.cancel()
        self.pendingPositionWorkItem = nil
        if let menuWindow = self.menuWindow, let parent = menuWindow.parent {
            parent.removeChildWindow(menuWindow)
        }
        self.menuWindow?.orderOut(nil)
    }

    private func scheduleMenuPositionUpdate() {
        guard self.pendingPositionWorkItem == nil else { return }

        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingPositionWorkItem = nil
            self.updateMenuSizeAndPosition()
        }

        self.pendingPositionWorkItem = task
        DispatchQueue.main.async(execute: task)
    }

    private func showMenuIfPossible() {
        guard self.selectorFrameInScreen.width > 0, self.selectorFrameInScreen.height > 0 else { return }

        self.createWindowIfNeeded()
        self.updateMenuContent()
        self.attachToParentWindowIfNeeded()
        self.updateMenuSizeAndPosition()
        self.menuWindow?.orderFrontRegardless()
    }

    private func createWindowIfNeeded() {
        guard self.menuWindow == nil else { return }

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        let contentView = BottomOverlayModeMenuView(
            maxWidth: self.menuMaxWidth,
            onHoverChanged: { [weak self] hovering in
                self?.menuHoverChanged(hovering)
            },
            onDismissRequested: { [weak self] in
                self?.hide()
            }
        )

        let hostingView = NSHostingView(rootView: contentView)
        let fittingSize = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        panel.setContentSize(fittingSize)
        panel.contentView = hostingView

        self.hostingView = hostingView
        self.menuWindow = panel
    }

    private func updateMenuContent() {
        let rootView = BottomOverlayModeMenuView(
            maxWidth: self.menuMaxWidth,
            onHoverChanged: { [weak self] hovering in
                self?.menuHoverChanged(hovering)
            },
            onDismissRequested: { [weak self] in
                self?.hide()
            }
        )
        self.hostingView?.rootView = rootView
    }

    private func attachToParentWindowIfNeeded() {
        guard let menuWindow = self.menuWindow else { return }

        if let currentParent = menuWindow.parent, currentParent !== self.parentWindow {
            currentParent.removeChildWindow(menuWindow)
        }

        if let parentWindow = self.parentWindow, menuWindow.parent !== parentWindow {
            parentWindow.addChildWindow(menuWindow, ordered: .above)
        }
    }

    private func updateMenuSizeAndPosition() {
        guard let menuWindow = self.menuWindow, let hostingView = self.hostingView else { return }
        guard self.selectorFrameInScreen.width > 0, self.selectorFrameInScreen.height > 0 else { return }

        let fittingSize = hostingView.fittingSize
        guard fittingSize.width > 0, fittingSize.height > 0 else { return }

        let preferredX = self.selectorFrameInScreen.midX - (fittingSize.width / 2)
        let preferredY = self.selectorFrameInScreen.maxY + self.menuGap

        let screen = self.parentWindow?.screen
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: self.selectorFrameInScreen.midX, y: self.selectorFrameInScreen.midY)) })
            ?? NSScreen.main

        var targetX = preferredX
        var targetY = preferredY

        if let screen {
            let visible = screen.visibleFrame
            let horizontalInset: CGFloat = 8
            let verticalInset: CGFloat = 8

            if fittingSize.width < visible.width - (horizontalInset * 2) {
                targetX = max(visible.minX + horizontalInset, min(preferredX, visible.maxX - fittingSize.width - horizontalInset))
            } else {
                targetX = visible.minX + horizontalInset
            }

            if fittingSize.height < visible.height - (verticalInset * 2) {
                targetY = max(visible.minY + verticalInset, min(preferredY, visible.maxY - fittingSize.height - verticalInset))
            } else {
                targetY = visible.minY + verticalInset
            }
        }

        let targetFrame = NSRect(x: targetX, y: targetY, width: fittingSize.width, height: fittingSize.height)
        let currentFrame = menuWindow.frame
        let frameTolerance: CGFloat = 0.5
        let isSameFrame =
            abs(currentFrame.origin.x - targetFrame.origin.x) <= frameTolerance &&
            abs(currentFrame.origin.y - targetFrame.origin.y) <= frameTolerance &&
            abs(currentFrame.size.width - targetFrame.size.width) <= frameTolerance &&
            abs(currentFrame.size.height - targetFrame.size.height) <= frameTolerance

        if !isSameFrame {
            menuWindow.setFrame(targetFrame, display: false)
        }
    }
}

@MainActor
final class BottomOverlayActionsMenuController {
    static let shared = BottomOverlayActionsMenuController()

    private var menuWindow: NSPanel?
    private var hostingView: NSHostingView<BottomOverlayActionsMenuView>?
    private var selectorFrameInScreen: CGRect = .zero
    private weak var parentWindow: NSWindow?
    private var menuMaxWidth: CGFloat = 220
    private var menuGap: CGFloat = 6

    private var isHoveringSelector = false
    private var isHoveringMenu = false
    private var pendingShowWorkItem: DispatchWorkItem?
    private var pendingHideWorkItem: DispatchWorkItem?
    private var pendingPositionWorkItem: DispatchWorkItem?

    private init() {}

    func updateAnchor(selectorFrameInScreen: CGRect, parentWindow: NSWindow?, maxWidth: CGFloat, menuGap: CGFloat) {
        guard selectorFrameInScreen.width > 0, selectorFrameInScreen.height > 0 else { return }

        let resolvedMaxWidth = max(maxWidth, 120)
        let widthChanged = abs(self.menuMaxWidth - resolvedMaxWidth) > 0.5

        self.selectorFrameInScreen = selectorFrameInScreen
        self.parentWindow = parentWindow
        self.menuMaxWidth = resolvedMaxWidth
        self.menuGap = max(menuGap, 0)

        if self.menuWindow?.isVisible == true {
            if widthChanged {
                self.updateMenuContent()
            }
            self.attachToParentWindowIfNeeded()
            self.scheduleMenuPositionUpdate()
        }
    }

    func selectorHoverChanged(_ hovering: Bool) {
        // Hover-open disabled: menu is click/tap driven.
    }

    func menuHoverChanged(_ hovering: Bool) {
        // Hover-open disabled: menu is click/tap driven.
    }

    func toggleFromTap() {
        if self.menuWindow?.isVisible == true {
            self.hide()
            return
        }
        self.showMenuIfPossible()
    }

    func hide() {
        self.pendingShowWorkItem?.cancel()
        self.pendingShowWorkItem = nil
        self.pendingHideWorkItem?.cancel()
        self.pendingHideWorkItem = nil
        self.pendingPositionWorkItem?.cancel()
        self.pendingPositionWorkItem = nil

        self.isHoveringSelector = false
        self.isHoveringMenu = false

        if let menuWindow = self.menuWindow, let parent = menuWindow.parent {
            parent.removeChildWindow(menuWindow)
        }
        self.menuWindow?.orderOut(nil)
    }

    func dismissIfNeeded(for screenPoint: NSPoint) {
        guard self.menuWindow?.isVisible == true else { return }
        let insideMenu = self.menuWindow?.frame.contains(screenPoint) ?? false
        let insideSelector = self.selectorFrameInScreen.contains(screenPoint)
        if !insideMenu, !insideSelector {
            self.hide()
        }
    }

    private func updateVisibility() {
        let shouldShow = self.isHoveringSelector || self.isHoveringMenu

        if shouldShow {
            self.pendingHideWorkItem?.cancel()
            self.pendingHideWorkItem = nil

            if self.menuWindow?.isVisible == true {
                self.scheduleMenuPositionUpdate()
                return
            }

            self.pendingShowWorkItem?.cancel()
            let showTask = DispatchWorkItem { [weak self] in
                self?.showMenuIfPossible()
            }
            self.pendingShowWorkItem = showTask
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: showTask)
            return
        }

        self.pendingShowWorkItem?.cancel()
        self.pendingShowWorkItem = nil

        self.pendingHideWorkItem?.cancel()
        let hideTask = DispatchWorkItem { [weak self] in
            self?.hideIfNotHovered()
        }
        self.pendingHideWorkItem = hideTask
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: hideTask)
    }

    private func hideIfNotHovered() {
        guard !self.isHoveringSelector, !self.isHoveringMenu else { return }
        self.pendingPositionWorkItem?.cancel()
        self.pendingPositionWorkItem = nil
        if let menuWindow = self.menuWindow, let parent = menuWindow.parent {
            parent.removeChildWindow(menuWindow)
        }
        self.menuWindow?.orderOut(nil)
    }

    private func scheduleMenuPositionUpdate() {
        guard self.pendingPositionWorkItem == nil else { return }

        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingPositionWorkItem = nil
            self.updateMenuSizeAndPosition()
        }

        self.pendingPositionWorkItem = task
        DispatchQueue.main.async(execute: task)
    }

    private func showMenuIfPossible() {
        guard self.selectorFrameInScreen.width > 0, self.selectorFrameInScreen.height > 0 else { return }

        self.createWindowIfNeeded()
        self.updateMenuContent()
        self.attachToParentWindowIfNeeded()
        self.updateMenuSizeAndPosition()
        self.menuWindow?.orderFrontRegardless()
    }

    private func createWindowIfNeeded() {
        guard self.menuWindow == nil else { return }

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        let contentView = BottomOverlayActionsMenuView(
            maxWidth: self.menuMaxWidth,
            onHoverChanged: { [weak self] hovering in
                self?.menuHoverChanged(hovering)
            },
            onDismissRequested: { [weak self] in
                self?.hide()
            }
        )

        let hostingView = NSHostingView(rootView: contentView)
        let fittingSize = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        panel.setContentSize(fittingSize)
        panel.contentView = hostingView

        self.hostingView = hostingView
        self.menuWindow = panel
    }

    private func updateMenuContent() {
        let rootView = BottomOverlayActionsMenuView(
            maxWidth: self.menuMaxWidth,
            onHoverChanged: { [weak self] hovering in
                self?.menuHoverChanged(hovering)
            },
            onDismissRequested: { [weak self] in
                self?.hide()
            }
        )
        self.hostingView?.rootView = rootView
    }

    private func attachToParentWindowIfNeeded() {
        guard let menuWindow = self.menuWindow else { return }

        if let currentParent = menuWindow.parent, currentParent !== self.parentWindow {
            currentParent.removeChildWindow(menuWindow)
        }

        if let parentWindow = self.parentWindow, menuWindow.parent !== parentWindow {
            parentWindow.addChildWindow(menuWindow, ordered: .above)
        }
    }

    private func updateMenuSizeAndPosition() {
        guard let menuWindow = self.menuWindow, let hostingView = self.hostingView else { return }
        guard self.selectorFrameInScreen.width > 0, self.selectorFrameInScreen.height > 0 else { return }

        let fittingSize = hostingView.fittingSize
        guard fittingSize.width > 0, fittingSize.height > 0 else { return }

        let preferredX = self.selectorFrameInScreen.midX - (fittingSize.width / 2)
        let preferredY = self.selectorFrameInScreen.maxY + self.menuGap

        let screen = self.parentWindow?.screen
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: self.selectorFrameInScreen.midX, y: self.selectorFrameInScreen.midY)) })
            ?? NSScreen.main

        var targetX = preferredX
        var targetY = preferredY

        if let screen {
            let visible = screen.visibleFrame
            let horizontalInset: CGFloat = 8
            let verticalInset: CGFloat = 8

            if fittingSize.width < visible.width - (horizontalInset * 2) {
                targetX = max(visible.minX + horizontalInset, min(preferredX, visible.maxX - fittingSize.width - horizontalInset))
            } else {
                targetX = visible.minX + horizontalInset
            }

            if fittingSize.height < visible.height - (verticalInset * 2) {
                targetY = max(visible.minY + verticalInset, min(preferredY, visible.maxY - fittingSize.height - verticalInset))
            } else {
                targetY = visible.minY + verticalInset
            }
        }

        let targetFrame = NSRect(x: targetX, y: targetY, width: fittingSize.width, height: fittingSize.height)
        let currentFrame = menuWindow.frame
        let frameTolerance: CGFloat = 0.5
        let isSameFrame =
            abs(currentFrame.origin.x - targetFrame.origin.x) <= frameTolerance &&
            abs(currentFrame.origin.y - targetFrame.origin.y) <= frameTolerance &&
            abs(currentFrame.size.width - targetFrame.size.width) <= frameTolerance &&
            abs(currentFrame.size.height - targetFrame.size.height) <= frameTolerance

        if !isSameFrame {
            menuWindow.setFrame(targetFrame, display: false)
        }
    }
}

private struct BottomOverlayModeMenuView: View {
    @ObservedObject private var contentState = NotchContentState.shared
    @ObservedObject private var settings = SettingsStore.shared

    let maxWidth: CGFloat
    let onHoverChanged: (Bool) -> Void
    let onDismissRequested: () -> Void

    @State private var hoveredRowID: String?

    private var normalizedOverlayMode: OverlayMode {
        .dictation
    }

    private func rowBackground(isSelected: Bool, rowID: String) -> some View {
        let isHovered = self.hoveredRowID == rowID
        let fillColor: Color
        if isSelected {
            fillColor = Color.white.opacity(0.28)
        } else if isHovered {
            fillColor = Color.white.opacity(0.20)
        } else {
            fillColor = Color.clear
        }

        let strokeColor: Color
        if isSelected {
            strokeColor = Color.white.opacity(0.38)
        } else if isHovered {
            strokeColor = Color.white.opacity(0.24)
        } else {
            strokeColor = Color.clear
        }

        return RoundedRectangle(cornerRadius: 7)
            .fill(fillColor)
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(strokeColor, lineWidth: 1)
            )
    }

    @ViewBuilder
    private func modeRow(_ title: String, mode: OverlayMode, rowID: String) -> some View {
        let isSelected = self.normalizedOverlayMode == mode
        let shortcut = OverlayShortcutResolver.shortcutDisplay(for: mode, settings: self.settings)

        Button(action: {
            guard !self.contentState.isProcessing else { return }
            self.contentState.onOverlayModeSwitchRequested?(mode)
            self.onDismissRequested()
        }) {
            HStack(alignment: .center, spacing: 8) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                if !shortcut.isEmpty {
                    Text(shortcut)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Capsule())
                }
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(self.rowBackground(isSelected: isSelected, rowID: rowID))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            self.hoveredRowID = hovering ? rowID : nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            self.modeRow("Dictate", mode: .dictation, rowID: "dictate")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .frame(maxWidth: self.maxWidth)
        .preferredColorScheme(.dark)
        .onHover { hovering in
            self.onHoverChanged(hovering)
        }
    }
}

private struct BottomOverlayPromptMenuView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var contentState = NotchContentState.shared

    let promptMode: SettingsStore.PromptMode
    let maxWidth: CGFloat
    let onHoverChanged: (Bool) -> Void
    let onDismissRequested: () -> Void
    @State private var hoveredRowID: String?

    private func rowBackground(isSelected: Bool, rowID: String) -> some View {
        let isHovered = self.hoveredRowID == rowID
        let fillColor: Color
        if isSelected {
            fillColor = Color.white.opacity(0.28)
        } else if isHovered {
            fillColor = Color.white.opacity(0.20)
        } else {
            fillColor = Color.clear
        }

        let strokeColor: Color
        if isSelected {
            strokeColor = Color.white.opacity(0.38)
        } else if isHovered {
            strokeColor = Color.white.opacity(0.24)
        } else {
            strokeColor = Color.clear
        }

        return RoundedRectangle(cornerRadius: 7)
            .fill(fillColor)
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(strokeColor, lineWidth: 1)
            )
    }

    private func shortcutDisplay(for selection: SettingsStore.DictationPromptSelection) -> String? {
        guard self.promptMode.normalized == .dictate else { return nil }

        var displays: [String] = []
        if self.settings.dictationPromptSelection(for: .primary) == selection {
            displays.append(self.settings.primaryDictationShortcutDisplayString)
        }
        if self.settings.promptModeShortcutEnabled,
           self.settings.dictationPromptSelection(for: .secondary) == selection
        {
            displays.append(self.settings.promptModeHotkeyShortcut.displayString)
        }
        if let shortcut = self.settings.dictationPromptConfiguration(for: selection).shortcut {
            displays.append(shortcut.displayString)
        }

        let uniqueDisplays = displays.reduce(into: [String]()) { result, display in
            let trimmed = display.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !result.contains(trimmed) {
                result.append(trimmed)
            }
        }
        return uniqueDisplays.isEmpty ? nil : uniqueDisplays.joined(separator: " · ")
    }

    @ViewBuilder
    private func shortcutBadge(for selection: SettingsStore.DictationPromptSelection) -> some View {
        if let shortcut = self.shortcutDisplay(for: selection) {
            Text(shortcut)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 82)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        }
    }

    @ViewBuilder
    private func offRow() -> some View {
        let activeSlot = self.contentState.activeDictationShortcutSlot ?? .primary
        let isSelected = self.settings.dictationPromptSelection(for: activeSlot) == .off
        Button(action: {
            if self.promptMode.normalized == .dictate {
                self.contentState.onDictationPromptSelectionRequested?(.off)
            } else {
                self.settings.setDictationPromptSelection(.off)
            }
            self.restoreTypingTargetApp()
            self.onDismissRequested()
        }) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Fast")
                Spacer(minLength: 12)
                Text("No cleanup")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                self.shortcutBadge(for: .off)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(self.rowBackground(isSelected: isSelected, rowID: "off"))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            self.hoveredRowID = hovering ? "off" : nil
        }
    }

    @ViewBuilder
    private func defaultRow(selectedID: String?) -> some View {
        let activeSlot = self.contentState.activeDictationShortcutSlot ?? .primary
        let isSelected = (
            self.promptMode.normalized == .dictate
                ? (self.settings.dictationPromptSelection(for: activeSlot) == .default)
                : (selectedID == nil)
        )
        Button(action: {
            if self.promptMode.normalized == .dictate {
                self.contentState.onDictationPromptSelectionRequested?(.default)
            } else {
                self.settings.setSelectedPromptID(nil, for: self.promptMode)
            }
            self.restoreTypingTargetApp()
            self.onDismissRequested()
        }) {
            HStack {
                Text("Cleanup")
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                self.shortcutBadge(for: .default)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(self.rowBackground(isSelected: isSelected, rowID: "default"))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            self.hoveredRowID = hovering ? "default" : nil
        }
    }

    @ViewBuilder
    private func privateAIRow() -> some View {
        let activeSlot = self.contentState.activeDictationShortcutSlot ?? .primary
        let isAvailable = PrivateAIProviderPromptFormat.isAvailable(settings: self.settings)
        let isSelected = self.settings.dictationPromptSelection(for: activeSlot) == .privateAI
        Button(action: {
            guard isAvailable else { return }
            self.contentState.onDictationPromptSelectionRequested?(.privateAI)
            self.restoreTypingTargetApp()
            self.onDismissRequested()
        }) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Cleanup")
                Spacer(minLength: 12)
                Text("Fluid-1")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                self.shortcutBadge(for: .privateAI)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(self.rowBackground(isSelected: isSelected, rowID: PrivateAIProviderFeature.shared.providerID))
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .opacity(isAvailable ? 1 : 0.45)
        .help(isAvailable ? "Use \(PrivateAIProviderFeature.displayName)" : "Select \(PrivateAIProviderFeature.displayName) to enable this prompt")
        .onHover { hovering in
            self.hoveredRowID = hovering && isAvailable ? PrivateAIProviderFeature.shared.providerID : nil
        }
    }

    @ViewBuilder
    private func profileRow(_ profile: SettingsStore.DictationPromptProfile, selectedID: String?) -> some View {
        let activeSlot = self.contentState.activeDictationShortcutSlot ?? .primary
        let isSelected = (
            self.promptMode.normalized == .dictate
                ? (self.settings.dictationPromptSelection(for: activeSlot) == .profile(profile.id))
                : (selectedID == profile.id)
        )
        Button(action: {
            if self.promptMode.normalized == .dictate {
                self.contentState.onDictationPromptSelectionRequested?(.profile(profile.id))
            } else {
                self.settings.setSelectedPromptID(profile.id, for: self.promptMode)
            }
            self.restoreTypingTargetApp()
            self.onDismissRequested()
        }) {
            HStack {
                Text(profile.name.isEmpty ? "Untitled" : profile.name)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                self.shortcutBadge(for: .profile(profile.id))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(self.rowBackground(isSelected: isSelected, rowID: profile.id))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            self.hoveredRowID = hovering ? profile.id : nil
        }
    }

    var body: some View {
        let selectedID = self.settings.selectedPromptID(for: self.promptMode)
        let profiles = self.settings.promptProfiles(for: self.promptMode)

        VStack(alignment: .leading, spacing: 0) {
            if self.promptMode.normalized == .dictate {
                Text("ON-DEVICE")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                    .padding(.bottom, 3)

                self.offRow()

                if PrivateFeatures.privateAIProvider {
                    self.privateAIRow()
                }
            }

            if self.promptMode.normalized == .dictate {
                Divider()
                    .padding(.vertical, 4)
            }

            Text("EXTERNAL")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.horizontal, 8)
                .padding(.top, self.promptMode.normalized == .dictate ? 0 : 4)
                .padding(.bottom, 3)

            self.defaultRow(selectedID: selectedID)

            if !profiles.isEmpty {
                ForEach(profiles) { profile in
                    self.profileRow(profile, selectedID: selectedID)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .frame(width: min(self.maxWidth, 250), alignment: .leading)
        .preferredColorScheme(.dark)
        .onHover { hovering in
            self.onHoverChanged(hovering)
        }
    }

    private func restoreTypingTargetApp() {
        let pid = NotchContentState.shared.recordingTargetPID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let pid { _ = TypingService.activateApp(pid: pid) }
        }
    }
}

private struct BottomOverlayActionsMenuView: View {
    @ObservedObject private var contentState = NotchContentState.shared
    @ObservedObject private var historyStore = TranscriptionHistoryStore.shared
    @ObservedObject private var settings = SettingsStore.shared

    let maxWidth: CGFloat
    let onHoverChanged: (Bool) -> Void
    let onDismissRequested: () -> Void

    @State private var hoveredRowID: String?

    private var normalizedOverlayMode: OverlayMode {
        .dictation
    }

    private var canReprocessLast: Bool {
        !self.historyStore.entries.isEmpty && !self.contentState.isProcessing
    }

    private var latestEntry: TranscriptionHistoryEntry? {
        self.historyStore.entries.first
    }

    private var canCopyLast: Bool {
        guard !self.contentState.isProcessing else { return false }
        return self.latestEntry?.clipboardText != nil
    }

    private var canPasteLast: Bool {
        self.canCopyLast
    }

    private var canUndoLastAI: Bool {
        guard !self.contentState.isProcessing else { return false }
        guard let latest = self.latestEntry else { return false }
        let raw = latest.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        return latest.wasAIProcessed && !raw.isEmpty
    }

    private func rowBackground(isSelected: Bool, rowID: String) -> some View {
        let isHovered = self.hoveredRowID == rowID
        let fillColor: Color
        if isSelected {
            fillColor = Color.white.opacity(0.28)
        } else if isHovered {
            fillColor = Color.white.opacity(0.20)
        } else {
            fillColor = Color.clear
        }

        let strokeColor: Color
        if isSelected {
            strokeColor = Color.white.opacity(0.38)
        } else if isHovered {
            strokeColor = Color.white.opacity(0.24)
        } else {
            strokeColor = Color.clear
        }

        return RoundedRectangle(cornerRadius: 7)
            .fill(fillColor)
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(strokeColor, lineWidth: 1)
            )
    }

    private func actionRow(
        title: String,
        icon: String,
        rowID: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: {
            guard enabled else { return }
            action()
            self.onDismissRequested()
        }) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(self.rowBackground(isSelected: false, rowID: rowID))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hovering in
            guard enabled else {
                self.hoveredRowID = nil
                return
            }
            self.hoveredRowID = hovering ? rowID : nil
        }
    }

    private func modeRow(_ title: String, mode: OverlayMode, rowID: String) -> some View {
        let isSelected = self.normalizedOverlayMode == mode
        let shortcut = OverlayShortcutResolver.shortcutDisplay(for: mode, settings: self.settings)
        return Button(action: {
            guard !self.contentState.isProcessing else { return }
            self.contentState.onOverlayModeSwitchRequested?(mode)
            self.onDismissRequested()
        }) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if !shortcut.isEmpty {
                    Text(shortcut)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(self.rowBackground(isSelected: isSelected, rowID: rowID))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            self.hoveredRowID = hovering ? rowID : nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("MODE")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 3)

            self.modeRow("Dictate", mode: .dictation, rowID: "mode_dictate")

            Divider()
                .padding(.vertical, 4)

            Text("ACTIONS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.horizontal, 8)
                .padding(.bottom, 3)

            self.actionRow(
                title: "Process Again",
                icon: "arrow.clockwise",
                rowID: "reprocess_last",
                enabled: self.canReprocessLast
            ) {
                self.contentState.onReprocessLastRequested?()
            }

            self.actionRow(
                title: "Copy Last",
                icon: "doc.on.doc",
                rowID: "copy_last",
                enabled: self.canCopyLast
            ) {
                self.contentState.onCopyLastRequested?()
            }

            self.actionRow(
                title: "Insert Last",
                icon: "arrow.down.doc",
                rowID: "paste_last",
                enabled: self.canPasteLast
            ) {
                self.contentState.onPasteLastRequested?()
            }

            self.actionRow(
                title: "Use Raw Text",
                icon: "arrow.uturn.backward",
                rowID: "undo_ai_last",
                enabled: self.canUndoLastAI
            ) {
                self.contentState.onUndoLastAIRequested?()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .frame(maxWidth: self.maxWidth)
        .preferredColorScheme(.dark)
        .onHover { hovering in
            self.onHoverChanged(hovering)
        }
    }
}

struct PromptSelectorAnchorReader: NSViewRepresentable {
    let onFrameChange: (CGRect, NSWindow?) -> Void

    func makeNSView(context: Context) -> AnchorReportingView {
        let view = AnchorReportingView()
        view.onFrameChange = self.onFrameChange
        return view
    }

    func updateNSView(_ nsView: AnchorReportingView, context: Context) {
        nsView.onFrameChange = self.onFrameChange
        nsView.reportFrame(force: true)
    }

    final class AnchorReportingView: NSView {
        var onFrameChange: ((CGRect, NSWindow?) -> Void)?
        private var windowObservers: [NSObjectProtocol] = []
        private var lastReportedFrameInScreen: CGRect = .null
        private weak var lastReportedWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            self.installWindowObservers()
            self.reportFrame(force: true)
        }

        override func layout() {
            super.layout()
            self.reportFrame()
        }

        deinit {
            self.cleanup()
        }

        func cleanup() {
            for observer in self.windowObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            self.windowObservers.removeAll()
        }

        private func installWindowObservers() {
            self.cleanup()
            guard let window = self.window else { return }

            let center = NotificationCenter.default
            self.windowObservers.append(
                center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
                    self?.reportFrame()
                }
            )
            self.windowObservers.append(
                center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                    self?.reportFrame()
                }
            )
            self.windowObservers.append(
                center.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main) { [weak self] _ in
                    self?.reportFrame()
                }
            )
        }

        func reportFrame(force: Bool = false) {
            guard let window = self.window else {
                if force || !self.lastReportedFrameInScreen.isNull {
                    self.lastReportedFrameInScreen = .null
                    self.lastReportedWindow = nil
                    self.onFrameChange?(CGRect.zero, nil)
                }
                return
            }

            let frameInWindow = self.convert(self.bounds, to: nil)
            let frameInScreen = window.convertToScreen(frameInWindow)
            let frameTolerance: CGFloat = 0.5
            let hasLastFrame = !self.lastReportedFrameInScreen.isNull
            let frameChanged = !hasLastFrame ||
                abs(frameInScreen.origin.x - self.lastReportedFrameInScreen.origin.x) > frameTolerance ||
                abs(frameInScreen.origin.y - self.lastReportedFrameInScreen.origin.y) > frameTolerance ||
                abs(frameInScreen.size.width - self.lastReportedFrameInScreen.size.width) > frameTolerance ||
                abs(frameInScreen.size.height - self.lastReportedFrameInScreen.size.height) > frameTolerance
            let windowChanged = self.lastReportedWindow !== window

            guard force || frameChanged || windowChanged else { return }

            self.lastReportedFrameInScreen = frameInScreen
            self.lastReportedWindow = window
            self.onFrameChange?(frameInScreen, window)
        }
    }
}

enum PillShadowMetrics {
    // Keep in sync with the pill shadow in BottomOverlayView.body.
    static let radius: CGFloat = 10
    static let yOffset: CGFloat = 4
    /// Hit-test inset must cover the visible shadow extent (radius + |offset|)
    /// plus a small margin so the shadow region doesn't intercept clicks.
    static let hitTestInset: CGFloat = radius + abs(yOffset) + 12
}

private final class BottomOverlayHostingView: NSHostingView<BottomOverlayView> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        if SettingsStore.shared.overlaySize == .pill {
            let visibleOverlayBounds = self.bounds.insetBy(
                dx: PillShadowMetrics.hitTestInset,
                dy: PillShadowMetrics.hitTestInset
            )
            guard visibleOverlayBounds.contains(point) else { return nil }
        }
        return super.hitTest(point)
    }
}
