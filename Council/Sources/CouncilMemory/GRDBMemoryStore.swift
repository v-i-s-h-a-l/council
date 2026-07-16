import CouncilCore
import CryptoKit
import Foundation
import GRDB
import Security

/// `MemoryStore` implementation backed by GRDB with encrypted sensitive columns.
///
/// When built against the SQLCipher fork of GRDB, the entire database file is
/// encrypted at the page level (full-database encryption). The existing
/// column-level AES-256-GCM encryption remains as defense-in-depth.
public actor GRDBMemoryStore: MemoryStore {
    enum GRDBMemoryStoreError: Error {
        case saltGenerationFailed
        case invalidSaltLength
        case sqlCipherKeyFailed(String)
    }

    let dbQueue: DatabaseQueue
    private let databaseKey: Data

    /// Creates a memory store.
    ///
    /// - Parameters:
    ///   - dbQueue: The GRDB database queue.
    ///   - profileKey: The profile key from which the database encryption key is derived.
    ///   - salt: Optional 16-byte salt. If supplied, it is used directly. If omitted, the salt is
    ///     loaded from `salt.bin` next to the database file, from the keychain as a fallback, or
    ///     generated randomly and persisted in both locations on first creation.
    ///   - useSQLCipher: When `true` (default), apply the derived key via `PRAGMA key` so the
    ///     entire database file is encrypted by SQLCipher. For file-based databases, the queue
    ///     should be created with ``sqlCipherConfiguration(key:)`` instead — see ``make(path:profileKey:salt:useSQLCipher:)``.
    ///     The `PRAGMA key` path here is only effective for in-memory databases.
    public init(dbQueue: DatabaseQueue, profileKey: Data, salt: Data? = nil, useSQLCipher: Bool = true) throws {
        self.dbQueue = dbQueue
        self.databaseKey = Self.deriveDatabaseKey(from: profileKey, salt: try Self.resolveSalt(dbQueue: dbQueue, injectedSalt: salt))
        if useSQLCipher {
            let path = dbQueue.path
            if path.isEmpty || path == ":memory:" {
                // In-memory databases: PRAGMA key works because there is no file header to conflict.
                try Self.applySQLCipherKey(dbQueue: dbQueue, key: databaseKey)
            }
            // File-based queues must be created with sqlCipherConfiguration(key:) so that
            // PRAGMA key runs inside prepareDatabase before GRDB touches the file.
        }
        try Self.registerMigrations(dbQueue: dbQueue)
    }

    /// Creates a memory store at the given file path.
    ///
    /// The containing directory is created automatically. A 16-byte salt is generated and
    /// persisted next to the database on first creation unless `salt` is supplied.
    ///
    /// When `useSQLCipher` is `true` (default), the database is opened with
    /// `Configuration.prepareDatabase` that applies `PRAGMA key` before any other SQL runs,
    /// ensuring the file is encrypted from the first page.
    ///
    /// - Parameters:
    ///   - path: File path for the SQLite database.
    ///   - profileKey: The profile key from which the database encryption key is derived.
    ///   - salt: Optional 16-byte salt. When provided, keychain fallback is skipped.
    ///   - useSQLCipher: When `true` (default), open the database with SQLCipher full-database
    ///     encryption using the derived key.
    public static func make(
        path: String,
        profileKey: Data,
        salt: Data? = nil,
        useSQLCipher: Bool = true
    ) async throws -> GRDBMemoryStore {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let resolvedSalt = try resolveSalt(forPath: path, injectedSalt: salt)
        let databaseKey = deriveDatabaseKey(from: profileKey, salt: resolvedSalt)
        let dbQueue: DatabaseQueue
        if useSQLCipher {
            let config = sqlCipherConfiguration(key: databaseKey)
            dbQueue = try DatabaseQueue(path: path, configuration: config)
        } else {
            dbQueue = try DatabaseQueue(path: path)
        }
        // Key is already applied via prepareDatabase; pass useSQLCipher: false to skip re-applying.
        let store = try GRDBMemoryStore(dbQueue: dbQueue, profileKey: profileKey, salt: resolvedSalt, useSQLCipher: false)

        // Write the SQLCipher marker so future launches don't misdetect this as a legacy database.
        if useSQLCipher {
            try? Data("sqlcipher-v1\n".utf8).write(
                to: URL(fileURLWithPath: SQLCipherMigration.markerPath(for: path))
            )
        }

        return store
    }

    // MARK: - Episodes

    public func saveEpisode(_ episode: EpisodicGist) async throws {
        try await dbQueue.write { [databaseKey] db in
            var record = try EpisodicGistRecord(episode: episode, key: databaseKey)
            try record.save(db)
        }
    }

    public func episodes(matching filter: MemoryFilter) async throws -> [EpisodicGist] {
        try await dbQueue.read { [databaseKey] db in
            var request = EpisodicGistRecord.all()
            if let locked = filter.locked {
                request = request.filter(EpisodicGistRecord.Columns.isLocked == locked)
            }
            let records = try request.fetchAll(db)
            return try records.compactMap { try $0.toGist(key: databaseKey) }
        }.filter { episode in
            if let subject = filter.subject {
                return episode.question.localizedStandardContains(subject)
            }
            return true
        }
    }

    public func updateEpisode(_ episode: EpisodicGist) async throws {
        try await dbQueue.write { [databaseKey] db in
            _ = try EpisodicGistRecord
                .filter(EpisodicGistRecord.Columns.id == episode.id)
                .deleteAll(db)
            var record = try EpisodicGistRecord(episode: episode, key: databaseKey)
            try record.insert(db)
        }
    }

    public func deleteEpisode(id: UUID) async throws {
        try await dbQueue.write { db in
            _ = try EpisodicGistRecord
                .filter(EpisodicGistRecord.Columns.id == id)
                .deleteAll(db)
        }
    }

    public func lockEpisode(id: UUID, isLocked: Bool) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE \(EpisodicGistRecord.databaseTableName) SET isLocked = ? WHERE id = ?",
                arguments: [isLocked, id]
            )
        }
    }

    // MARK: - Facts

    public func temporalFacts(for purpose: AccessPurpose) async throws -> [TemporalFact] {
        try await temporalFacts(matching: MemoryFilter(purposes: [purpose]))
            .filter { !$0.isLocked && $0.accessScope.contains(purpose) && !$0.deniedPurposes.contains(purpose) }
    }

    public func temporalFacts(matching filter: MemoryFilter) async throws -> [TemporalFact] {
        try await dbQueue.read { [databaseKey] db in
            var request = TemporalFactRecord.all()
            if let locked = filter.locked {
                request = request.filter(TemporalFactRecord.Columns.isLocked == locked)
            }
            if let subject = filter.subject {
                request = request.filter(TemporalFactRecord.Columns.subject == subject)
            }
            let records = try request.fetchAll(db)
            return try records.compactMap { try $0.toFact(key: databaseKey) }
        }.filter { fact in
            if let purposes = filter.purposes {
                let purposeSet = Set(purposes)
                let scopeSet = Set(fact.accessScope)
                let deniedSet = Set(fact.deniedPurposes)
                // Authorized iff request overlaps accessScope AND does not overlap deniedPurposes.
                return !purposeSet.isDisjoint(with: scopeSet)
                    && purposeSet.isDisjoint(with: deniedSet)
            }
            return true
        }
    }

    public func saveFact(_ fact: TemporalFact) async throws {
        try await dbQueue.write { [databaseKey] db in
            var record = try TemporalFactRecord(fact: fact, key: databaseKey)
            try record.save(db)
        }
    }

    public func deleteFact(id: UUID) async throws {
        try await dbQueue.write { db in
            _ = try TemporalFactRecord
                .filter(TemporalFactRecord.Columns.id == id)
                .deleteAll(db)
        }
    }

    // MARK: - Salt resolution and key derivation

    /// Resolves the salt for a database identified by its queue (used by `init`).
    static func resolveSalt(dbQueue: DatabaseQueue, injectedSalt: Data?) throws -> Data {
        try resolveSalt(forPath: dbQueue.path, injectedSalt: injectedSalt)
    }

    /// Resolves the salt for a database identified by its file path.
    ///
    /// When the path is empty or `:memory:`, an ephemeral (non-persisted) salt is generated.
    /// Otherwise the salt is loaded from `salt.bin` next to the database, from the keychain as a
    /// fallback, or generated randomly and persisted in both locations on first creation.
    static func resolveSalt(forPath path: String, injectedSalt: Data?) throws -> Data {
        if let injectedSalt {
            guard injectedSalt.count == 16 else {
                throw GRDBMemoryStoreError.invalidSaltLength
            }
            return injectedSalt
        }

        if path.isEmpty || path == ":memory:" {
            // In-memory database: generate an ephemeral salt that is not persisted.
            return try generateRandomSalt()
        }

        let saltURL = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("salt.bin")
        let saltKeychainItem = KeychainItem(service: "com.council.memory.salt", account: path)

        if FileManager.default.fileExists(atPath: saltURL.path),
           let salt = try? Data(contentsOf: saltURL),
           salt.count == 16 {
            return salt
        }

        if let salt = try saltKeychainItem.load(), salt.count == 16 {
            // Restore the salt to the file as defense-in-depth.
            try? salt.write(to: saltURL, options: .completeFileProtectionUnlessOpen)
            return salt
        }

        let salt = try generateRandomSalt()
        try salt.write(to: saltURL, options: .completeFileProtectionUnlessOpen)
        try saltKeychainItem.save(data: salt)
        return salt
    }

    private static func generateRandomSalt() throws -> Data {
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw GRDBMemoryStoreError.saltGenerationFailed
        }
        return salt
    }

    static func deriveDatabaseKey(from profileKey: Data, salt: Data) -> Data {
        let inputKey = SymmetricKey(data: profileKey)
        let info = Data("com.council.memory.database.v1".utf8)
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: salt,
            info: info,
            outputByteCount: 32
        )
        return derived.withUnsafeBytes { Data($0) }
    }

    private static func registerMigrations(dbQueue: DatabaseQueue) throws {
        try DatabaseMigrator.migrator().migrate(dbQueue)
    }

    // MARK: - SQLCipher

    /// Applies the derived 32-byte key to the database via `PRAGMA key` in raw-key mode.
    ///
    /// The hex string is the lower-case representation of the 32-byte `databaseKey`, formatted as
    /// `x'<64-hex-characters>'`. This avoids an additional PBKDF2 round and preserves the existing
    /// key hierarchy.
    ///
    /// Must be called before any other database operations (migrations, reads, writes).
    /// For `DatabaseQueue` (single connection), calling once is sufficient.
    static func applySQLCipherKey(dbQueue: DatabaseQueue, key: Data) throws {
        let hexKey = key.map { String(format: "%02x", $0) }.joined()
        let rawKey = "x'\(hexKey)'"
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA key = \"\(rawKey)\"")
        }
    }

    /// Returns a GRDB `Configuration` that applies `PRAGMA key` via `prepareDatabase`.
    ///
    /// Use this when creating a `DatabaseQueue` for a file-based database so that the SQLCipher
    /// key is set before GRDB runs any other SQL (including its own `PRAGMA journal_mode` etc.).
    ///
    /// - Parameter key: The 32-byte derived database key.
    /// - Returns: A `Configuration` suitable for `DatabaseQueue(path:configuration:)`.
    static func sqlCipherConfiguration(key: Data) -> Configuration {
        let hexKey = key.map { String(format: "%02x", $0) }.joined()
        let rawKey = "x'\(hexKey)'"
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA key = \"\(rawKey)\"")
        }
        return config
    }
}

// MARK: - Conversions

extension EpisodicGistRecord {
    init(episode: EpisodicGist, key: Data) throws {
        self.id = episode.id
        self.sessionID = episode.sessionID
        self.question = episode.question
        self.createdAt = episode.createdAt
        self.isLocked = episode.isLocked

        let perspective = episode.perspective
        let encoder = JSONEncoder()
        self.summaryEncrypted = try FieldEncryption.encrypt(
            plaintext: Data(perspective.summary.utf8),
            key: key
        )
        self.tradeOffsEncrypted = try FieldEncryption.encrypt(
            plaintext: try encoder.encode(perspective.tradeOffs),
            key: key
        )
        self.blindSpotsEncrypted = try FieldEncryption.encrypt(
            plaintext: try encoder.encode(perspective.blindSpots),
            key: key
        )
        self.dissentEncrypted = try FieldEncryption.encrypt(
            plaintext: try encoder.encode(perspective.dissent),
            key: key
        )
    }

    func toGist(key: Data) throws -> EpisodicGist {
        let decoder = JSONDecoder()
        let summaryData = try FieldEncryption.decrypt(ciphertext: summaryEncrypted, key: key)
        let summary = String(data: summaryData, encoding: .utf8) ?? ""
        let tradeOffs = try decoder.decode([String].self, from: try FieldEncryption.decrypt(ciphertext: tradeOffsEncrypted, key: key))
        let blindSpots = try decoder.decode([String].self, from: try FieldEncryption.decrypt(ciphertext: blindSpotsEncrypted, key: key))
        let dissent = try decoder.decode([String].self, from: try FieldEncryption.decrypt(ciphertext: dissentEncrypted, key: key))

        return EpisodicGist(
            id: id,
            sessionID: sessionID,
            question: question,
            createdAt: createdAt,
            perspective: Perspective(
                summary: summary,
                tradeOffs: tradeOffs,
                blindSpots: blindSpots,
                dissent: dissent
            ),
            isLocked: isLocked
        )
    }
}

extension TemporalFactRecord {
    init(fact: TemporalFact, key: Data) throws {
        self.id = fact.id
        self.subject = fact.subject
        self.predicate = fact.predicate
        self.validFrom = fact.validFrom
        self.validUntil = fact.validUntil
        self.isLocked = fact.isLocked
        let encoder = JSONEncoder()
        self.accessScopeJSON = String(data: try encoder.encode(fact.accessScope), encoding: .utf8) ?? "[]"
        self.deniedPurposesJSON = String(data: try encoder.encode(fact.deniedPurposes), encoding: .utf8) ?? "[]"
        self.objectEncrypted = try FieldEncryption.encrypt(
            plaintext: Data(fact.object.utf8),
            key: key
        )
    }

    func toFact(key: Data) throws -> TemporalFact {
        let decoder = JSONDecoder()
        let objectData = try FieldEncryption.decrypt(ciphertext: objectEncrypted, key: key)
        let object = String(data: objectData, encoding: .utf8) ?? ""
        let accessScope = try decoder.decode([AccessPurpose].self, from: Data(accessScopeJSON.utf8))
        // deniedPurposesJSON is NOT NULL DEFAULT '[]' (v2 migration); tolerate absence defensively.
        let deniedPurposes = (try? decoder.decode([AccessPurpose].self, from: Data(deniedPurposesJSON.utf8))) ?? []

        return TemporalFact(
            id: id,
            subject: subject,
            predicate: predicate,
            object: object,
            validFrom: validFrom,
            validUntil: validUntil,
            accessScope: accessScope,
            deniedPurposes: deniedPurposes,
            isLocked: isLocked
        )
    }
}
