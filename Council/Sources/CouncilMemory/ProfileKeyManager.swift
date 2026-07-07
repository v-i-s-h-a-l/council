import CryptoKit
import Foundation
import Security

/// Manages the profile encryption key.
///
/// On Secure Enclave-capable devices, the key is generated inside the SEP and the raw
/// profile key is wrapped with ECIES. On other devices the raw key is stored directly
/// in the keychain.
public actor ProfileKeyManager {
    public enum ProfileKeyError: Error {
        case missingKey
        case keyGenerationFailed
    }

    /// Whether this device can bind keys to the Secure Enclave.
    public let isDeviceBound: Bool

    private let wrappedKeyItem: KeychainItem
    private let seKeyItem: KeychainItem

    public init(
        service: String = "com.council.memory",
        wrappedKeyAccount: String = "wrapped-profile-key",
        seKeyAccount: String = "profile-se-key"
    ) {
        self.isDeviceBound = SecureEnclave.isAvailable
        self.wrappedKeyItem = KeychainItem(service: service, account: wrappedKeyAccount)
        self.seKeyItem = KeychainItem(service: service, account: seKeyAccount)
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

        if SecureEnclave.isAvailable {
            let sePrivateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey()
            let wrapped = try SecureEnclaveWrapping.wrap(key: rawKey, publicKey: sePrivateKey.publicKey)
            try wrappedKeyItem.save(data: wrapped)
            try seKeyItem.save(data: sePrivateKey.dataRepresentation)
        } else {
            try wrappedKeyItem.save(data: rawKey)
        }

        return rawKey
    }

    /// Unwraps and returns the persisted profile key.
    public func unwrapKey() async throws -> Data {
        guard let wrapped = try wrappedKeyItem.load() else {
            throw ProfileKeyError.missingKey
        }

        if SecureEnclave.isAvailable {
            guard let seKeyData = try seKeyItem.load() else {
                throw ProfileKeyError.missingKey
            }
            let sePrivateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: seKeyData)
            return try SecureEnclaveWrapping.unwrap(wrappedKey: wrapped, privateKey: sePrivateKey)
        } else {
            return wrapped
        }
    }

    /// Removes persisted keys. Useful for testing and key rotation.
    public nonisolated func deleteKeys() {
        wrappedKeyItem.delete()
        seKeyItem.delete()
    }
}
