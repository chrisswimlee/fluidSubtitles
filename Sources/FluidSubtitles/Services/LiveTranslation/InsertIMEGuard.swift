import Carbon.HIToolbox
import Foundation

/// Korean and Thai IMEs treat `virtualKey 0` unicode CGEvents as composition.
/// Infer IME kind from the selected input source; another app’s 조합 중 state
/// is not a public AX attribute.
enum InsertIMEGuard {
    struct Snapshot: Equatable {
        var identifier: String
        var isASCIICapable: Bool
    }

    private static let cache = InsertIMESourceCache()

    static func startTracking() {
        self.cache.start()
    }

    static func shouldAvoidUnicodeInjection(snapshot: Snapshot? = nil) -> Bool {
        if self.shouldPreferPasteForTheaterCaption() { return true }
        return self.snapshotRequiresPaste(snapshot ?? self.cache.snapshot())
    }

    static func snapshotRequiresPaste(_ snapshot: Snapshot) -> Bool {
        if !snapshot.isASCIICapable { return true }
        return self.isKoreanOrThaiInputSource(snapshot.identifier)
    }

    static func shouldPreferPasteForTheaterCaption() -> Bool {
        SettingsStore.shared.theaterListenUsed
            && self.isKoreanOrThaiLanguage(SpokenLanguageResolver.targetLanguage().id)
    }

    static func isKoreanOrThaiLanguage(_ languageID: String) -> Bool {
        switch TranslationClauseSegmenter.languageCode(from: languageID) {
        case "ko", "th":
            return true
        default:
            return false
        }
    }

    static func isKoreanOrThaiInputSource(_ identifier: String) -> Bool {
        let id = identifier.lowercased()
        if id.contains("korean") || id.contains("hangul") { return true }
        if id.contains("thai") { return true }
        return false
    }

    static func snapshot(
        identifier: String?,
        isASCIICapable: Bool
    ) -> Snapshot {
        Snapshot(
            identifier: identifier ?? "",
            isASCIICapable: isASCIICapable
        )
    }

    static func readSystemSnapshot() -> Snapshot {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return Snapshot(identifier: "", isASCIICapable: true)
        }
        let identifier = Self.stringProperty(source, kTISPropertyInputSourceID) ?? ""
        let ascii = Self.boolProperty(source, kTISPropertyInputSourceIsASCIICapable) ?? true
        return Snapshot(identifier: identifier, isASCIICapable: ascii)
    }

    private static func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private static func boolProperty(_ source: TISInputSource, _ key: CFString) -> Bool? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue() == kCFBooleanTrue
    }
}

/// Main-thread TIS snapshot so insert workers never call TIS off the main queue.
final class InsertIMESourceCache: @unchecked Sendable {
    private let lock = NSLock()
    private var current = InsertIMEGuard.Snapshot(identifier: "", isASCIICapable: true)
    private var observer: NSObjectProtocol?
    private var refreshScheduled = false

    func start() {
        precondition(Thread.isMainThread)
        guard self.observer == nil else { return }
        self.observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleRefresh()
        }
        self.refresh()
    }

    func snapshot() -> InsertIMEGuard.Snapshot {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.current
    }

    private func scheduleRefresh() {
        precondition(Thread.isMainThread)
        guard !self.refreshScheduled else { return }
        self.refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    private func refresh() {
        precondition(Thread.isMainThread)
        let updated = InsertIMEGuard.readSystemSnapshot()
        self.lock.lock()
        self.current = updated
        self.lock.unlock()
    }

    deinit {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }
}
