import CouncilMemory
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

    @Test func corruptKeyFileThrowsCorruptKeyNotMissingKey() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let keyFileURL = dir.appendingPathComponent("profile.key")

        let keyManager = ProfileKeyManager(
            service: "com.council.test.keyfile.\(UUID().uuidString)",
            wrappedKeyAccount: "wrapped-key-\(UUID().uuidString)",
            seKeyAccount: "se-key-\(UUID().uuidString)",
            keyFileURL: keyFileURL
        )
        defer { keyManager.deleteKeys() }

        let key = try await keyManager.generateKey()
        #expect(key.count == 32)

        // Regression: a truncated key file used to be reported as `missingKey`,
        // which lets the vault "recover" by generating a fresh key and silently
        // orphaning the existing profile. Corrupt must be distinct from missing.
        try Data(repeating: 0xFF, count: 31).write(to: keyFileURL)
        await #expect(throws: ProfileKeyManager.ProfileKeyError.corruptKey) {
            _ = try await keyManager.unwrapKey()
        }
    }

    @Test func secondGenerateKeyOverwritesStoredKey() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let keyFileURL = dir.appendingPathComponent("profile.key")

        let keyManager = ProfileKeyManager(
            service: "com.council.test.keyfile.\(UUID().uuidString)",
            wrappedKeyAccount: "wrapped-key-\(UUID().uuidString)",
            seKeyAccount: "se-key-\(UUID().uuidString)",
            keyFileURL: keyFileURL
        )
        defer { keyManager.deleteKeys() }

        // Pin: generateKey() has no "already exists" guard — a second call silently
        // replaces the stored key, orphaning anything encrypted under the first.
        let first = try await keyManager.generateKey()
        let second = try await keyManager.generateKey()
        #expect(first != second)
        #expect(try await keyManager.unwrapKey() == second)
    }
}
