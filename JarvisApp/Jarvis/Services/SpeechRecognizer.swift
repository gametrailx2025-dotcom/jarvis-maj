import AVFoundation
import Foundation
import Speech

/// Reconnaissance vocale en français (framework Speech d'Apple), deux modes :
/// - **mot d'éveil** (par défaut) : écoute en continu tant que l'app est ouverte ; dire « Jarvis »
///   (ou « Jarvis, ouvre Discord ») déclenche la commande, sans toucher l'écran ;
/// - **appui pour parler** : bouton micro, une phrase, arrêt automatique après un court silence.
/// Pendant que JARVIS parle, seul un mot d'interruption est écouté (« Jarvis », « stop », « tais-toi »…) :
/// on peut lui couper la parole à la voix.
@MainActor
final class SpeechRecognizer: ObservableObject {
    @Published private(set) var transcript = ""
    @Published private(set) var isRunning = false      // micro ouvert
    @Published private(set) var isCapturing = false    // une commande est en cours de dictée
    @Published private(set) var wakeMode = false

    var onFinal: ((String) -> Void)?
    var onWake: (() -> Void)?
    /// Interruption à la voix pendant que JARVIS parle.
    var onBargeIn: (() -> Void)?
    var bargeInEnabled = true
    /// Texte que JARVIS est en train de dire (pour ne pas réagir à sa propre voix captée par le micro).
    var speakingText = ""
    private var bargeListening = false
    private static let bargeWords = ["jarvis", "jarvisse", "stop", "tais toi", "tais-toi", "chut", "arrete", "arrête",
                                     "ca suffit", "ça suffit", "attends", "silence"]

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "fr-FR"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Task<Void, Never>?
    private var recycleTimer: Task<Void, Never>?
    private var armedUntil = Date.distantPast
    private var paused = false
    private var generation = 0

    private static let wakeWords = ["jarvis", "jarvisse", "jar vis", "djarvis", "charvis"]

    enum SpeechError: LocalizedError {
        case unavailable
        var errorDescription: String? { "La reconnaissance vocale française n'est pas disponible sur cet appareil." }
    }

    /// Micro et reconnaissance vocale déjà autorisés ?
    var isAuthorized: Bool {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return false }
        #if os(iOS)
        return AVAudioApplication.shared.recordPermission == .granted
        #else
        return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        #endif
    }

    func requestAuthorization() async -> Bool {
        let speechOK = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in cont.resume(returning: status == .authorized) }
        }
        guard speechOK else { return false }
        #if os(iOS)
        return await AVAudioApplication.requestRecordPermission()
        #else
        return await AVCaptureDevice.requestAccess(for: .audio)
        #endif
    }

    // MARK: - Commandes publiques

    /// Appui sur le micro : capture une phrase. En mode mot d'éveil, équivaut à dire « Jarvis ».
    func listenOnce() throws {
        if wakeMode && isRunning {
            arm()
            return
        }
        try startSession()
        isCapturing = true
        armSilence(seconds: 8)
    }

    func stop(commit: Bool) {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let wasCapturing = isCapturing
        if wakeMode {
            isCapturing = false
            if commit && wasCapturing && text.isEmpty {
                arm()  // « Jarvis » seul, suivi d'un silence : il répond « Oui ? » et attend
                return
            }
            armedUntil = .distantPast
            restartSession()
        } else {
            teardown()
        }
        if commit && wasCapturing && !text.isEmpty { onFinal?(text) }
    }

    func setWakeMode(_ on: Bool) {
        wakeMode = on
        if on {
            if !paused { try? startSession() }
        } else {
            teardown()
        }
    }

    /// Pendant que JARVIS parle : on n'écoute plus les commandes, seulement les mots d'interruption.
    func setPaused(_ value: Bool) {
        paused = value
        if value {
            guard wakeMode else { return }
            if bargeInEnabled {
                isCapturing = false
                bargeListening = true
                try? startSession()          // session neuve : on n'analyse que ce qui est dit pendant sa phrase
            } else {
                teardown(keepMode: true)
            }
        } else if wakeMode && (!isRunning || bargeListening) {
            bargeListening = false
            try? startSession()
        }
    }

    /// Un mot d'interruption a-t-il été dit (et pas simplement entendu dans la propre phrase de JARVIS) ?
    static func isBargeIn(_ text: String, ignoring spoken: String) -> Bool {
        let fold: (String) -> String = {
            $0.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
        }
        let heard = fold(text)
        let own = fold(spoken)
        return bargeWords.map(fold).contains { word in heard.contains(word) && !own.contains(word) }
    }

    // MARK: - Session audio

    private func startSession() throws {
        guard let recognizer, recognizer.isAvailable else { throw SpeechError.unavailable }
        teardown(keepMode: true)
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.makeTap(request))
        engine.prepare()
        try engine.start()

        generation += 1
        transcript = ""
        isRunning = true
        task = recognizer.recognitionTask(with: request, resultHandler: Self.makeHandler(self, generation))
        if wakeMode { scheduleRecycle() }
    }

    /// Les sessions de reconnaissance sont limitées (~1 min) : on en relance une régulièrement.
    private func scheduleRecycle() {
        recycleTimer?.cancel()
        recycleTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000_000)
            guard !Task.isCancelled, let self, self.wakeMode, !self.isCapturing else { return }
            self.restartSession()
        }
    }

    private func restartSession() {
        guard wakeMode, !paused else { return }
        try? startSession()
    }

    private func teardown(keepMode: Bool = false) {
        silenceTimer?.cancel()
        silenceTimer = nil
        recycleTimer?.cancel()
        recycleTimer = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isRunning = false
        if !keepMode { isCapturing = false }
        #if os(iOS)
        if !wakeMode || paused {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        }
        #endif
    }

    // MARK: - Résultats

    nonisolated private static func makeTap(_ request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        return { buffer, _ in request.append(buffer) }
    }

    nonisolated private static func makeHandler(_ owner: SpeechRecognizer, _ gen: Int) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        return { [weak owner] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in
                guard let owner, owner.isRunning, owner.generation == gen else { return }
                owner.received(text: text ?? "", isFinal: isFinal, failed: failed)
            }
        }
    }

    private func received(text: String, isFinal: Bool, failed: Bool) {
        if paused {
            guard bargeListening else { return }
            if Self.isBargeIn(text, ignoring: speakingText) {
                bargeListening = false
                armedUntil = Date().addingTimeInterval(8)   // la phrase suivante est une commande
                onBargeIn?()
            } else if isFinal || failed {
                try? startSession()
            }
            return
        }
        if wakeMode && !isCapturing {
            if let command = Self.afterWakeWord(text) {
                // On attend la fin de la phrase : « Jarvis… ouvre Discord » ne doit pas être coupé après « Jarvis ».
                isCapturing = true
                transcript = command
                armSilence(seconds: command.isEmpty ? 1.2 : 1.4)
            } else if Date() < armedUntil, !text.isEmpty {
                isCapturing = true
                transcript = text
                armSilence(seconds: 1.4)
            } else if isFinal || failed {
                restartSession()
            }
            return
        }
        if isCapturing {
            if wakeMode, let command = Self.afterWakeWord(text) {
                transcript = command
            } else if !text.isEmpty {
                transcript = text
            }
            if !transcript.isEmpty { armSilence(seconds: 1.4) }
            if isFinal || failed { stop(commit: true) }
        }
    }

    /// « Jarvis » seul : JARVIS répond « Oui ? » et attend la phrase suivante quelques secondes.
    private func arm() {
        isCapturing = false
        transcript = ""
        armedUntil = Date().addingTimeInterval(8)
        onWake?()
        restartSession()
    }

    /// Renvoie le texte après le mot d'éveil (chaîne vide si « Jarvis » seul), nil s'il n'y est pas.
    static func afterWakeWord(_ text: String) -> String? {
        let lower = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
        for word in wakeWords {
            if let range = lower.range(of: word, options: .backwards) {
                let offset = lower.distance(from: lower.startIndex, to: range.upperBound)
                let tail = String(text.dropFirst(offset))
                return tail.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            }
        }
        return nil
    }

    private func armSilence(seconds: Double) {
        silenceTimer?.cancel()
        silenceTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.stop(commit: true)
        }
    }
}
