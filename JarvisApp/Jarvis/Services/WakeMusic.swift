import AVFoundation
import Foundation

/// Musique de démarrage (Highway to Hell, instrumentale) jouée à l'ouverture de JARVIS, pendant le récap.
/// Réglages › Voix › « Musique au démarrage ». Baisse automatiquement quand JARVIS parle.
@MainActor
final class WakeMusic {
    static let shared = WakeMusic()
    nonisolated static let enabledKey = "wakeMusicEnabled"
    private var player: AVAudioPlayer?
    private var fadeTask: Task<Void, Never>?

    var enabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func play() {
        guard enabled, player == nil,
              let url = Bundle.main.url(forResource: "wake", withExtension: "mp3") else { return }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.volume = 0.7
        p.prepareToPlay()
        p.play()
        player = p
        // fondu final sur les 3 dernières secondes
        let wait = max(0, p.duration - 3)
        fadeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            self?.player?.setVolume(0, fadeDuration: 3)
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            if !Task.isCancelled { self?.stop() }
        }
    }

    /// Quand JARVIS parle, la musique passe en fond.
    func duck(_ speaking: Bool) {
        guard let p = player, p.isPlaying else { return }
        p.setVolume(speaking ? 0.22 : 0.7, fadeDuration: 0.4)
    }

    func stop() {
        fadeTask?.cancel()
        player?.stop()
        player = nil
    }
}
