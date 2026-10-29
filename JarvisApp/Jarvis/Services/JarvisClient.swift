import Foundation

enum ClientError: LocalizedError {
    case badURL
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "Adresse du PC invalide."
        case .server(401, _): return "Jeton refusé par le PC."
        case .server(429, _): return "Trop d'essais : réessayez dans une minute."
        case .server(let code, let msg): return msg.isEmpty ? "Erreur \(code) du PC." : msg
        }
    }
}

private struct ErrorBody: Decodable { let error: String }

/// Client de l'API distante du cerveau JARVIS (jarvis/server/remote.py).
struct JarvisClient {
    let baseURL: URL
    let token: String

    static let deviceNameKey = "deviceName"

    /// Nom de l'appareil (modifiable dans les Réglages), ex. « iPhone d'Evan », « MacBook Air ».
    static var deviceName: String {
        if let n = UserDefaults.standard.string(forKey: deviceNameKey), !n.trimmingCharacters(in: .whitespaces).isEmpty {
            return n
        }
        #if os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return "iPhone"
        #endif
    }

    static func make(urlString: String, token: String) -> JarvisClient? {
        let raw = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !token.isEmpty,
              let url = URL(string: raw.hasPrefix("http") ? raw : "http://" + raw) else { return nil }
        return JarvisClient(baseURL: url, token: token)
    }

    func get<T: Decodable>(_ path: String, timeout: TimeInterval = 10) async throws -> T {
        try await send(path, method: "GET", body: nil, timeout: timeout)
    }

    func post<T: Decodable>(_ path: String, body: [String: Any], timeout: TimeInterval = 20) async throws -> T {
        try await send(path, method: "POST", body: body, timeout: timeout)
    }

    private func send<T: Decodable>(_ path: String, method: String, body: [String: Any]?,
                                    timeout: TimeInterval) async throws -> T {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw ClientError.badURL }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Nom de cet appareil : le PC en déduit la pièce où l'on se trouve (micros de cette pièce)
        req.setValue(Self.deviceName.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "",
                     forHTTPHeaderField: "X-Jarvis-Device")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let msg = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? ""
            throw ClientError.server(code, msg)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
