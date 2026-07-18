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
        perspective: Perspective,
        deniedPurposes: [AccessPurpose] = []
    ) async throws {
        let gist = EpisodicGist(
            sessionID: sessionID,
            question: question,
            perspective: perspective,
            deniedPurposes: deniedPurposes
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
    /// do not overlap its `deniedPurposes`. When `purposes` is non-empty, the access
    /// decision is recorded in the audit log: one aggregate entry for the allowed
    /// facts and one entry per denied fact so users can verify exclusions.
    public func facts(subject: String? = nil, purposes: [AccessPurpose]) async throws -> [TemporalFact] {
        let all = try await store.temporalFacts(matching: MemoryFilter(locked: false, subject: subject))
        let request = Set(purposes)
        var allowed: [TemporalFact] = []
        var denied: [TemporalFact] = []
        for fact in all {
            let isAllowed = !request.isDisjoint(with: Set(fact.accessScope))
                && request.isDisjoint(with: Set(fact.deniedPurposes))
            if isAllowed {
                allowed.append(fact)
            } else {
                denied.append(fact)
            }
        }
        if !purposes.isEmpty {
            let purposeNames = purposes.map(\.rawValue).sorted().joined(separator: ",")
            try? await appendAuditEntry(
                category: .memoryAccess,
                payload: [
                    "purpose": purposeNames,
                    "dataElementType": "TemporalFact",
                    "decision": "allowed",
                    "count": "\(allowed.count)",
                ]
            )
            for fact in denied {
                try? await appendAuditEntry(
                    category: .memoryAccess,
                    payload: [
                        "purpose": purposeNames,
                        "dataElementType": "TemporalFact",
                        "decision": "denied",
                        "elementID": fact.id.uuidString,
                    ]
                )
            }
        }
        return allowed
    }

    /// Verifies the integrity of the audit chain.
    public func verifyAuditChain() async throws -> Bool {
        try await auditLog.verifyChain()
    }
}
