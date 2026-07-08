import CouncilCore
import CryptoKit
import Foundation
import GRDB
import Security

/// `MemoryStore` implementation backed by GRDB with encrypted sensitive columns.
public actor GRDBMemoryStore: MemoryStore {
    enum GRDBMemoryStoreError: Error {
        case saltGenerationFailed
        case invalidSaltLength
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
    public init(dbQueue: DatabaseQueue, profileKey: Data, salt: Data? = nil) throws {
        self.dbQueue = dbQueue
        self.databaseKey = Self.deriveDatabaseKey(from: profileKey, salt: try Self.resolveSalt(dbQueue: dbQueue, injectedSalt: salt))
        try Self.registerMigrations(dbQueue: dbQueue)
    }

    /// Creates a memory store at the given file path.
    ///
    /// The containing directory is created automatically. A 16-byte salt is generated and
    /// persisted next to the database on first creation unless `salt` is supplied.
    ///
    /// - Parameters:
    ///   - path: File path for the SQLite database.
    ///   - profileKey: The profile key from which the database encryption key is derived.
    ///   - salt: Optional 16-byte salt. When provided, keychain fallback is skipped.
    public static func make(
        path: String,
        profileKey: Data,
        salt: Data? = nil
    ) async throws -> GRDBMemoryStore {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let dbQueue = try DatabaseQueue(path: path)
        return try GRDBMemoryStore(dbQueue: dbQueue, profileKey: profileKey, salt: salt)
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
            .filter { !$0.isLocked && $0.accessScope.contains(purpose) }
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
                return !purposeSet.isDisjoint(with: scopeSet)
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

    private static func resolveSalt(dbQueue: DatabaseQueue, injectedSalt: Data?) throws -> Data {
        if let injectedSalt {
            guard injectedSalt.count == 16 else {
                throw GRDBMemoryStoreError.invalidSaltLength
            }
            return injectedSalt
        }

        let path = dbQueue.path
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

    private static func deriveDatabaseKey(from profileKey: Data, salt: Data) -> Data {
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

        return TemporalFact(
            id: id,
            subject: subject,
            predicate: predicate,
            object: object,
            validFrom: validFrom,
            validUntil: validUntil,
            accessScope: accessScope,
            isLocked: isLocked
        )
    }
}
