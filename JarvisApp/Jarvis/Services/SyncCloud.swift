import CryptoKit
import Foundation

/// Lecture de la sauvegarde cloud chiffrée faite par le PC (tâches, rendez-vous, courses…).
/// La clé de déchiffrement est donnée par le PC quand on relie l'appareil avec le compte.
/// Utile quand le PC est éteint : l'iPhone / le Mac retrouvent vos listes.
enum SyncCloud {
    private static let binKey = "syncBin"
    private static let secretKey = "syncSecret"
    // Clé de l'éditeur (lecture du service de sauvegarde) ; les données restent chiffrées.
    private static let master = String(data: Data(base64Encoded:
        "JDJhJDEwJENvT1VnUlZiUU15cUNHSkJGbFZyOU9YS1Z6S2lIWVBvdXZNU096NzJZeDZWZ3RmV0pqSW1H") ?? Data(), encoding: .utf8) ?? ""

    static var isConfigured: Bool { Keychain.get(binKey) != nil && Keychain.get(secretKey) != nil }

    static func store(_ info: [String: Any]?) {
        guard let info, let bin = info["bin"] as? String, let secret = info["secret"] as? String,
              !bin.isEmpty, !secret.isEmpty else { return }
        Keychain.set(bin, for: binKey)
        Keychain.set(secret, for: secretKey)
    }

    /// Demande au PC relié l'accès à la sauvegarde (pour les appareils reliés avant cette fonction).
    @MainActor private static var nextFetch = Date.distantPast

    @MainActor
    static func fetchInfo(from client: JarvisClient) async {
        guard Date() > nextFetch else { return }           // au plus toutes les 10 minutes
        nextFetch = Date().addingTimeInterval(600)
        struct R: Decodable { let sync: [String: String]? }
        if let r: R = try? await client.get("/api/sync"), let s = r.sync { store(s) }
    }

    static func snapshot() async -> [String: Any]? {
        guard let bin = Keychain.get(binKey), let secret = Keychain.get(secretKey),
              let keyData = Data(base64Encoded: secret),
              let url = URL(string: "https://api.jsonbin.io/v3/b/\(bin)/latest") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(master, forHTTPHeaderField: "X-Master-Key")
        req.setValue("false", forHTTPHeaderField: "X-Bin-Meta")
        guard let result = try? await URLSession.shared.data(for: req),
              let record = (try? JSONSerialization.jsonObject(with: result.0)) as? [String: Any],
              let b64 = record["data"] as? String, let combined = Data(base64Encoded: b64),
              let box = try? AES.GCM.SealedBox(combined: combined),
              let plain = try? AES.GCM.open(box, using: SymmetricKey(data: keyData), authenticating: Data("jarvis".utf8))
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any]
    }

    /// PC injoignable : on reprend tâches, rendez-vous et courses de la dernière sauvegarde.
    @MainActor
    static func importIfUseful(into hub: LocalHub) async -> Bool {
        guard isConfigured, let snap = await snapshot(), let data = snap["data"] as? [String: Any] else { return false }
        let tasks = (data["tasks"] as? [[String: Any]] ?? []).filter { ($0["done"] as? Int ?? 0) == 0 }
            .compactMap { $0["title"] as? String }
        let iso = DateFormatter()
        iso.locale = Locale(identifier: "en_US_POSIX")
        let events: [(String, Date)] = (data["events"] as? [[String: Any]] ?? []).compactMap { e in
            guard let t = e["title"] as? String, let s = e["start"] as? String else { return nil }
            for f in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss"] {
                iso.dateFormat = f
                if let d = iso.date(from: String(s.prefix(19))) { return (t, d) }
            }
            return nil
        }
        let shopping = (data["shopping"] as? [[String: Any]] ?? []).compactMap { $0["item"] as? String }
        hub.replaceFromCloud(tasks: tasks, events: events, shopping: shopping)
        return true
    }
}
