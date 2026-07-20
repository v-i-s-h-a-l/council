@testable import CouncilMemory
import Foundation
import Security
import Testing

/// Malformed-input tests for the ECIES wrap/unwrap used to bind the profile key to
/// a P-256 key-agreement key. Plain software P-256 keys work outside the Secure
/// Enclave, so the full round trip is exercisable in the test runner.
///
/// The wrapped blob layout is
/// `ephemeralPublicKey.x963 (65) || nonce (12) || tag (16) || ciphertext`.
struct SecureEnclaveWrappingAdversarialTests {
    private func makePrivateKey() throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error!.takeRetainedValue()
        }
        return key
    }

    @Test func wrapUnwrapRoundTrip() throws {
        let privateKey = try makePrivateKey()
        let profileKey = Data(repeating: 0x33, count: 32)

        let wrapped = try SecureEnclaveWrapping.wrap(key: profileKey, sePrivateKey: privateKey)
        // 65-byte ephemeral pubkey + 12-byte nonce + 16-byte tag + 32-byte ciphertext.
        #expect(wrapped.count == 125)

        let unwrapped = try SecureEnclaveWrapping.unwrap(wrappedKey: wrapped, sePrivateKey: privateKey)
        #expect(unwrapped == profileKey)
    }

    @Test func unwrapRejectsBlobTruncatedInsidePubkeyPrefix() throws {
        let privateKey = try makePrivateKey()
        let wrapped = try SecureEnclaveWrapping.wrap(
            key: Data(repeating: 0x33, count: 32),
            sePrivateKey: privateKey
        )

        // 40 bytes: the blob does not even cover the ephemeral public key.
        #expect(throws: SecureEnclaveWrapping.WrappingError.invalidWrappedKey) {
            _ = try SecureEnclaveWrapping.unwrap(
                wrappedKey: Data(wrapped.prefix(40)),
                sePrivateKey: privateKey
            )
        }
    }

    @Test func unwrapRejectsBlobWithEmptyCiphertext() throws {
        let privateKey = try makePrivateKey()
        let wrapped = try SecureEnclaveWrapping.wrap(
            key: Data(repeating: 0x33, count: 32),
            sePrivateKey: privateKey
        )

        // Exactly pubkey + nonce + tag (93 bytes): no ciphertext at all, rejected
        // by the strict `>` size check.
        #expect(throws: SecureEnclaveWrapping.WrappingError.invalidWrappedKey) {
            _ = try SecureEnclaveWrapping.unwrap(
                wrappedKey: Data(wrapped.prefix(93)),
                sePrivateKey: privateKey
            )
        }
    }

    @Test func unwrapRejectsCorruptedEphemeralPublicKey() throws {
        let privateKey = try makePrivateKey()
        var wrapped = try SecureEnclaveWrapping.wrap(
            key: Data(repeating: 0x33, count: 32),
            sePrivateKey: privateKey
        )

        // Flip a byte inside the 65-byte ephemeral public key prefix. Whether the
        // key import itself fails or the shared secret simply comes out wrong,
        // unwrap must throw — never return wrong key material.
        wrapped[10] ^= 0xFF
        #expect(throws: (any Error).self) {
            _ = try SecureEnclaveWrapping.unwrap(wrappedKey: wrapped, sePrivateKey: privateKey)
        }
    }

    @Test func unwrapRejectsCorruptedTag() throws {
        let privateKey = try makePrivateKey()
        var wrapped = try SecureEnclaveWrapping.wrap(
            key: Data(repeating: 0x33, count: 32),
            sePrivateKey: privateKey
        )

        // Flip a byte inside the tag region (bytes 77..<93).
        wrapped[80] ^= 0x01
        #expect(throws: (any Error).self) {
            _ = try SecureEnclaveWrapping.unwrap(wrappedKey: wrapped, sePrivateKey: privateKey)
        }
    }
}
