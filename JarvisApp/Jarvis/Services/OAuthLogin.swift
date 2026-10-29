import AuthenticationServices
import CryptoKit
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Connexion « Se connecter avec Google / Discord » (OAuth + PKCE), dans une fenêtre sécurisée du système.
@MainActor
final class OAuthLogin: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let callbackScheme = "jarvis"
    static let redirect = "jarvis://auth-callback"
    private var session: ASWebAuthenticationSession?

    /// Ouvre la page du fournisseur et renvoie l'adresse de retour (contenant le code d'autorisation).
    func start(_ url: URL, scheme: String = OAuthLogin.callbackScheme) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let s = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
                if let callback {
                    cont.resume(returning: callback)
                } else {
                    cont.resume(throwing: error ?? URLError(.userCancelledAuthentication))
                }
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false
            session = s
            if !s.start() { cont.resume(throwing: URLError(.cannotLoadFromNetwork)) }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(macOS)
            return NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow()
            #else
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first ?? UIWindow()
            #endif
        }
    }

    // MARK: - PKCE

    static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
