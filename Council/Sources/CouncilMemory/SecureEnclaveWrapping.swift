import CryptoKit
import Foundation
import Security

/// ECIES wrap/unwrap using a Secure Enclave `SecKey` key-agreement key.
///
/// The Secure Enclave private key never leaves the SEP; only a keychain
/// reference to it is persisted. On wrap, an ephemeral P-256 key agrees with
/// the SEP public key; HKDF-SHA256 derives an AES-256-GCM key used to encrypt
/// the profile key. The wrapped blob format is
/// `ephemeralPublicKey.x963 || nonce || tag || ciphertext`.
enum SecureEnclaveWrapping {
    enum WrappingError: Error {
        case invalidWrappedKey
        case keyExchangeFailed
        case publicKeyExportFailed
        case invalidPublicKeyData
        case ephemeralKeyGenerationFailed
    }

    static let info = Data("com.council.profile.wrap.v1".utf8)

    static func wrap(key: Data, sePrivateKey: SecKey) throws -> Data {
        guard let sePublicKey = SecKeyCopyPublicKey(sePrivateKey) else {
            throw WrappingError.publicKeyExportFailed
        }

        let ephemeralPrivateKey = try makeEphemeralPrivateKey()
        guard let ephemeralPublicKey = SecKeyCopyPublicKey(ephemeralPrivateKey) else {
            throw WrappingError.publicKeyExportFailed
        }
        guard let ephemeralPublicKeyData = SecKeyCopyExternalRepresentation(ephemeralPublicKey, nil) else {
            throw WrappingError.publicKeyExportFailed
        }

        let sharedSecret = try sharedSecret(privateKey: ephemeralPrivateKey, publicKey: sePublicKey)
        let symmetricKey = deriveKey(sharedSecret: sharedSecret)

        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(key, using: symmetricKey, nonce: nonce)

        var output = Data()
        output.append(contentsOf: ephemeralPublicKeyData as Data)
        output.append(contentsOf: nonce)
        output.append(contentsOf: sealed.tag)
        output.append(contentsOf: sealed.ciphertext)
        return output
    }

    static func unwrap(wrappedKey: Data, sePrivateKey: SecKey) throws -> Data {
        guard let sePublicKey = SecKeyCopyPublicKey(sePrivateKey),
              let sePublicKeyData = SecKeyCopyExternalRepresentation(sePublicKey, nil) else {
            throw WrappingError.publicKeyExportFailed
        }
        let publicKeySize = (sePublicKeyData as Data).count
        let nonceSize = 12
        let tagSize = 16

        guard wrappedKey.count > publicKeySize + nonceSize + tagSize else {
            throw WrappingError.invalidWrappedKey
        }

        let ephemeralPublicKeyData = wrappedKey.prefix(publicKeySize)
        let nonceData = wrappedKey.dropFirst(publicKeySize).prefix(nonceSize)
        let tagData = wrappedKey.dropFirst(publicKeySize + nonceSize).prefix(tagSize)
        let cipherData = wrappedKey.dropFirst(publicKeySize + nonceSize + tagSize)

        let ephemeralPublicKey = try makePublicKey(from: ephemeralPublicKeyData)
        let sharedSecret = try sharedSecret(privateKey: sePrivateKey, publicKey: ephemeralPublicKey)
        let symmetricKey = deriveKey(sharedSecret: sharedSecret)

        let nonce = try AES.GCM.Nonce(data: nonceData)
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: cipherData, tag: tagData)
        return try AES.GCM.open(sealedBox, using: symmetricKey)
    }

    // MARK: - Private helpers

    private static func makeEphemeralPrivateKey() throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            if let error = error?.takeRetainedValue() {
                throw error
            }
            throw WrappingError.ephemeralKeyGenerationFailed
        }
        return privateKey
    }

    private static func makePublicKey(from representation: Data) throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 256,
        ]
        var error: Unmanaged<CFError>?
        guard let publicKey = SecKeyCreateWithData(representation as CFData, attributes as CFDictionary, &error) else {
            if let error = error?.takeRetainedValue() {
                throw error
            }
            throw WrappingError.invalidPublicKeyData
        }
        return publicKey
    }

    private static func sharedSecret(privateKey: SecKey, publicKey: SecKey) throws -> Data {
        let algorithm = SecKeyAlgorithm.ecdhKeyExchangeStandard
        let params: [SecKeyKeyExchangeParameter: Any] = [
            .requestedSize: 32,
        ]
        var error: Unmanaged<CFError>?
        guard let sharedSecret = SecKeyCopyKeyExchangeResult(
            privateKey,
            algorithm,
            publicKey,
            params as CFDictionary,
            &error
        ) else {
            if let error = error?.takeRetainedValue() {
                throw error
            }
            throw WrappingError.keyExchangeFailed
        }
        return sharedSecret as Data
    }

    private static func deriveKey(sharedSecret: Data) -> SymmetricKey {
        let inputKey = SymmetricKey(data: sharedSecret)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: Data(),
            info: info,
            outputByteCount: 32
        )
    }
}
