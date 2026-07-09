import CouncilCore
import Foundation

/// In-memory actor conforming to `AuditLog` for testing.
public actor MockAuditLog: AuditLog {
    public private(set) var entries: [AuditEntry] = []

    public init() {}

    public func append(_ entry: AuditEntry) async throws {
        entries.append(entry)
    }

    public func entries(for sessionID: UUID?) async throws -> [AuditEntry] {
        if let sessionID {
            return entries.filter { $0.sessionID == sessionID }
        }
        return entries
    }

    public func entries(since: Date?, limit: Int?, includePayloads: Bool) async throws -> [AuditEntry] {
        var filtered = entries
        if let since {
            filtered = filtered.filter { $0.timestamp >= since }
        }
        let sorted = filtered.sorted { $0.timestamp > $1.timestamp }
        let limited = limit.map { Array(sorted.prefix($0)) } ?? sorted
        if includePayloads {
            return limited
        }
        return limited.map { entry in
            AuditEntry(
                id: entry.id,
                sessionID: entry.sessionID,
                timestamp: entry.timestamp,
                category: entry.category,
                payload: [:],
                previousHash: entry.previousHash,
                hmac: entry.hmac
            )
        }
    }
}
