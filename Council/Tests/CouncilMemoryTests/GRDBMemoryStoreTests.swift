import CouncilCore
@testable import CouncilMemory
import CryptoKit
import Foundation
import GRDB
import Testing

struct GRDBMemoryStoreTests {
    private func makeStore() throws -> GRDBMemoryStore {
        var rawKey = Data(count: 32)
        _ = rawKey.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        let dbQueue = try DatabaseQueue()
        return try GRDBMemoryStore(dbQueue: dbQueue, profileKey: rawKey)
    }

    @Test func saveAndLoadEpisode() async throws {
        let store = try makeStore()
        let episode = EpisodicGist(
            sessionID: UUID(),
            question: "Should I buy a laptop?",
            perspective: Perspective(
                summary: "It is expensive but useful.",
                tradeOffs: ["cost", "productivity"],
                blindSpots: ["depreciation"],
                dissent: ["wait for sale"]
            )
        )

        try await store.saveEpisode(episode)
        let loaded = try await store.episodes(matching: MemoryFilter())

        #expect(loaded.count == 1)
        #expect(loaded.first?.question == episode.question)
        #expect(loaded.first?.perspective.summary == episode.perspective.summary)
        #expect(loaded.first?.perspective.tradeOffs == episode.perspective.tradeOffs)
    }

    @Test func saveAndLoadEpisodeWithDefaultPerspective() async throws {
        let store = try makeStore()
        let episode = EpisodicGist(sessionID: UUID(), question: "Default perspective?")

        try await store.saveEpisode(episode)
        let loaded = try await store.episodes(matching: MemoryFilter())

        #expect(loaded.count == 1)
        #expect(loaded.first?.question == episode.question)
        #expect(loaded.first?.perspective.summary == "")
        #expect(loaded.first?.perspective.tradeOffs.isEmpty == true)
    }

    @Test func updateEpisode() async throws {
        let store = try makeStore()
        var episode = EpisodicGist(
            sessionID: UUID(),
            question: "Original question?"
        )
        try await store.saveEpisode(episode)

        episode.question = "Updated question?"
        try await store.updateEpisode(episode)

        let loaded = try await store.episodes(matching: MemoryFilter())
        #expect(loaded.first?.question == "Updated question?")
    }

    @Test func deleteEpisode() async throws {
        let store = try makeStore()
        let episode = EpisodicGist(sessionID: UUID(), question: "Delete me?")
        try await store.saveEpisode(episode)
        try await store.deleteEpisode(id: episode.id)

        let loaded = try await store.episodes(matching: MemoryFilter())
        #expect(loaded.isEmpty)
    }

    @Test func lockEpisode() async throws {
        let store = try makeStore()
        let episode = EpisodicGist(sessionID: UUID(), question: "Lock me?")
        try await store.saveEpisode(episode)
        try await store.lockEpisode(id: episode.id, isLocked: true)

        let locked = try await store.episodes(matching: MemoryFilter(locked: true))
        let unlocked = try await store.episodes(matching: MemoryFilter(locked: false))
        #expect(locked.count == 1)
        #expect(unlocked.isEmpty)
    }

    @Test func saveAndLoadFact() async throws {
        let store = try makeStore()
        let fact = TemporalFact(
            subject: "user",
            predicate: "owns",
            object: "MacBook Pro",
            accessScope: [.purchaseDeliberation]
        )

        try await store.saveFact(fact)
        let loaded = try await store.temporalFacts(matching: MemoryFilter())

        #expect(loaded.count == 1)
        #expect(loaded.first?.object == "MacBook Pro")
        #expect(loaded.first?.accessScope == [.purchaseDeliberation])
    }

    @Test func temporalFactsFilteredByPurpose() async throws {
        let store = try makeStore()
        let purchaseFact = TemporalFact(
            subject: "user",
            predicate: "owns",
            object: "Laptop",
            accessScope: [.purchaseDeliberation]
        )
        let travelFact = TemporalFact(
            subject: "user",
            predicate: "plans",
            object: "Japan trip",
            accessScope: [.travelDeliberation]
        )
        try await store.saveFact(purchaseFact)
        try await store.saveFact(travelFact)

        let purchaseFacts = try await store.temporalFacts(for: .purchaseDeliberation)
        #expect(purchaseFacts.count == 1)
        #expect(purchaseFacts.first?.object == "Laptop")

        let travelFacts = try await store.temporalFacts(for: .travelDeliberation)
        #expect(travelFacts.count == 1)
        #expect(travelFacts.first?.object == "Japan trip")
    }

    @Test func lockedFactsExcludedFromAgentContext() async throws {
        let store = try makeStore()
        let unlockedFact = TemporalFact(
            subject: "user",
            predicate: "owns",
            object: "Unlocked",
            accessScope: [.purchaseDeliberation]
        )
        var lockedFact = TemporalFact(
            subject: "user",
            predicate: "owns",
            object: "Locked",
            accessScope: [.purchaseDeliberation]
        )
        lockedFact.isLocked = true
        try await store.saveFact(unlockedFact)
        try await store.saveFact(lockedFact)

        let facts = try await store.temporalFacts(for: .purchaseDeliberation)
        #expect(facts.count == 1)
        #expect(facts.first?.object == "Unlocked")
    }

    @Test func sensitiveColumnsAreEncrypted() async throws {
        let store = try makeStore()
        let fact = TemporalFact(
            subject: "user",
            predicate: "balance",
            object: "12345.67",
            accessScope: [.purchaseDeliberation]
        )
        try await store.saveFact(fact)

        // Read raw record and verify the object is not stored as plaintext UTF-8 bytes.
        let records = try await store.dbQueue.read { db in
            try TemporalFactRecord.fetchAll(db)
        }
        let rawObject = records.first?.objectEncrypted ?? Data()
        #expect(String(data: rawObject, encoding: .utf8) != "12345.67")
    }
}
