import Foundation
#if os(macOS)
import AppKit
#endif

/// Module « Globe » : la vue 3D God's Eye View (open source, MIT) lancée en local sur le Mac,
/// puis affichée dans l'onglet Globe de JARVIS.
@MainActor
final class GlobeServer: ObservableObject {
    enum Status: Equatable {
        case idle, installing, starting, ready, unavailable(String), failed(String)
    }

    static let port = 4173
    /// Mac : le globe tourne sur le Mac. iPhone : c'est le PC qui le fait tourner, affiché par le Wi-Fi.
    static var url: URL {
        #if os(macOS)
        return URL(string: "http://127.0.0.1:\(port)/")!
        #else
        let pc = UserDefaults.standard.string(forKey: SettingsKey.pcURL) ?? ""
        if let u = URL(string: pc.hasPrefix("http") ? pc : "http://" + pc), let host = u.host, !host.isEmpty {
            return URL(string: "http://\(host):\(port)/")!
        }
        return URL(string: "http://127.0.0.1:\(port)/")!
        #endif
    }

    #if !os(macOS)
    private struct GlobeReply: Decodable { let status: String?; let message: String? }
    #endif

    @Published private(set) var status: Status = .idle
    @Published private(set) var log: [String] = []

    #if os(macOS)
    private var process: Process?
    private var stopping = false
    private var quitObserver: NSObjectProtocol?

    /// Dossier JARVIS : enregistré par jarvis-mac.command, sinon déduit de l'emplacement du code (lancement Xcode).
    var jarvisRoot: URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let saved = UserDefaults.standard.string(forKey: "jarvisRoot"), !saved.isEmpty {
            candidates.append(URL(fileURLWithPath: saved))
        }
        // …/JARVIS/apple/JarvisApp/Jarvis/Services/GlobeServer.swift → remonter de 5 niveaux
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        candidates.append(url)
        return candidates.first { fm.fileExists(atPath: $0.appendingPathComponent("addons/gods-eye-view/package.json").path) }
    }

    private var addon: URL? { jarvisRoot?.appendingPathComponent("addons/gods-eye-view") }

    private func findNode() -> String? {
        var paths: [String] = []
        if let root = jarvisRoot { paths.append(root.appendingPathComponent("tools/node/bin/node").path) }
        paths += ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    #endif

    /// Démarre le serveur du globe si besoin (sans effet s'il tourne déjà).
    func start() async {
        #if !os(macOS)
        // iPhone : on demande au PC de lancer le globe, puis on l'affiche quand il répond
        if status == .ready || status == .starting { return }
        if await Self.isUp() { status = .ready; return }
        guard let client = JarvisClient.make(urlString: UserDefaults.standard.string(forKey: SettingsKey.pcURL) ?? "",
                                             token: Keychain.get(Keychain.pcToken) ?? "") else {
            status = .unavailable("Reliez d'abord l'iPhone au PC (Réglages › Connexion au PC) : c'est le PC qui fait tourner le globe.")
            return
        }
        status = .starting
        for i in 0..<40 {
            if i % 5 == 0, let r: GlobeReply = try? await client.post("/api/globe/start", body: [:]) {
                if r.status == "failed" || r.status == "unavailable" {
                    status = .failed(r.message ?? "Le globe n'a pas pu démarrer sur le PC.")
                    return
                }
                if let m = r.message, !m.isEmpty { log.append(m) }
            }
            if await Self.isUp() { status = .ready; return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        status = .unavailable("Le globe ne répond pas : sur le PC, ouvrez l'onglet Globe (et autorisez Node.js dans le pare-feu Windows).")
        #endif
        #if os(macOS)
        if status == .ready || status == .starting || status == .installing { return }
        if await Self.isUp() { status = .ready; return }
        guard let addon else {
            status = .unavailable("Module Globe introuvable. Lance JARVIS avec « bash jarvis-mac.command » depuis le dossier JARVIS.")
            return
        }
        let vite = addon.appendingPathComponent("node_modules/vite/bin/vite.js")
        if findNode() == nil || !FileManager.default.fileExists(atPath: vite.path) {
            // Première fois : installation automatique (Node.js privé + composants), sans Terminal.
            guard await install() else { return }
        }
        guard let node = findNode(), FileManager.default.fileExists(atPath: vite.path) else {
            status = .failed("Installation du globe incomplète. " + log.suffix(3).joined(separator: " "))
            return
        }
        status = .starting
        stopping = false
        let p = Process()
        p.executableURL = URL(fileURLWithPath: node)
        p.arguments = [vite.path]
        p.currentDirectoryURL = addon
        var env = ProcessInfo.processInfo.environment
        env["HOST"] = "127.0.0.1"
        env["PORT"] = String(Self.port)
        env["PATH"] = URL(fileURLWithPath: node).deletingLastPathComponent().path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                guard let self else { return }
                self.log.append(contentsOf: text.split(separator: "\n").map(String.init))
                if self.log.count > 200 { self.log.removeFirst(self.log.count - 200) }
            }
        }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self, self.process === proc else { return }   // ancien processus : ignorer
                self.process = nil
                if self.stopping {
                    self.status = .idle
                } else {
                    let last = self.log.suffix(3).joined(separator: " ")
                    self.status = .failed("Le globe s'est arrêté. " + last)
                }
            }
        }
        do {
            try p.run()
        } catch {
            status = .failed("Impossible de lancer le globe : \(error.localizedDescription)")
            return
        }
        process = p
        if quitObserver == nil {
            quitObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            }
        }
        // Attend que le serveur réponde (premier démarrage : jusqu'à ~90 s)
        for _ in 0..<180 {
            if await Self.isUp() { status = .ready; return }
            if process == nil { return }   // arrêté entre-temps (statut déjà mis à jour)
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        status = .failed("Le globe met trop de temps à démarrer.")
        #else
        status = .unavailable("Le globe 3D fonctionne sur Mac (et sur PC). Ouvre l'onglet Globe dans l'app Mac.")
        #endif
    }

    #if os(macOS)
    /// Lance scripts/setup_globe_mac.sh (2 à 5 min la première fois). Renvoie vrai si tout s'est bien passé.
    private func install() async -> Bool {
        guard let root = jarvisRoot else { return false }
        status = .installing
        let script = root.appendingPathComponent("scripts/setup_globe_mac.sh").path
        let ok: Bool = await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script]
            p.currentDirectoryURL = root
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { handle.readabilityHandler = nil; return }
                let text = String(decoding: data, as: UTF8.self)
                Task { @MainActor in
                    self?.log.append(contentsOf: text.split(separator: "\n").map(String.init))
                }
            }
            p.terminationHandler = { proc in cont.resume(returning: proc.terminationStatus == 0) }
            do { try p.run() } catch { cont.resume(returning: false) }
        }
        if !ok {
            status = .failed("L'installation du globe a échoué (connexion Internet ?). " + log.suffix(2).joined(separator: " "))
        }
        return ok
    }
    #endif

    func stop() {
        #if os(macOS)
        stopping = true
        process?.terminate()
        process = nil
        status = .idle
        #endif
    }

    func restart() async {
        stop()
        try? await Task.sleep(nanoseconds: 600_000_000)
        await start()
    }

    static func isUp() async -> Bool {
        var req = URLRequest(url: url, timeoutInterval: 1.5)
        req.httpMethod = "GET"
        guard let result = try? await URLSession.shared.data(for: req) else { return false }
        return ((result.1 as? HTTPURLResponse)?.statusCode ?? 0) < 500
    }
}
