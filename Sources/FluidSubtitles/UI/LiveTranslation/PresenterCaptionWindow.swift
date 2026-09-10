import AppKit
import Combine
import SwiftUI

@MainActor
final class PresenterCaptionController: NSObject, NSWindowDelegate {
    static let shared = PresenterCaptionController()

    private var panel: NSPanel?
    private let model = PresenterCaptionModel()
    private var lastExternalAppPID: pid_t?

    private var isDismissing = false

    var isEditing: Bool { self.model.isEditing }

    func setVisible(_ visible: Bool) {
        if visible {
            self.show()
        } else {
            self.hide()
        }
    }

    func show() {
        SettingsStore.shared.theaterWindowEnabled = true
        if self.panel == nil {
            self.panel = Self.makePanel(model: self.model)
            self.panel?.delegate = self
        }
        self.rememberExternalApp()
        self.panel?.orderFrontRegardless()
        LiveTranslationController.shared.syncTheater()
    }

    func hide() {
        self.panel?.orderOut(nil)
        self.dismissCaptions()
    }

    func orderOutIfClosed() {
        guard !SettingsStore.shared.theaterWindowEnabled else { return }
        self.panel?.orderOut(nil)
    }

    func clearDisplay() {
        self.model.committed = []
        self.model.committedIDs = []
        self.model.source = ""
        self.model.draft = ""
        self.model.spokenLine = ""
        self.model.status = ""
        self.model.isEditing = false
        self.model.editedText = ""
    }

    func update(
        source: String,
        draft: String,
        committed: [String],
        committedIDs: [UInt64] = [],
        committedSources: [String] = [],
        pairLabel: String,
        status: String,
        isListening: Bool
    ) {
        self.model.source = source
        self.model.draft = draft
        self.model.committed = committed
        self.model.committedIDs = committedIDs
        self.model.spokenLine = committedSources.last ?? ""
        self.model.pairLabel = pairLabel
        self.model.status = status
        self.model.isListening = isListening
        if !self.model.isEditing {
            self.model.editedText = Self.captionDocument(
                committed: committed,
                draft: draft
            )
        }
    }

    func commitEdits() {
        guard self.model.isEditing else { return }
        LiveTranslationController.shared.applyEditedDocument(self.model.editedText)
        self.model.isEditing = false
    }

    func makeKeyForInteraction() {
        self.panel?.makeKeyAndOrderFront(nil)
    }

    func documentTextForDelivery() -> String {
        if self.model.isEditing {
            return self.model.editedText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Self.captionDocument(committed: self.model.committed, draft: self.model.draft)
    }

    func preferredInsertTargetPID() -> pid_t? {
        if let pid = self.lastExternalAppPID, pid > 0 { return pid }
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
            return front?.processIdentifier
        }
        return nil
    }

    func windowWillClose(_ notification: Notification) {
        self.dismissCaptions()
    }

    private func dismissCaptions() {
        guard !self.isDismissing else { return }
        self.isDismissing = true
        SettingsStore.shared.theaterWindowEnabled = false
        self.model.isEditing = false
        LiveTranslationController.shared.theaterWasClosed()
        self.isDismissing = false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        self.rememberExternalApp()
    }

    static func captionDocument(committed: [String], draft: String) -> String {
        var lines = committed
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let current = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty, lines.last != current {
            lines.append(current)
        }
        return lines.joined(separator: "\n")
    }

    private func rememberExternalApp() {
        let front = NSWorkspace.shared.frontmostApplication
        if let pid = front?.processIdentifier,
           front?.bundleIdentifier != Bundle.main.bundleIdentifier
        {
            self.lastExternalAppPID = pid
        }
    }

    private static func makePanel(model: PresenterCaptionModel) -> NSPanel {
        let view = PresenterCaptionView(model: model)
        let hosting = NSHostingController(rootView: view)
        let panel = NSPanel(
            contentRect: NSRect(x: 80, y: 80, width: 1100, height: 440),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "\(FluidProduct.displayName) Theater"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .black
        panel.contentViewController = hosting
        panel.minSize = NSSize(width: 560, height: 260)
        panel.setContentSize(NSSize(width: 1100, height: 440))
        if let screen = Self.preferredScreen() {
            let frame = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.minY + 48
            ))
        }
        return panel
    }

    private static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}

@MainActor
final class PresenterCaptionModel: ObservableObject {
    @Published var committed: [String] = []
    @Published var committedIDs: [UInt64] = []
    @Published var source: String = ""
    @Published var draft: String = ""
    @Published var spokenLine: String = ""
    @Published var pairLabel: String = ""
    @Published var status: String = ""
    @Published var isListening: Bool = false
    @Published var isEditing: Bool = false
    @Published var editedText: String = ""
}

enum TheaterTypeface: String, CaseIterable, Identifiable {
    case system
    case helveticaNeue = "Helvetica Neue"
    case avenirNext = "Avenir Next"
    case georgia = "Georgia"
    case palatino = "Palatino"
    case menlo = "Menlo"
    case gothicNeo = "Apple SD Gothic Neo"
    case thonburi = "Thonburi"

    var id: String { self.rawValue }

    var displayName: String {
        self == .system ? "System" : self.rawValue
    }

    static func resolved(_ stored: String) -> TheaterTypeface {
        Self(rawValue: stored.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .system
    }

    var postScriptName: String? {
        switch self {
        case .system:
            return nil
        case .helveticaNeue:
            return "HelveticaNeue"
        case .avenirNext:
            return "AvenirNext-DemiBold"
        case .georgia:
            return "Georgia"
        case .palatino:
            return "Palatino-Roman"
        case .menlo:
            return "Menlo-Regular"
        case .gothicNeo:
            return "AppleSDGothicNeo-SemiBold"
        case .thonburi:
            return "Thonburi"
        }
    }

    func font(size: CGFloat, weight: Font.Weight) -> Font {
        if let name = self.postScriptName {
            return .custom(name, size: size)
        }
        return .system(size: size, weight: weight)
    }

    func nsFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        if let name = self.postScriptName, let named = NSFont(name: name, size: size) {
            return named
        }
        if self != .system, let family = NSFontManager.shared.font(
            withFamily: self.rawValue,
            traits: [],
            weight: 7,
            size: size
        ) {
            return family
        }
        return .systemFont(ofSize: size, weight: weight)
    }
}

struct TheaterFlowLine: Equatable, Identifiable {
    let id: String
    let text: String
    let isCurrent: Bool
}

enum TheaterCaptionFlow {
    static func lines(
        committed: [String],
        committedIDs: [UInt64] = [],
        draft: String
    ) -> [TheaterFlowLine] {
        let history = committed
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let draftText = draft.trimmingCharacters(in: .whitespacesAndNewlines)

        var result: [TheaterFlowLine] = history.enumerated().map { index, text in
            let id = index < committedIDs.count ? "c-\(committedIDs[index])" : "c-\(index)"
            return TheaterFlowLine(id: id, text: text, isCurrent: false)
        }

        if !draftText.isEmpty, history.last != draftText {
            result.append(TheaterFlowLine(id: "draft", text: draftText, isCurrent: true))
        } else if let last = result.popLast() {
            result.append(TheaterFlowLine(id: last.id, text: last.text, isCurrent: true))
        }
        return result
    }
}

struct PresenterCaptionView: View {
    @ObservedObject var model: PresenterCaptionModel
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var controller = LiveTranslationController.shared
    @ObservedObject private var asr = AppServices.shared.asr

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            self.header
            self.typographyBar
            if self.model.isEditing {
                TheaterTextEditor(
                    text: self.$model.editedText,
                    typeface: self.typeface,
                    fontSize: CGFloat(self.settings.presenterFontSize)
                )
                .padding(.top, 6)
            } else {
                self.presentationStage
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, 36)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.94))
        .background(TranslationSessionHost())
        .transaction { $0.disablesAnimations = true }
    }

    private var typeface: TheaterTypeface {
        TheaterTypeface.resolved(self.settings.presenterFontFamily)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(FluidProduct.displayName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(red: 0.35, green: 0.92, blue: 0.78))
            Text(self.model.pairLabel)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
            Spacer(minLength: 8)
            if !self.model.status.isEmpty {
                Text(self.model.status)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            HStack(spacing: 8) {
                Button(self.model.isEditing ? "Done" : "Edit") {
                    self.toggleEditing()
                }
                Button("Copy") {
                    self.controller.copyCaptionText()
                }
                .disabled(self.deliveryIsEmpty)
                Button("Insert") {
                    self.controller.insertCaptionText()
                }
                .disabled(self.insertIsEmpty)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.white)
            self.listenButton
        }
    }

    private var listenButton: some View {
        Button {
            if self.model.isListening {
                self.controller.stopListening()
            } else {
                self.controller.startCaptionListening()
            }
        } label: {
            Label(self.model.isListening ? "Stop" : "Listen", systemImage: self.model.isListening ? "stop.fill" : "mic.fill")
                .font(.system(size: 13, weight: .semibold))
                .frame(minWidth: 84)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .tint(self.model.isListening ? .red : Color(red: 0.18, green: 0.83, blue: 0.75))
        .disabled(self.microphoneBusy || self.voiceEngineMissing)
        .help(self.listenHelp)
        .accessibilityLabel(self.model.isListening ? "Stop" : "Listen")
        .layoutPriority(1)
    }

    private var typographyBar: some View {
        HStack(spacing: 8) {
            Picker("Font", selection: self.fontFamilyBinding) {
                ForEach(TheaterTypeface.allCases) { face in
                    Text(face.displayName).tag(face)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 200)
            .help("Caption font")

            Button {
                self.nudgeFontSize(-2)
            } label: {
                Image(systemName: "textformat.size.smaller")
            }
            .disabled(self.settings.presenterFontSize <= SettingsStore.presenterFontSizeRange.lowerBound)
            .help("Smaller captions")

            Text("\(self.settings.presenterFontSize) pt")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
                .frame(minWidth: 44)

            Button {
                self.nudgeFontSize(2)
            } label: {
                Image(systemName: "textformat.size.larger")
            }
            .disabled(self.settings.presenterFontSize >= SettingsStore.presenterFontSizeRange.upperBound)
            .help("Larger captions")

            Spacer()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(.white)
    }

    private var fontFamilyBinding: Binding<TheaterTypeface> {
        Binding(
            get: { TheaterTypeface.resolved(self.settings.presenterFontFamily) },
            set: {
                PresenterCaptionController.shared.makeKeyForInteraction()
                self.settings.presenterFontFamily = $0.rawValue
            }
        )
    }

    private var presentationStage: some View {
        let fontSize = CGFloat(self.settings.presenterFontSize)
        let lines = TheaterCaptionFlow.lines(
            committed: self.model.committed,
            committedIDs: self.model.committedIDs,
            draft: self.model.draft
        )
        return GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if lines.isEmpty {
                            VStack(alignment: .leading, spacing: 14) {
                                Text(self.model.isListening ? "Listening" : "Press Listen to caption.")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.32))
                                    .fixedSize(horizontal: false, vertical: true)
                                if !self.model.isListening {
                                    self.listenButton
                                }
                            }
                        } else {
                            ForEach(lines) { line in
                                Text(line.text)
                                    .font(self.typeface.font(
                                        size: line.isCurrent ? fontSize : max(18, fontSize * 0.72),
                                        weight: line.isCurrent ? .semibold : .medium
                                    ))
                                    .foregroundStyle(.white.opacity(line.isCurrent ? 1 : 0.42))
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(nil)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        }

                        if self.settings.translationShowSource, !self.model.spokenLine.isEmpty {
                            Text(self.model.spokenLine)
                                .font(self.typeface.font(size: max(14, fontSize * 0.38), weight: .regular))
                                .foregroundStyle(.white.opacity(0.34))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("theater-bottom")
                    }
                    .frame(width: geometry.size.width, alignment: .leading)
                    .padding(.top, 4)
                }
                .scrollIndicators(.hidden)
                .onChange(of: lines.last?.id) { _, _ in
                    proxy.scrollTo("theater-bottom", anchor: .bottom)
                }
                .onChange(of: self.model.committed.last) { _, _ in
                    proxy.scrollTo("theater-bottom", anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var microphoneBusy: Bool {
        !self.model.isListening && self.asr.isRunningOrStarting
    }

    private var voiceEngineMissing: Bool {
        !self.model.isListening && !self.asr.isAsrReady && !self.asr.modelsExistOnDisk
    }

    private func nudgeFontSize(_ delta: Int) {
        PresenterCaptionController.shared.makeKeyForInteraction()
        self.settings.presenterFontSize += delta
    }

    private var deliveryIsEmpty: Bool {
        PresenterCaptionController.shared.documentTextForDelivery().isEmpty
    }

    private var insertIsEmpty: Bool {
        if self.model.isEditing {
            return self.deliveryIsEmpty
        }
        return self.controller.subscriber.pendingInsertDocument().isEmpty
    }

    private var listenHelp: String {
        if self.voiceEngineMissing {
            return "Download a Voice Engine first"
        }
        if self.microphoneBusy {
            return "Stop dictation or Insert listening first"
        }
        return self.model.isListening ? "Stop" : "Listen"
    }

    private func toggleEditing() {
        if self.model.isEditing {
            PresenterCaptionController.shared.commitEdits()
            return
        }
        PresenterCaptionController.shared.makeKeyForInteraction()
        self.model.editedText = PresenterCaptionController.shared.documentTextForDelivery()
        self.model.isEditing = true
    }
}

/// AppKit editor so Theater can use white text. SwiftUI TextEditor ignores foreground on macOS.
private struct TheaterTextEditor: NSViewRepresentable {
    @Binding var text: String
    var typeface: TheaterTypeface
    var fontSize: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(text: self.$text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = .white
        textView.insertionPointColor = .white
        textView.font = self.typeface.nsFont(size: self.fontSize, weight: .semibold)
        textView.string = self.text
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineBreakMode = .byWordWrapping
        textView.textContainerInset = NSSize(width: 0, height: 4)

        scroll.documentView = textView
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        textView.font = self.typeface.nsFont(size: self.fontSize, weight: .semibold)
        textView.textColor = .white
        if textView.string != self.text, context.coordinator.isEditing == false {
            textView.string = self.text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        weak var textView: NSTextView?
        var isEditing = false

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidBeginEditing(_ notification: Notification) {
            self.isEditing = true
        }

        func textDidEndEditing(_ notification: Notification) {
            self.isEditing = false
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            self.text.wrappedValue = textView.string
        }
    }
}
