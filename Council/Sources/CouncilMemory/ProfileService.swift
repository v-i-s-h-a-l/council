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
        tags: [String] = [],
        accessScope: [AccessPurpose] = AccessPurpose.allDeliberation,
        deniedPurposes: [AccessPurpose] = []
    ) async throws -> ValueStatement {
        var profile = try await load()
        let statement = ValueStatement(
            text: text,
            tags: tags,
            accessScope: accessScope,
            deniedPurposes: deniedPurposes
        )
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
        status: GoalStatus? = nil,
        accessScope: [AccessPurpose] = AccessPurpose.allDeliberation,
        deniedPurposes: [AccessPurpose] = []
    ) async throws -> Goal {
        var profile = try await load()
        let goal = Goal(
            text: text,
            timeframe: timeframe,
            tags: tags,
            status: status,
            accessScope: accessScope,
            deniedPurposes: deniedPurposes
        )
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
        severity: BoundarySeverity? = nil,
        accessScope: [AccessPurpose] = AccessPurpose.allDeliberation,
        deniedPurposes: [AccessPurpose] = []
    ) async throws -> Boundary {
        var profile = try await load()
        let boundary = Boundary(
            text: text,
            tags: tags,
            severity: severity,
            accessScope: accessScope,
            deniedPurposes: deniedPurposes
        )
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
    /// Values, goals, and boundaries are filtered by their PBAC labels: an item is routed
    /// only when the request purposes intersect its `accessScope` and do not intersect its
    /// `deniedPurposes`. Journal entries and financial history are confidential and are
    /// NEVER included, regardless of purpose; this is enforced by the shape of
    /// `RoutableProfileContext` itself.
    public func routableContext(purposes: [AccessPurpose]) async throws -> RoutableProfileContext {
        try await profileAccessDecision(purposes: purposes).context
    }

    /// Returns the purpose-filtered routable context together with the per-item denials,
    /// so callers can record each denied access decision in the audit chain.
    public func profileAccessDecision(purposes: [AccessPurpose]) async throws -> ProfileAccessDecision {
        let profile = try await load()
        let request = Set(purposes)

        func isAllowed(_ scope: [AccessPurpose], denied: [AccessPurpose]) -> Bool {
            !request.isDisjoint(with: Set(scope)) && request.isDisjoint(with: Set(denied))
        }

        var denials: [ProfileItemDenial] = []
        let values = profile.values.filter { item in
            let allowed = isAllowed(item.accessScope, denied: item.deniedPurposes)
            if !allowed { denials.append(ProfileItemDenial(elementType: "ValueStatement", elementID: item.id, purposes: purposes)) }
            return allowed
        }
        let goals = profile.goals.filter { item in
            let allowed = isAllowed(item.accessScope, denied: item.deniedPurposes)
            if !allowed { denials.append(ProfileItemDenial(elementType: "Goal", elementID: item.id, purposes: purposes)) }
            return allowed
        }
        let boundaries = profile.boundaries.filter { item in
            let allowed = isAllowed(item.accessScope, denied: item.deniedPurposes)
            if !allowed { denials.append(ProfileItemDenial(elementType: "Boundary", elementID: item.id, purposes: purposes)) }
            return allowed
        }

        return ProfileAccessDecision(
            context: RoutableProfileContext(values: values, goals: goals, boundaries: boundaries),
            denials: denials
        )
    }
}

/// A single purpose-bound denial of a profile item, recorded for audit.
public struct ProfileItemDenial: Sendable {
    public var elementType: String
    public var elementID: UUID
    public var purposes: [AccessPurpose]

    public init(elementType: String, elementID: UUID, purposes: [AccessPurpose]) {
        self.elementType = elementType
        self.elementID = elementID
        self.purposes = purposes
    }
}

/// The result of evaluating profile access for a set of purposes: the items that may be
/// routed to agents plus one denial entry per excluded item.
public struct ProfileAccessDecision: Sendable {
    public var context: RoutableProfileContext
    public var denials: [ProfileItemDenial]

    public init(context: RoutableProfileContext, denials: [ProfileItemDenial]) {
        self.context = context
        self.denials = denials
    }
}
