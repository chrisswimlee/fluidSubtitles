import CoreGraphics
import Foundation
import ScreenCaptureKit

enum ScreenRecordingAccess {
    enum Resolution: String, Equatable, Error {
        case granted
        case denied
        case needsReopen
        case noDisplay
    }

    static let deniedCopy =
        "Allow Screen Recording in System Settings. If you just turned it on, quit and reopen FluidSubtitles."

    static let reopenCopy =
        "Screen Recording is on, but this app still cannot capture. Quit and reopen FluidSubtitles."

    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func message(for resolution: Resolution) -> String {
        switch resolution {
        case .granted:
            return ""
        case .denied:
            return self.deniedCopy
        case .needsReopen:
            return self.reopenCopy
        case .noDisplay:
            return "No display is available to capture audio."
        }
    }

    static func message(forStartError error: Error) -> String {
        if let capture = error as? SystemAudioCaptureError, let text = capture.errorDescription {
            return text
        }
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain,
           let code = SCStreamError.Code(rawValue: nsError.code)
        {
            switch code {
            case .userDeclined, .missingEntitlements:
                return self.isGranted ? self.reopenCopy : self.deniedCopy
            default:
                break
            }
        }
        let folded = error.localizedDescription.lowercased()
        if folded.contains("not authorized")
            || folded.contains("not permitted")
            || folded.contains("denied")
            || folded.contains("declined")
            || folded.contains("tcc")
        {
            return self.isGranted ? self.reopenCopy : self.deniedCopy
        }
        let text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? self.deniedCopy : text
    }

    static func resolve() async -> Resolution {
        switch await self.load() {
        case .success:
            return .granted
        case .failure(let resolution):
            return resolution
        }
    }

    static func load() async -> Result<SCShareableContent, Resolution> {
        if !self.isGranted {
            self.invalidateCache()
            return .failure(.denied)
        }
        if let cached = self.cachedContent() {
            return cached.displays.isEmpty ? .failure(.noDisplay) : .success(cached)
        }
        do {
            // On-screen windows only: we never read the window list, and the
            // off-screen set is the expensive part of this call.
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            self.storeCache(content)
            if content.displays.isEmpty {
                return .failure(.noDisplay)
            }
            return .success(content)
        } catch {
            self.invalidateCache()
            return .failure(.needsReopen)
        }
    }

    private static let cacheLock = NSLock()
    private static var cachedShareableContent: SCShareableContent?
    private static var cachedAt = Date.distantPast
    private static let cacheTTL: TimeInterval = 2

    private static func cachedContent() -> SCShareableContent? {
        self.cacheLock.lock()
        defer { self.cacheLock.unlock() }
        guard let cachedShareableContent,
              Date().timeIntervalSince(self.cachedAt) < self.cacheTTL
        else { return nil }
        return cachedShareableContent
    }

    private static func storeCache(_ content: SCShareableContent) {
        self.cacheLock.lock()
        self.cachedShareableContent = content
        self.cachedAt = Date()
        self.cacheLock.unlock()
    }

    static func invalidateCache() {
        self.cacheLock.lock()
        self.cachedShareableContent = nil
        self.cachedAt = .distantPast
        self.cacheLock.unlock()
    }
}
