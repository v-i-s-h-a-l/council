import Foundation
import Security

/// Keychain read/write wrapper for a generic password item.
struct KeychainItem: Sendable {
    enum KeychainError: Error {
        case itemNotFound
        case unexpectedStatus(OSStatus)
        case invalidResult
    }

    let service: String
    let account: String

    init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    /// Saves `data` to the keychain, replacing any existing item.
    func save(data: Data) throws {
        delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Loads data from the keychain, or `nil` if the item does not exist.
    func load() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let data = result as? Data else {
            throw KeychainError.invalidResult
        }
        return data
    }

    /// Deletes the keychain item if it exists.
    func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
