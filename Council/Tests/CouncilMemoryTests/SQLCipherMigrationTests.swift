import CouncilCore
@testable import CouncilMemory
import CryptoKit
import Foundation
import GRDB
import Testing

struct SQLCipherMigrationTests {
    private let profileKey = Data(repeating: 0xAA, count: 32)
    private let salt = Data(repeating: 0xBB, count: 16)

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Creates a legacy (plaintext) database at the given path with known data.
    private func createLegacyDatabase(at path: String) throws -> (episodeIDs: [UUID], factIDs: [UUID], auditIDs: [UUID]) {
        let dbQueue = try DatabaseQueue(path: path)
        try DatabaseMigrator.migrator().migrate(dbQueue)

        let key = GRDBMemoryStore.deriveDatabaseKey(from: profileKey, salt: salt)

        let episode = EpisodicGist(
            sessionID: UUID(),
            question: "Should I migrate?",
            perspective: Perspective(
                summary: "Migration preserves data.",
                tradeOffs: ["complexity"],
                blindSpots: ["rollback"],
                dissent: ["stay plaintext"]
            )
        )
        let fact = TemporalFact(
            subject: "user",
            predicate: "database",
            object: "memory.sqlite",
            accessScope: [.purchaseDeliberation]
        )

        var episodeRecord = try EpisodicGistRecord(episode: episode, key: key)
        var factRecord = try TemporalFactRecord(fact: fact, key: key)

        // Create an audit entry with valid HMAC chain.
        let auditKey = Self.deriveAuditKey(from: profileKey)
        let genesisHash = SHA256.hash(data: Data("COUNCIL_AUDIT_GENESIS_v1".utf8))
            .map { String(format: "%02x", $0) }.joined()
        var auditEntry = AuditEntry(
            sessionID: UUID(),
            timestamp: Date(),
            category: .sessionStarted,
            payload: ["test": "migration"],
            previousHash: genesisHash,
            hmac: ""
        )
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let sortedPayload = auditEntry.payload.sorted { $0.key < $1.key }
        let payloadObject: [String: String] = Dictionary(uniqueKeysWithValues: sortedPayload)
        let object: [String: Any] = [
            "id": auditEntry.id.uuidString,
            "timestamp": formatter.string(from: auditEntry.timestamp),
            "category": auditEntry.category.rawValue,
            "payload": payloadObject,
            "previousHash": auditEntry.previousHash,
        ]
        let canonicalData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let code = HMAC<SHA256>.authenticationCode(for: canonicalData, using: auditKey)
        auditEntry.hmac = code.map { String(format: "%02x", $0) }.joined()

        var auditRecord = try AuditLogRecord(entry: auditEntry, key: auditKey)

        try dbQueue.write { db in
            try episodeRecord.insert(db)
            try factRecord.insert(db)
            try auditRecord.insert(db)
        }

        return ([episode.id], [fact.id], [auditEntry.id])
    }

    private static func deriveAuditKey(from profileKey: Data) -> SymmetricKey {
        let inputKey = SymmetricKey(data: profileKey)
        let info = Data("com.council.audit.integrity.v1".utf8)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            info: info,
            outputByteCount: 32
        )
    }

    // MARK: - Detection

    @Test func detectLegacyDatabaseReturnsTrueWhenNoMarker() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let dbPath = dir.appendingPathComponent("memory.sqlite").path

        // Create a plaintext database.
        let dbQueue = try DatabaseQueue(path: dbPath)
        try DatabaseMigrator.migrator().migrate(dbQueue)

        #expect(SQLCipherMigration.detectLegacyDatabase(at: dbPath))
        #expect(!SQLCipherMigration.isMigrated(at: dbPath))
    }

    @Test func detectLegacyDatabaseReturnsFalseWhenMarkerExists() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let dbPath = dir.appendingPathComponent("memory.sqlite").path

        // Create a database and marker file.
        let dbQueue = try DatabaseQueue(path: dbPath)
        try DatabaseMigrator.migrator().migrate(dbQueue)
        try Data("sqlcipher-v1\n".utf8).write(
            to: URL(fileURLWithPath: dbPath + ".sqlcipher")
        )

        #expect(!SQLCipherMigration.detectLegacyDatabase(at: dbPath))
        #expect(SQLCipherMigration.isMigrated(at: dbPath))
    }

    @Test func detectLegacyDatabaseReturnsFalseWhenNoDatabaseExists() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let dbPath = dir.appendingPathComponent("memory.sqlite").path

        #expect(!SQLCipherMigration.detectLegacyDatabase(at: dbPath))
    }

    // MARK: - SQLCipher Encryption

    @Test func sqlCipherDatabaseCannotBeOpenedWithoutKey() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let dbPath = dir.appendingPathComponent("memory.sqlite").path

        // Create a SQLCipher-encrypted database.
        let store = try await GRDBMemoryStore.make(
            path: dbPath,
            profileKey: profileKey,
            salt: salt,
            useSQLCipher: true
        )
        let fact = TemporalFact(
            subject: "user",
            predicate: "encrypted",
            object: "secret-data",
            accessScope: [.purchaseDeliberation]
        )
        try await store.saveFact(fact)

        // Attempt to open the same database without a key should fail.
        // DatabaseQueue(path:) throws during init because validateFormat()
        // cannot read the encrypted file.
        #expect(throws: (any Error).self) {
            _ = try DatabaseQueue(path: dbPath)
        }
    }

    @Test func sqlCipherDatabaseOpensWithCorrectKey() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let dbPath = dir.appendingPathComponent("memory.sqlite").path

        // Create and write to a SQLCipher database.
        let store = try await GRDBMemoryStore.make(
            path: dbPath,
            profileKey: profileKey,
            salt: salt,
            useSQLCipher: true
        )
        let fact = TemporalFact(
            subject: "user",
            predicate: "test",
            object: "roundtrip",
            accessScope: [.travelDeliberation]
        )
        try await store.saveFact(fact)

        // Open the same path with the correct key — should succeed.
        let store2 = try await GRDBMemoryStore.make(
            path: dbPath,
            profileKey: profileKey,
            salt: salt,
            useSQLCipher: true
        )
        let facts = try await store2.temporalFacts(matching: MemoryFilter())
        #expect(facts.count == 1)
        #expect(facts.first?.object == "roundtrip")
    }

    @Test func sqlCipherInMemoryDatabaseWorks() async throws {
        // In-memory databases should work with SQLCipher key.
        let dbQueue = try DatabaseQueue()
        let store = try GRDBMemoryStore(
            dbQueue: dbQueue,
            profileKey: profileKey,
            salt: salt,
            useSQLCipher: true
        )
        let fact = TemporalFact(
            subject: "user",
            predicate: "memory",
            object: "in-memory-test",
            accessScope: [.purchaseDeliberation]
        )
        try await store.saveFact(fact)
        let facts = try await store.temporalFacts(matching: MemoryFilter())
        #expect(facts.count == 1)
    }

    // MARK: - Migration

    @Test func migratePreservesAllData() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let dbPath = dir.appendingPathComponent("memory.sqlite").path

        // Create legacy database with known data.
        let (episodeIDs, factIDs, auditIDs) = try createLegacyDatabase(at: dbPath)

        // Run migration.
        let result = try SQLCipherMigration.migrate(
            legacyPath: dbPath,
            profileKey: profileKey,
            salt: salt
        )

        #expect(result.episodeCount == 1)
        #expect(result.factCount == 1)
        #expect(result.auditCount == 1)

        // Verify backup exists.
        #expect(FileManager.default.fileExists(atPath: result.backupPath))

        // Verify marker file exists.
        #expect(SQLCipherMigration.isMigrated(at: dbPath))

        // Open the migrated database and verify data.
        let store = try await GRDBMemoryStore.make(
            path: dbPath,
            profileKey: profileKey,
            salt: salt,
            useSQLCipher: true
        )

        let episodes = try await store.episodes(matching: MemoryFilter())
        #expect(episodes.count == 1)
        #expect(episodes.first?.id == episodeIDs.first)
        #expect(episodes.first?.question == "Should I migrate?")
        #expect(episodes.first?.perspective.summary == "Migration preserves data.")

        let facts = try await store.temporalFacts(matching: MemoryFilter())
        #expect(facts.count == 1)
        #expect(facts.first?.id == factIDs.first)
        #expect(facts.first?.object == "memory.sqlite")

        // Verify audit data via raw records.
        let auditRecords = try await store.dbQueue.read { db in
            try AuditLogRecord.fetchAll(db)
        }
        #expect(auditRecords.count == 1)
        #expect(auditRecords.first?.id == auditIDs.first)
    }

    @Test func migrateLegacyDatabaseNotFoundThrows() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let dbPath = dir.appendingPathComponent("nonexistent.sqlite").path

        #expect(throws: SQLCipherMigration.MigrationError.self) {
            try SQLCipherMigration.migrate(legacyPath: dbPath, profileKey: profileKey, salt: salt)
        }
    }

    @Test func rollbackRestoresLegacyDatabase() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let dbPath = dir.appendingPathComponent("memory.sqlite").path

        // Create and migrate legacy database.
        _ = try createLegacyDatabase(at: dbPath)
        let result = try SQLCipherMigration.migrate(
            legacyPath: dbPath,
            profileKey: profileKey,
            salt: salt
        )

        // Verify migration completed.
        #expect(SQLCipherMigration.isMigrated(at: dbPath))
        #expect(FileManager.default.fileExists(atPath: result.backupPath))

        // Rollback.
        try SQLCipherMigration.rollback(at: dbPath)

        // Backup should be gone, marker removed.
        #expect(!FileManager.default.fileExists(atPath: result.backupPath))
        #expect(!SQLCipherMigration.isMigrated(at: dbPath))

        // Legacy database should be back and readable without key.
        let plainQueue = try DatabaseQueue(path: dbPath)
        let facts = try plainQueue.read { db in
            try TemporalFactRecord.fetchAll(db)
        }
        #expect(facts.count == 1)
    }

    @Test func markerFileContentsAreCorrect() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let dbPath = dir.appendingPathComponent("memory.sqlite").path

        _ = try createLegacyDatabase(at: dbPath)
        try SQLCipherMigration.migrate(legacyPath: dbPath, profileKey: profileKey, salt: salt)

        let markerPath = dbPath + ".sqlcipher"
        let contents = try String(contentsOfFile: markerPath, encoding: .utf8)
        #expect(contents.contains("sqlcipher-v1"))
    }

    // MARK: - Audit Log with SQLCipher

    @Test func auditLogWithSQLCipherRoundTrips() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let dbPath = dir.appendingPathComponent("audit.sqlite").path

        let auditLog = try await GRDBAuditLog.make(
            path: dbPath,
            profileKey: profileKey,
            salt: salt,
            useSQLCipher: true
        )
        try await auditLog.append(AuditEntry(category: .sessionStarted, payload: ["k": "v"]))
        try await auditLog.append(AuditEntry(category: .agentCalled, payload: ["agent": "test"]))

        let entries = try await auditLog.entries(for: nil)
        #expect(entries.count == 2)
        #expect(try await auditLog.verifyChain())
    }
}
