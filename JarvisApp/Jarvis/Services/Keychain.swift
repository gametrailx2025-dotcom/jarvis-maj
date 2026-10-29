import Foundation
import Security

/// Stockage des secrets (jeton du PC, clés API) dans le trousseau Apple.
enum Keychain {
    static let pcToken = "pcToken"
    static let openrouterKey = "openrouterKey"
    static let anthropicKey = "anthropicKey"
    static let groqKey = "groqKey"
    private static let service = "jarvis.app"

    private static func baseQuery(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    static func set(_ value: String, for key: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        SecItemDelete(baseQuery(key) as CFDictionary)
        guard !trimmed.isEmpty else { return }
        var add = baseQuery(key)
        add[kSecValueData as String] = Data(trimmed.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        var q = baseQuery(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let s = String(data: data, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }
}
