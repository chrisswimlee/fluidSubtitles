import AVFoundation
import Foundation

/// Theater asks for the microphone. Voice and Translate both use it.
enum MicrophoneAccess {
    static let deniedCopy =
        "Allow the microphone in System Settings."

    static func status() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static func isAuthorized(_ status: AVAuthorizationStatus) -> Bool {
        status == .authorized
    }

    static func isDenied(_ status: AVAuthorizationStatus) -> Bool {
        status == .denied || status == .restricted
    }

    @MainActor
    static func refresh(_ asr: ASRService) {
        asr.micStatus = self.status()
        asr.micPermissionGranted = asr.micStatus == .authorized
    }

    /// Prompts when the grant is still undetermined. Denied stays denied.
    @MainActor
    static func authorize(updating asr: ASRService) async -> Bool {
        self.refresh(asr)
        if self.isAuthorized(asr.micStatus) { return true }
        if self.isDenied(asr.micStatus) { return false }

        let granted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        asr.micPermissionGranted = granted
        asr.micStatus = granted ? .authorized : .denied
        if granted {
            await asr.prewarmConfiguredAudioCaptureIfPossible(reason: "permission_granted")
        }
        return granted
    }
}
