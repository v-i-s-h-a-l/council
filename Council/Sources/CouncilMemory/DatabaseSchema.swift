import Foundation
import GRDB

// MARK: - Episodic gist

struct EpisodicGistRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "episodic_gists"

    var id: UUID
    var sessionID: UUID
    var question: String
    var createdAt: Date
    var isLocked: Bool

    // Encrypted JSON blobs.
    var summaryEncrypted: Data
    var tradeOffsEncrypted: Data
    var blindSpotsEncrypted: Data
    var dissentEncrypted: Data

    enum Columns {
        static let id = Column("id")
        static let sessionID = Column("sessionID")
        static let question = Column("question")
        static let createdAt = Column("createdAt")
        static let isLocked = Column("isLocked")
        static let summaryEncrypted = Column("summaryEncrypted")
        static let tradeOffsEncrypted = Column("tradeOffsEncrypted")
        static let blindSpotsEncrypted = Column("blindSpotsEncrypted")
        static let dissentEncrypted = Column("dissentEncrypted")
    }
}

// MARK: - Temporal fact

struct TemporalFactRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "temporal_facts"

    var id: UUID
    var subject: String
    var predicate: String
    var validFrom: Date?
    var validUntil: Date?
    var accessScopeJSON: String
    var isLocked: Bool

    // Encrypted JSON blob.
    var objectEncrypted: Data

    enum Columns {
        static let id = Column("id")
        static let subject = Column("subject")
        static let predicate = Column("predicate")
        static let validFrom = Column("validFrom")
        static let validUntil = Column("validUntil")
        static let accessScopeJSON = Column("accessScopeJSON")
        static let isLocked = Column("isLocked")
        static let objectEncrypted = Column("objectEncrypted")
    }
}

// MARK: - Audit log

struct AuditLogRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "audit_log"

    var id: UUID
    var sessionID: UUID?
    var timestamp: Date
    var category: String
    var previousHash: String
    var hmac: String

    // Encrypted JSON blob.
    var payloadEncrypted: Data

    enum Columns {
        static let id = Column("id")
        static let sessionID = Column("sessionID")
        static let timestamp = Column("timestamp")
        static let category = Column("category")
        static let previousHash = Column("previousHash")
        static let hmac = Column("hmac")
        static let payloadEncrypted = Column("payloadEncrypted")
    }
}
