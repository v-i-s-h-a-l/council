import CouncilCore
@testable import CouncilMemory
import CryptoKit
import Foundation
import GRDB
import Testing

struct ProfileMemoryIntegrationTests {
    private func makeServices() async throws -> (profileService: ProfileService, memoryService: MemoryService, auditLog: GRDBAuditLog, keyManager: ProfileKeyManager, fileURL: URL) {
        let keyManager = ProfileKeyManager(
            service: "com.council.test.integration.\(UUID().uuidString)",
            wrappedKeyAccount: "wrapped-key-\(UUID().uuidString)",
            seKeyAccount: "se-key-\(UUID().uuidString)"
        )
        // Ensure a key exists so the vault and memory store share the same source key.
        _ = try await keyManager.generateKey()

        let fileManager = FileManager()
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let testDir = appSupport.appendingPathComponent("CouncilIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = testDir.appendingPathComponent("vault.enc")
        try fileManager.createDirectory(at: testDir, withIntermediateDirectories: true)
        let vault = CryptoKitProfileVault(keyManager: keyManager, fileURL: fileURL, fileManager: fileManager, writingOptions: [])
        let profileService = ProfileService(vault: vault)

        let rawKey = try await keyManager.unwrapKey()
        let dbQueue = try DatabaseQueue()
        let store = try GRDBMemoryStore(dbQueue: dbQueue, profileKey: rawKey)
        let auditLog = try GRDBAuditLog(dbQueue: dbQueue, profileKey: rawKey)
        let memoryService = MemoryService(store: store, auditLog: auditLog)

        return (profileService, memoryService, auditLog, keyManager, fileURL)
    }

    private func cleanup(fileURL: URL, keyManager: ProfileKeyManager) {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        keyManager.deleteKeys()
    }

    @Test func profileKeyDerivesMemoryAndAuditKeys() async throws {
        let (profileService, memoryService, auditLog, keyManager, fileURL) = try await makeServices()
        defer { cleanup(fileURL: fileURL, keyManager: keyManager) }

        let profile = UserProfile(
            values: [ValueStatement(text: "Privacy")],
            goals: [Goal(text: "Stay debt-free")]
        )
        try await profileService.save(profile)

        let sessionID = UUID()
        let episode = EpisodicGist(
            sessionID: sessionID,
            question: "Should I subscribe to a service?",
            perspective: Perspective(summary: "Recurring cost matters.")
        )
        try await memoryService.store.saveEpisode(episode)
        try await memoryService.auditLog.append(
            AuditEntry(sessionID: sessionID, category: .memoryAccess, payload: ["action": "saveEpisode"])
        )

        let loadedProfile = try await profileService.load()
        #expect(loadedProfile.values.map(\.text) == ["Privacy"])

        let loadedEpisodes = try await memoryService.store.episodes(matching: MemoryFilter())
        #expect(loadedEpisodes.count == 1)

        let auditEntries = try await memoryService.auditLog.entries(for: sessionID)
        #expect(auditEntries.count == 1)
        #expect(try await auditLog.verifyChain())
    }
}
