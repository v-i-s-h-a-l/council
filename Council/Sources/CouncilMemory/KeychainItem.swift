import Foundation
import Security

/// Keychain read/write wrapper for a generic password item.
///
/// On macOS the data-protection keychain is preferred, but operations transparently fall back
/// to the legacy file-based keychain when the binary lacks the required entitlements (e.g., the
/// SwiftPM test runner).
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

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif

        let status = SecItemAdd(query as CFDictionary, nil)
        #if os(macOS)
        if status == errSecMissingEntitlement {
            var fallbackQuery = query
            fallbackQuery.removeValue(forKey: kSecUseDataProtectionKeychain as String)
            let fallbackStatus = SecItemAdd(fallbackQuery as CFDictionary, nil)
            guard fallbackStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(fallbackStatus)
            }
            return
        }
        #endif

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Loads data from the keychain, or `nil` if the item does not exist.
    func load() throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        #if os(macOS)
        if status == errSecItemNotFound || status == errSecMissingEntitlement {
            var fallbackQuery = query
            fallbackQuery.removeValue(forKey: kSecUseDataProtectionKeychain as String)
            var fallbackResult: CFTypeRef?
            let fallbackStatus = SecItemCopyMatching(fallbackQuery as CFDictionary, &fallbackResult)
            if fallbackStatus == errSecItemNotFound {
                return nil
            }
            guard fallbackStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(fallbackStatus)
            }
            guard let data = fallbackResult as? Data else {
                throw KeychainError.invalidResult
            }
            return data
        }
        #endif

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
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        SecItemDelete(query as CFDictionary)
        query.removeValue(forKey: kSecUseDataProtectionKeychain as String)
        #endif
        SecItemDelete(query as CFDictionary)
    }
}
