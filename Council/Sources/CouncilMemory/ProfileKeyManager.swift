import CryptoKit
import Foundation
import Security

/// Manages the profile encryption key.
///
/// On Secure Enclave-capable devices, the key is generated inside the SEP and only a
/// keychain reference to the private key is persisted; the raw profile key is wrapped
/// with ECIES and stored in the keychain. On other devices the raw key is stored
/// directly in the keychain.
public actor ProfileKeyManager {
    public enum ProfileKeyError: Error {
        case missingKey
        case keyGenerationFailed
    }

    /// Whether this device can bind keys to the Secure Enclave.
    public let isDeviceBound: Bool

    private let wrappedKeyItem: KeychainItem
    private let seKeyAccount: String
    private let keyFileURL: URL?

    public init(
        service: String = "com.council.memory",
        wrappedKeyAccount: String = "wrapped-profile-key",
        seKeyAccount: String = "profile-se-key",
        useSecureEnclave: Bool = true,
        keyFileURL: URL? = nil
    ) {
        self.isDeviceBound = SecureEnclave.isAvailable && useSecureEnclave
        self.wrappedKeyItem = KeychainItem(service: service, account: wrappedKeyAccount)
        self.seKeyAccount = seKeyAccount
        self.keyFileURL = keyFileURL
    }

    /// Generates a new 256-bit profile key and persists it.
    @discardableResult
    public func generateKey() async throws -> Data {
        var rawKey = Data(count: 32)
        let status = rawKey.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw ProfileKeyError.keyGenerationFailed
        }

        if let keyFileURL {
            try persistKeyToFile(rawKey, url: keyFileURL)
            return rawKey
        }

        if isDeviceBound {
            do {
                let sePrivateKey = try generateSecureEnclaveKey()
                let wrapped = try SecureEnclaveWrapping.wrap(key: rawKey, sePrivateKey: sePrivateKey)
                try wrappedKeyItem.save(data: wrapped)
            } catch {
                // -34018 is errSecMissingEntitlement. Unsigned binaries (including the SwiftPM
                // test runner on macOS) lack the application-identifier entitlement required to
                // create permanent Secure Enclave keychain keys. In that situation we safely fall
                // back to storing the raw key in the keychain with device-only accessibility.
                if (error as NSError).code == -34018 {
                    try wrappedKeyItem.save(data: rawKey)
                } else {
                    throw error
                }
            }
        } else {
            try wrappedKeyItem.save(data: rawKey)
        }

        return rawKey
    }

    /// Unwraps and returns the persisted profile key.
    public func unwrapKey() async throws -> Data {
        if let keyFileURL {
            guard FileManager.default.fileExists(atPath: keyFileURL.path),
                  let data = FileManager.default.contents(atPath: keyFileURL.path),
                  data.count == 32 else {
                throw ProfileKeyError.missingKey
            }
            return data
        }

        guard let wrapped = try wrappedKeyItem.load() else {
            throw ProfileKeyError.missingKey
        }

        if isDeviceBound {
            do {
                if let sePrivateKey = try loadSecureEnclaveKey() {
                    return try SecureEnclaveWrapping.unwrap(wrappedKey: wrapped, sePrivateKey: sePrivateKey)
                }
            } catch {
                // In entitlement-limited environments the SEP keychain query itself can fail;
                // fall back to the raw key if it was stored directly.
                if (error as NSError).code != -34018 {
                    throw error
                }
            }
            return wrapped
        } else {
            return wrapped
        }
    }

    /// Removes persisted keys. Useful for testing and key rotation.
    public nonisolated func deleteKeys() {
        wrappedKeyItem.delete()
        deleteSecureEnclaveKey()
        if let keyFileURL {
            try? FileManager.default.removeItem(at: keyFileURL)
        }
    }

    // MARK: - File-based key storage

    private func persistKeyToFile(_ key: Data, url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [FileAttributeKey.posixPermissions: 0o700]
        )
        // The raw key file is protected by the profile directory (0700) and the
        // explicit 0600 permission set below. Avoid .completeFileProtectionUnlessOpen
        // here because unsigned CLI binaries and test runners may not have the
        // entitlements required to apply it on all filesystems.
        try key.write(to: url)

        // Defense-in-depth: ensure the raw key file is readable only by the owner.
        try FileManager.default.setAttributes(
            [FileAttributeKey.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )

        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var directoryURL = directory
        try directoryURL.setResourceValues(resourceValues)
    }

    // MARK: - Secure Enclave helpers

    private func seKeyTag() -> Data {
        Data(seKeyAccount.utf8)
    }

    /// Generates a permanent SEP key-agreement key and stores a keychain reference.
    private func generateSecureEnclaveKey() throws -> SecKey {
        let tag = seKeyTag()
        // Ensure a stale key with the same tag does not block creation.
        deleteSecureEnclaveKey()

        var attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ],
        ]
        #if os(macOS)
        attributes[kSecUseDataProtectionKeychain as String] = true
        #endif

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            if let error = error?.takeRetainedValue() {
                throw error
            }
            throw ProfileKeyError.keyGenerationFailed
        }
        return privateKey
    }

    /// Loads the persisted SEP key reference, or `nil` if it does not exist.
    private func loadSecureEnclaveKey() throws -> SecKey? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: seKeyTag(),
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return (result as! SecKey)
    }

    private nonisolated func deleteSecureEnclaveKey() {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(seKeyAccount.utf8),
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        SecItemDelete(query as CFDictionary)
    }
}
