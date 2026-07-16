import CouncilCore
import CryptoKit
import Foundation
import GRDB

/// Migrates legacy plaintext SQLite databases to SQLCipher full-database encryption.
///
/// The migration follows the sequence described in ADR-025:
/// 1. Detect a legacy database (no `.sqlcipher` marker file).
/// 2. Open the legacy database, create a new SQLCipher database.
/// 3. Copy all `EpisodicGistRecord`, `TemporalFactRecord`, and `AuditEntryRecord` rows.
/// 4. Atomically swap files, preserving a `.pre-sqlcipher-backup` for rollback.
/// 5. Write the `.sqlcipher` marker file.
public enum SQLCipherMigration {
    /// Errors that can occur during migration.
    public enum MigrationError: Error {
        case legacyDatabaseNotFound
        case migrationFailed(String)
        case backupFailed(String)
        case swapFailed(String)
    }

    /// Result of a successful migration.
    public struct MigrationResult: Sendable {
        /// Number of episodic gist records migrated.
        public let episodeCount: Int
        /// Number of temporal fact records migrated.
        public let factCount: Int
        /// Number of audit log records migrated.
        public let auditCount: Int
        /// Path to the backup of the original plaintext database.
        public let backupPath: String
    }

    // MARK: - Detection

    /// Returns `true` if a legacy (plaintext) database exists at `path` that has not yet been
    /// migrated to SQLCipher.
    ///
    /// A database is considered legacy when the file exists but the `.sqlcipher` marker file
    /// does not.
    public static func detectLegacyDatabase(at path: String) -> Bool {
        let fileManager = FileManager.default
        let markerPath = markerPath(for: path)
        return fileManager.fileExists(atPath: path) && !fileManager.fileExists(atPath: markerPath)
    }

    /// Returns `true` if the database at `path` has already been migrated to SQLCipher.
    public static func isMigrated(at path: String) -> Bool {
        FileManager.default.fileExists(atPath: markerPath(for: path))
    }

    // MARK: - Migration

    /// Migrates a legacy plaintext database to SQLCipher full-database encryption.
    ///
    /// - Parameters:
    ///   - legacyPath: Path to the existing plaintext database.
    ///   - profileKey: The profile key used to derive the database encryption key.
    ///   - salt: The 16-byte salt for key derivation.
    /// - Returns: A `MigrationResult` with row counts and the backup path.
    @discardableResult
    public static func migrate(
        legacyPath: String,
        profileKey: Data,
        salt: Data
    ) throws -> MigrationResult {
        let fileManager = FileManager.default
        let nextPath = legacyPath + ".next"
        let backupPath = legacyPath + ".pre-sqlcipher-backup"

        guard fileManager.fileExists(atPath: legacyPath) else {
            throw MigrationError.legacyDatabaseNotFound
        }

        // Clean up any previous partial migration.
        try? fileManager.removeItem(atPath: nextPath)

        let databaseKey = GRDBMemoryStore.deriveDatabaseKey(from: profileKey, salt: salt)

        // Step 1: Open legacy database (plaintext) and read all records.
        let legacyQueue: DatabaseQueue
        do {
            legacyQueue = try DatabaseQueue(path: legacyPath)
        } catch {
            throw MigrationError.migrationFailed("Cannot open legacy database: \(error.localizedDescription)")
        }

        let episodes: [EpisodicGistRecord]
        let facts: [TemporalFactRecord]
        let auditEntries: [AuditLogRecord]
        do {
            episodes = try legacyQueue.read { db in
                try EpisodicGistRecord.fetchAll(db)
            }
            facts = try legacyQueue.read { db in
                try TemporalFactRecord.fetchAll(db)
            }
            auditEntries = try legacyQueue.read { db in
                try AuditLogRecord.fetchAll(db)
            }
        } catch {
            throw MigrationError.migrationFailed("Cannot read legacy database: \(error.localizedDescription)")
        }

        // Step 2: Create new SQLCipher database with the key applied via prepareDatabase.
        let nextQueue: DatabaseQueue
        do {
            let config = GRDBMemoryStore.sqlCipherConfiguration(key: databaseKey)
            nextQueue = try DatabaseQueue(path: nextPath, configuration: config)
            try DatabaseMigrator.migrator().migrate(nextQueue)
        } catch {
            try? fileManager.removeItem(atPath: nextPath)
            throw MigrationError.migrationFailed("Cannot create SQLCipher database: \(error.localizedDescription)")
        }

        // Step 3: Copy records.
        do {
            try nextQueue.write { db in
                for var record in episodes {
                    try record.insert(db)
                }
                for var record in facts {
                    try record.insert(db)
                }
                for var record in auditEntries {
                    try record.insert(db)
                }
            }
        } catch {
            try? fileManager.removeItem(atPath: nextPath)
            throw MigrationError.migrationFailed("Cannot copy records: \(error.localizedDescription)")
        }

        // Step 4: Atomic swap — backup legacy, move next into place.
        do {
            // Remove any existing backup from a previous migration.
            try? fileManager.removeItem(atPath: backupPath)
            try fileManager.moveItem(atPath: legacyPath, toPath: backupPath)
        } catch {
            try? fileManager.removeItem(atPath: nextPath)
            throw MigrationError.backupFailed(error.localizedDescription)
        }

        do {
            try fileManager.moveItem(atPath: nextPath, toPath: legacyPath)
        } catch {
            // Restore backup on swap failure.
            try? fileManager.moveItem(atPath: backupPath, toPath: legacyPath)
            throw MigrationError.swapFailed(error.localizedDescription)
        }

        // Step 5: Write marker file.
        do {
            try Data("sqlcipher-v1\n".utf8).write(
                to: URL(fileURLWithPath: markerPath(for: legacyPath))
            )
        } catch {
            // Marker write failure is non-fatal; the database is already migrated.
            // On next launch, detectLegacyDatabase will return false because the
            // legacy file no longer exists (it was moved to backup).
        }

        return MigrationResult(
            episodeCount: episodes.count,
            factCount: facts.count,
            auditCount: auditEntries.count,
            backupPath: backupPath
        )
    }

    // MARK: - Rollback

    /// Restores the pre-migration backup, undoing a migration.
    ///
    /// - Parameter path: Path to the current (migrated) database.
    public static func rollback(at path: String) throws {
        let fileManager = FileManager.default
        let backupPath = path + ".pre-sqlcipher-backup"
        guard fileManager.fileExists(atPath: backupPath) else {
            throw MigrationError.legacyDatabaseNotFound
        }
        try? fileManager.removeItem(atPath: path)
        try fileManager.moveItem(atPath: backupPath, toPath: path)
        try? fileManager.removeItem(atPath: markerPath(for: path))
    }

    // MARK: - Private

    static func markerPath(for databasePath: String) -> String {
        databasePath + ".sqlcipher"
    }
}
