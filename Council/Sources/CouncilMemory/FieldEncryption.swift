import CryptoKit
import Foundation

/// AES-256-GCM field encryption helpers.
///
/// Nonce (12 bytes) is prepended to the ciphertext, followed by the tag (16 bytes).
enum FieldEncryption {
    enum FieldEncryptionError: Error {
        case invalidCiphertext
    }

    /// Encrypts plaintext with AES-256-GCM.
    /// - Returns: `nonce || ciphertext || tag`.
    static func encrypt(plaintext: Data, key: Data) throws -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: symmetricKey, nonce: nonce)
        var output = Data()
        output.append(contentsOf: nonce)
        output.append(contentsOf: sealed.ciphertext)
        output.append(contentsOf: sealed.tag)
        return output
    }

    /// Decrypts a ciphertext produced by `encrypt(plaintext:key:)`.
    static func decrypt(ciphertext: Data, key: Data) throws -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let nonceSize = 12
        let tagSize = 16
        guard ciphertext.count >= nonceSize + tagSize else {
            throw FieldEncryptionError.invalidCiphertext
        }
        let nonceData = ciphertext.prefix(nonceSize)
        let tagData = ciphertext.suffix(tagSize)
        let cipherData = ciphertext.dropFirst(nonceSize).dropLast(tagSize)
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: cipherData, tag: tagData)
        return try AES.GCM.open(sealedBox, using: symmetricKey)
    }
}
