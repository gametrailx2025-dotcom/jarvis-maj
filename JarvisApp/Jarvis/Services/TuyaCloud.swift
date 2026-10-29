import CryptoKit
import Foundation

/// LSC Smart Connect (Action) / Smart Life / Tuya, directement par le cloud Tuya (sans PC ni Home Assistant).
/// Réglages › Maison connectée : Access ID + Access Secret du projet platform.tuya.com (tutoriel, étape W).
@MainActor
enum TuyaCloud {
    nonisolated static let idKey = "tuyaAccessID"
    nonisolated static let regionKey = "tuyaRegion"
    nonisolated static let secretKey = "tuyaAccessSecret"

    struct Region: Identifiable { let id: String; let label: String; let url: String }

    static let regions: [Region] = [
        Region(id: "eu", label: "Europe centrale (France)", url: "https://openapi.tuyaeu.com"),
        Region(id: "weu", label: "Europe de l'Ouest", url: "https://openapi-weaz.tuyaeu.com"),
        Region(id: "us", label: "Amérique", url: "https://openapi.tuyaus.com"),
        Region(id: "in", label: "Inde", url: "https://openapi.tuyain.com"),
        Region(id: "cn", label: "Chine", url: "https://openapi.tuyacn.com"),
    ]

    static var accessID: String { (UserDefaults.standard.string(forKey: idKey) ?? "").trimmingCharacters(in: .whitespaces) }
    static var secret: String { (Keychain.get(secretKey) ?? "").trimmingCharacters(in: .whitespaces) }
    static var base: String {
        let r = UserDefaults.standard.string(forKey: regionKey) ?? "eu"
        return regions.first { $0.id == r }?.url ?? regions[0].url
    }
    static var isConfigured: Bool { !accessID.isEmpty && !secret.isEmpty }

    private static var token: (value: String, expires: Date)?
    private static var cache: [[String: Any]] = []

    private static let switchCodes = ["switch_led", "switch_1", "switch", "switch_on", "switch_2"]
    private static let categories: [String: String] = [
        "dj": "light", "dd": "light", "xdd": "light", "fwd": "light", "dc": "light", "fsd": "light", "tgq": "light",
        "tgkg": "light", "gyd": "light", "cz": "switch", "pc": "switch", "kg": "switch", "tdq": "switch",
        "cl": "cover", "clkg": "cover", "mc": "cover", "fs": "fan",
    ]

    // MARK: Signature HMAC-SHA256

    private static func hex(_ data: some Sequence<UInt8>) -> String { data.map { String(format: "%02x", $0) }.joined() }

    private static func call(_ method: String, _ path: String, body: [String: Any]? = nil, auth: Bool = true) async throws -> Any? {
        let bodyData = try body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
        var tok = ""
        if auth { tok = try await accessToken() }
        let t = String(Int(Date().timeIntervalSince1970 * 1000))
        let contentHash = hex(SHA256.hash(data: bodyData))
        let toSign = "\(method)\n\(contentHash)\n\n\(path)"
        let mac = HMAC<SHA256>.authenticationCode(for: Data((accessID + tok + t + toSign).utf8),
                                                 using: SymmetricKey(data: Data(secret.utf8)))
        guard let url = URL(string: base + path) else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.httpMethod = method
        req.setValue(accessID, forHTTPHeaderField: "client_id")
        req.setValue(hex(mac).uppercased(), forHTTPHeaderField: "sign")
        req.setValue(t, forHTTPHeaderField: "t")
        req.setValue("HMAC-SHA256", forHTTPHeaderField: "sign_method")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if auth { req.setValue(tok, forHTTPHeaderField: "access_token") }
        if body != nil { req.httpBody = bodyData }
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard json["success"] as? Bool == true else {
            let code = json["code"] as? Int ?? 0
            if code == 1010 || code == 1011 { token = nil }
            if [1004, 1005, 2009, 2017].contains(code) {
                throw AccountError.message("Tuya refuse l'Access ID ou l'Access Secret (vérifiez aussi la région).")
            }
            throw AccountError.message("Tuya : \(json["msg"] as? String ?? "erreur \(code)").")
        }
        return json["result"]
    }

    private static func accessToken() async throws -> String {
        if let token, Date() < token.expires { return token.value }
        let res = try await call("GET", "/v1.0/token?grant_type=1", auth: false) as? [String: Any] ?? [:]
        guard let v = res["access_token"] as? String else { throw AccountError.message("Connexion à Tuya impossible.") }
        token = (v, Date().addingTimeInterval(Double(res["expire_time"] as? Int ?? 3600) - 120))
        return v
    }

    // MARK: Appareils

    private static func status(_ d: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for s in d["status"] as? [[String: Any]] ?? [] {
            if let c = s["code"] as? String { out[c] = s["value"] }
        }
        return out
    }

    private static func domain(_ d: [String: Any]) -> String? {
        if let c = d["category"] as? String, let dom = categories[c] { return dom }
        let st = status(d)
        if st["switch_led"] != nil { return "light" }
        return switchCodes.contains { st[$0] != nil } ? "switch" : nil
    }

    static func load() async -> HomeInfo {
        guard isConfigured else { return HomeInfo(configured: false, devices: [], error: nil, message: nil) }
        do {
            let res = try await call("GET", "/v1.0/iot-01/associated-users/devices?size=100")
            let list = ((res as? [String: Any])?["devices"] as? [[String: Any]]) ?? (res as? [[String: Any]]) ?? []
            cache = list
            let devices: [HomeDevice] = list.compactMap { d in
                guard let id = d["id"] as? String, let dom = domain(d) else { return nil }
                let st = status(d)
                let on = switchCodes.compactMap { st[$0] as? Bool }.first ?? false
                let state = dom == "cover" ? ((st["control"] as? String) == "open" ? "open" : "closed") : (on ? "on" : "off")
                return HomeDevice(id: id, name: d["name"] as? String ?? id, state: state, domain: dom)
            }
            return HomeInfo(configured: true, devices: devices,
                            error: devices.isEmpty ? "Aucun appareil : reliez le compte de l'application au projet Tuya (tutoriel, étape W)." : nil,
                            message: nil)
        } catch {
            return HomeInfo(configured: true, devices: [], error: error.localizedDescription, message: nil)
        }
    }

    private static func send(_ id: String, _ commands: [[String: Any]]) async throws {
        _ = try await call("POST", "/v1.0/iot-03/devices/\(id)/commands", body: ["commands": commands])
    }

    private static func switchCode(_ id: String, domain: String) -> String {
        let st = cache.first { $0["id"] as? String == id }.map(status) ?? [:]
        return switchCodes.first { st[$0] != nil } ?? (domain == "light" ? "switch_led" : "switch_1")
    }

    static func set(_ device: HomeDevice, on: Bool) async -> String {
        do {
            if device.domain == "cover" {
                try await send(device.id, [["code": "control", "value": on ? "open" : "close"]])
            } else {
                try await send(device.id, [["code": switchCode(device.id, domain: device.domain), "value": on]])
            }
            return "« \(device.name) » \(on ? "allumé" : "éteint")."
        } catch {
            return error.localizedDescription
        }
    }

    static func toggle(_ device: HomeDevice) async -> String { await set(device, on: !device.isOn) }

    /// « allume la lampe du salon », « éteins tout », « éteins toutes les lumières »
    static func voice(_ t: String, devices: [HomeDevice]) async -> String? {
        guard isConfigured else { return nil }
        let on = t.hasPrefix("allume")
        let off = t.hasPrefix("eteins") || t.hasPrefix("eteint") || t.hasPrefix("coupe")
        guard on || off else { return nil }
        var list = devices
        if list.isEmpty { list = (await load()).devices }
        let generic = ["allume", "eteins", "eteint", "coupe", "la", "le", "les", "du", "de", "des", "lumiere", "lumieres",
                       "lampe", "lampes", "prise", "prises", "toutes", "tout", "tous", "mon", "ma", "mes", "dans", "salle"]
        if t.contains("tout") {
            let lightsOnly = t.contains("lumiere") || t.contains("lampe")
            let targets = list.filter { $0.domain == "light" || (!lightsOnly && $0.domain == "switch") }
            for d in targets { _ = await set(d, on: on) }
            return targets.isEmpty ? nil : "\(targets.count) appareil\(targets.count > 1 ? "s" : "") \(on ? "allumé" : "éteint")\(targets.count > 1 ? "s" : "")."
        }
        let words = t.split(separator: " ").map(String.init).filter { $0.count > 2 && !generic.contains($0) }
        guard !words.isEmpty, let d = list.first(where: { dev in
            let n = DeviceCommands.fold(dev.name)
            return words.allSatisfy { n.contains($0) }
        }) ?? list.first(where: { dev in words.contains { DeviceCommands.fold(dev.name).contains($0) } }) else { return nil }
        return await set(d, on: on)
    }

    static func test() async -> String {
        token = nil
        let info = await load()
        if let e = info.error { return "❌ " + e }
        return "✅ Connexion réussie : \(info.devices.count) appareil\(info.devices.count > 1 ? "s" : "")."
    }
}
