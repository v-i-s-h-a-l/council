import CouncilCore
import Foundation

/// Actor-isolated service exposing memory storage and audit logging.
public actor MemoryService {
    public let store: any MemoryStore
    public let auditLog: any AuditLog

    public init(store: any MemoryStore, auditLog: any AuditLog) {
        self.store = store
        self.auditLog = auditLog
    }

    /// Records an episodic gist for a completed deliberation.
    public func recordEpisode(
        sessionID: UUID,
        question: String,
        perspective: Perspective
    ) async throws {
        let gist = EpisodicGist(
            sessionID: sessionID,
            question: question,
            perspective: perspective
        )
        try await store.saveEpisode(gist)
    }

    /// Appends a structured audit entry.
    public func appendAuditEntry(
        category: AuditCategory,
        sessionID: UUID? = nil,
        payload: [String: String] = [:]
    ) async throws {
        let entry = AuditEntry(
            sessionID: sessionID,
            category: category,
            payload: payload
        )
        try await auditLog.append(entry)
    }

    /// Returns a single unlocked episodic gist by ID, if it exists.
    public func episode(id: UUID) async throws -> EpisodicGist? {
        let episodes = try await store.episodes(matching: MemoryFilter(locked: false))
        return episodes.first { $0.id == id }
    }

    /// Returns recent unlocked episodic gists, newest first.
    public func recentEpisodes(limit: Int = 100) async throws -> [EpisodicGist] {
        let episodes = try await store.episodes(matching: MemoryFilter(locked: false))
        return episodes.sorted { $0.createdAt > $1.createdAt }.prefix(limit).map { $0 }
    }

    /// Searches unlocked episodic gists by question substring, newest first.
    public func searchEpisodes(query: String, limit: Int = 100) async throws -> [EpisodicGist] {
        let episodes = try await store.episodes(matching: MemoryFilter(locked: false, subject: query))
        return episodes.sorted { $0.createdAt > $1.createdAt }.prefix(limit).map { $0 }
    }

    // MARK: - Temporal fact management

    @discardableResult
    public func addFact(
        subject: String,
        predicate: String,
        object: String,
        accessScope: [AccessPurpose] = [.purchaseDeliberation],
        deniedPurposes: [AccessPurpose] = []
    ) async throws -> TemporalFact {
        let fact = TemporalFact(
            subject: subject,
            predicate: predicate,
            object: object,
            accessScope: accessScope,
            deniedPurposes: deniedPurposes
        )
        try await store.saveFact(fact)
        return fact
    }

    public func facts(subject: String? = nil) async throws -> [TemporalFact] {
        try await store.temporalFacts(matching: MemoryFilter(locked: false, subject: subject))
    }

    /// Returns unlocked temporal facts authorized for the given purposes.
    ///
    /// A fact is authorized when the requested purposes overlap its `accessScope` and
    /// do not overlap its `deniedPurposes`. When `purposes` is non-empty, a single
    /// purpose-bound access decision is recorded in the audit log.
    public func facts(subject: String? = nil, purposes: [AccessPurpose]) async throws -> [TemporalFact] {
        let filter = MemoryFilter(purposes: purposes, locked: false, subject: subject)
        let results = try await store.temporalFacts(matching: filter)
        if !purposes.isEmpty {
            let purposeNames = purposes.map(\.rawValue).sorted().joined(separator: ",")
            try? await appendAuditEntry(
                category: .memoryAccess,
                payload: [
                    "purpose": purposeNames,
                    "dataElementType": "TemporalFact",
                    "decision": "allowed",
                    "count": "\(results.count)",
                ]
            )
        }
        return results
    }

    /// Verifies the integrity of the audit chain.
    public func verifyAuditChain() async throws -> Bool {
        try await auditLog.verifyChain()
    }
}
