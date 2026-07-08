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
}
