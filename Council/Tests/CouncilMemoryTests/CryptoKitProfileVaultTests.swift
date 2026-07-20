import CouncilCore
@testable import CouncilMemory
import Foundation
import Testing

struct CryptoKitProfileVaultTests {
    private func makeVault() throws -> (vault: CryptoKitProfileVault, fileURL: URL, keyManager: ProfileKeyManager) {
        let keyManager = ProfileKeyManager(
            service: "com.council.test.vault.\(UUID().uuidString)",
            wrappedKeyAccount: "wrapped-key-\(UUID().uuidString)",
            seKeyAccount: "se-key-\(UUID().uuidString)"
        )
        let fileManager = FileManager()
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let testDir = appSupport.appendingPathComponent("CouncilVaultTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = testDir.appendingPathComponent("vault.enc")
        try fileManager.createDirectory(at: testDir, withIntermediateDirectories: true)
        let vault = CryptoKitProfileVault(keyManager: keyManager, fileURL: fileURL, fileManager: fileManager, writingOptions: [])
        return (vault, fileURL, keyManager)
    }

    private func cleanup(fileURL: URL, keyManager: ProfileKeyManager) {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        keyManager.deleteKeys()
    }

    @Test func roundTripSaveAndLoad() async throws {
        let (vault, fileURL, keyManager) = try makeVault()
        defer { cleanup(fileURL: fileURL, keyManager: keyManager) }

        let profile = UserProfile(
            values: [ValueStatement(text: "Frugality")],
            goals: [Goal(text: "Save for travel")],
            boundaries: [Boundary(text: "No impulse buys")],
            financialHistory: ClientConfidentialContainer(items: ["salary: 100000"]),
            journalEntries: [JournalEntry(text: "private dream")]
        )

        try await vault.save(profile)
        let loaded = try await vault.load()

        #expect(loaded.values.map(\.text) == ["Frugality"])
        #expect(loaded.goals.map(\.text) == ["Save for travel"])
        #expect(loaded.boundaries.map(\.text) == ["No impulse buys"])
        #expect(loaded.financialHistory.items == ["salary: 100000"])
        #expect(loaded.journalEntries.map(\.text) == ["private dream"])
    }

    @Test func missingVaultReturnsEmptyProfile() async throws {
        let (vault, fileURL, keyManager) = try makeVault()
        defer { cleanup(fileURL: fileURL, keyManager: keyManager) }

        let loaded = try await vault.load()
        #expect(loaded.values.isEmpty)
        #expect(loaded.goals.isEmpty)
        #expect(loaded.boundaries.isEmpty)
        #expect(loaded.financialHistory.items.isEmpty)
        #expect(loaded.journalEntries.isEmpty)
    }

    @Test func exportAndReplaceEncryptedBlob() async throws {
        let (vault, fileURL, keyManager) = try makeVault()
        defer { cleanup(fileURL: fileURL, keyManager: keyManager) }

        let profile = UserProfile(
            values: [ValueStatement(text: "Health")],
            goals: [Goal(text: "Exercise daily")]
        )
        try await vault.save(profile)

        let blob = try await vault.exportEncryptedBlob()
        #expect(!blob.isEmpty)

        // Create a second vault file that uses the same key manager so the blob can be decrypted.
        let fileManager = FileManager()
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let newTestDir = appSupport.appendingPathComponent("CouncilVaultTests-\(UUID().uuidString)", isDirectory: true)
        let newFileURL = newTestDir.appendingPathComponent("vault.enc")
        try fileManager.createDirectory(at: newTestDir, withIntermediateDirectories: true)
        let newVault = CryptoKitProfileVault(keyManager: keyManager, fileURL: newFileURL, fileManager: fileManager, writingOptions: [])
        defer { cleanup(fileURL: newFileURL, keyManager: keyManager) }

        try await newVault.replaceFromEncryptedBlob(blob)
        let loaded = try await newVault.load()
        #expect(loaded.values.map(\.text) == ["Health"])
        #expect(loaded.goals.map(\.text) == ["Exercise daily"])
    }

    @Test func corruptKeyFileThrowsInsteadOfSilentlyRekeying() async throws {
        let fileManager = FileManager()
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let testDir = appSupport.appendingPathComponent("CouncilVaultTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let keyFileURL = testDir.appendingPathComponent("profile.key")
        let keyManager = ProfileKeyManager(
            service: "com.council.test.vault.\(UUID().uuidString)",
            wrappedKeyAccount: "wrapped-key-\(UUID().uuidString)",
            seKeyAccount: "se-key-\(UUID().uuidString)",
            keyFileURL: keyFileURL
        )
        defer { keyManager.deleteKeys() }
        let fileURL = testDir.appendingPathComponent("vault.enc")
        let vault = CryptoKitProfileVault(keyManager: keyManager, fileURL: fileURL, fileManager: fileManager, writingOptions: [])

        try await vault.save(UserProfile(values: [ValueStatement(text: "Frugality")]))
        let originalKey = try Data(contentsOf: keyFileURL)
        #expect(originalKey.count == 32)

        // Corrupt the key file: the vault must refuse to save rather than silently
        // generating a fresh key and orphaning the existing profile.
        try Data(repeating: 0xFF, count: 31).write(to: keyFileURL)
        await #expect(throws: ProfileKeyManager.ProfileKeyError.corruptKey) {
            try await vault.save(UserProfile(values: [ValueStatement(text: "Replacement")]))
        }

        // With the original key restored, the original profile is still intact.
        try originalKey.write(to: keyFileURL)
        let loaded = try await vault.load()
        #expect(loaded.values.map(\.text) == ["Frugality"])
    }

    @Test func replaceFromEncryptedBlobAppliesVaultHardening() async throws {
        let (vault, fileURL, keyManager) = try makeVault()
        defer { cleanup(fileURL: fileURL, keyManager: keyManager) }

        try await vault.save(UserProfile(values: [ValueStatement(text: "Health")]))
        let blob = try await vault.exportEncryptedBlob()

        let fileManager = FileManager()
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let newTestDir = appSupport.appendingPathComponent("CouncilVaultTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: newTestDir, withIntermediateDirectories: true)
        let newFileURL = newTestDir.appendingPathComponent("vault.enc")
        let newVault = CryptoKitProfileVault(keyManager: keyManager, fileURL: newFileURL, fileManager: fileManager, writingOptions: [])
        defer { cleanup(fileURL: newFileURL, keyManager: keyManager) }

        // Regression: replace used to skip the 0600 permission and backup-exclusion
        // hardening that save applies.
        try await newVault.replaceFromEncryptedBlob(blob)

        let attributes = try FileManager.default.attributesOfItem(atPath: newFileURL.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)

        let resourceValues = try newTestDir.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(resourceValues.isExcludedFromBackup == true)
    }

    @Test func replaceFromGarbageBlobFailsLoudlyOnLoad() async throws {
        let (vault, fileURL, keyManager) = try makeVault()
        defer { cleanup(fileURL: fileURL, keyManager: keyManager) }

        // Ensure a key exists, then replace the vault with undecryptable bytes.
        try await vault.save(UserProfile(values: [ValueStatement(text: "Health")]))
        try await vault.replaceFromEncryptedBlob(Data(repeating: 0xAB, count: 100))

        // Pin: a garbage blob must throw on load, never read back as an empty
        // (silently wiped) profile.
        await #expect(throws: (any Error).self) {
            _ = try await vault.load()
        }
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
    }
}
