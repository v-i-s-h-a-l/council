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

    /// Hardcoded on purpose: recomputing this with the same formula as the source
    /// would let a changed genesis constant slip through review and silently
    /// invalidate every existing chain. SHA-256 of "COUNCIL_AUDIT_GENESIS_v1".
    private let expectedGenesis = "bd622ccd0e744c7324089ee61696bd0bea7dec31aefe08160a3b0c837d936a5a"

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

    // MARK: - Adversarial: chain integrity

    @Test func concurrentAppendsNeverForkTheChain() async throws {
        let auditLog = try makeAuditLog()

        // Regression: `append` used to read the chain tip in a separate suspending
        // read; two concurrent appends could both link to the same tip and fork the
        // chain, which `verifyChain()` then rejected — silent audit corruption.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    try await auditLog.append(
                        AuditEntry(category: .memoryAccess, payload: ["index": "\(index)"])
                    )
                }
            }
            try await group.waitForAll()
        }

        let entries = try await auditLog.entries(for: nil)
        #expect(entries.count == 20)
        #expect(try await auditLog.verifyChain())
    }

    @Test func backdatedEntryDoesNotBreakChain() async throws {
        let auditLog = try makeAuditLog()
        try await auditLog.append(AuditEntry(category: .sessionStarted, payload: ["a": "1"]))
        try await auditLog.append(AuditEntry(category: .stageTransition, payload: ["b": "2"]))

        // Regression: chain ordering used to follow wall-clock timestamps, so an
        // entry whose timestamp predates its predecessors broke verification. The
        // chain now follows insertion order; display reads still sort by timestamp.
        let backdatedID = UUID()
        try await auditLog.append(
            AuditEntry(
                id: backdatedID,
                timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                category: .agentCalled,
                payload: ["c": "3"]
            )
        )

        #expect(try await auditLog.verifyChain())
        let entries = try await auditLog.entries(for: nil)
        #expect(entries.count == 3)
        #expect(entries.first?.id == backdatedID)
    }

    @Test func tamperedEncryptedPayloadMakesVerifyChainThrow() async throws {
        let auditLog = try makeAuditLog()
        try await auditLog.append(AuditEntry(category: .sessionStarted, payload: ["a": "1"]))
        try await auditLog.append(AuditEntry(category: .stageTransition, payload: ["b": "2"]))

        // Flip one byte inside the encrypted payload of the first record.
        let records = try await auditLog.dbQueue.read { db in
            try AuditLogRecord.fetchAll(db)
        }
        try await auditLog.dbQueue.write { db in
            var firstRecord = records[0]
            var payload = firstRecord.payloadEncrypted
            payload[payload.count - 1] ^= 0x01
            firstRecord.payloadEncrypted = payload
            try firstRecord.update(db)
        }

        // Pin: payload corruption makes verification THROW (not return false) —
        // callers checking `== false` must also handle the error path.
        await #expect(throws: (any Error).self) {
            _ = try await auditLog.verifyChain()
        }
    }

    @Test func canonicalizationIsTimestampPrecisionStable() async throws {
        let auditLog = try makeAuditLog()
        // The HMAC is computed over the ISO8601-millisecond rendering while GRDB
        // round-trips the date through SQLite; pin that the two truncations agree
        // for sub-millisecond input.
        try await auditLog.append(
            AuditEntry(
                timestamp: Date(timeIntervalSince1970: 1_700_000_000.123456),
                category: .sessionStarted,
                payload: ["precision": "microseconds"]
            )
        )
        #expect(try await auditLog.verifyChain())
    }

    @Test func verifyChainEmptyLogIsTrueAndStaysTrue() async throws {
        let auditLog = try makeAuditLog()
        #expect(try await auditLog.verifyChain())

        try await auditLog.append(AuditEntry(category: .sessionStarted))
        #expect(try await auditLog.verifyChain())
    }

    @Test func reopeningWithWrongProfileKeyFailsLoudly() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("audit.sqlite").path

        let salt = Data(repeating: 0xBB, count: 16)
        let auditLog = try await GRDBAuditLog.make(
            path: dbPath,
            profileKey: Data(repeating: 0xAA, count: 32),
            salt: salt,
            useSQLCipher: false
        )
        try await auditLog.append(AuditEntry(category: .sessionStarted, payload: ["k": "v"]))

        // Reopening under a different profile key must fail loudly: undecryptable
        // payloads and unverifiable HMACs throw rather than read as an empty log.
        let wrongKeyLog = try await GRDBAuditLog.make(
            path: dbPath,
            profileKey: Data(repeating: 0xCC, count: 32),
            salt: salt,
            useSQLCipher: false
        )
        await #expect(throws: (any Error).self) {
            _ = try await wrongKeyLog.entries(for: nil)
        }
        await #expect(throws: (any Error).self) {
            _ = try await wrongKeyLog.verifyChain()
        }
    }

    // MARK: - Adversarial: malformed rows and boundaries

    @Test func unknownAuditCategoryRawValueDowngradesToError() async throws {
        let auditLog = try makeAuditLog()
        try await auditLog.append(AuditEntry(category: .sessionStarted, payload: ["a": "1"]))

        // Simulate a record written by a newer app version with an unknown category.
        try await auditLog.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE audit_log SET category = ?",
                arguments: ["telemetry-v9"]
            )
        }

        // Pin the silent forward-compatibility downgrade on both read paths.
        let full = try await auditLog.entries(for: nil)
        #expect(full.count == 1)
        #expect(full.first?.category == .error)
        #expect(full.first?.payload == ["a": "1"])

        let stripped = try await auditLog.entries(since: nil, limit: nil, includePayloads: false)
        #expect(stripped.count == 1)
        #expect(stripped.first?.category == .error)
    }

    @Test func negativeLimitIsConsistentBetweenReadPaths() async throws {
        let auditLog = try makeAuditLog()
        for index in 0..<3 {
            try await auditLog.append(AuditEntry(category: .sessionStarted, payload: ["i": "\(index)"]))
        }

        // Regression: a negative limit was "unlimited" on the SQL path (LIMIT -1)
        // but crashed the process on the payload path (prefix(-1) traps). Both
        // paths now clamp to zero.
        let strippedNegative = try await auditLog.entries(since: nil, limit: -1, includePayloads: false)
        let fullNegative = try await auditLog.entries(since: nil, limit: -1, includePayloads: true)
        #expect(strippedNegative.isEmpty)
        #expect(fullNegative.isEmpty)

        let strippedZero = try await auditLog.entries(since: nil, limit: 0, includePayloads: false)
        let fullZero = try await auditLog.entries(since: nil, limit: 0, includePayloads: true)
        #expect(strippedZero.isEmpty)
        #expect(fullZero.isEmpty)

        let strippedTwo = try await auditLog.entries(since: nil, limit: 2, includePayloads: false)
        let fullTwo = try await auditLog.entries(since: nil, limit: 2, includePayloads: true)
        #expect(strippedTwo.count == 2)
        #expect(fullTwo.count == 2)
    }

    @Test func oneCorruptRowBlocksAllEntriesReads() async throws {
        let auditLog = try makeAuditLog()
        try await auditLog.append(AuditEntry(category: .sessionStarted, payload: ["good": "1"]))

        // Insert a second record whose encrypted payload is garbage.
        try await auditLog.dbQueue.write { db in
            var record = AuditLogRecord(
                id: UUID(),
                sessionID: nil,
                timestamp: Date(),
                category: "error",
                previousHash: "corrupt",
                hmac: "corrupt",
                payloadEncrypted: Data(repeating: 0xFF, count: 40)
            )
            try record.insert(db)
        }

        // Pin: listing maps every record, so one corrupt row throws the whole read.
        await #expect(throws: (any Error).self) {
            _ = try await auditLog.entries(for: nil)
        }
    }

    @Test func hugeAndHostilePayloadsRoundTrip() async throws {
        let auditLog = try makeAuditLog()
        var payload: [String: String] = [:]
        for index in 0..<10_000 {
            payload["key-\(index)"] = "value-\(index)"
        }
        payload["huge"] = String(repeating: "x", count: 1_000_000)
        payload["hostile"] = "nul\u{0}byte emoji 👨‍👩‍👧‍👦 rtl \u{202E}abc newline\nend"

        try await auditLog.append(AuditEntry(category: .memoryAccess, payload: payload))

        let entries = try await auditLog.entries(for: nil)
        #expect(entries.count == 1)
        #expect(entries.first?.payload == payload)
        #expect(try await auditLog.verifyChain())
    }
}
