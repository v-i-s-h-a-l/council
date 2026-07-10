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
}
