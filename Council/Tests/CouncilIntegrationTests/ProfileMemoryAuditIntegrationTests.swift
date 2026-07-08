import CouncilAgents
import CouncilCore
@testable import CouncilMemory
import CouncilTestUtilities
import Foundation
import GRDB
import Testing

/// Full profile → memory → audit wiring through a test composition root.
struct ProfileMemoryAuditIntegrationTests {
    private struct TestCompositionRoot {
        let profileService: ProfileService
        let memoryService: MemoryService
        let auditLog: GRDBAuditLog
        let keyManager: ProfileKeyManager
        let fileURL: URL

        static func make() async throws -> TestCompositionRoot {
            let keyManager = ProfileKeyManager(
                service: "com.council.test.integration.\(UUID().uuidString)",
                wrappedKeyAccount: "wrapped-key-\(UUID().uuidString)",
                seKeyAccount: "se-key-\(UUID().uuidString)"
            )
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

            return TestCompositionRoot(profileService: profileService, memoryService: memoryService, auditLog: auditLog, keyManager: keyManager, fileURL: fileURL)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
            keyManager.deleteKeys()
        }
    }

    @Test func fullWiringSavesProfileMemoryAndAudit() async throws {
        let root = try await TestCompositionRoot.make()
        defer { root.cleanup() }

        let profile = UserProfile(
            values: [ValueStatement(text: "Frugality")],
            goals: [Goal(text: "Save for a house")],
            boundaries: [Boundary(text: "No high-interest debt")],
            financialHistory: ClientConfidentialContainer(items: ["secret account: 99999"]),
            journalExcerpts: ClientConfidentialContainer(items: ["secret thought"])
        )
        try await root.profileService.save(profile)

        let sessionID = UUID()
        let episode = EpisodicGist(
            sessionID: sessionID,
            question: "Should I buy a new laptop?",
            perspective: Perspective(
                summary: "Expensive but useful.",
                tradeOffs: ["cost", "productivity"],
                blindSpots: ["depreciation"],
                dissent: ["keep current device"]
            )
        )
        try await root.memoryService.store.saveEpisode(episode)
        try await root.memoryService.auditLog.append(
            AuditEntry(sessionID: sessionID, category: .memoryAccess, payload: ["action": "saveEpisode"])
        )

        let fact = TemporalFact(
            subject: "user",
            predicate: "owns",
            object: "2019 MacBook Pro",
            accessScope: [.purchaseDeliberation]
        )
        try await root.memoryService.store.saveFact(fact)

        let loadedProfile = try await root.profileService.load()
        #expect(loadedProfile.values.map(\.text) == ["Frugality"])

        let episodes = try await root.memoryService.store.episodes(matching: MemoryFilter())
        #expect(episodes.count == 1)
        #expect(episodes.first?.perspective.summary == "Expensive but useful.")

        let facts = try await root.memoryService.store.temporalFacts(for: .purchaseDeliberation)
        #expect(facts.count == 1)
        #expect(facts.first?.object == "2019 MacBook Pro")

        let auditEntries = try await root.memoryService.auditLog.entries(for: sessionID)
        #expect(auditEntries.count == 1)
        #expect(try await root.auditLog.verifyChain())
    }

    @Test func confidentialDataDoesNotLeakIntoAgentPrompts() async throws {
        let root = try await TestCompositionRoot.make()
        defer { root.cleanup() }

        let profile = UserProfile(
            values: [ValueStatement(text: "Privacy")],
            financialHistory: ClientConfidentialContainer(items: ["salary: 1000000"]),
            journalExcerpts: ClientConfidentialContainer(items: ["private journal entry"])
        )
        try await root.profileService.save(profile)

        let loadedProfile = try await root.profileService.load()
        let context = RoutableProfileContext(profile: loadedProfile)

        let agents: [any Agent] = [
            FrugalAgent(),
            FutureSelfAgent(),
            SystemsThinkerAgent(),
            PleasureAgent(),
            ChairAgent(),
        ]

        for agent in agents {
            let messages = agent.prompt(
                stage: .firstOpinions,
                question: "Should I buy a yacht?",
                context: context,
                priorOutputs: []
            )
            let combined = messages.map(\.content).joined(separator: "\n")
            #expect(!combined.contains("salary: 1000000"))
            #expect(!combined.contains("private journal entry"))
            #expect(!combined.contains("ClientConfidentialContainer"))
        }
    }
}
