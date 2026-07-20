import CouncilCore
import Foundation

/// Actor-isolated service exposing profile persistence operations.
public actor ProfileService {
    private let vault: any ProfileVault

    /// Tail of the mutation chain serializing load→mutate→save cycles.
    ///
    /// `ProfileService` is an actor, but every mutation suspends while talking to the
    /// vault, and actors are reentrant: without this chain, two concurrent mutations
    /// can load the same base profile and the later save silently overwrites the
    /// earlier one (a lost update).
    private var mutationTail: Task<Void, Error>?

    public init(vault: any ProfileVault) {
        self.vault = vault
    }

    /// Runs `mutation` against the freshest persisted profile, strictly after every
    /// previously enqueued mutation has settled.
    private func mutateProfile(_ mutation: @escaping @Sendable (inout UserProfile) -> Void) async throws {
        let tail = mutationTail
        let vault = self.vault
        // Detached so the task captures neither the actor nor its isolation (which
        // would retain a cycle through `mutationTail`); ordering comes from awaiting
        // the previous tail, not from actor isolation.
        let task: Task<Void, Error> = Task.detached {
            // Wait for the previous mutation to settle (errors included) so this
            // mutation always starts from the freshest persisted profile.
            _ = try? await tail?.value
            var profile = try await vault.load()
            mutation(&profile)
            try await vault.save(profile)
        }
        mutationTail = task
        try await task.value
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
        let statement = ValueStatement(
            text: text,
            tags: tags,
            accessScope: accessScope,
            deniedPurposes: deniedPurposes
        )
        try await mutateProfile { $0.values.append(statement) }
        return statement
    }

    public func removeValue(id: UUID) async throws {
        try await mutateProfile { $0.values.removeAll { $0.id == id } }
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
        let goal = Goal(
            text: text,
            timeframe: timeframe,
            tags: tags,
            status: status,
            accessScope: accessScope,
            deniedPurposes: deniedPurposes
        )
        try await mutateProfile { $0.goals.append(goal) }
        return goal
    }

    public func removeGoal(id: UUID) async throws {
        try await mutateProfile { $0.goals.removeAll { $0.id == id } }
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
        let boundary = Boundary(
            text: text,
            tags: tags,
            severity: severity,
            accessScope: accessScope,
            deniedPurposes: deniedPurposes
        )
        try await mutateProfile { $0.boundaries.append(boundary) }
        return boundary
    }

    public func removeBoundary(id: UUID) async throws {
        try await mutateProfile { $0.boundaries.removeAll { $0.id == id } }
    }

    // MARK: - Journal management

    @discardableResult
    public func addJournalEntry(
        _ text: String,
        createdAt: Date = Date(),
        tags: [String] = []
    ) async throws -> JournalEntry {
        let entry = JournalEntry(text: text, createdAt: createdAt, tags: tags)
        try await mutateProfile { $0.journalEntries.append(entry) }
        return entry
    }

    public func removeJournalEntry(id: UUID) async throws {
        try await mutateProfile { $0.journalEntries.removeAll { $0.id == id } }
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
