import CouncilCore
import CouncilMemory
import CouncilTestUtilities
import Foundation
import Testing

/// An audit log whose appends always fail, used to exercise the `try?` audit path
/// in `MemoryService.facts(subject:purposes:)`.
private actor ThrowingAuditLog: AuditLog {
    struct AppendError: Error {}
    func append(_ entry: AuditEntry) async throws {
        throw AppendError()
    }

    func entries(for sessionID: UUID?) async throws -> [AuditEntry] {
        []
    }
}

/// Adversarial tests for `MemoryService` fact routing.
struct MemoryServiceAdversarialTests {
    @Test func failingAuditLogDoesNotBlockFactAccess() async throws {
        let store = MockMemoryStore()
        try await store.saveFact(TemporalFact(
            subject: "user",
            predicate: "owns",
            object: "Laptop",
            accessScope: [.purchaseDeliberation]
        ))
        let service = MemoryService(store: store, auditLog: ThrowingAuditLog())

        // Pin: access-decision audit writes use `try?`, so a failing audit log
        // must not block reads. The documented trade-off of that choice is that
        // access is then granted WITHOUT an audit record.
        let facts = try await service.facts(subject: "user", purposes: [.purchaseDeliberation])
        #expect(facts.count == 1)
        #expect(facts.first?.object == "Laptop")
    }

    @Test func expiredFactIsExcludedFromPurposeRoutedFacts() async throws {
        let store = MockMemoryStore()
        let expired = TemporalFact(
            subject: "user",
            predicate: "likes",
            object: "Expired thing",
            validUntil: Date(timeIntervalSinceNow: -60),
            accessScope: [.purchaseDeliberation]
        )
        let current = TemporalFact(
            subject: "user",
            predicate: "likes",
            object: "Current thing",
            validUntil: Date(timeIntervalSinceNow: 3_600),
            accessScope: [.purchaseDeliberation]
        )
        try await store.saveFact(expired)
        try await store.saveFact(current)
        let service = MemoryService(store: store, auditLog: MockAuditLog())

        // Regression: stale facts used to flow into purpose-routed (agent-facing)
        // reads because nothing evaluated validFrom/validUntil.
        let facts = try await service.facts(subject: "user", purposes: [.purchaseDeliberation])
        #expect(facts.map(\.object) == ["Current thing"])
    }

    @Test func negativeEpisodeLimitsReturnEmptyWithoutCrashing() async throws {
        let store = MockMemoryStore()
        try await store.saveEpisode(EpisodicGist(sessionID: UUID(), question: "Q?"))
        let service = MemoryService(store: store, auditLog: MockAuditLog())

        // Regression: prefix(-1) traps — negative limits must clamp to empty.
        #expect(try await service.recentEpisodes(limit: -1).isEmpty)
        #expect(try await service.searchEpisodes(query: "Q", limit: -5).isEmpty)
        // Zero and positive limits still behave.
        #expect(try await service.recentEpisodes(limit: 0).isEmpty)
        #expect(try await service.recentEpisodes(limit: 1).count == 1)
    }
}
