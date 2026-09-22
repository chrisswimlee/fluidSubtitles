import AVFoundation
import Foundation

final class TranscriptionSoundPlayer {
    static let shared = TranscriptionSoundPlayer()

    private let playbackQueue = DispatchQueue(label: "app.fluidsubtitles.transcription-sounds", qos: .userInteractive)
    private var players: [String: AVAudioPlayer] = [:]

    private init() {}

    @MainActor
    func playStartSound() {
        guard TheaterListenCapture.shouldPlayListenChime(
            policyPlaysChime: TheaterSpeechSession.shared.playsListenChime
        ) else { return }
        let settings = SettingsStore.shared
        guard settings.enableTranscriptionSounds else { return }
        let selected = settings.transcriptionStartSound
        guard let soundName = selected.startSoundFileName else { return }
        self.play(
            soundName: soundName,
            desiredVolume: settings.transcriptionSoundVolume,
            independentVolume: settings.transcriptionSoundIndependentVolume
        )
    }

    @MainActor
    func playStopSound() {
        guard TheaterListenCapture.shouldPlayListenChime(
            policyPlaysChime: TheaterSpeechSession.shared.playsListenChime
        ) else { return }
        let settings = SettingsStore.shared
        guard settings.enableTranscriptionSounds else { return }
        let selected = settings.transcriptionStartSound
        guard let soundName = selected.stopSoundFileName else { return }
        self.play(
            soundName: soundName,
            desiredVolume: settings.transcriptionSoundVolume,
            independentVolume: settings.transcriptionSoundIndependentVolume
        )
    }

    /// Preview a specific sound at the current volume setting (used in Settings UI).
    func playPreview(sound: SettingsStore.TranscriptionStartSound) {
        guard let soundName = sound.startSoundFileName else { return }
        let settings = SettingsStore.shared
        self.play(
            soundName: soundName,
            desiredVolume: settings.transcriptionSoundVolume,
            independentVolume: settings.transcriptionSoundIndependentVolume
        )
    }

    /// Preview current sound at a specific volume (used when slider is released).
    func playPreviewAtVolume(_ volume: Float) {
        let selected = SettingsStore.shared.transcriptionStartSound
        guard let soundName = selected.startSoundFileName else { return }
        self.play(
            soundName: soundName,
            desiredVolume: volume,
            independentVolume: SettingsStore.shared.transcriptionSoundIndependentVolume
        )
    }

    private func play(
        soundName: String,
        desiredVolume: Float,
        independentVolume: Bool
    ) {
        let startedAt = ProcessInfo.processInfo.systemUptime
        DebugLogger.shared.benchmark(
            "APP_BENCH",
            message: "sound_play_request sound=\(soundName)",
            source: "AppBenchmark"
        )

        guard let url = Bundle.main.url(forResource: soundName, withExtension: "m4a") else {
            DebugLogger.shared.error("Missing sound resource: \(soundName).m4a", source: "TranscriptionSoundPlayer")
            return
        }

        self.playbackQueue.async { [weak self] in
            self?.playOnPlaybackQueue(
                soundName: soundName,
                url: url,
                desiredVolume: desiredVolume,
                independentVolume: independentVolume,
                startedAt: startedAt
            )
        }
    }

    private func playOnPlaybackQueue(
        soundName: String,
        url: URL,
        desiredVolume: Float,
        independentVolume: Bool,
        startedAt: TimeInterval
    ) {
        _ = independentVolume
        do {
            let player: AVAudioPlayer
            if let existing = self.players[soundName] {
                player = existing
            } else {
                player = try AVAudioPlayer(contentsOf: url)
                player.prepareToPlay()
                self.players[soundName] = player
            }

            player.currentTime = 0
            player.volume = desiredVolume
            player.play()
            DebugLogger.shared.benchmark(
                "APP_BENCH",
                message: "sound_play_dispatched sound=\(soundName) elapsedMs=\(Int(((ProcessInfo.processInfo.systemUptime - startedAt) * 1000).rounded()))",
                source: "AppBenchmark"
            )

        } catch {
            DebugLogger.shared.error(
                "Failed to play sound \(soundName).m4a: \(error.localizedDescription)",
                source: "TranscriptionSoundPlayer"
            )
        }
    }
}
