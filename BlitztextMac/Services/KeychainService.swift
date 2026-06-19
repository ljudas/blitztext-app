import Foundation
import Security

enum KeychainKey: String, CaseIterable, Codable {
    case openAIAPIKey = "openAIAPIKey"
    case scalewayAPIKey = "scalewayAPIKey"
    case customAPIKey = "customAPIKey"

    var label: String {
        switch self {
        case .openAIAPIKey: return "OpenAI API Key"
        case .scalewayAPIKey: return "Scaleway API Key"
        case .customAPIKey: return "API Key (Eigener)"
        }
    }
}

/// Stores preview credentials in the user's macOS Keychain.
enum KeychainService {
    private static let service = "app.blitztext.preview.credentials"

    static func save(key: KeychainKey, value: String) throws {
        let data = Data(value.utf8)
        var query = baseQuery(for: key)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)

        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                baseQuery(for: key) as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw KeychainError.saveFailed(updateStatus)
            }
            return
        }

        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    static func load(key: KeychainKey) -> String? {
        var query = baseQuery(for: key)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }

        return value
    }

    static func delete(key: KeychainKey) {
        SecItemDelete(baseQuery(for: key) as CFDictionary)
    }

    /// Force the next `load` to re-read credentials.
    static func invalidateCache() {
        // Kept for call-site compatibility. Keychain reads do not use an in-memory cache.
    }

    static var isConfigured: Bool {
        load(key: .openAIAPIKey) != nil
    }

    static func key(for provider: APIProvider) -> KeychainKey {
        switch provider {
        case .openai: return .openAIAPIKey
        case .scaleway: return .scalewayAPIKey
        case .custom: return .customAPIKey
        }
    }

    static func hasKey(for provider: APIProvider) -> Bool {
        load(key: key(for: provider)) != nil
    }

    private static func baseQuery(for key: KeychainKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
    }
}

enum KeychainError: LocalizedError {
    case saveFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "Zugangsdaten konnten nicht im macOS Keychain gespeichert werden. Status: \(status)"
        }
    }
}
