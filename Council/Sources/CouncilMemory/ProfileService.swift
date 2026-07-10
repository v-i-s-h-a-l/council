import CouncilCore
import Foundation

/// Actor-isolated service exposing profile persistence operations.
public actor ProfileService {
    private let vault: any ProfileVault

    public init(vault: any ProfileVault) {
        self.vault = vault
    }

    /// Whether the underlying vault is bound to the Secure Enclave.
    public var isDeviceBound: Bool {
        get async { await vault.isDeviceBound }
    }

    public func load() async throws -> UserProfile {
        try await vault.load()
    }

    public func save(_ profile: UserProfile) async throws {
        try await vault.save(profile)
    }

    public func exportEncryptedBlob() async throws -> Data {
        try await vault.exportEncryptedBlob()
    }

    // MARK: - Value management

    @discardableResult
    public func addValue(
        _ text: String,
        tags: [String] = []
    ) async throws -> ValueStatement {
        var profile = try await load()
        let statement = ValueStatement(text: text, tags: tags)
        profile.values.append(statement)
        try await save(profile)
        return statement
    }

    public func removeValue(id: UUID) async throws {
        var profile = try await load()
        profile.values.removeAll { $0.id == id }
        try await save(profile)
    }

    // MARK: - Goal management

    @discardableResult
    public func addGoal(
        _ text: String,
        timeframe: String? = nil,
        tags: [String] = [],
        status: GoalStatus? = nil
    ) async throws -> Goal {
        var profile = try await load()
        let goal = Goal(text: text, timeframe: timeframe, tags: tags, status: status)
        profile.goals.append(goal)
        try await save(profile)
        return goal
    }

    public func removeGoal(id: UUID) async throws {
        var profile = try await load()
        profile.goals.removeAll { $0.id == id }
        try await save(profile)
    }

    // MARK: - Boundary management

    @discardableResult
    public func addBoundary(
        _ text: String,
        tags: [String] = [],
        severity: BoundarySeverity? = nil
    ) async throws -> Boundary {
        var profile = try await load()
        let boundary = Boundary(text: text, tags: tags, severity: severity)
        profile.boundaries.append(boundary)
        try await save(profile)
        return boundary
    }

    public func removeBoundary(id: UUID) async throws {
        var profile = try await load()
        profile.boundaries.removeAll { $0.id == id }
        try await save(profile)
    }

    // MARK: - Journal management

    @discardableResult
    public func addJournalEntry(
        _ text: String,
        createdAt: Date = Date(),
        tags: [String] = []
    ) async throws -> JournalEntry {
        var profile = try await load()
        let entry = JournalEntry(text: text, createdAt: createdAt, tags: tags)
        profile.journalEntries.append(entry)
        try await save(profile)
        return entry
    }

    public func removeJournalEntry(id: UUID) async throws {
        var profile = try await load()
        profile.journalEntries.removeAll { $0.id == id }
        try await save(profile)
    }

    public func journalEntries(
        tags: [String] = [],
        from: Date? = nil,
        to: Date? = nil
    ) async throws -> [JournalEntry] {
        let profile = try await load()
        return profile.journalEntries.filter { entry in
            if !tags.isEmpty {
                let entryTags = Set(entry.tags)
                let requiredTags = Set(tags)
                if !requiredTags.isSubset(of: entryTags) {
                    return false
                }
            }
            if let from, entry.createdAt < from {
                return false
            }
            if let to, entry.createdAt > to {
                return false
            }
            return true
        }
    }

    // MARK: - Purpose-bound context

    /// Returns the profile context that is safe to route to agents for the given purposes.
    ///
    /// Values, goals, and boundaries are inherently routable profile facts and are returned in
    /// full. Journal entries and financial history are confidential and are NEVER included,
    /// regardless of purpose; this is enforced by the shape of `RoutableProfileContext` itself.
    /// The `purposes` parameter is the explicit PBAC choke point for future per-purpose
    /// filtering and is recorded by callers as an access decision.
    public func routableContext(purposes: [AccessPurpose]) async throws -> RoutableProfileContext {
        let profile = try await load()
        return RoutableProfileContext(profile: profile)
    }
}
