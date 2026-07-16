import CouncilCore
import CryptoKit
import Foundation
import GRDB

/// `AuditLog` implementation backed by GRDB with an HMAC-SHA256 chain.
///
/// When built against the SQLCipher fork of GRDB, the entire database file is
/// encrypted at the page level (full-database encryption).
public actor GRDBAuditLog: AuditLog {
    let dbQueue: DatabaseQueue
    private let hmacKey: SymmetricKey

    /// Creates an audit log.
    ///
    /// - Parameters:
    ///   - dbQueue: The GRDB database queue.
    ///   - profileKey: The profile key from which the audit HMAC key is derived.
    ///   - salt: Optional 16-byte salt used to derive the SQLCipher database key. When
    ///     `useSQLCipher` is `true` the salt is resolved the same way as `GRDBMemoryStore`.
    ///   - useSQLCipher: When `true` (default), apply the SQLCipher key so the audit database
    ///     file is encrypted at the page level. For file-based databases, the queue should be
    ///     created with `GRDBMemoryStore.sqlCipherConfiguration(key:)`. The `PRAGMA key` path
    ///     here is only effective for in-memory databases.
    public init(dbQueue: DatabaseQueue, profileKey: Data, salt: Data? = nil, useSQLCipher: Bool = true) throws {
        self.dbQueue = dbQueue
        self.hmacKey = Self.deriveAuditKey(from: profileKey)
        if useSQLCipher {
            let path = dbQueue.path
            if path.isEmpty || path == ":memory:" {
                if let salt, salt.count == 16 {
                    // Explicit salt provided — safe to apply the key.
                    let databaseKey = GRDBMemoryStore.deriveDatabaseKey(from: profileKey, salt: salt)
                    try GRDBMemoryStore.applySQLCipherKey(dbQueue: dbQueue, key: databaseKey)
                } else if !Self.hasExistingTables(dbQueue) {
                    // No tables yet — fresh database, safe to apply key with ephemeral salt.
                    let resolvedSalt = try GRDBMemoryStore.resolveSalt(dbQueue: dbQueue, injectedSalt: salt)
                    let databaseKey = GRDBMemoryStore.deriveDatabaseKey(from: profileKey, salt: resolvedSalt)
                    try GRDBMemoryStore.applySQLCipherKey(dbQueue: dbQueue, key: databaseKey)
                }
                // else: database already has tables (shared queue with GRDBMemoryStore) — skip.
            }
            // File-based queues must be created with sqlCipherConfiguration(key:) — see make(path:).
        }
        try DatabaseMigrator.migrator().migrate(dbQueue)
    }

    /// Returns `true` if the database already has user tables, indicating it has been set up
    /// (and possibly already keyed by a shared `GRDBMemoryStore` on the same queue).
    private static func hasExistingTables(_ dbQueue: DatabaseQueue) -> Bool {
        let count = (try? dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM sqlite_master
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations'
                """) ?? 0
        }) ?? 0
        return count > 0
    }

    /// Creates an audit log at the given file path.
    ///
    /// When `useSQLCipher` is `true` (default), the database is opened with
    /// `Configuration.prepareDatabase` that applies `PRAGMA key` before any other SQL runs.
    public static func make(path: String, profileKey: Data, salt: Data? = nil, useSQLCipher: Bool = true) async throws -> GRDBAuditLog {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let resolvedSalt = try GRDBMemoryStore.resolveSalt(forPath: path, injectedSalt: salt)
        let databaseKey = GRDBMemoryStore.deriveDatabaseKey(from: profileKey, salt: resolvedSalt)
        let dbQueue: DatabaseQueue
        if useSQLCipher {
            let config = GRDBMemoryStore.sqlCipherConfiguration(key: databaseKey)
            dbQueue = try DatabaseQueue(path: path, configuration: config)
        } else {
            dbQueue = try DatabaseQueue(path: path)
        }
        // Key already applied via prepareDatabase; pass useSQLCipher: false to skip re-applying.
        return try GRDBAuditLog(dbQueue: dbQueue, profileKey: profileKey, salt: resolvedSalt, useSQLCipher: false)
    }

    public func append(_ entry: AuditEntry) async throws {
        var mutableEntry = entry
        let previousHash = try await latestHash() ?? Self.genesisHash()
        mutableEntry.previousHash = previousHash
        mutableEntry.hmac = try Self.hmac(for: mutableEntry, key: hmacKey)

        try await dbQueue.write { [hmacKey, mutableEntry] db in
            var record = try AuditLogRecord(entry: mutableEntry, key: hmacKey)
            try record.save(db)
        }
    }

    public func entries(for sessionID: UUID?) async throws -> [AuditEntry] {
        try await dbQueue.read { db in
            let records = try AuditLogRecord
                .order(AuditLogRecord.Columns.timestamp)
                .fetchAll(db)
            return try records
                .filter { record in
                    guard let sessionID else { return true }
                    return record.sessionID == sessionID
                }
                .map { try $0.toEntry(key: self.hmacKey) }
        }
    }

    public func entries(
        since: Date?,
        limit: Int?,
        includePayloads: Bool
    ) async throws -> [AuditEntry] {
        if includePayloads {
            let all = try await entries(for: nil)
            let filtered = since.map { sinceDate in
                all.filter { $0.timestamp >= sinceDate }
            } ?? all
            let sorted = filtered.sorted { $0.timestamp > $1.timestamp }
            return limit.map { Array(sorted.prefix($0)) } ?? sorted
        }

        return try await dbQueue.read { db in
            var request = AuditLogRecord
                .select(
                    AuditLogRecord.Columns.id,
                    AuditLogRecord.Columns.sessionID,
                    AuditLogRecord.Columns.timestamp,
                    AuditLogRecord.Columns.category,
                    AuditLogRecord.Columns.previousHash,
                    AuditLogRecord.Columns.hmac
                )
                .order(AuditLogRecord.Columns.timestamp.desc)
            if let since {
                request = request.filter(AuditLogRecord.Columns.timestamp >= since)
            }
            if let limit {
                request = request.limit(limit)
            }
            let rows = try Row.fetchAll(db, request)
            return rows.map { row in
                AuditEntry(
                    id: row[AuditLogRecord.Columns.id],
                    sessionID: row[AuditLogRecord.Columns.sessionID],
                    timestamp: row[AuditLogRecord.Columns.timestamp],
                    category: AuditCategory(rawValue: row[AuditLogRecord.Columns.category]) ?? .error,
                    payload: [:],
                    previousHash: row[AuditLogRecord.Columns.previousHash],
                    hmac: row[AuditLogRecord.Columns.hmac]
                )
            }
        }
    }

    /// Verifies the integrity of the entire audit chain.
    public func verifyChain() async throws -> Bool {
        let records = try await allRecordsOrdered()
        var previousHash = Self.genesisHash()

        for record in records {
            guard record.previousHash == previousHash else { return false }
            let entry = try record.toEntry(key: hmacKey)
            let expectedHMAC = try Self.hmac(for: entry, key: hmacKey)
            guard record.hmac == expectedHMAC else { return false }
            previousHash = record.hmac
        }

        return true
    }

    // MARK: - Private helpers

    private func latestHash() async throws -> String? {
        let records = try await allRecordsOrdered()
        return records.last?.hmac
    }

    private func allRecordsOrdered() async throws -> [AuditLogRecord] {
        try await dbQueue.read { db in
            try AuditLogRecord
                .order(AuditLogRecord.Columns.timestamp)
                .fetchAll(db)
        }
    }

    private static func genesisHash() -> String {
        let data = Data("COUNCIL_AUDIT_GENESIS_v1".utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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

    private static func canonicalJSON(for entry: AuditEntry) throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let sortedPayload = entry.payload.sorted { $0.key < $1.key }
        let payloadObject: [String: String] = Dictionary(uniqueKeysWithValues: sortedPayload)

        let object: [String: Any] = [
            "id": entry.id.uuidString,
            "timestamp": formatter.string(from: entry.timestamp),
            "category": entry.category.rawValue,
            "payload": payloadObject,
            "previousHash": entry.previousHash,
        ]

        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func hmac(for entry: AuditEntry, key: SymmetricKey) throws -> String {
        let data = try canonicalJSON(for: entry)
        let code = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return code.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Audit log conversions

extension AuditLogRecord {
    init(entry: AuditEntry, key: SymmetricKey) throws {
        self.id = entry.id
        self.sessionID = entry.sessionID
        self.timestamp = entry.timestamp
        self.category = entry.category.rawValue
        self.previousHash = entry.previousHash
        self.hmac = entry.hmac
        let payloadData = try JSONEncoder().encode(entry.payload)
        self.payloadEncrypted = try FieldEncryption.encrypt(plaintext: payloadData, key: key.withUnsafeBytes { Data($0) })
    }

    func toEntry(key: SymmetricKey) throws -> AuditEntry {
        let payloadData = try FieldEncryption.decrypt(
            ciphertext: payloadEncrypted,
            key: key.withUnsafeBytes { Data($0) }
        )
        let payload = try JSONDecoder().decode([String: String].self, from: payloadData)
        return AuditEntry(
            id: id,
            sessionID: sessionID,
            timestamp: timestamp,
            category: AuditCategory(rawValue: category) ?? .error,
            payload: payload,
            previousHash: previousHash,
            hmac: hmac
        )
    }
}
