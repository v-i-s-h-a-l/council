import CouncilCore
import CryptoKit
import Foundation
import GRDB

/// `AuditLog` implementation backed by GRDB with an HMAC-SHA256 chain.
public actor GRDBAuditLog: AuditLog {
    let dbQueue: DatabaseQueue
    private let hmacKey: SymmetricKey

    public init(dbQueue: DatabaseQueue, profileKey: Data) throws {
        self.dbQueue = dbQueue
        self.hmacKey = Self.deriveAuditKey(from: profileKey)
        try DatabaseMigrator.migrator().migrate(dbQueue)
    }

    /// Creates an audit log at the given file path.
    public static func make(path: String, profileKey: Data) async throws -> GRDBAuditLog {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let dbQueue = try DatabaseQueue(path: path)
        return try GRDBAuditLog(dbQueue: dbQueue, profileKey: profileKey)
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
