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
}
