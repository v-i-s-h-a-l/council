@testable import CouncilMemory
import Foundation
import Testing

/// Boundary and tamper tests for the AES-256-GCM field encryption helpers.
/// The blob layout is `nonce (12) || ciphertext || tag (16)`.
struct FieldEncryptionAdversarialTests {
    private let key = Data(repeating: 0x11, count: 32)

    @Test func decryptRejectsShorterThanNoncePlusTag() throws {
        // 27 bytes is below the 12-byte nonce + 16-byte tag minimum.
        #expect(throws: FieldEncryption.FieldEncryptionError.invalidCiphertext) {
            _ = try FieldEncryption.decrypt(ciphertext: Data(repeating: 0x42, count: 27), key: key)
        }
    }

    @Test func emptyPlaintextRoundTripsAtMinimumSize() throws {
        let blob = try FieldEncryption.encrypt(plaintext: Data(), key: key)
        // Exactly nonce + tag: the smallest valid ciphertext.
        #expect(blob.count == 28)
        let opened = try FieldEncryption.decrypt(ciphertext: blob, key: key)
        #expect(opened.isEmpty)
    }

    @Test func flippedTagByteFailsAuthentication() throws {
        var blob = try FieldEncryption.encrypt(plaintext: Data("hello".utf8), key: key)
        blob[blob.count - 1] ^= 0x01
        #expect(throws: (any Error).self) {
            _ = try FieldEncryption.decrypt(ciphertext: blob, key: key)
        }
    }

    @Test func decryptWithWrongKeyThrows() throws {
        let blob = try FieldEncryption.encrypt(plaintext: Data("hello".utf8), key: key)
        let otherKey = Data(repeating: 0x22, count: 32)
        #expect(throws: (any Error).self) {
            _ = try FieldEncryption.decrypt(ciphertext: blob, key: otherKey)
        }
    }
}
