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

    /// Returns recent episodic gists, newest first.
    public func recentEpisodes(limit: Int = 100) async throws -> [EpisodicGist] {
        let episodes = try await store.episodes(matching: MemoryFilter())
        return episodes.sorted { $0.createdAt > $1.createdAt }.prefix(limit).map { $0 }
    }

    /// Verifies the integrity of the audit chain.
    public func verifyAuditChain() async throws -> Bool {
        try await auditLog.verifyChain()
    }
}
