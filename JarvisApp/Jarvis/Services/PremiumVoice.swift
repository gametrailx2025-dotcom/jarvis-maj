import AVFoundation
import Foundation

/// Voix premium (ElevenLabs) : très naturelle, voix au choix. Repli automatique sur la voix Apple en cas de souci.
enum PremiumVoice {
    /// Clés de l'éditeur : quand la 1re n'a plus de crédits, la suivante prend le relais.
    static let apiKeys = [
        "sk_51148cc45f93a680b8ac3a14ea3975c0d2ce251fcdf92f54",
        "sk_6fbe8cea5392b63cb125359af0477a078785914a1b57f38b",
    ]

    static var keyIndex: Int {
        get { min(max(0, UserDefaults.standard.integer(forKey: "premiumKeyIndex")), apiKeys.count - 1) }
        set { UserDefaults.standard.set(newValue % apiKeys.count, forKey: "premiumKeyIndex") }
    }

    static var apiKey: String { apiKeys[keyIndex] }

    struct Credits: Identifiable {
        let id: Int
        let key: String
        let active: Bool
        var used = 0
        var limit = 0
        var reset: Date?
        var error: String?
        var remaining: Int { max(0, limit - used) }
    }

    /// Crédits restants de chaque clé (et date de remise à zéro).
    static func credits() async -> [Credits] {
        var out: [Credits] = []
        for (i, key) in apiKeys.enumerated() {
            var c = Credits(id: i + 1, key: "…" + String(key.suffix(4)), active: i == keyIndex)
            var req = URLRequest(url: URL(string: "\(api)/v1/user/subscription")!, timeoutInterval: 10)
            req.setValue(key, forHTTPHeaderField: "xi-api-key")
            if let r = try? await URLSession.shared.data(for: req),
               let code = (r.1 as? HTTPURLResponse)?.statusCode {
                if code == 200, let d = (try? JSONSerialization.jsonObject(with: r.0)) as? [String: Any] {
                    c.used = d["character_count"] as? Int ?? 0
                    c.limit = d["character_limit"] as? Int ?? 0
                    if let t = d["next_character_count_reset_unix"] as? Double { c.reset = Date(timeIntervalSince1970: t) }
                } else {
                    c.error = code == 401 ? "cette clé ne peut pas lire ses crédits" : "réponse \(code)"
                }
            } else {
                c.error = "service injoignable"
            }
            out.append(c)
        }
        return out
    }
    static let api = "https://api.elevenlabs.io"
    static let fastModel = "eleven_flash_v2_5"
    static let qualityModel = "eleven_multilingual_v2"
    /// « George » : voix masculine posée, accent britannique — très JARVIS.
    static let defaultVoice = Voice(id: "JBFqnCBsd6RMkjVDRZzb", name: "George", detail: "male, british", previewURL: nil)

    struct Voice: Identifiable, Hashable {
        let id: String
        let name: String
        let detail: String
        let previewURL: URL?
    }

    private static var defaults: UserDefaults { .standard }

    static var isEnabled: Bool {
        get { defaults.object(forKey: "premiumVoiceEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "premiumVoiceEnabled") }
    }

    static var highQuality: Bool {
        get { defaults.bool(forKey: "premiumVoiceQuality") }
        set { defaults.set(newValue, forKey: "premiumVoiceQuality") }
    }

    static var current: Voice {
        guard let id = defaults.string(forKey: "premiumVoiceID"), !id.isEmpty else { return defaultVoice }
        return Voice(id: id, name: defaults.string(forKey: "premiumVoiceName") ?? "?", detail: "", previewURL: nil)
    }

    static func select(_ v: Voice) {
        defaults.set(v.id, forKey: "premiumVoiceID")
        defaults.set(v.name, forKey: "premiumVoiceName")
        isEnabled = true
    }

    static func synthesize(_ text: String) async throws -> Data {
        for _ in 0..<apiKeys.count {
            do {
                return try await synthesizeOnce(text)
            } catch is QuotaError {
                keyIndex = keyIndex + 1          // plus de crédits : on passe à la clé suivante
            }
        }
        throw URLError(.userAuthenticationRequired)
    }

    struct QuotaError: Error {}

    private static func synthesizeOnce(_ text: String) async throws -> Data {
        var comps = URLComponents(string: "\(api)/v1/text-to-speech/\(current.id)")
        comps?.queryItems = [URLQueryItem(name: "output_format", value: "mp3_44100_128")]
        guard let url = comps?.url else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "text": text,
            "model_id": highQuality ? qualityModel : fastModel,
            "language_code": "fr",
            "voice_settings": ["stability": 0.5, "similarity_boost": 0.8, "style": 0.2, "use_speaker_boost": true],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let result = try await URLSession.shared.data(for: req)
        let code = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
        if [401, 402, 429].contains(code), apiKeys.count > 1 {
            let txt = String(decoding: result.0, as: UTF8.self)
            if code != 429 || txt.contains("quota") { throw QuotaError() }
        }
        guard code == 200, result.0.count > 100 else {
            throw URLError(.badServerResponse)
        }
        return result.0
    }

    static func listVoices(search: String = "") async -> [Voice] {
        var comps = URLComponents(string: "\(api)/v2/voices")
        var items = [URLQueryItem(name: "page_size", value: "40"), URLQueryItem(name: "sort", value: "name"),
                     URLQueryItem(name: "sort_direction", value: "asc")]
        if !search.isEmpty { items.append(URLQueryItem(name: "search", value: search)) }
        comps?.queryItems = items
        guard let url = comps?.url else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        guard let result = try? await URLSession.shared.data(for: req),
              let json = (try? JSONSerialization.jsonObject(with: result.0)) as? [String: Any] else { return [] }
        let raw = json["voices"] as? [[String: Any]] ?? []
        return raw.compactMap { v -> Voice? in
            guard let id = v["voice_id"] as? String else { return nil }
            let labels = v["labels"] as? [String: Any] ?? [:]
            let detail = ["gender", "accent", "age"].compactMap { labels[$0] as? String }.joined(separator: ", ")
            return Voice(id: id, name: v["name"] as? String ?? "?", detail: detail,
                         previewURL: (v["preview_url"] as? String).flatMap(URL.init(string:)))
        }
    }
}
