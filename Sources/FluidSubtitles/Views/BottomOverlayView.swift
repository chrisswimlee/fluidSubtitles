//
//  BottomOverlayView.swift
//  Fluid
//
//  Bottom overlay for transcription (alternative to notch overlay)
//

import AppKit
import Combine
import QuartzCore
import SwiftUI


// swiftlint:disable file_length type_body_length function_body_length cyclomatic_complexity
// Tracked grandfather: dictation overlay view. Do not add new product surfaces here.

private struct DynamicPreviewHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 {
            value = next
        }
    }
}

// MARK: - Bottom Overlay SwiftUI View

struct BottomOverlayView: View {
    @ObservedObject private var contentState = NotchContentState.shared
    @ObservedObject private var appServices = AppServices.shared
    @ObservedObject private var activeAppMonitor = ActiveAppMonitor.shared
    @ObservedObject private var historyStore = TranscriptionHistoryStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHoveringModeChip = false
    @State private var isHoveringPromptChip = false
    @State private var isHoveringActionsChip = false
    @State private var isHoveringSettingsChip = false
    @State private var modeSelectorFrameInScreen: CGRect = .zero
    @State private var modeSelectorWindow: NSWindow?
    @State private var promptSelectorFrameInScreen: CGRect = .zero
    @State private var promptSelectorWindow: NSWindow?
    @State private var actionsSelectorFrameInScreen: CGRect = .zero
    @State private var actionsSelectorWindow: NSWindow?
    @State private var dynamicPreviewMeasuredHeight: CGFloat = 0
    @State private var frozenDynamicPreviewHeight: CGFloat?
    @State private var dynamicPreviewResizeBucket: Int = 0
    @State private var processingStatusVisible = false
    @State private var processingStatusCycleID = 0
    @State private var lastResolvedAppIcon: NSImage?
    @State private var borderAnimationStartedAt: Date?

    struct LayoutConstants {
        let hPadding: CGFloat
        let vPadding: CGFloat
        let waveformWidth: CGFloat
        let waveformHeight: CGFloat
        let iconSize: CGFloat
        let transFontSize: CGFloat
        let modeFontSize: CGFloat
        let cornerRadius: CGFloat
        let barCount: Int
        let barWidth: CGFloat
        let barSpacing: CGFloat
        let minBarHeight: CGFloat
        let maxBarHeight: CGFloat
        let containerWidth: CGFloat
        let overlayWidth: CGFloat
        let overlayHeight: CGFloat
        let previewBoxHeight: CGFloat
        let usesFixedCanvas: Bool
        let showsTopControls: Bool
        let showsPreview: Bool
        let showsModeLabel: Bool

        static func get(for size: SettingsStore.OverlaySize) -> LayoutConstants {
            switch size {
            case .pill:
                return LayoutConstants(
                    hPadding: 12,
                    vPadding: 8,
                    waveformWidth: 46,
                    waveformHeight: 30,
                    iconSize: 18,
                    transFontSize: 10,
                    modeFontSize: 9,
                    cornerRadius: 23,
                    barCount: 8,
                    barWidth: 3.0,
                    barSpacing: 2.5,
                    minBarHeight: 4,
                    maxBarHeight: 28,
                    containerWidth: 100,
                    overlayWidth: 100,
                    overlayHeight: 46,
                    previewBoxHeight: 0,
                    usesFixedCanvas: false,
                    showsTopControls: false,
                    showsPreview: false,
                    showsModeLabel: false
                )
            case .small:
                return LayoutConstants(
                    hPadding: 10,
                    vPadding: 6,
                    waveformWidth: 90,
                    waveformHeight: 20,
                    iconSize: 16,
                    transFontSize: 11,
                    modeFontSize: 10,
                    cornerRadius: 14,
                    barCount: 7,
                    barWidth: 3.0,
                    barSpacing: 3.5,
                    minBarHeight: 5,
                    maxBarHeight: 16,
                    containerWidth: 200,
                    overlayWidth: 300,
                    overlayHeight: 124,
                    previewBoxHeight: 0,
                    usesFixedCanvas: false,
                    showsTopControls: false,
                    showsPreview: true,
                    showsModeLabel: true
                )
            case .medium:
                return LayoutConstants(
                    hPadding: 18,
                    vPadding: 12,
                    waveformWidth: 130,
                    waveformHeight: 32,
                    iconSize: 20,
                    transFontSize: 13,
                    modeFontSize: 12,
                    cornerRadius: 18,
                    barCount: 8,
                    barWidth: 3.5,
                    barSpacing: 4.5,
                    minBarHeight: 6,
                    maxBarHeight: 28,
                    containerWidth: 340,
                    overlayWidth: 380,
                    overlayHeight: 156,
                    previewBoxHeight: 0,
                    usesFixedCanvas: false,
                    showsTopControls: true,
                    showsPreview: true,
                    showsModeLabel: true
                )
            case .large:
                return LayoutConstants(
                    hPadding: 18,
                    vPadding: 12,
                    waveformWidth: 180,
                    waveformHeight: 48,
                    iconSize: 26,
                    transFontSize: 15,
                    modeFontSize: 14,
                    cornerRadius: 24,
                    barCount: 11,
                    barWidth: 5.0,
                    barSpacing: 6.0,
                    minBarHeight: 8,
                    maxBarHeight: 44,
                    containerWidth: 600,
                    overlayWidth: 600,
                    overlayHeight: 288,
                    previewBoxHeight: 92,
                    usesFixedCanvas: true,
                    showsTopControls: true,
                    showsPreview: true,
                    showsModeLabel: true
                )
            }
        }
    }

    private var layout: LayoutConstants {
        LayoutConstants.get(for: self.settings.overlaySize)
    }

    private var isCompactControls: Bool {
        self.settings.overlaySize == .medium
    }

    private var waveformHorizontalOffset: CGFloat {
        self.settings.overlaySize == .medium ? -28 : 0
    }

    private var isPillSize: Bool {
        self.settings.overlaySize == .pill
    }

    private var modeColor: Color {
        self.contentState.mode.notchColor
    }

    private var modeLabel: String {
        "Dictate"
    }

    private var displayedAppIcon: NSImage? {
        self.contentState.targetAppIcon ?? self.activeAppMonitor.activeAppIcon ?? self.lastResolvedAppIcon
    }

    private var processingLabel: String {
        "Refining..."
    }

    private var showsSpokenSendIndicator: Bool {
        self.contentState.mode == .dictation &&
            self.settings.spokenSendEnabled &&
            self.contentState.spokenSendIndicatorState.isVisible
    }

    private var spokenSendIndicatorSize: CGFloat {
        max(self.layout.modeFontSize + 3, 13)
    }

    private static let transientOverlayStatusTexts: Set<String> = [
        "Transcribing",
        "Refining",
        "Thinking",
        "Working",
        "Transcribing...",
        "Refining...",
        "Thinking...",
        "Working...",
    ]

    /// ContentView writes transient status strings into transcriptionText while processing
    /// (e.g. "Transcribing...", "Refining..."). Prefer that when present.
    private var processingStatusText: String {
        let t = self.contentState.transcriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.transientOverlayStatusTexts.contains(t) else { return self.processingLabel }
        return t
    }

    private var hasTranscription: Bool {
        !self.transcriptionPreviewText.isEmpty
    }

    private var activePromptMode: SettingsStore.PromptMode? {
        .dictate
    }

    private var isPromptSelectableMode: Bool {
        self.activePromptMode != nil
    }

    private var promptResolutionBundleID: String? {
        self.activeAppMonitor.activeAppBundleID
    }

    private var activeDictationShortcutSlot: SettingsStore.DictationShortcutSlot {
        self.contentState.activeDictationShortcutSlot ?? .primary
    }

    private var isAppPromptOverrideActive: Bool {
        guard let activePromptMode else { return false }
        if activePromptMode.normalized == .dictate {
            return self.settings.isAppDictationPromptBindingActive(
                for: self.activeDictationShortcutSlot,
                appBundleID: self.promptResolutionBundleID
            )
        }
        return self.settings.hasAppPromptBinding(
            for: activePromptMode,
            appBundleID: self.promptResolutionBundleID
        )
    }

    private var selectedPromptLabel: String {
        guard let activePromptMode else { return "N/A" }
        if activePromptMode.normalized == .dictate {
            return self.settings.dictationPromptDisplayName(
                for: self.activeDictationShortcutSlot,
                appBundleID: self.promptResolutionBundleID
            )
        }
        if let profile = self.settings.resolvedPromptProfile(
            for: activePromptMode,
            appBundleID: self.promptResolutionBundleID
        ) {
            let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "Untitled" : name
        }
        return "Default"
    }

    private var promptSelectorBuiltInLabel: String? {
        guard let activePromptMode else { return nil }
        if activePromptMode.normalized == .dictate {
            switch self.settings.dictationPromptSelection(for: self.activeDictationShortcutSlot) {
            case .off:
                return "Fast"
            case .privateAI:
                return "Cleanup"
            case .default:
                let hasAppOverride = self.settings.resolvedDictationPromptProfile(
                    for: self.activeDictationShortcutSlot,
                    appBundleID: self.promptResolutionBundleID
                ) != nil
                return hasAppOverride ? nil : "Cleanup"
            case .profile:
                return nil
            }
        }

        return self.settings.resolvedPromptProfile(
            for: activePromptMode,
            appBundleID: self.promptResolutionBundleID
        ) == nil ? "Cleanup" : nil
    }

    private var promptSelectorDisplayLabel: String {
        let selectedLabel = self.selectedPromptLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = self.promptSelectorBuiltInLabel ?? selectedLabel
        guard !label.isEmpty else { return "Default" }

        let maxLength: Int
        if self.promptSelectorBuiltInLabel == nil {
            maxLength = 11
        } else if self.isCompactControls {
            maxLength = self.isAppPromptOverrideActive ? 8 : 14
        } else {
            maxLength = self.isAppPromptOverrideActive ? 11 : 16
        }

        guard label.count > maxLength else { return label }
        let prefixLength = max(maxLength - 3, 1)
        return "\(label.prefix(prefixLength))..."
    }

    private var promptSelectorIconName: String? {
        switch self.promptSelectorBuiltInLabel {
        case "Fast"?:
            return "bolt.fill"
        case "Cleanup"?:
            return "sparkles"
        default:
            return nil
        }
    }

    private var promptSelectorFontSize: CGFloat {
        if self.isCompactControls { return 10 }
        return max(self.layout.modeFontSize - 1, 9)
    }

    private var promptSelectorLabelFontSize: CGFloat {
        max(self.promptSelectorFontSize - 1, 8)
    }

    private var promptSelectorVerticalPadding: CGFloat {
        4
    }

    private var promptMenuGap: CGFloat {
        max(0, self.layout.vPadding * 0.05)
    }

    private var promptSelectorCornerRadius: CGFloat {
        max(self.layout.cornerRadius * 0.42, 8)
    }

    private var promptSelectorMaxWidth: CGFloat {
        self.layout.waveformWidth * 1.75
    }

    private var previewMaxHeight: CGFloat {
        self.layout.usesFixedCanvas ? self.layout.previewBoxHeight : self.layout.transFontSize * 4.2
    }

    private var shouldReservePreviewArea: Bool {
        self.layout.showsPreview &&
            (self.settings.enableStreamingPreview || self.contentState.isAIProcessingFailureVisible)
    }

    private var overlayFrameHeight: CGFloat? {
        guard self.layout.usesFixedCanvas else { return nil }
        return self.shouldReservePreviewArea ? self.layout.overlayHeight : nil
    }

    private var previewMaxWidth: CGFloat {
        if self.layout.usesFixedCanvas {
            return self.layout.waveformWidth * 2.2
        }

        return max(self.layout.waveformWidth * 2.2, self.layout.containerWidth - self.layout.hPadding * 2)
    }

    private var dynamicPreviewBaseMinHeight: CGFloat {
        guard self.shouldReservePreviewArea else { return 0 }
        let verticalPadding = self.settings.overlaySize == .small
            ? max(2, self.transcriptionVerticalPadding - 1)
            : self.transcriptionVerticalPadding
        return self.estimatedPreviewLineHeight + verticalPadding * 2
    }

    private var effectiveDynamicPreviewLockedHeight: CGFloat? {
        guard self.contentState.isBottomOverlayReleaseTransitioning else { return nil }
        guard let frozenDynamicPreviewHeight else { return nil }
        return max(frozenDynamicPreviewHeight, self.dynamicPreviewBaseMinHeight)
    }

    private var effectiveDynamicPreviewMinHeight: CGFloat {
        self.effectiveDynamicPreviewLockedHeight ?? self.dynamicPreviewBaseMinHeight
    }

    private var estimatedPreviewLineHeight: CGFloat {
        max(self.layout.transFontSize * 1.25, self.layout.transFontSize + 2)
    }

    private var currentPreviewSizingText: String {
        guard self.shouldReservePreviewArea else { return "" }
        if self.shouldShowProcessingPreview {
            return self.processingPreviewText
        }
        return self.shouldShowProcessingStatus ? self.processingStatusText : self.transcriptionPreviewText
    }

    private var shouldShowProcessingStatus: Bool {
        self.shouldReservePreviewArea && self.contentState.isProcessing && self.processingStatusVisible
    }

    private var shouldShowAIProcessingFailure: Bool {
        self.shouldReservePreviewArea && self.contentState.isAIProcessingFailureVisible && !self.contentState.isProcessing
    }

    private var shouldSuppressPreviewDuringRelease: Bool {
        if self.shouldShowProcessingPreview {
            return false
        }
        return self.contentState.isBottomOverlayReleaseTransitioning || self.contentState.isBottomOverlayDismissing
    }

    private func previewResizeBucket(for previewText: String) -> Int {
        guard self.shouldReservePreviewArea else { return 0 }
        if self.shouldShowAIProcessingFailure { return 1 }
        let trimmed = previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return self.shouldShowProcessingStatus ? 1 : 0 }

        if self.settings.overlaySize == .small {
            return 1
        }

        let newlineCount = trimmed.filter { $0 == "\n" }.count
        let estimatedCharacterWidth = max(self.layout.transFontSize * 0.56, 1)
        let characterCapacity = max(Int((self.previewMaxWidth / estimatedCharacterWidth).rounded(.down)), 12)
        let estimatedWrappedLines = max(1, (trimmed.count + characterCapacity - 1) / characterCapacity)
        let maxVisibleLines = max(Int((self.previewMaxHeight / max(self.estimatedPreviewLineHeight, 1)).rounded(.down)), 1)
        return min(max(estimatedWrappedLines + newlineCount, 1), maxVisibleLines)
    }

    private func refreshDynamicPreviewSizeIfNeeded(for previewText: String) {
        guard self.shouldReservePreviewArea else { return }
        guard !self.layout.usesFixedCanvas else { return }
        let nextBucket = self.previewResizeBucket(for: previewText)
        guard nextBucket != self.dynamicPreviewResizeBucket else { return }
        self.dynamicPreviewResizeBucket = nextBucket
        BottomOverlayWindowController.shared.refreshSizeForContent()
    }

    private var transcriptionVerticalPadding: CGFloat {
        max(4, self.layout.vPadding / 2)
    }

    private var transcriptionPreviewText: String {
        let preview = self.contentState.cachedPreviewText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !self.contentState.isProcessing else { return self.contentState.cachedPreviewText }
        guard Self.transientOverlayStatusTexts.contains(preview) else { return self.contentState.cachedPreviewText }
        return ""
    }

    private var processingPreviewText: String {
        guard self.contentState.isProcessing else { return "" }
        let preview = self.transcriptionPreviewText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Self.transientOverlayStatusTexts.contains(preview) else { return "" }
        return self.transcriptionPreviewText
    }

    private var shouldShowProcessingPreview: Bool {
        !self.processingPreviewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func richPreviewText(_ previewText: String) -> Text {
        Text(previewText)
            .foregroundColor(.white.opacity(0.9))
    }

    private var overlayBorderLineWidth: CGFloat {
        self.settings.overlaySize == .large ? 0.8 : 1
    }

    private var overlayBorderTopOpacity: Double {
        switch self.settings.overlaySize {
        case .pill: return 0.22 // a touch crisper so the smaller pill reads clearly
        case .large: return 0.10
        default: return 0.15
        }
    }

    private var overlayBorderBottomOpacity: Double {
        switch self.settings.overlaySize {
        case .pill: return 0.10
        case .large: return 0.05
        default: return 0.08
        }
    }

    private var overlayAnimatedOffsetY: CGFloat {
        if self.contentState.isBottomOverlayDismissing {
            return self.contentState.bottomOverlayDismissOffsetY
        }
        return 0
    }

    private var overlayAnimatedScale: CGFloat {
        self.contentState.isBottomOverlayDismissing ? 0.985 : 1.0
    }

    private var overlayAnimatedOpacity: Double {
        1.0
    }

    private func chipBackground(isHovered: Bool, disabled: Bool) -> some View {
        let fillColor: Color
        if disabled {
            fillColor = Color.black.opacity(0.95)
        } else if isHovered {
            fillColor = Color(red: 0.13, green: 0.13, blue: 0.16)
        } else {
            fillColor = Color.black
        }

        let topStrokeOpacity: Double = disabled ? 0.10 : (isHovered ? 0.36 : 0.14)
        let bottomStrokeOpacity: Double = disabled ? 0.06 : (isHovered ? 0.22 : 0.08)
        let hoverShadowColor: Color = (isHovered && !disabled) ? Color.white.opacity(0.16) : .clear

        return RoundedRectangle(cornerRadius: self.promptSelectorCornerRadius)
            .fill(fillColor)
            .overlay(
                RoundedRectangle(cornerRadius: self.promptSelectorCornerRadius)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(topStrokeOpacity),
                                Color.white.opacity(bottomStrokeOpacity),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: hoverShadowColor, radius: 6, x: 0, y: 1)
    }

    private func closePromptMenu() {
        BottomOverlayPromptMenuController.shared.hide()
    }

    private func rememberAppIcon(_ icon: NSImage?) {
        guard let icon else { return }
        self.lastResolvedAppIcon = icon
    }

    private func handlePromptSelectorHover(_ hovering: Bool) {
        // Hover-open disabled by design.
    }

    private func handlePromptSelectorFrameChange(_ frameInScreen: CGRect, window: NSWindow?) {
        guard self.promptSelectorFrameInScreen != frameInScreen || self.promptSelectorWindow !== window else {
            return
        }
        DispatchQueue.main.async {
            self.promptSelectorFrameInScreen = frameInScreen
            self.promptSelectorWindow = window
            guard self.layout.showsTopControls, self.isPromptSelectableMode, !self.contentState.isProcessing else {
                BottomOverlayPromptMenuController.shared.hide()
                return
            }
            BottomOverlayPromptMenuController.shared.updateAnchor(
                selectorFrameInScreen: frameInScreen,
                parentWindow: window,
                maxWidth: self.promptSelectorMaxWidth,
                menuGap: self.promptMenuGap
            )
        }
    }

    private func requestModeSwitch(_ mode: OverlayMode) {
        guard !self.contentState.isProcessing else { return }
        self.contentState.onOverlayModeSwitchRequested?(mode)
        BottomOverlayModeMenuController.shared.hide()
    }

    private func closeModeMenu() {
        BottomOverlayModeMenuController.shared.hide()
    }

    private func closeActionsMenu() {
        BottomOverlayActionsMenuController.shared.hide()
    }

    private func handleModeSelectorHover(_ hovering: Bool) {
        guard !self.contentState.isProcessing else {
            self.closeModeMenu()
            return
        }
        BottomOverlayModeMenuController.shared.selectorHoverChanged(hovering)
    }

    private func handleModeSelectorFrameChange(_ frameInScreen: CGRect, window: NSWindow?) {
        guard self.modeSelectorFrameInScreen != frameInScreen || self.modeSelectorWindow !== window else {
            return
        }
        DispatchQueue.main.async {
            self.modeSelectorFrameInScreen = frameInScreen
            self.modeSelectorWindow = window
            guard self.layout.showsTopControls, !self.contentState.isProcessing else {
                BottomOverlayModeMenuController.shared.hide()
                return
            }
            BottomOverlayModeMenuController.shared.updateAnchor(
                selectorFrameInScreen: frameInScreen,
                parentWindow: window,
                maxWidth: self.promptSelectorMaxWidth,
                menuGap: self.promptMenuGap
            )
        }
    }

    private func handleActionsSelectorHover(_ hovering: Bool) {
        let actionsDisabled = self.contentState.isProcessing
        guard !actionsDisabled else {
            self.closeActionsMenu()
            return
        }
        BottomOverlayActionsMenuController.shared.selectorHoverChanged(hovering)
    }

    private func handleActionsSelectorFrameChange(_ frameInScreen: CGRect, window: NSWindow?) {
        guard self.actionsSelectorFrameInScreen != frameInScreen || self.actionsSelectorWindow !== window else {
            return
        }
        DispatchQueue.main.async {
            self.actionsSelectorFrameInScreen = frameInScreen
            self.actionsSelectorWindow = window
            let actionsDisabled = self.contentState.isProcessing
            guard self.layout.showsTopControls, !actionsDisabled else {
                BottomOverlayActionsMenuController.shared.hide()
                return
            }
            BottomOverlayActionsMenuController.shared.updateAnchor(
                selectorFrameInScreen: frameInScreen,
                parentWindow: window,
                maxWidth: self.promptSelectorMaxWidth,
                menuGap: self.promptMenuGap
            )
        }
    }

    private var modeSelectorTrigger: some View {
        HStack(spacing: 5) {
            if !self.isCompactControls {
                Text("Mode:")
                    .font(.system(size: self.promptSelectorFontSize, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Text(self.modeLabel)
                .font(.system(size: self.promptSelectorFontSize, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
            Image(systemName: "chevron.up")
                .font(.system(size: max(self.promptSelectorFontSize - 1, 8), weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 8)
        .padding(.vertical, self.promptSelectorVerticalPadding)
        .background(
            self.chipBackground(isHovered: self.isHoveringModeChip, disabled: self.contentState.isProcessing)
        )
    }

    private var modeSelectorView: some View {
        self.modeSelectorTrigger
            .background(
                PromptSelectorAnchorReader { frameInScreen, window in
                    self.handleModeSelectorFrameChange(frameInScreen, window: window)
                }
                .allowsHitTesting(false)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                self.isHoveringModeChip = hovering && !self.contentState.isProcessing
            }
            .onTapGesture {
                guard self.layout.showsTopControls, !self.contentState.isProcessing else { return }
                self.closePromptMenu()
                self.closeActionsMenu()
                BottomOverlayModeMenuController.shared.updateAnchor(
                    selectorFrameInScreen: self.modeSelectorFrameInScreen,
                    parentWindow: self.modeSelectorWindow,
                    maxWidth: self.promptSelectorMaxWidth,
                    menuGap: self.promptMenuGap
                )
                BottomOverlayModeMenuController.shared.toggleFromTap()
            }
    }

    private var promptSelectorTrigger: some View {
        HStack(spacing: 5) {
            if let promptSelectorIconName = self.promptSelectorIconName {
                Image(systemName: promptSelectorIconName)
                    .font(.system(size: max(self.promptSelectorFontSize - 1, 9), weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
            }
            Text(self.promptSelectorDisplayLabel)
                .font(.system(size: self.promptSelectorFontSize, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(
                    maxWidth: self.promptSelectorBuiltInLabel == nil ? 72 : nil,
                    alignment: .leading
                )
            if self.isAppPromptOverrideActive {
                Text("App")
                    .font(.system(size: max(self.promptSelectorFontSize - 2, 8), weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.15))
                    )
            }
            Image(systemName: "chevron.down")
                .font(.system(size: max(self.promptSelectorFontSize - 1, 8), weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, self.promptSelectorVerticalPadding)
        .background(
            RoundedRectangle(cornerRadius: self.promptSelectorCornerRadius, style: .continuous)
                .fill(
                    self.isHoveringPromptChip && self.isPromptSelectableMode && !self.contentState.isProcessing
                        ? Color.white.opacity(0.10)
                        : Color.clear
                )
        )
        .overlay(alignment: .top) {
            if self.isHoveringPromptChip, self.isPromptSelectableMode, !self.contentState.isProcessing {
                Text("Select cleanup mode")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.94))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.16), lineWidth: 1)
                    )
                    .fixedSize()
                    .offset(y: -30)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Select cleanup mode")
    }

    private var promptSelectorView: some View {
        Group {
            if self.isPromptSelectableMode {
                self.promptSelectorTrigger
                    .background(
                        PromptSelectorAnchorReader { frameInScreen, window in
                            self.handlePromptSelectorFrameChange(frameInScreen, window: window)
                        }
                        .allowsHitTesting(false)
                    )
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        self.isHoveringPromptChip = hovering && !self.contentState.isProcessing
                    }
                    .onTapGesture {
                        guard self.layout.showsTopControls, self.isPromptSelectableMode, !self.contentState.isProcessing else { return }
                        self.closeModeMenu()
                        self.closeActionsMenu()
                        BottomOverlayPromptMenuController.shared.updateAnchor(
                            selectorFrameInScreen: self.promptSelectorFrameInScreen,
                            parentWindow: self.promptSelectorWindow,
                            maxWidth: self.promptSelectorMaxWidth,
                            menuGap: self.promptMenuGap
                        )
                        BottomOverlayPromptMenuController.shared.toggleFromTap()
                    }
            } else {
                self.promptSelectorTrigger
                    .opacity(0.6)
                    .onHover { _ in
                        self.isHoveringPromptChip = false
                    }
            }
        }
    }

    private var actionsSelectorTrigger: some View {
        let actionsDisabled = self.contentState.isProcessing
        return HStack(spacing: 0) {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white.opacity(actionsDisabled ? 0.3 : 0.78))
        }
        .frame(width: 32, height: 32)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(self.isHoveringActionsChip && !actionsDisabled ? Color.white.opacity(0.1) : Color.clear)
        )
        .overlay(alignment: .top) {
            if self.isHoveringActionsChip, !actionsDisabled {
                Text("Actions")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.94))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.16), lineWidth: 1)
                    )
                    .fixedSize()
                    .offset(y: -30)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Actions")
    }

    private var actionsSelectorView: some View {
        let actionsDisabled = self.contentState.isProcessing
        return self.actionsSelectorTrigger
            .background(
                PromptSelectorAnchorReader { frameInScreen, window in
                    self.handleActionsSelectorFrameChange(frameInScreen, window: window)
                }
                .allowsHitTesting(false)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                self.isHoveringActionsChip = hovering && !actionsDisabled
                self.handleActionsSelectorHover(hovering)
            }
            .onTapGesture {
                guard self.layout.showsTopControls, !actionsDisabled else { return }
                self.isHoveringActionsChip = false
                self.closePromptMenu()
                self.closeModeMenu()
                BottomOverlayActionsMenuController.shared.updateAnchor(
                    selectorFrameInScreen: self.actionsSelectorFrameInScreen,
                    parentWindow: self.actionsSelectorWindow,
                    maxWidth: self.promptSelectorMaxWidth,
                    menuGap: self.promptMenuGap
                )
                BottomOverlayActionsMenuController.shared.toggleFromTap()
            }
    }

    private var settingsChip: some View {
        let disabled = false
        return HStack(spacing: 0) {
            Image(systemName: "gearshape")
                .font(.system(size: max(self.promptSelectorFontSize + 1, 10), weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, self.promptSelectorVerticalPadding)
        .background(
            self.chipBackground(
                isHovered: self.isHoveringSettingsChip,
                disabled: disabled
            )
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            self.isHoveringSettingsChip = hovering
        }
        .onTapGesture {
            self.closePromptMenu()
            self.closeModeMenu()
            self.closeActionsMenu()
            self.contentState.onOpenPreferencesRequested?()
        }
        .help("Open Preferences")
    }

    private func failureIconButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: max(self.layout.transFontSize - 1, 10), weight: .semibold))
                .foregroundStyle(.white.opacity(0.86))
                .frame(width: 20, height: 20)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var aiProcessingFailureView: some View {
        HStack(spacing: 8) {
            Text(self.contentState.aiProcessingFailureMessage)
                .font(.system(size: self.layout.transFontSize, weight: .semibold))
                .foregroundStyle(
                    self.contentState.canRetryAIProcessingFailure
                        ? Color.white.opacity(0.9)
                        : Color.orange.opacity(0.9)
                )
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            if self.contentState.canRetryAIProcessingFailure {
                self.failureIconButton(systemName: "arrow.clockwise", help: "Try again") {
                    self.contentState.clearAIProcessingFailure()
                    self.contentState.onReprocessLastRequested?()
                }
            }

            self.failureIconButton(systemName: "xmark", help: "Dismiss") {
                self.contentState.clearAIProcessingFailure()
                NotchOverlayManager.shared.hide()
            }
        }
        .frame(maxWidth: self.previewMaxWidth, alignment: .leading)
    }

    private var targetAppIconView: some View {
        let appIcon = self.displayedAppIcon
        let showModelLoading = self.layout.showsModeLabel && !self.appServices.asr.isAsrReady &&
            (self.appServices.asr.isLoadingModel || self.appServices.asr.isDownloadingModel)
        return VStack(spacing: 2) {
            if showModelLoading {
                ProgressView()
                    .controlSize(.mini)
            }
            if let appIcon = appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: self.layout.iconSize, height: self.layout.iconSize)
                    .clipShape(RoundedRectangle(cornerRadius: self.layout.iconSize / 4))
            } else if !self.layout.showsModeLabel {
                Circle()
                    .fill(self.modeColor.opacity(0.9))
                    .frame(width: max(self.layout.iconSize * 0.45, 7), height: max(self.layout.iconSize * 0.45, 7))
            }
        }
        .frame(width: self.layout.iconSize, height: self.layout.iconSize)
        .opacity((appIcon != nil || showModelLoading || !self.layout.showsModeLabel) ? 1 : 0)
    }

    private var leadingAppContextView: some View {
        HStack(spacing: self.isPillSize ? 4 : 8) {
            if self.showsSpokenSendIndicator {
                SpokenSendIndicatorView(
                    state: self.contentState.spokenSendIndicatorState,
                    color: self.modeColor,
                    size: self.isPillSize ? 14 : self.spokenSendIndicatorSize
                )
                .id(self.contentState.spokenSendCountdownID)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }

            self.targetAppIconView
        }
        .animation(
            self.reduceMotion ? nil : .easeOut(duration: 0.14),
            value: self.contentState.spokenSendIndicatorState
        )
    }

    private func scrollablePreviewText(_ previewText: String) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                self.richPreviewText(previewText)
                    .font(.system(size: self.layout.transFontSize, weight: .medium))
                    .multilineTextAlignment(.leading)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(height: 1).id("bottom")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            .onChange(of: previewText) { _, _ in
                DispatchQueue.main.async {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func dynamicPreviewText(_ previewText: String) -> some View {
        if self.settings.overlaySize == .small {
            self.richPreviewText(previewText)
                .font(.system(size: self.layout.transFontSize, weight: .medium))
                .multilineTextAlignment(.leading)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, max(2, self.transcriptionVerticalPadding - 1))
        } else {
            self.richPreviewText(previewText)
                .font(.system(size: self.layout.transFontSize, weight: .medium))
                .multilineTextAlignment(.leading)
                .lineLimit(Int(self.previewMaxHeight / max(self.estimatedPreviewLineHeight, 1)))
                .truncationMode(.head)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: self.previewMaxWidth, alignment: .leading)
                .padding(.vertical, self.transcriptionVerticalPadding)
        }
    }

    var body: some View {
        VStack(spacing: max(4, self.layout.vPadding / 2)) {
            if self.layout.showsTopControls, !self.isCompactControls {
                HStack {
                    Spacer(minLength: 4)
                    self.settingsChip
                }
                .padding(.horizontal, self.layout.hPadding)
            }

            VStack(spacing: self.layout.vPadding / 2) {
                if self.shouldReservePreviewArea {
                    if self.layout.usesFixedCanvas {
                        // Transcription text area (fixed-height in large mode)
                        Group {
                            if self.shouldSuppressPreviewDuringRelease {
                                Color.clear
                            } else if self.shouldShowAIProcessingFailure {
                                self.aiProcessingFailureView
                            } else if self.shouldShowProcessingPreview {
                                self.scrollablePreviewText(self.processingPreviewText)
                            } else if self.shouldShowProcessingStatus {
                                // Temporarily hidden; the waveform sweep carries processing state.
                                // ShimmerText(
                                //     text: self.processingStatusText,
                                //     color: self.modeColor,
                                //     font: .system(size: self.layout.transFontSize, weight: .medium)
                                // )
                                // .id(self.processingStatusCycleID)
                                // .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                                Color.clear
                            } else if self.contentState.isProcessing {
                                Color.clear
                            } else if self.hasTranscription {
                                let previewText = self.transcriptionPreviewText
                                if !previewText.isEmpty {
                                    ScrollViewReader { proxy in
                                        ScrollView(.vertical, showsIndicators: false) {
                                            Text(previewText)
                                                .font(.system(size: self.layout.transFontSize, weight: .medium))
                                                .foregroundStyle(.white.opacity(0.9))
                                                .multilineTextAlignment(.leading)
                                                .lineLimit(nil)
                                                .fixedSize(horizontal: false, vertical: true)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            Color.clear.frame(height: 1).id("bottom")
                                        }
                                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                        .clipped()
                                        .onAppear {
                                            DispatchQueue.main.async {
                                                proxy.scrollTo("bottom", anchor: .bottom)
                                            }
                                        }
                                        .onChange(of: previewText) { _, _ in
                                            DispatchQueue.main.async {
                                                proxy.scrollTo("bottom", anchor: .bottom)
                                            }
                                        }
                                    }
                                }
                            } else {
                                Color.clear
                            }
                        }
                        .padding(.vertical, self.transcriptionVerticalPadding)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: self.previewMaxHeight,
                            maxHeight: self.previewMaxHeight,
                            alignment: .topLeading
                        )
                    } else {
                        // Original dynamic preview behavior for small/medium
                        Group {
                            if self.shouldSuppressPreviewDuringRelease {
                                Color.clear
                            } else if self.shouldShowAIProcessingFailure {
                                self.aiProcessingFailureView
                            } else if self.shouldShowProcessingPreview {
                                self.dynamicPreviewText(self.processingPreviewText)
                            } else if self.hasTranscription && !self.contentState.isProcessing {
                                let previewText = self.transcriptionPreviewText
                                if !previewText.isEmpty {
                                    if self.settings.overlaySize == .small {
                                        Text(previewText)
                                            .font(.system(size: self.layout.transFontSize, weight: .medium))
                                            .foregroundStyle(.white.opacity(0.9))
                                            .multilineTextAlignment(.leading)
                                            .lineLimit(1)
                                            .truncationMode(.head)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.vertical, max(2, self.transcriptionVerticalPadding - 1))
                                    } else {
                                        Text(previewText)
                                            .font(.system(size: self.layout.transFontSize, weight: .medium))
                                            .foregroundStyle(.white.opacity(0.9))
                                            .multilineTextAlignment(.leading)
                                            .lineLimit(Int(self.previewMaxHeight / max(self.estimatedPreviewLineHeight, 1)))
                                            .truncationMode(.head)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .frame(width: self.previewMaxWidth, alignment: .leading)
                                            .padding(.vertical, self.transcriptionVerticalPadding)
                                    }
                                }
                            } else if self.shouldShowProcessingStatus {
                                // Temporarily hidden; the waveform sweep carries processing state.
                                // ShimmerText(
                                //     text: self.processingStatusText,
                                //     color: self.modeColor,
                                //     font: .system(size: self.layout.transFontSize, weight: .medium)
                                // )
                                // .id(self.processingStatusCycleID)
                                Color.clear
                            } else if self.contentState.isProcessing {
                                Color.clear
                            } else {
                                Color.clear
                            }
                        }
                        .background(
                            GeometryReader { proxy in
                                Color.clear
                                    .preference(key: DynamicPreviewHeightPreferenceKey.self, value: proxy.size.height)
                            }
                        )
                        .frame(
                            maxWidth: self.previewMaxWidth,
                            minHeight: self.effectiveDynamicPreviewMinHeight,
                            maxHeight: self.effectiveDynamicPreviewLockedHeight
                        )
                    }
                }

                // Waveform + Mode label row
                HStack(spacing: self.isPillSize ? 4 : self.layout.hPadding / 1.5) {
                    if !self.layout.showsTopControls {
                        self.leadingAppContextView
                    }

                    // Waveform visualization
                    BottomWaveformView(
                        color: self.modeColor,
                        layout: self.layout,
                        visibleBarCount: self.isPillSize && self.showsSpokenSendIndicator ? 6 : nil
                    )
                    .frame(
                        width: self.isPillSize && self.showsSpokenSendIndicator
                            ? 32
                            : self.layout.waveformWidth,
                        height: self.layout.waveformHeight
                    )

                    // Compact overlays still need a visible mode because they have no selector.
                    if self.layout.showsModeLabel, !self.layout.showsTopControls {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(self.modeLabel)
                                .font(.system(size: self.layout.modeFontSize, weight: .semibold))
                                .foregroundStyle(self.modeColor)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)

                            if !self.appServices.asr.isAsrReady &&
                                (self.appServices.asr.isLoadingModel || self.appServices.asr.isDownloadingModel)
                                && self.settings.overlaySize != .small
                            {
                                Text("Loading model…")
                                    .font(.system(size: max(self.layout.modeFontSize - 2, 9), weight: .medium))
                                    .foregroundStyle(.orange.opacity(0.85))
                                    .lineLimit(1)
                            }
                        }
                        .animation(
                            self.reduceMotion ? nil : .easeOut(duration: 0.14),
                            value: self.contentState.spokenSendIndicatorState
                        )
                    }
                }
                .offset(x: self.waveformHorizontalOffset)
                .frame(maxWidth: .infinity, alignment: .center)
                .overlay(alignment: .leading) {
                    if self.layout.showsTopControls {
                        self.leadingAppContextView
                    }
                }
                .overlay(alignment: .trailing) {
                    if self.layout.showsTopControls {
                        HStack(spacing: 8) {
                            self.promptSelectorView
                            self.actionsSelectorView
                        }
                    }
                }
            }
            .padding(.horizontal, self.layout.hPadding)
            .padding(.vertical, self.layout.vPadding)
            .frame(maxWidth: .infinity, alignment: .center)
            .background(
                ZStack {
                    // Solid pitch black background, with a soft drop shadow so the pill lifts
                    // off whatever is behind it (pill size only; outer padding reserves room).
                    RoundedRectangle(cornerRadius: self.layout.cornerRadius)
                        .fill(Color.black)
                        .shadow(
                            color: Color.black.opacity(self.isPillSize ? 0.32 : 0),
                            radius: self.isPillSize ? PillShadowMetrics.radius : 0,
                            x: 0,
                            y: self.isPillSize ? PillShadowMetrics.yOffset : 0
                        )

                    if self.isPillSize {
                        // Glossy border: a bright highlight that slowly rotates around the edge.
                        // Paused under reduce-motion to avoid continuous redraws on low-resource Macs.
                        if self.reduceMotion || !self.contentState.isBottomOverlayPresented {
                            RoundedRectangle(cornerRadius: self.layout.cornerRadius)
                                .strokeBorder(
                                    AngularGradient(
                                        gradient: Gradient(stops: [
                                            .init(color: .white.opacity(0.06), location: 0.00),
                                            .init(color: .white.opacity(0.55), location: 0.13),
                                            .init(color: .white.opacity(0.10), location: 0.30),
                                            .init(color: .white.opacity(0.03), location: 0.55),
                                            .init(color: .white.opacity(0.22), location: 0.80),
                                            .init(color: .white.opacity(0.06), location: 1.00),
                                        ]),
                                        center: .center,
                                        angle: .degrees(0)
                                    ),
                                    lineWidth: 1.2
                                )
                        } else {
                            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                                let seconds = max(
                                    0,
                                    timeline.date.timeIntervalSince(self.borderAnimationStartedAt ?? timeline.date)
                                )
                                let angle = (seconds.truncatingRemainder(dividingBy: 6.0) / 6.0) * 360.0
                                RoundedRectangle(cornerRadius: self.layout.cornerRadius)
                                    .strokeBorder(
                                        AngularGradient(
                                            gradient: Gradient(stops: [
                                                .init(color: .white.opacity(0.06), location: 0.00),
                                                .init(color: .white.opacity(0.55), location: 0.13),
                                                .init(color: .white.opacity(0.10), location: 0.30),
                                                .init(color: .white.opacity(0.03), location: 0.55),
                                                .init(color: .white.opacity(0.22), location: 0.80),
                                                .init(color: .white.opacity(0.06), location: 1.00),
                                            ]),
                                            center: .center,
                                            angle: .degrees(angle)
                                        ),
                                        lineWidth: 1.2
                                    )
                            }
                        }
                    } else {
                        // Inner border
                        RoundedRectangle(cornerRadius: self.layout.cornerRadius)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(self.overlayBorderTopOpacity),
                                        Color.white.opacity(self.overlayBorderBottomOpacity),
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: self.overlayBorderLineWidth
                            )
                    }
                }
            )
            .frame(maxWidth: .infinity, alignment: .top)
            .transaction { transaction in
                if self.shouldSuppressPreviewDuringRelease {
                    transaction.animation = nil
                }
            }
        }
        .frame(
            width: self.layout.usesFixedCanvas ? self.layout.overlayWidth : self.layout.containerWidth,
            height: self.overlayFrameHeight,
            alignment: .top
        )
        // Reserve space around the pill so its drop shadow isn't clipped by the (content-sized) window.
        .padding(self.isPillSize ? 26 : 0)
        .frame(maxHeight: .infinity, alignment: .top)
        .scaleEffect(self.overlayAnimatedScale, anchor: .center)
        .offset(y: self.overlayAnimatedOffsetY)
        .opacity(self.overlayAnimatedOpacity)
        .animation(.timingCurve(0.22, 0.0, 0.2, 1.0, duration: 0.02), value: self.contentState.isBottomOverlayDismissing)
        .onChange(of: self.settings.overlaySize) { _, _ in
            self.dynamicPreviewResizeBucket = self.previewResizeBucket(for: self.currentPreviewSizingText)
            self.frozenDynamicPreviewHeight = nil
            BottomOverlayWindowController.shared.refreshSizeForContent()
        }
        .onChange(of: self.contentState.isBottomOverlayPresented) { _, presented in
            self.borderAnimationStartedAt = presented ? Date() : nil
        }
        .onChange(of: self.settings.enableStreamingPreview) { _, _ in
            self.dynamicPreviewResizeBucket = self.previewResizeBucket(for: self.currentPreviewSizingText)
            self.frozenDynamicPreviewHeight = nil
            BottomOverlayWindowController.shared.refreshSizeForContent()
        }
        .onChange(of: self.contentState.cachedPreviewText) { _, _ in
            self.refreshDynamicPreviewSizeIfNeeded(for: self.currentPreviewSizingText)
        }
        .onChange(of: self.contentState.mode) { _, _ in
            if !self.isPromptSelectableMode || self.contentState.isProcessing {
                self.closePromptMenu()
            }
            self.closeModeMenu()
            self.closeActionsMenu()
            self.isHoveringModeChip = false
            self.isHoveringPromptChip = false
            self.isHoveringActionsChip = false
            self.isHoveringSettingsChip = false
            self.contentState.promptPickerMode = .dictate
            if !self.layout.usesFixedCanvas {
                self.dynamicPreviewResizeBucket = self.previewResizeBucket(for: self.currentPreviewSizingText)
                BottomOverlayWindowController.shared.refreshSizeForContent()
            }
        }
        .onChange(of: self.contentState.isProcessing) { _, processing in
            self.processingStatusVisible = processing
            if processing {
                self.processingStatusCycleID &+= 1
                self.closePromptMenu()
                self.closeModeMenu()
                self.closeActionsMenu()
            }
            self.isHoveringModeChip = false
            self.isHoveringPromptChip = false
            self.isHoveringActionsChip = false
            self.isHoveringSettingsChip = false
            if !self.layout.usesFixedCanvas {
                self.refreshDynamicPreviewSizeIfNeeded(for: self.currentPreviewSizingText)
            }
        }
        .onChange(of: self.contentState.isAIProcessingFailureVisible) { _, _ in
            guard !self.layout.usesFixedCanvas else { return }
            self.refreshDynamicPreviewSizeIfNeeded(for: self.currentPreviewSizingText)
        }
        .onChange(of: self.processingStatusVisible) { _, _ in
            guard !self.layout.usesFixedCanvas else { return }
            self.refreshDynamicPreviewSizeIfNeeded(for: self.currentPreviewSizingText)
        }
        .onChange(of: self.contentState.isBottomOverlayReleaseTransitioning) { _, transitioning in
            guard self.shouldReservePreviewArea else {
                self.frozenDynamicPreviewHeight = nil
                return
            }
            guard !self.layout.usesFixedCanvas else { return }
            if transitioning {
                let measuredHeight = self.dynamicPreviewMeasuredHeight > 0
                    ? self.dynamicPreviewMeasuredHeight
                    : self.effectiveDynamicPreviewMinHeight
                self.frozenDynamicPreviewHeight = max(measuredHeight, self.dynamicPreviewBaseMinHeight)
            } else {
                self.frozenDynamicPreviewHeight = nil
                BottomOverlayWindowController.shared.refreshSizeForContent()
            }
        }
        .onPreferenceChange(DynamicPreviewHeightPreferenceKey.self) { measuredHeight in
            guard !self.layout.usesFixedCanvas else { return }
            guard measuredHeight > 0 else { return }
            self.dynamicPreviewMeasuredHeight = measuredHeight
        }
        .onAppear {
            self.rememberAppIcon(self.contentState.targetAppIcon ?? self.activeAppMonitor.activeAppIcon)
            self.dynamicPreviewResizeBucket = self.previewResizeBucket(for: self.currentPreviewSizingText)
        }
        .onReceive(self.contentState.$targetAppIcon) { icon in
            self.rememberAppIcon(icon)
        }
        .onDisappear {
            self.closePromptMenu()
            self.closeModeMenu()
            self.closeActionsMenu()
            self.isHoveringModeChip = false
            self.isHoveringPromptChip = false
            self.isHoveringActionsChip = false
            self.isHoveringSettingsChip = false
        }
    }
}

