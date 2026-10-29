import Foundation

/// Compte JARVIS (Supabase) : réglages partagés entre PC, Mac et iPhone.
/// Utilise uniquement la clé PUBLIQUE du projet et la session de l'utilisateur.
/// Le mot de passe n'est jamais enregistré ; seul le jeton de rafraîchissement va dans le trousseau.
@MainActor
final class SupabaseService: ObservableObject {
    @Published private(set) var email: String?
    @Published private(set) var profile: [String: Any] = [:]
    @Published private(set) var lastError: String?

    private var accessToken: String?
    private var expiresAt = Date.distantPast
    private var userID: String?
    private static let refreshKey = "supabaseRefresh"

    enum CloudError: LocalizedError {
        case notConfigured, notSignedIn, server(String)
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Le serveur JARVIS n'est pas encore configuré."
            case .notSignedIn: return "Pas connecté au compte JARVIS."
            case .server(let m): return m
            }
        }
    }

    /// Serveur central intégré (AppConfig) ; sinon, réglage manuel (mode développeur).
    private var baseURL: String {
        let raw = AppConfig.hasBuiltInServer ? AppConfig.supabaseURL
            : (UserDefaults.standard.string(forKey: SettingsKey.supabaseURL) ?? "")
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: "/ ").union(.whitespacesAndNewlines))
    }
    private var apiKey: String {
        (AppConfig.hasBuiltInServer ? AppConfig.supabasePublishableKey
            : (UserDefaults.standard.string(forKey: SettingsKey.supabaseKey) ?? "")).trimmingCharacters(in: .whitespaces)
    }

    var isConfigured: Bool { !baseURL.isEmpty && !apiKey.isEmpty }
    var isSignedIn: Bool { isConfigured && Keychain.get(Self.refreshKey) != nil }

    // MARK: - Authentification

    func signIn(email: String, password: String) async throws {
        let mail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let json = try await call("/auth/v1/token?grant_type=password", body: ["email": mail, "password": password], auth: false)
        try store(json)
    }

    /// Renvoie un message (confirmation d'e-mail éventuelle).
    /// « Se connecter avec Google / Discord » : aucun mot de passe à créer.
    func signIn(provider: String) async throws {
        guard isConfigured else { throw CloudError.notConfigured }
        let verifier = OAuthLogin.makeVerifier()
        var comps = URLComponents(string: baseURL + "/auth/v1/authorize")
        comps?.queryItems = [
            URLQueryItem(name: "provider", value: provider),
            URLQueryItem(name: "redirect_to", value: OAuthLogin.redirect),
            URLQueryItem(name: "code_challenge", value: OAuthLogin.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "s256"),
        ]
        guard let url = comps?.url else { throw CloudError.notConfigured }
        let login = OAuthLogin()
        let callback: URL
        do {
            callback = try await login.start(url)
        } catch {
            throw CloudError.server("Connexion annulée.")
        }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        // Certaines erreurs reviennent dans le fragment (#error=…)
        let fragmentItems = URLComponents(string: "x://y?" + (callback.fragment ?? ""))?.queryItems ?? []
        if let err = (items + fragmentItems).first(where: { $0.name == "error_description" || $0.name == "error" })?.value {
            throw CloudError.server(err.contains("provider is not enabled") || err.contains("Unsupported provider")
                ? "Ce mode de connexion n'est pas encore activé côté serveur (tutoriel, étape M)."
                : "Connexion refusée : \(err)")
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw CloudError.server("Connexion interrompue : réessayez.")
        }
        let json = try await call("/auth/v1/token?grant_type=pkce", body: ["auth_code": code, "code_verifier": verifier],
                                  auth: false)
        try store(json)
    }

    func signUp(email: String, password: String) async throws -> String {
        let mail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let json = try await call("/auth/v1/signup", body: ["email": mail, "password": password], auth: false)
        if json["access_token"] != nil {
            try store(json)
            return "Compte créé et connecté."
        }
        return "Compte créé : ouvrez l'e-mail de confirmation puis connectez-vous."
    }

    func signOut() {
        objectWillChange.send()
        Keychain.set("", for: Self.refreshKey)
        accessToken = nil
        userID = nil
        email = nil
        profile = [:]
    }

    private func store(_ json: [String: Any]) throws {
        guard let access = json["access_token"] as? String, let refresh = json["refresh_token"] as? String else {
            throw CloudError.server("Réponse de connexion inattendue.")
        }
        accessToken = access
        expiresAt = Date().addingTimeInterval((json["expires_in"] as? Double ?? 3600) - 60)
        let user = json["user"] as? [String: Any]
        userID = user?["id"] as? String
        email = user?["email"] as? String
        objectWillChange.send()
        Keychain.set(refresh, for: Self.refreshKey)
        lastError = nil
    }

    private func validToken() async throws -> String {
        if let accessToken, Date() < expiresAt, userID != nil { return accessToken }
        guard let refresh = Keychain.get(Self.refreshKey) else { throw CloudError.notSignedIn }
        do {
            let json = try await call("/auth/v1/token?grant_type=refresh_token", body: ["refresh_token": refresh], auth: false)
            try store(json)
        } catch {
            signOut()
            throw CloudError.server("Session expirée : reconnectez-vous avec Google ou Discord.")
        }
        return accessToken ?? ""
    }

    // MARK: - Profil

    @discardableResult
    func pull() async throws -> [String: Any] {
        guard isSignedIn else { return [:] }
        let token = try await validToken()
        guard let uid = userID,
              var comps = URLComponents(string: baseURL + "/rest/v1/user_settings") else { throw CloudError.notConfigured }
        comps.queryItems = [.init(name: "select", value: "data"), .init(name: "user_id", value: "eq.\(uid)")]
        var req = URLRequest(url: comps.url!, timeoutInterval: 15)
        req.setValue(apiKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp, data)
        let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        profile = rows.first?["data"] as? [String: Any] ?? [:]
        return profile
    }

    /// Fusionne `patch` dans les réglages du compte.
    func push(_ patch: [String: Any]) async {
        guard isSignedIn else { return }
        do {
            var current = try await pull()
            for (k, v) in patch { current[k] = v }
            let token = try await validToken()
            guard let uid = userID, let url = URL(string: baseURL + "/rest/v1/user_settings") else { return }
            var req = URLRequest(url: url, timeoutInterval: 15)
            req.httpMethod = "POST"
            req.setValue(apiKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
            let payload: [String: Any] = [
                "user_id": uid, "data": current, "updated_at": ISO8601DateFormatter().string(from: Date()),
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, resp) = try await URLSession.shared.data(for: req)
            try Self.check(resp, data)
            profile = current
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - IA partagée (fonction serveur jarvis-ai : tes clés restent sur le serveur)

    func aiChat(messages: [[String: String]], system: String) async throws -> String {
        guard isSignedIn else { throw CloudError.server("Connectez-vous à votre compte JARVIS pour discuter avec moi.") }
        let token = try await validToken()
        guard let url = URL(string: baseURL + "/functions/v1/jarvis-ai") else { throw CloudError.notConfigured }
        var req = URLRequest(url: url, timeoutInterval: 90)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = ["system": system, "messages": messages]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let reply = json["reply"] as? String, !reply.isEmpty else {
            throw CloudError.server(json["error"] as? String ?? "Le serveur JARVIS ne répond pas (code \(code)).")
        }
        return reply
    }

    /// Supprime définitivement le compte et toutes ses données (exigé par l'App Store et le RGPD).
    func deleteAccount() async throws {
        let token = try await validToken()
        guard let url = URL(string: baseURL + "/rest/v1/rpc/delete_my_account") else { throw CloudError.notConfigured }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp, data)
        signOut()
    }

    // MARK: - Connexion par code reçu par e-mail (v3.39)

    /// 1) pseudo + e-mail : le serveur envoie un code à 6 chiffres par e-mail.
    func requestCode(username: String, email: String) async throws {
        if let (code, data) = try? await raw("POST", "/rest/v1/rpc/jarvis_username_taken",
                                              body: ["p_username": username, "p_email": email], auth: false),
           code == 200, String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "true" {
            throw CloudError.server("Ce pseudo est déjà pris : choisissez-en un autre.")
        }
        _ = try await call("/auth/v1/otp", body: ["email": email, "create_user": true, "data": ["username": username]], auth: false)
    }

    /// 2) le code reçu : ouvre la session et enregistre le profil (pseudo). Renvoie l'identifiant et « bloqué ».
    func verifyCode(email: String, code: String, username: String) async throws -> (uid: String, blocked: Bool) {
        let json: [String: Any]
        do {
            json = try await call("/auth/v1/verify", body: ["type": "email", "email": email, "token": code], auth: false)
        } catch {
            throw CloudError.server("Code incorrect ou expiré : vérifiez-le, ou demandez un nouveau code.")
        }
        try store(json)
        let uid = userID ?? ""
        let row: [String: Any] = ["user_id": uid, "username": username, "email": email, "version": Release.version,
                                  "device": DeviceName.current, "last_seen": ISO8601DateFormatter().string(from: Date())]
        let (status, data) = try await raw("POST", "/rest/v1/profiles?on_conflict=user_id", body: row, auth: true,
                                           prefer: "resolution=merge-duplicates,return=representation")
        if status == 409 {
            signOut()
            throw CloudError.server("Ce pseudo est déjà pris : choisissez-en un autre.")
        }
        let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        let blocked = rows.first?["blocked"] as? Bool ?? false
        if blocked { signOut() }
        return (uid, blocked)
    }

    /// Administrateur (zelda) : tous les comptes.
    func adminAccounts() async throws -> [[String: Any]] {
        let (status, data) = try await raw("GET", "/rest/v1/profiles?select=user_id,username,email,version,device,created_at,last_seen,blocked&order=created_at.desc",
                                           body: nil, auth: true)
        guard status < 400 else { throw CloudError.server("Liste des comptes indisponible.") }
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
    }

    func adminSetBlocked(uid: String, blocked: Bool) async throws {
        let (status, _) = try await raw("PATCH", "/rest/v1/profiles?user_id=eq.\(uid)", body: ["blocked": blocked], auth: true)
        guard status < 400 else { throw CloudError.server("Modification impossible.") }
    }

    private func raw(_ method: String, _ path: String, body: [String: Any]?, auth: Bool, prefer: String? = nil) async throws -> (Int, Data) {
        guard isConfigured, let url = URL(string: baseURL + path) else { throw CloudError.notConfigured }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = method
        req.setValue(apiKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if auth {
            let token = try await validToken()
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let prefer { req.setValue(prefer, forHTTPHeaderField: "Prefer") }
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    // MARK: - HTTP

    private func call(_ path: String, body: [String: Any], auth: Bool) async throws -> [String: Any] {
        guard isConfigured, let url = URL(string: baseURL + path) else { throw CloudError.notConfigured }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp, data)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static func check(_ resp: URLResponse, _ data: Data) throws {
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code >= 400 else { return }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let msg = ((json["error_description"] ?? json["msg"] ?? json["message"] ?? json["error"]) as? String ?? "").lowercased()
        let errorCode = (json["error_code"] as? String ?? "").lowercased()
        // Messages traduits et neutres : l'utilisateur ne voit jamais le détail technique du serveur.
        switch errorCode {
        case "email_address_invalid": throw CloudError.server("Cette adresse e-mail est refusée. Vérifiez-la ou essayez-en une autre.")
        case "email_address_not_authorized":
            throw CloudError.server("Inscription bloquée : désactivez « Confirmer l'email » côté serveur (tutoriel, étape M1).")
        case "weak_password": throw CloudError.server("Mot de passe trop simple : mélangez lettres et chiffres (8 caractères ou plus).")
        case "signup_disabled", "email_provider_disabled":
            throw CloudError.server("Les inscriptions sont fermées côté serveur (activez « Autoriser les nouveaux utilisateurs »).")
        case "user_already_exists", "email_exists": throw CloudError.server("Un compte existe déjà avec cet e-mail : connectez-vous.")
        case "invalid_credentials": throw CloudError.server("E-mail ou mot de passe incorrect.")
        case "otp_expired": throw CloudError.server("Code incorrect ou expiré : demandez un nouveau code.")
        case "otp_disabled": throw CloudError.server("La connexion par code n'est pas encore activée sur le serveur.")
        case "email_not_confirmed": throw CloudError.server("Confirmez d'abord votre e-mail (lien reçu par e-mail).")
        case "over_email_send_rate_limit", "over_request_rate_limit":
            throw CloudError.server("Trop de tentatives : réessayez dans quelques minutes.")
        case "validation_failed": throw CloudError.server("E-mail ou mot de passe mal saisi. Vérifiez les deux champs.")
        default: break
        }
        if msg.contains("invalid login") { throw CloudError.server("E-mail ou mot de passe incorrect.") }
        if msg.contains("not confirmed") { throw CloudError.server("Confirmez d'abord votre e-mail (lien reçu par e-mail).") }
        if msg.contains("already registered") || msg.contains("already been registered") {
            throw CloudError.server("Un compte existe déjà avec cet e-mail : connectez-vous.")
        }
        if msg.contains("password") && msg.contains("character") {
            throw CloudError.server("Mot de passe trop court ou trop simple.")
        }
        if code == 429 || msg.contains("rate limit") { throw CloudError.server("Trop de tentatives : réessayez dans quelques minutes.") }
        let hint = errorCode.isEmpty ? "" : " — \(errorCode)"
        throw CloudError.server("Le serveur JARVIS a refusé la demande (code \(code)\(hint)).")
    }
}


/// Nom de l'appareil (pour la liste des comptes de l'administrateur).
enum DeviceName {
    static var current: String {
        #if os(iOS)
        return "iPhone · " + ProcessInfo.processInfo.hostName
        #else
        return (Host.current().localizedName ?? ProcessInfo.processInfo.hostName) + " · Mac"
        #endif
    }
}
