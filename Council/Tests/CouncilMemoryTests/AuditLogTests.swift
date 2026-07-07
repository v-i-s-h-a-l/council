import CouncilCore
@testable import CouncilMemory
import CryptoKit
import Foundation
import GRDB
import Testing

struct AuditLogTests {
    private func makeAuditLog() throws -> GRDBAuditLog {
        var rawKey = Data(count: 32)
        _ = rawKey.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        let dbQueue = try DatabaseQueue()
        return try GRDBAuditLog(dbQueue: dbQueue, profileKey: rawKey)
    }

    private let expectedGenesis = SHA256.hash(data: Data("COUNCIL_AUDIT_GENESIS_v1".utf8)).map { String(format: "%02x", $0) }.joined()

    @Test func appendCreatesChainedEntries() async throws {
        let auditLog = try makeAuditLog()
        let sessionID = UUID()

        try await auditLog.append(
            AuditEntry(sessionID: sessionID, category: .sessionStarted, payload: ["foo": "1"])
        )
        try await auditLog.append(
            AuditEntry(sessionID: sessionID, category: .agentCalled, payload: ["agent": "frugal"])
        )

        let entries = try await auditLog.entries(for: sessionID)
        #expect(entries.count == 2)
        #expect(entries[0].previousHash == expectedGenesis)
        #expect(entries[1].previousHash != entries[0].previousHash)
        #expect(!entries[0].hmac.isEmpty)
        #expect(!entries[1].hmac.isEmpty)
        #expect(entries[0].hmac != entries[1].hmac)
    }

    @Test func verifyChainSucceedsForUntamperedLog() async throws {
        let auditLog = try makeAuditLog()
        try await auditLog.append(AuditEntry(category: .sessionStarted, payload: ["a": "1"]))
        try await auditLog.append(AuditEntry(category: .stageTransition, payload: ["b": "2"]))
        try await auditLog.append(AuditEntry(category: .agentCalled, payload: ["c": "3"]))

        #expect(try await auditLog.verifyChain())
    }

    @Test func tamperedEntryFailsVerification() async throws {
        let auditLog = try makeAuditLog()
        try await auditLog.append(AuditEntry(category: .sessionStarted, payload: ["a": "1"]))
        try await auditLog.append(AuditEntry(category: .stageTransition, payload: ["b": "2"]))

        // Tamper with the underlying record directly.
        let records = try await auditLog.dbQueue.read { db in
            try AuditLogRecord.fetchAll(db)
        }
        let tamperedHMAC = "deadbeef"
        try await auditLog.dbQueue.write { db in
            var firstRecord = records.first!
            firstRecord.hmac = tamperedHMAC
            try firstRecord.update(db)
        }

        #expect(try await auditLog.verifyChain() == false)
    }

    @Test func brokenChainFailsVerification() async throws {
        let auditLog = try makeAuditLog()
        try await auditLog.append(AuditEntry(category: .sessionStarted, payload: ["a": "1"]))
        try await auditLog.append(AuditEntry(category: .stageTransition, payload: ["b": "2"]))

        // Break the chain by altering the previous hash of the second record.
        let records = try await auditLog.dbQueue.read { db in
            try AuditLogRecord.fetchAll(db)
        }
        try await auditLog.dbQueue.write { db in
            var secondRecord = records[1]
            secondRecord.previousHash = "broken"
            try secondRecord.update(db)
        }

        #expect(try await auditLog.verifyChain() == false)
    }

    @Test func genesisHashIsExpectedValue() async throws {
        let auditLog = try makeAuditLog()
        let entries = try await auditLog.entries(for: nil)
        #expect(entries.isEmpty)

        try await auditLog.append(AuditEntry(category: .sessionStarted))
        let firstEntry = try await auditLog.entries(for: nil).first!
        #expect(firstEntry.previousHash == expectedGenesis)
    }
}
