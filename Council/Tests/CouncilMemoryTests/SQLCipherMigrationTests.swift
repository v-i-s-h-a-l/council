import CouncilCore
@testable import CouncilMemory
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
    ///
    /// Built through the real store and audit-log implementations so the migration
    /// is tested against a realistic legacy artifact — including a genuine
    /// HMAC-chained audit entry — instead of a hand-rolled reimplementation of the
    /// audit canonicalization.
    private func createLegacyDatabase(at path: String) async throws -> (episodeIDs: [UUID], factIDs: [UUID], auditIDs: [UUID]) {
        let auditLog = try await GRDBAuditLog.make(
            path: path,
            profileKey: profileKey,
            salt: salt,
            useSQLCipher: false
        )
        let store = try GRDBMemoryStore(
            dbQueue: await auditLog.dbQueue,
            profileKey: profileKey,
            salt: salt,
            useSQLCipher: false
        )

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
        try await store.saveEpisode(episode)
        try await store.saveFact(fact)

        let auditEntry = AuditEntry(
            sessionID: UUID(),
            category: .sessionStarted,
            payload: ["test": "migration"]
        )
        try await auditLog.append(auditEntry)

        return ([episode.id], [fact.id], [auditEntry.id])
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

    // MARK: - Migration

    @Test func migratePreservesAllData() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let dbPath = dir.appendingPathComponent("memory.sqlite").path

        // Create legacy database with known data.
        let (episodeIDs, factIDs, auditIDs) = try await createLegacyDatabase(at: dbPath)

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

    @Test func rollbackRestoresLegacyDatabase() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let dbPath = dir.appendingPathComponent("memory.sqlite").path

        // Create and migrate legacy database.
        _ = try await createLegacyDatabase(at: dbPath)
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
        let facts = try await plainQueue.read { db in
            try TemporalFactRecord.fetchAll(db)
        }
        #expect(facts.count == 1)
    }

    @Test func migrateTwiceFailsCleanlyAndPreservesData() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let dbPath = dir.appendingPathComponent("memory.sqlite").path

        _ = try await createLegacyDatabase(at: dbPath)
        let result = try SQLCipherMigration.migrate(
            legacyPath: dbPath,
            profileKey: profileKey,
            salt: salt
        )
        #expect(SQLCipherMigration.isMigrated(at: dbPath))

        // Second run: the legacy path now holds an encrypted database, so migration
        // must fail loudly — and leave the working database, backup, and marker intact.
        #expect(throws: SQLCipherMigration.MigrationError.self) {
            try SQLCipherMigration.migrate(legacyPath: dbPath, profileKey: profileKey, salt: salt)
        }

        #expect(SQLCipherMigration.isMigrated(at: dbPath))
        #expect(FileManager.default.fileExists(atPath: result.backupPath))
        #expect(!FileManager.default.fileExists(atPath: dbPath + ".next"))

        let store = try await GRDBMemoryStore.make(
            path: dbPath,
            profileKey: profileKey,
            salt: salt,
            useSQLCipher: true
        )
        #expect(try await store.episodes(matching: MemoryFilter()).count == 1)
        #expect(try await store.temporalFacts(matching: MemoryFilter()).count == 1)
        let auditRecords = try await store.dbQueue.read { db in
            try AuditLogRecord.fetchAll(db)
        }
        #expect(auditRecords.count == 1)
    }

    @Test func migrationFailureLeavesLegacyDatabaseUntouched() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let dbPath = dir.appendingPathComponent("memory.sqlite").path

        // A "legacy database" that is not a database at all cannot be opened.
        let garbage = Data("definitely not sqlite".utf8)
        try garbage.write(to: URL(fileURLWithPath: dbPath))

        #expect(throws: SQLCipherMigration.MigrationError.self) {
            try SQLCipherMigration.migrate(legacyPath: dbPath, profileKey: profileKey, salt: salt)
        }

        // The original file is byte-identical, and no marker or partial output remains.
        #expect(try Data(contentsOf: URL(fileURLWithPath: dbPath)) == garbage)
        #expect(!SQLCipherMigration.isMigrated(at: dbPath))
        #expect(!FileManager.default.fileExists(atPath: dbPath + ".next"))
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
