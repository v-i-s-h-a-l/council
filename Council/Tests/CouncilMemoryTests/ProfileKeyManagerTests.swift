import CouncilMemory
import CryptoKit
import Foundation
import Testing

struct ProfileKeyManagerTests {
    private func makeKeyManager() -> ProfileKeyManager {
        ProfileKeyManager(
            service: "com.council.test.keymanager.\(UUID().uuidString)",
            wrappedKeyAccount: "wrapped-key-\(UUID().uuidString)",
            seKeyAccount: "se-key-\(UUID().uuidString)"
        )
    }

    @Test func generatesAndUnwrapsKey() async throws {
        let keyManager = makeKeyManager()
        defer { keyManager.deleteKeys() }

        let key = try await keyManager.generateKey()
        #expect(key.count == 32)

        let unwrapped = try await keyManager.unwrapKey()
        #expect(unwrapped == key)
    }

    @Test func unwrapWithoutKeyThrowsMissingKey() async throws {
        let keyManager = makeKeyManager()
        defer { keyManager.deleteKeys() }

        await #expect(throws: ProfileKeyManager.ProfileKeyError.missingKey) {
            _ = try await keyManager.unwrapKey()
        }
    }

    @Test func reportedDeviceBindingMatchesSecureEnclaveAvailability() async throws {
        let keyManager = makeKeyManager()
        defer { keyManager.deleteKeys() }

        let isDeviceBound = await keyManager.isDeviceBound
        #expect(isDeviceBound == SecureEnclave.isAvailable)
    }

    @Test func sepWrapsAndUnwrapsIfAvailable() async throws {
        let keyManager = makeKeyManager()
        defer { keyManager.deleteKeys() }

        let key = try await keyManager.generateKey()
        let isDeviceBound = await keyManager.isDeviceBound

        if isDeviceBound {
            let unwrapped = try await keyManager.unwrapKey()
            #expect(unwrapped == key)
        } else {
            try await #expect(keyManager.unwrapKey() == key)
        }
    }
}
