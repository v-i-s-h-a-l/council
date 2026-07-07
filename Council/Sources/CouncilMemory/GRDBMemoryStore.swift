import CouncilCore
import CryptoKit
import Foundation
import GRDB

/// `MemoryStore` implementation backed by GRDB with encrypted sensitive columns.
public actor GRDBMemoryStore: MemoryStore {
    let dbQueue: DatabaseQueue
    private let databaseKey: Data

    public init(dbQueue: DatabaseQueue, profileKey: Data) throws {
        self.dbQueue = dbQueue
        self.databaseKey = Self.deriveDatabaseKey(from: profileKey)
        try Self.registerMigrations(dbQueue: dbQueue)
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

    // MARK: - Key derivation

    private static func deriveDatabaseKey(from profileKey: Data) -> Data {
        let inputKey = SymmetricKey(data: profileKey)
        let info = Data("com.council.memory.database.v1".utf8)
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
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
