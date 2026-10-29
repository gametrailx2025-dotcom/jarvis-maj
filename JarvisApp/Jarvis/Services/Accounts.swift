import Foundation

/// Comptes JARVIS : obligatoires pour utiliser JARVIS.
/// - Compte JARVIS (v3.39) : pseudo + e-mail + pseudo Discord, vérifié par un code envoyé en MP par le bot Discord.
/// - Administrateur : pseudo « zelda » (gametrailx2025@gmail.com).
/// - À chaque nouvelle version, tout le monde se reconnecte.
/// - Compte Google : la vraie page Google « Accéder à l'application JARVIS » (dès que GoogleAuth.clientID est rempli).
struct JarvisAccount: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var email: String
    var provider: String          // "jarvis" ou "google"
    var picture: String?
    var created: Date
    var verified: Bool? = nil
    var version: String? = nil
    var uid: String? = nil
    var discord: String? = nil

    var isAdmin: Bool { verified == true && email.lowercased() == AdminAccount.email && name.lowercased() == AdminAccount.name }

    var initial: String { String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased() }
}

/// L'administrateur de JARVIS : il voit tous les comptes et peut en bloquer.
enum AdminAccount {
    static let email = "gametrailx2025@gmail.com"
    static let name = "zelda"
}

enum AccountError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        }
    }
}

@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var accounts: [JarvisAccount] = []
    @Published private(set) var currentID: String?

    private let listKey = "jarvisAccounts"
    private let currentKey = "jarvisCurrentAccount"
    private let defaults = UserDefaults.standard

    @Published private(set) var logoutReason: String?

    init() {
        if let data = defaults.data(forKey: listKey),
           let list = try? JSONDecoder().decode([JarvisAccount].self, from: data) {
            accounts = list
        }
        currentID = defaults.string(forKey: currentKey)
        if let cur = current, cur.verified != true || cur.version != Release.version {
            // nouvelle version (ou ancien compte non vérifié) : on se reconnecte avec un code
            logoutReason = cur.verified == true ? "Nouvelle version de JARVIS (\(Release.version)) : reconnectez-vous."
                : "Les comptes sont maintenant vérifiés par e-mail : reconnectez-vous."
            currentID = nil
            save()
        }
        if current == nil { currentID = nil }
    }

    /// Pseudo (3 à 20 caractères) et e-mail valides ; « zelda » réservé à l'administrateur.
    nonisolated static func cleanDiscord(_ d: String) throws -> String {
        let v = d.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "@")).lowercased()
        guard v.range(of: #"^[a-z0-9_.]{2,32}$"#, options: .regularExpression) != nil else {
            throw AccountError.message("Pseudo Discord invalide (celui de votre profil Discord, ex. nathan_92).")
        }
        return v
    }

    nonisolated static func clean(name: String, email: String) throws -> (String, String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard n.range(of: #"^[A-Za-z0-9_.\-]{3,20}$"#, options: .regularExpression) != nil else {
            throw AccountError.message("Pseudo : 3 à 20 caractères (lettres, chiffres, _ . -), sans espace.")
        }
        guard e.range(of: #"^[^@\s]+@[^@\s]+\.[a-z]{2,}$"#, options: .regularExpression) != nil else {
            throw AccountError.message("Adresse e-mail invalide.")
        }
        if n.lowercased() == AdminAccount.name && e != AdminAccount.email { throw AccountError.message("Ce pseudo est réservé.") }
        return (n, e)
    }

    /// Après la vérification du code : le compte devient le compte actif.
    func signIn(name: String, email: String, discord: String) {
        logoutReason = nil
        upsert(JarvisAccount(id: "jarvis:" + email, name: name, email: email, provider: "jarvis",
                             picture: nil, created: Date(), verified: true, version: Release.version, uid: nil, discord: discord))
    }

    var current: JarvisAccount? { accounts.first { $0.id == currentID } }
    var isSignedIn: Bool { current != nil }


    func signOut() {
        currentID = nil
        save()
    }

    /// Vraie connexion Google (page « Accéder à l'application JARVIS »).
    func signInWithGoogle() async throws {
        let profile = try await GoogleAuth.signIn()
        upsert(JarvisAccount(id: "google:" + profile.sub, name: profile.name, email: profile.email,
                             provider: "google", picture: profile.picture, created: Date()))
    }

    private func upsert(_ account: JarvisAccount) {
        if let i = accounts.firstIndex(where: { $0.id == account.id }) {
            var updated = account
            updated.created = accounts[i].created
            accounts[i] = updated
        } else {
            accounts.append(account)
        }
        currentID = account.id
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(accounts) { defaults.set(data, forKey: listKey) }
        defaults.set(currentID, forKey: currentKey)
        if let name = current?.name { defaults.set(name, forKey: SettingsKey.userName) }
    }
}

/// Connexion Google directe (OAuth + PKCE, sans serveur intermédiaire).
/// Remplis `clientID` avec l'« ID client iOS » de ton projet Google « JARVIS » (PROPRIETAIRE.md, section 2 bis).
enum GoogleAuth {
    static let clientID = ""      // ex. "1234567890-abcdefg.apps.googleusercontent.com"

    static var isAvailable: Bool { !clientID.isEmpty }

    struct Profile { let sub: String; let name: String; let email: String; let picture: String? }

    /// Schéma de retour imposé par Google pour les apps iPhone/Mac : l'ID client à l'envers.
    static var scheme: String {
        "com.googleusercontent.apps." + clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
    }

    @MainActor
    static func signIn() async throws -> Profile {
        guard isAvailable else { throw AccountError.message("La connexion Google n'est pas encore activée.") }
        let verifier = OAuthLogin.makeVerifier()
        let redirect = scheme + ":/oauth2redirect"
        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "code_challenge", value: OAuthLogin.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        let login = OAuthLogin()
        let callback: URL
        do {
            callback = try await login.start(comps.url!, scheme: scheme)
        } catch {
            throw AccountError.message("Connexion annulée.")
        }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw AccountError.message("Connexion Google refusée.")
        }
        // Échange du code contre un jeton
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = ["client_id": clientID, "code": code, "code_verifier": verifier,
                    "grant_type": "authorization_code", "redirect_uri": redirect]
        req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let tokenResult = try await URLSession.shared.data(for: req)
        let token = (try? JSONSerialization.jsonObject(with: tokenResult.0)) as? [String: Any] ?? [:]
        guard let access = token["access_token"] as? String else {
            throw AccountError.message("Connexion Google impossible. Réessayez.")
        }
        // Profil : nom, e-mail, photo
        var info = URLRequest(url: URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!)
        info.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        let infoResult = try await URLSession.shared.data(for: info)
        let user = (try? JSONSerialization.jsonObject(with: infoResult.0)) as? [String: Any] ?? [:]
        guard let sub = user["sub"] as? String else { throw AccountError.message("Profil Google illisible.") }
        let email = user["email"] as? String ?? ""
        let name = (user["given_name"] as? String) ?? (user["name"] as? String) ?? email
        return Profile(sub: sub, name: name, email: email, picture: user["picture"] as? String)
    }
}
