import AVFoundation
import Foundation

/// Synthèse vocale française (voix Apple ; la meilleure voix installée est choisie automatiquement).
/// Astuce : Réglages > Accessibilité > Contenu énoncé > Voix > Français → télécharger une voix « améliorée ».
@MainActor
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    @Published private(set) var isSpeaking = false {
        didSet { if isSpeaking != oldValue { WakeMusic.shared.duck(isSpeaking) } }
    }
    private let synth = AVSpeechSynthesizer()
    // Voix premium : file de phrases jouées l'une après l'autre
    private var queue: [String] = []
    private var player: AVAudioPlayer?
    private var fetchTask: Task<Void, Never>?
    private var previewPlayer: AVPlayer?

    override init() {
        super.init()
        synth.delegate = self
    }

    func say(_ text: String) {
        let clean = Self.clean(text)
        guard !clean.isEmpty else { return }
        if PremiumVoice.isEnabled {
            queue.append(clean)
            if player == nil && fetchTask == nil { playNextPremium() }
            return
        }
        sayApple(clean)
    }

    /// Joue la prochaine phrase avec la voix premium ; en cas d'échec, la voix Apple prend le relais.
    private func playNextPremium() {
        guard !queue.isEmpty else { return }
        let text = queue.removeFirst()
        isSpeaking = true
        fetchTask = Task { [weak self] in
            let data = try? await PremiumVoice.synthesize(text)
            guard let self, !Task.isCancelled else { return }
            self.fetchTask = nil
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try? AVAudioSession.sharedInstance().setActive(true)
            #endif
            if let data, let p = try? AVAudioPlayer(data: data) {
                p.delegate = self
                self.player = p
                p.play()
            } else {
                self.isSpeaking = false
                self.sayApple(text)
                self.queue.forEach { self.sayApple($0) }
                self.queue.removeAll()
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.player = nil
            if self.queue.isEmpty {
                self.isSpeaking = self.synth.isSpeaking
            } else {
                self.playNextPremium()
            }
        }
    }

    /// Écouter un extrait d'une voix (Réglages).
    func preview(_ url: URL) {
        previewPlayer = AVPlayer(url: url)
        previewPlayer?.play()
    }

    private func sayApple(_ clean: String) {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let u = AVSpeechUtterance(string: clean)
        u.voice = Self.bestVoice
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        u.pitchMultiplier = 0.95
        synth.speak(u)
    }

    func stop() {
        queue.removeAll()
        fetchTask?.cancel()
        fetchTask = nil
        player?.stop()
        player = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        isSpeaking = false
    }

    static let bestVoice: AVSpeechSynthesisVoice? = {
        let fr = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("fr") }
        let ranked = fr.sorted { $0.quality.rawValue > $1.quality.rawValue }
        return ranked.first(where: { $0.language == "fr-FR" }) ?? ranked.first ?? AVSpeechSynthesisVoice(language: "fr-FR")
    }()

    static func clean(_ text: String) -> String {
        // Les sources (liens) restent affichées à l'écran mais ne sont pas lues
        let spoken = text.components(separatedBy: "\n\nSources").first ?? text
        var t = spoken.replacingOccurrences(of: "```[\\s\\S]*?```", with: " (le code est affiché à l'écran) ",
                                          options: .regularExpression)
        t = t.replacingOccurrences(of: "https?://\\S+", with: "le lien affiché", options: .regularExpression)
        t = t.replacingOccurrences(of: "[*_#`>|]", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = true }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = self.synth.isSpeaking }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}
