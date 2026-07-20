import Foundation
import Testing
@testable import CouncilCore

/// Minimal `AuditLog` that implements only the two requirements without
/// defaults, so every test below exercises the *protocol extension* in
/// Protocols.swift — the code path used by any log that does not override
/// `entries(since:limit:includePayloads:)` or `verifyChain()`.
private actor StubAuditLog: AuditLog {
    private var stored: [AuditEntry] = []

    func append(_ entry: AuditEntry) async throws {
        stored.append(entry)
    }

    func entries(for sessionID: UUID?) async throws -> [AuditEntry] {
        stored
    }
}

/// Adversarial coverage for the `AuditLog` default implementations, which sit
/// in front of audit exports and telemetry views.
struct AuditLogDefaultsAdversarialTests {

    private func makeEntry(
        timestamp: Date,
        payload: [String: String] = [:]
    ) -> AuditEntry {
        AuditEntry(
            timestamp: timestamp,
            category: .memoryAccess,
            payload: payload,
            previousHash: "prev",
            hmac: "hmac"
        )
    }

    // MARK: - Regression: includePayloads was accepted but silently ignored,
    // so payload-free exports received full payloads (possibly containing
    // memory-access details). Fixed in Protocols.swift.

    @Test func auditLogDefaultQueryStripsPayloadsWhenIncludePayloadsIsFalse() async throws {
        let log = StubAuditLog()
        try await log.append(makeEntry(
            timestamp: Date(timeIntervalSinceReferenceDate: 1000),
            payload: ["factID": "CANARY-SECRET", "purpose": "purchaseDeliberation"]
        ))

        let stripped = try await log.entries(since: nil, limit: nil, includePayloads: false)
        #expect(stripped.count == 1)
        #expect(stripped[0].payload.isEmpty, "includePayloads: false must strip every payload")

        let full = try await log.entries(since: nil, limit: nil, includePayloads: true)
        #expect(full[0].payload["factID"] == "CANARY-SECRET", "includePayloads: true must preserve payloads")
    }

    @Test func auditLogDefaultQueryStrippingPreservesIdentityAndChainFields() async throws {
        let log = StubAuditLog()
        let original = makeEntry(
            timestamp: Date(timeIntervalSinceReferenceDate: 2000),
            payload: ["k": "v"]
        )
        try await log.append(original)

        let stripped = try await log.entries(since: nil, limit: nil, includePayloads: false)
        #expect(stripped.count == 1)
        // Stripping payloads must not sever identity or the HMAC chain fields.
        #expect(stripped[0].id == original.id)
        #expect(stripped[0].timestamp == original.timestamp)
        #expect(stripped[0].category == original.category)
        #expect(stripped[0].previousHash == original.previousHash)
        #expect(stripped[0].hmac == original.hmac)
    }

    // MARK: - A14: query-semantics boundaries

    @Test func auditLogDefaultQuerySinceFilterIsInclusiveAndSortsDescending() async throws {
        let log = StubAuditLog()
        let t1 = Date(timeIntervalSinceReferenceDate: 100)
        let t2 = Date(timeIntervalSinceReferenceDate: 200)
        let t3 = Date(timeIntervalSinceReferenceDate: 300)
        try await log.append(makeEntry(timestamp: t1))
        try await log.append(makeEntry(timestamp: t2))
        try await log.append(makeEntry(timestamp: t3))

        // An entry exactly at `since` is included (timestamp >= since).
        let results = try await log.entries(since: t2, limit: nil, includePayloads: true)
        #expect(results.map(\.timestamp) == [t3, t2])
    }

    @Test func auditLogDefaultQueryLimitZeroReturnsEmptyAndLimitTruncatesNewest() async throws {
        let log = StubAuditLog()
        for i in 0..<5 {
            try await log.append(makeEntry(timestamp: Date(timeIntervalSinceReferenceDate: Double(i))))
        }

        let zero = try await log.entries(since: nil, limit: 0, includePayloads: true)
        #expect(zero.isEmpty)

        let two = try await log.entries(since: nil, limit: 2, includePayloads: true)
        #expect(two.map(\.timestamp) == [
            Date(timeIntervalSinceReferenceDate: 4),
            Date(timeIntervalSinceReferenceDate: 3),
        ])
    }

    @Test func auditLogDefaultQueryEqualTimestampsHaveUnspecifiedOrder() async throws {
        // The descending sort is not stable; pin the contract as set-equality
        // so no consumer comes to rely on insertion order for ties.
        let log = StubAuditLog()
        let shared = Date(timeIntervalSinceReferenceDate: 500)
        var ids: [UUID] = []
        for _ in 0..<3 {
            let entry = makeEntry(timestamp: shared)
            ids.append(entry.id)
            try await log.append(entry)
        }

        let results = try await log.entries(since: nil, limit: nil, includePayloads: true)
        #expect(Set(results.map(\.id)) == Set(ids))
        #expect(results.allSatisfy { $0.timestamp == shared })
    }

    @Test func auditLogDefaultVerifyChainReturnsTrueEvenForTamperedEntries() async throws {
        // The default verifyChain() is a no-op returning true for logs without
        // an HMAC chain. Pin this so no consumer mistakes the default for
        // integrity — real verification lives in GRDBAuditLog (CouncilMemory).
        let log = StubAuditLog()
        try await log.append(makeEntry(timestamp: Date(), payload: ["tampered": "yes"]))
        #expect(try await log.verifyChain())
    }
}
