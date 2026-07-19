import Foundation

// MARK: - Message roles

public enum MessageRole: String, Codable, Sendable, CaseIterable {
    case system
    case user
    case assistant
}

// MARK: - Inference

public struct InferenceMessage: Sendable {
    public let role: MessageRole
    public let content: String

    public init(role: MessageRole, content: String) {
        self.role = role
        self.content = content
    }
}

public struct RetryBudget: Sendable {
    public var maxRetries: Int
    public var baseDelayMilliseconds: Int

    public init(maxRetries: Int = 2, baseDelayMilliseconds: Int = 100) {
        self.maxRetries = maxRetries
        self.baseDelayMilliseconds = baseDelayMilliseconds
    }
}

public struct InferenceOptions: Sendable {
    public var temperature: Double
    public var maxTokens: Int
    public var stopSequences: [String]
    public var jsonMode: Bool
    public var retryBudget: RetryBudget

    public init(
        temperature: Double = 0.7,
        maxTokens: Int = 2048,
        stopSequences: [String] = [],
        jsonMode: Bool = false,
        retryBudget: RetryBudget = RetryBudget()
    ) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.stopSequences = stopSequences
        self.jsonMode = jsonMode
        self.retryBudget = retryBudget
    }
}

// MARK: - Perspective

public struct Perspective: Codable, Sendable {
    public var summary: String
    public var tradeOffs: [String]
    public var blindSpots: [String]
    public var dissent: [String]

    public init(
        summary: String = "",
        tradeOffs: [String] = [],
        blindSpots: [String] = [],
        dissent: [String] = []
    ) {
        self.summary = summary
        self.tradeOffs = tradeOffs
        self.blindSpots = blindSpots
        self.dissent = dissent
    }
}

// MARK: - Profile

public enum GoalStatus: String, Codable, Sendable, CaseIterable {
    case active
    case completed
    case paused
}

public enum BoundarySeverity: String, Codable, Sendable, CaseIterable {
    case low
    case medium
    case high
    case critical
}

public struct ValueStatement: Codable, Sendable {
    public var id: UUID
    public var text: String
    public var createdAt: Date?
    public var tags: [String]
    public var accessScope: [AccessPurpose]
    public var deniedPurposes: [AccessPurpose]

    public init(
        id: UUID = UUID(),
        text: String,
        createdAt: Date? = nil,
        tags: [String] = [],
        accessScope: [AccessPurpose] = AccessPurpose.allDeliberation,
        deniedPurposes: [AccessPurpose] = []
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.tags = tags
        self.accessScope = accessScope
        self.deniedPurposes = deniedPurposes
    }

    enum CodingKeys: String, CodingKey {
        case id
        case text
        case createdAt
        case tags
        case accessScope
        case deniedPurposes
    }

    /// Decodes tolerantly so values persisted before PBAC fields existed still load;
    /// they default to the full deliberation scope with no denials.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.text = try container.decode(String.self, forKey: .text)
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        self.tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        self.accessScope = try container.decodeIfPresent([AccessPurpose].self, forKey: .accessScope) ?? AccessPurpose.allDeliberation
        self.deniedPurposes = try container.decodeIfPresent([AccessPurpose].self, forKey: .deniedPurposes) ?? []
    }
}

public struct Goal: Codable, Sendable {
    public var id: UUID
    public var text: String
    public var timeframe: String?
    public var createdAt: Date?
    public var tags: [String]
    public var status: GoalStatus?
    public var accessScope: [AccessPurpose]
    public var deniedPurposes: [AccessPurpose]

    public init(
        id: UUID = UUID(),
        text: String,
        timeframe: String? = nil,
        createdAt: Date? = nil,
        tags: [String] = [],
        status: GoalStatus? = nil,
        accessScope: [AccessPurpose] = AccessPurpose.allDeliberation,
        deniedPurposes: [AccessPurpose] = []
    ) {
        self.id = id
        self.text = text
        self.timeframe = timeframe
        self.createdAt = createdAt
        self.tags = tags
        self.status = status
        self.accessScope = accessScope
        self.deniedPurposes = deniedPurposes
    }

    enum CodingKeys: String, CodingKey {
        case id
        case text
        case timeframe
        case createdAt
        case tags
        case status
        case accessScope
        case deniedPurposes
    }

    /// Decodes tolerantly so goals persisted before PBAC fields existed still load;
    /// they default to the full deliberation scope with no denials.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.text = try container.decode(String.self, forKey: .text)
        self.timeframe = try container.decodeIfPresent(String.self, forKey: .timeframe)
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        self.tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        self.status = try container.decodeIfPresent(GoalStatus.self, forKey: .status)
        self.accessScope = try container.decodeIfPresent([AccessPurpose].self, forKey: .accessScope) ?? AccessPurpose.allDeliberation
        self.deniedPurposes = try container.decodeIfPresent([AccessPurpose].self, forKey: .deniedPurposes) ?? []
    }
}

public struct Boundary: Codable, Sendable {
    public var id: UUID
    public var text: String
    public var createdAt: Date?
    public var tags: [String]
    public var severity: BoundarySeverity?
    public var accessScope: [AccessPurpose]
    public var deniedPurposes: [AccessPurpose]

    public init(
        id: UUID = UUID(),
        text: String,
        createdAt: Date? = nil,
        tags: [String] = [],
        severity: BoundarySeverity? = nil,
        accessScope: [AccessPurpose] = AccessPurpose.allDeliberation,
        deniedPurposes: [AccessPurpose] = []
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.tags = tags
        self.severity = severity
        self.accessScope = accessScope
        self.deniedPurposes = deniedPurposes
    }

    enum CodingKeys: String, CodingKey {
        case id
        case text
        case createdAt
        case tags
        case severity
        case accessScope
        case deniedPurposes
    }

    /// Decodes tolerantly so boundaries persisted before PBAC fields existed still load;
    /// they default to the full deliberation scope with no denials.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.text = try container.decode(String.self, forKey: .text)
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        self.tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        self.severity = try container.decodeIfPresent(BoundarySeverity.self, forKey: .severity)
        self.accessScope = try container.decodeIfPresent([AccessPurpose].self, forKey: .accessScope) ?? AccessPurpose.allDeliberation
        self.deniedPurposes = try container.decodeIfPresent([AccessPurpose].self, forKey: .deniedPurposes) ?? []
    }
}

/// Container for data that must never leave the device or be routed to a language model.
public struct ClientConfidentialContainer: Codable, Sendable {
    public var items: [String]

    public init(items: [String] = []) {
        self.items = items
    }
}

/// A journal entry. Confidential by default; never included in routable agent context.
public struct JournalEntry: Codable, Sendable, Identifiable {
    public var id: UUID
    public var text: String
    public var createdAt: Date
    public var tags: [String]
    public var accessScope: [AccessPurpose]
    public var isLocked: Bool

    public init(
        id: UUID = UUID(),
        text: String,
        createdAt: Date = Date(),
        tags: [String] = [],
        accessScope: [AccessPurpose] = [.userInspection],
        isLocked: Bool = false
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.tags = tags
        self.accessScope = accessScope
        self.isLocked = isLocked
    }
}

public struct UserProfile: Codable, Sendable {
    public var values: [ValueStatement]
    public var goals: [Goal]
    public var boundaries: [Boundary]
    public var financialHistory: ClientConfidentialContainer
    public var journalEntries: [JournalEntry]

    public init(
        values: [ValueStatement] = [],
        goals: [Goal] = [],
        boundaries: [Boundary] = [],
        financialHistory: ClientConfidentialContainer = ClientConfidentialContainer(),
        journalEntries: [JournalEntry] = []
    ) {
        self.values = values
        self.goals = goals
        self.boundaries = boundaries
        self.financialHistory = financialHistory
        self.journalEntries = journalEntries
    }

    enum CodingKeys: String, CodingKey {
        case values
        case goals
        case boundaries
        case financialHistory
        case journalEntries
        case journalExcerpts
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(values, forKey: .values)
        try container.encode(goals, forKey: .goals)
        try container.encode(boundaries, forKey: .boundaries)
        try container.encode(financialHistory, forKey: .financialHistory)
        try container.encode(journalEntries, forKey: .journalEntries)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.values = try container.decodeIfPresent([ValueStatement].self, forKey: .values) ?? []
        self.goals = try container.decodeIfPresent([Goal].self, forKey: .goals) ?? []
        self.boundaries = try container.decodeIfPresent([Boundary].self, forKey: .boundaries) ?? []
        self.financialHistory = try container.decodeIfPresent(
            ClientConfidentialContainer.self,
            forKey: .financialHistory
        ) ?? ClientConfidentialContainer()

        if let entries = try container.decodeIfPresent([JournalEntry].self, forKey: .journalEntries) {
            self.journalEntries = entries
        } else if let legacyExcerpts = try container.decodeIfPresent(
            ClientConfidentialContainer.self,
            forKey: .journalExcerpts
        ) {
            // Migrate legacy plain-string journal excerpts to structured entries.
            // They are marked userInspection-only so they are never routed to a model.
            self.journalEntries = legacyExcerpts.items.map { text in
                JournalEntry(text: text, accessScope: [.userInspection])
            }
        } else {
            self.journalEntries = []
        }
    }
}

/// Profile context that is safe to route to agents. Excludes client-confidential containers and journal entries.
public struct RoutableProfileContext: Codable, Sendable {
    public var values: [ValueStatement]
    public var goals: [Goal]
    public var boundaries: [Boundary]

    public init(
        values: [ValueStatement] = [],
        goals: [Goal] = [],
        boundaries: [Boundary] = []
    ) {
        self.values = values
        self.goals = goals
        self.boundaries = boundaries
    }

    /// Unfiltered initializer: copies ALL values, goals, and boundaries without
    /// evaluating `accessScope`/`deniedPurposes`. Intended for user-inspection paths
    /// (e.g. `council profile show`), never for building agent context — use
    /// `ProfileService.routableContext(purposes:)` for that.
    public init(profile: UserProfile) {
        self.values = profile.values
        self.goals = profile.goals
        self.boundaries = profile.boundaries
    }
}

// MARK: - Memory

public enum AccessPurpose: String, Codable, Sendable, CaseIterable {
    case purchaseDeliberation
    case travelDeliberation
    case lifeDeliberation
    case userInspection

    /// Every deliberation purpose (everything except `.userInspection`). This is the
    /// default access scope for routable profile elements.
    public static let allDeliberation: [AccessPurpose] = [
        .purchaseDeliberation,
        .travelDeliberation,
        .lifeDeliberation,
    ]
}

public struct TemporalFact: Codable, Sendable, Identifiable {
    public var id: UUID
    public var subject: String
    public var predicate: String
    public var object: String
    public var validFrom: Date?
    public var validUntil: Date?
    public var accessScope: [AccessPurpose]
    public var deniedPurposes: [AccessPurpose]
    public var isLocked: Bool

    public init(
        id: UUID = UUID(),
        subject: String,
        predicate: String,
        object: String,
        validFrom: Date? = nil,
        validUntil: Date? = nil,
        accessScope: [AccessPurpose] = [.purchaseDeliberation],
        deniedPurposes: [AccessPurpose] = [],
        isLocked: Bool = false
    ) {
        self.id = id
        self.subject = subject
        self.predicate = predicate
        self.object = object
        self.validFrom = validFrom
        self.validUntil = validUntil
        self.accessScope = accessScope
        self.deniedPurposes = deniedPurposes
        self.isLocked = isLocked
    }

    enum CodingKeys: String, CodingKey {
        case id
        case subject
        case predicate
        case object
        case validFrom
        case validUntil
        case accessScope
        case deniedPurposes
        case isLocked
    }

    /// Decodes tolerantly so facts persisted before `deniedPurposes` existed still load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.subject = try container.decode(String.self, forKey: .subject)
        self.predicate = try container.decode(String.self, forKey: .predicate)
        self.object = try container.decode(String.self, forKey: .object)
        self.validFrom = try container.decodeIfPresent(Date.self, forKey: .validFrom)
        self.validUntil = try container.decodeIfPresent(Date.self, forKey: .validUntil)
        self.accessScope = try container.decodeIfPresent([AccessPurpose].self, forKey: .accessScope) ?? [.purchaseDeliberation]
        self.deniedPurposes = try container.decodeIfPresent([AccessPurpose].self, forKey: .deniedPurposes) ?? []
        self.isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
    }
}

public struct EpisodicGist: Codable, Sendable, Identifiable {
    public var id: UUID
    public var sessionID: UUID
    public var question: String
    public var createdAt: Date
    public var perspective: Perspective
    public var deniedPurposes: [AccessPurpose]
    public var isLocked: Bool

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        question: String,
        createdAt: Date = Date(),
        perspective: Perspective = Perspective(),
        deniedPurposes: [AccessPurpose] = [],
        isLocked: Bool = false
    ) {
        self.id = id
        self.sessionID = sessionID
        self.question = question
        self.createdAt = createdAt
        self.perspective = perspective
        self.deniedPurposes = deniedPurposes
        self.isLocked = isLocked
    }

    enum CodingKeys: String, CodingKey {
        case id
        case sessionID
        case question
        case createdAt
        case perspective
        case deniedPurposes
        case isLocked
    }

    /// Decodes tolerantly so gists persisted before `deniedPurposes` existed still load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.sessionID = try container.decode(UUID.self, forKey: .sessionID)
        self.question = try container.decode(String.self, forKey: .question)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.perspective = try container.decode(Perspective.self, forKey: .perspective)
        self.deniedPurposes = try container.decodeIfPresent([AccessPurpose].self, forKey: .deniedPurposes) ?? []
        self.isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
    }
}

// MARK: - Audit

public enum AuditCategory: String, Codable, Sendable {
    case sessionStarted
    case stageTransition
    case agentCalled
    case routeDecision
    case perspectiveProduced
    case cancellation
    case memoryAccess
    case toolCall
    case error
}

public struct AuditEntry: Codable, Sendable, Identifiable {
    public var id: UUID
    public var sessionID: UUID?
    public var timestamp: Date
    public var category: AuditCategory
    public var payload: [String: String]
    public var previousHash: String
    public var hmac: String

    public init(
        id: UUID = UUID(),
        sessionID: UUID? = nil,
        timestamp: Date = Date(),
        category: AuditCategory,
        payload: [String: String] = [:],
        previousHash: String = "",
        hmac: String = ""
    ) {
        self.id = id
        self.sessionID = sessionID
        self.timestamp = timestamp
        self.category = category
        self.payload = payload
        self.previousHash = previousHash
        self.hmac = hmac
    }
}

// MARK: - Model routing

public enum ComputeRoute: String, Codable, Sendable {
    case onDeviceApple
    case applePCC
    case thirdPartyLocal
    case thirdPartyCloud
}

public struct RouteSnapshot: Codable, Sendable {
    public var framework: String
    public var modelIdentifier: String
    public var route: ComputeRoute
    public var isLocal: Bool

    public init(
        framework: String,
        modelIdentifier: String,
        route: ComputeRoute,
        isLocal: Bool
    ) {
        self.framework = framework
        self.modelIdentifier = modelIdentifier
        self.route = route
        self.isLocal = isLocal
    }
}

public struct DeniedRoute: Codable, Sendable {
    public var route: ComputeRoute
    public var reason: String

    public init(route: ComputeRoute, reason: String) {
        self.route = route
        self.reason = reason
    }
}

public struct RouteDecision: Codable, Sendable {
    public var selectedRoute: ComputeRoute
    public var providerMetadata: RouteSnapshot
    public var deniedRoutes: [DeniedRoute]
    public var consentStatus: String
    public var dataClassClearance: String
    public var timestamp: Date

    public init(
        selectedRoute: ComputeRoute,
        providerMetadata: RouteSnapshot,
        deniedRoutes: [DeniedRoute] = [],
        consentStatus: String = "notRequired",
        dataClassClearance: String = "onDeviceOnly",
        timestamp: Date = Date()
    ) {
        self.selectedRoute = selectedRoute
        self.providerMetadata = providerMetadata
        self.deniedRoutes = deniedRoutes
        self.consentStatus = consentStatus
        self.dataClassClearance = dataClassClearance
        self.timestamp = timestamp
    }
}

// MARK: - Model configuration

public struct ModelConfiguration: Codable, Sendable {
    public var modelIdentifier: String
    public var hubID: String
    public var checksum: String?

    public init(
        modelIdentifier: String,
        hubID: String,
        checksum: String? = nil
    ) {
        self.modelIdentifier = modelIdentifier
        self.hubID = hubID
        self.checksum = checksum
    }
}
