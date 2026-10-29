import Foundation

/// Maison connectée directement depuis le Mac / l'iPhone (Home Assistant), sans passer par le PC.
/// Réglages › Maison connectée : adresse (ex. http://homeassistant.local:8123) + jeton d'accès longue durée.
@MainActor
enum HomeAssistant {
    nonisolated static let urlKey = "homeAssistantURL"
    nonisolated static let tokenKey = "homeAssistantToken"

    static var baseURL: String {
        (UserDefaults.standard.string(forKey: urlKey) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }
    static var token: String { Keychain.get(tokenKey) ?? "" }
    static var isConfigured: Bool { !baseURL.isEmpty && !token.isEmpty }

    private static let domains: Set<String> = ["light", "switch", "cover", "scene", "fan", "climate"]

    private static func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        guard let url = URL(string: baseURL + path) else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    static func load() async -> HomeInfo {
        guard isConfigured else { return HomeInfo(configured: false, devices: [], error: nil, message: nil) }
        do {
            let data = try await request("/api/states")
            let list = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
            let devices: [HomeDevice] = list.compactMap { s in
                guard let id = s["entity_id"] as? String, let domain = id.split(separator: ".").first.map(String.init),
                      domains.contains(domain) else { return nil }
                let attrs = s["attributes"] as? [String: Any] ?? [:]
                let name = attrs["friendly_name"] as? String ?? id
                return HomeDevice(id: id, name: name, state: s["state"] as? String, domain: domain)
            }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            return HomeInfo(configured: true, devices: Array(devices.prefix(60)), error: nil, message: nil)
        } catch {
            return HomeInfo(configured: true, devices: [], error: "Home Assistant injoignable : vérifiez l'adresse et le jeton.", message: nil)
        }
    }

    static func toggle(_ device: HomeDevice) async -> String {
        let service: String
        switch device.domain {
        case "scene": service = "turn_on"
        case "cover": service = device.isOn ? "close_cover" : "open_cover"
        default: service = "toggle"
        }
        do {
            _ = try await request("/api/services/\(device.domain)/\(service)", method: "POST", body: ["entity_id": device.id])
            return device.domain == "scene" ? "Scène « \(device.name) » activée." : "« \(device.name) » : c'est fait."
        } catch {
            return "Home Assistant ne répond pas."
        }
    }

    /// « allume / éteins toutes les lumières », « allume la lumière du salon »…
    static func voice(_ t: String, devices: [HomeDevice]) async -> String? {
        guard isConfigured else { return nil }
        let on = t.hasPrefix("allume")
        let off = t.hasPrefix("eteins") || t.hasPrefix("eteint") || t.hasPrefix("coupe")
        guard on || off, t.contains("lumiere") || t.contains("lampe") || t.contains("prise") || t.contains("tout") else { return nil }
        let service = on ? "turn_on" : "turn_off"
        if t.contains("toutes") || t.contains("tout") {
            _ = try? await request("/api/services/light/\(service)", method: "POST", body: ["entity_id": "all"])
            return on ? "Toutes les lumières sont allumées." : "Toutes les lumières sont éteintes."
        }
        let words = t.split(separator: " ").map(String.init).filter { $0.count > 3 }
        if let d = devices.first(where: { dev in
            let n = DeviceCommands.fold(dev.name)
            return (dev.domain == "light" || dev.domain == "switch") && words.contains { n.contains($0) && !["lumiere", "lampe", "allume", "eteins"].contains($0) }
        }) {
            _ = try? await request("/api/services/\(d.domain)/\(service)", method: "POST", body: ["entity_id": d.id])
            return "« \(d.name) » \(on ? "allumé" : "éteint")."
        }
        return nil
    }
}
