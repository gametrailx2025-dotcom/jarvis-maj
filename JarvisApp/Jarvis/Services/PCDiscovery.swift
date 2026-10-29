import Foundation

/// Trouve les PC JARVIS sur le Wi-Fi (annonce Bonjour « _jarvis._tcp ») et les relie avec un code à 6 chiffres.
@MainActor
final class PCDiscovery: NSObject, ObservableObject {
    struct FoundPC: Identifiable, Equatable {
        let id: String
        let name: String
        let url: String
    }

    @Published private(set) var found: [FoundPC] = []
    @Published private(set) var searching = false

    private var browser: NetServiceBrowser?
    private var pending: [NetService] = []

    func start() {
        stop()
        searching = true
        let b = NetServiceBrowser()
        b.delegate = self
        b.searchForServices(ofType: "_jarvis._tcp.", inDomain: "local.")
        browser = b
    }

    func stop() {
        browser?.stop()
        browser = nil
        pending.forEach { $0.stop() }
        pending.removeAll()
        searching = false
    }

    fileprivate func add(_ service: NetService) {
        guard let host = service.hostName, service.port > 0 else { return }
        let h = host.hasSuffix(".") ? String(host.dropLast()) : host
        let pc = FoundPC(id: service.name, name: service.name.replacingOccurrences(of: "JARVIS ", with: ""),
                         url: "http://\(h):\(service.port)")
        if !found.contains(pc) { found.append(pc) }
    }

    fileprivate func track(_ service: NetService) {
        pending.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    /// Échange le code affiché sur le PC contre le jeton d'accès (enregistré dans le trousseau).
    static func pair(url: String, code: String) async throws -> String {
        guard let endpoint = URL(string: url.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + "/api/pair") else {
            throw PairError.message("Adresse invalide.")
        }
        var req = URLRequest(url: endpoint, timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let digits = code.filter(\.isNumber)
        req.httpBody = try JSONSerialization.data(withJSONObject: ["code": digits])
        let result = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: result.0)) as? [String: Any] ?? [:]
        guard (result.1 as? HTTPURLResponse)?.statusCode == 200, let token = json["token"] as? String else {
            throw PairError.message(json["error"] as? String ?? "Le PC a refusé le code.")
        }
        return token
    }

    /// Relier avec le compte JARVIS : le PC affiche « Nouvel appareil », on attend son accord (5 min max).
    static func login(url: String, email: String, name: String) async throws -> String {
        let base = url.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let endpoint = URL(string: base + "/api/login") else { throw PairError.message("Adresse invalide.") }
        var req = URLRequest(url: endpoint, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["email": email, "name": name])
        let first = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: first.0)) as? [String: Any] ?? [:]
        guard (first.1 as? HTTPURLResponse)?.statusCode == 202, let rid = json["pending"] as? String,
              let statusURL = URL(string: base + "/api/login/status?id=" + rid) else {
            throw PairError.message(json["error"] as? String ?? "Le PC a refusé la demande.")
        }
        for _ in 0..<150 {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let r = try await URLSession.shared.data(from: statusURL)
            let st = (try? JSONSerialization.jsonObject(with: r.0)) as? [String: Any] ?? [:]
            if st["status"] as? String == "accepted", let token = st["token"] as? String {
                SyncCloud.store(st["sync"] as? [String: Any])     // accès à la sauvegarde chiffrée du compte
                return token
            }
            if st["status"] as? String == "refused" || (r.1 as? HTTPURLResponse)?.statusCode == 404 {
                throw PairError.message("L'appareil a été refusé sur le PC.")
            }
        }
        throw PairError.message("Pas de réponse : acceptez l'appareil sur l'écran du PC.")
    }

    enum PairError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let m): return m }
        }
    }
}

extension PCDiscovery: NetServiceBrowserDelegate, NetServiceDelegate {
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        MainActor.assumeIsolated { self.track(service) }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        MainActor.assumeIsolated { self.add(sender) }
    }

    nonisolated func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        MainActor.assumeIsolated { self.searching = false }
    }
}
