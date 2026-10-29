import Foundation

/// Configuration centrale de TON projet JARVIS — à remplir UNE SEULE FOIS par toi (le propriétaire).
/// Tes utilisateurs n'ont rien à saisir : ils créent seulement leur compte (e-mail + mot de passe).
///
/// Supabase › Project Settings › API Keys :
///   - supabaseURL            : https://xxxx.supabase.co
///   - supabasePublishableKey : sb_publishable_…   (clé PUBLIQUE : faite pour être dans une app)
///
/// ⚠️ Ne mets JAMAIS ici la clé sb_secret_…, ni tes clés OpenRouter / Groq :
///    celles-ci vont dans les secrets de la fonction serveur « jarvis-ai » (voir TUTORIEL.md).
enum AppConfig {
    static let supabaseURL = decode("aHR0cHM6Ly9qZG9waWtsanh1dXFxdWxkdXh3bS5zdXBhYmFzZS5jbw==")
    static let supabasePublishableKey = decode("c2JfcHVibGlzaGFibGVfRXhqQU9UNzhRSURfZktxendYb0JTUV9VQzVHMnRtUw==")

    private static func decode(_ b64: String) -> String {
        Data(base64Encoded: b64).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// Vrai quand le serveur central est intégré : les champs techniques disparaissent des Réglages.
    static var hasBuiltInServer: Bool { !supabaseURL.isEmpty && !supabasePublishableKey.isEmpty }
}
