import CouncilCore
@testable import CouncilMemory
import CryptoKit
import Foundation
import GRDB
import Testing

struct GRDBMemoryStoreTests {
    private func makeStore() throws -> GRDBMemoryStore {
        let rawKey = Data(repeating: 0xAA, count: 32)
        let salt = Data(repeating: 0xBB, count: 16)
        let dbQueue = try DatabaseQueue()
        return try GRDBMemoryStore(dbQueue: dbQueue, profileKey: rawKey, salt: salt)
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

    @Test func temporalFactsDeniedByPurpose() async throws {
        let store = try makeStore()
        let sensitive = TemporalFact(
            subject: "user",
            predicate: "ssn",
            object: "123-45-6789",
            accessScope: [.purchaseDeliberation, .travelDeliberation],
            deniedPurposes: [.purchaseDeliberation]
        )
        try await store.saveFact(sensitive)

        // Denied for purchase even though purchase is in accessScope.
        let purchase = try await store.temporalFacts(for: .purchaseDeliberation)
        #expect(purchase.isEmpty)

        let purchaseViaFilter = try await store.temporalFacts(
            matching: MemoryFilter(purposes: [.purchaseDeliberation])
        )
        #expect(purchaseViaFilter.isEmpty)

        // Still allowed for travel (in scope, not denied), and deniedPurposes round-trips.
        let travel = try await store.temporalFacts(for: .travelDeliberation)
        #expect(travel.count == 1)
        #expect(travel.first?.deniedPurposes == [.purchaseDeliberation])
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

    @Test func differentSaltsProduceDifferentCiphertexts() async throws {
        let rawKey = Data(repeating: 0xAB, count: 32)
        let salt1 = Data(repeating: 0x01, count: 16)
        let salt2 = Data(repeating: 0x02, count: 16)

        let dbQueue1 = try DatabaseQueue()
        let store1 = try GRDBMemoryStore(dbQueue: dbQueue1, profileKey: rawKey, salt: salt1)
        let fact1 = TemporalFact(
            subject: "user",
            predicate: "owns",
            object: "MacBook Pro",
            accessScope: [.purchaseDeliberation]
        )
        try await store1.saveFact(fact1)

        let dbQueue2 = try DatabaseQueue()
        let store2 = try GRDBMemoryStore(dbQueue: dbQueue2, profileKey: rawKey, salt: salt2)
        let fact2 = TemporalFact(
            subject: "user",
            predicate: "owns",
            object: "MacBook Pro",
            accessScope: [.purchaseDeliberation]
        )
        try await store2.saveFact(fact2)

        let records1 = try await store1.dbQueue.read { db in
            try TemporalFactRecord.fetchAll(db)
        }
        let records2 = try await store2.dbQueue.read { db in
            try TemporalFactRecord.fetchAll(db)
        }

        #expect(records1.first?.objectEncrypted != records2.first?.objectEncrypted)
    }
}
