import CryptoKit
import Foundation

/// ECIES wrap/unwrap using a `SecureEnclave.P256.KeyAgreement.PrivateKey`.
///
/// On wrap, an ephemeral P-256 key agrees with the Secure Enclave public key;
/// HKDF-SHA256 derives an AES-256-GCM key used to encrypt the profile key.
/// The wrapped blob format is `ephemeralPublicKey.x963 || nonce || tag || ciphertext`.
enum SecureEnclaveWrapping {
    enum WrappingError: Error {
        case invalidWrappedKey
    }

    static let sharedInfo = Data("com.council.sewrap.v1".utf8)

    static func wrap(key: Data, publicKey: P256.KeyAgreement.PublicKey) throws -> Data {
        let ephemeralPrivateKey = P256.KeyAgreement.PrivateKey()
        let ephemeralPublicKey = ephemeralPrivateKey.publicKey

        let sharedSecret = try ephemeralPrivateKey.sharedSecretFromKeyAgreement(with: publicKey)
        let symmetricKey = sharedSecret.x963DerivedSymmetricKey(
            using: SHA256.self,
            sharedInfo: sharedInfo,
            outputByteCount: 32
        )

        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(key, using: symmetricKey, nonce: nonce)

        var output = Data()
        output.append(contentsOf: ephemeralPublicKey.x963Representation)
        output.append(contentsOf: nonce)
        output.append(contentsOf: sealed.tag)
        output.append(contentsOf: sealed.ciphertext)
        return output
    }

    static func unwrap(
        wrappedKey: Data,
        privateKey: SecureEnclave.P256.KeyAgreement.PrivateKey
    ) throws -> Data {
        let publicKey = privateKey.publicKey
        let publicKeySize = publicKey.x963Representation.count
        let nonceSize = 12
        let tagSize = 16

        guard wrappedKey.count > publicKeySize + nonceSize + tagSize else {
            throw WrappingError.invalidWrappedKey
        }

        let ephemeralPublicKeyData = wrappedKey.prefix(publicKeySize)
        let nonceData = wrappedKey.dropFirst(publicKeySize).prefix(nonceSize)
        let tagData = wrappedKey.dropFirst(publicKeySize + nonceSize).prefix(tagSize)
        let cipherData = wrappedKey.dropFirst(publicKeySize + nonceSize + tagSize)

        let ephemeralPublicKey = try P256.KeyAgreement.PublicKey(x963Representation: ephemeralPublicKeyData)
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: ephemeralPublicKey)
        let symmetricKey = sharedSecret.x963DerivedSymmetricKey(
            using: SHA256.self,
            sharedInfo: sharedInfo,
            outputByteCount: 32
        )

        let nonce = try AES.GCM.Nonce(data: nonceData)
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: cipherData, tag: tagData)
        return try AES.GCM.open(sealedBox, using: symmetricKey)
    }
}
