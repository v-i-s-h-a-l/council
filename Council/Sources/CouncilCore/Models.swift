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

    public init(
        id: UUID = UUID(),
        text: String,
        createdAt: Date? = nil,
        tags: [String] = []
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.tags = tags
    }
}

public struct Goal: Codable, Sendable {
    public var id: UUID
    public var text: String
    public var timeframe: String?
    public var createdAt: Date?
    public var tags: [String]
    public var status: GoalStatus?

    public init(
        id: UUID = UUID(),
        text: String,
        timeframe: String? = nil,
        createdAt: Date? = nil,
        tags: [String] = [],
        status: GoalStatus? = nil
    ) {
        self.id = id
        self.text = text
        self.timeframe = timeframe
        self.createdAt = createdAt
        self.tags = tags
        self.status = status
    }
}

public struct Boundary: Codable, Sendable {
    public var id: UUID
    public var text: String
    public var createdAt: Date?
    public var tags: [String]
    public var severity: BoundarySeverity?

    public init(
        id: UUID = UUID(),
        text: String,
        createdAt: Date? = nil,
        tags: [String] = [],
        severity: BoundarySeverity? = nil
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.tags = tags
        self.severity = severity
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

    public init(profile: UserProfile) {
        self.values = profile.values
        self.goals = profile.goals
        self.boundaries = profile.boundaries
    }
}

// MARK: - Memory

public enum AccessPurpose: String, Codable, Sendable {
    case purchaseDeliberation
    case travelDeliberation
    case lifeDeliberation
    case userInspection
}

public struct TemporalFact: Codable, Sendable, Identifiable {
    public var id: UUID
    public var subject: String
    public var predicate: String
    public var object: String
    public var validFrom: Date?
    public var validUntil: Date?
    public var accessScope: [AccessPurpose]
    public var isLocked: Bool

    public init(
        id: UUID = UUID(),
        subject: String,
        predicate: String,
        object: String,
        validFrom: Date? = nil,
        validUntil: Date? = nil,
        accessScope: [AccessPurpose] = [.purchaseDeliberation],
        isLocked: Bool = false
    ) {
        self.id = id
        self.subject = subject
        self.predicate = predicate
        self.object = object
        self.validFrom = validFrom
        self.validUntil = validUntil
        self.accessScope = accessScope
        self.isLocked = isLocked
    }
}

public struct EpisodicGist: Codable, Sendable, Identifiable {
    public var id: UUID
    public var sessionID: UUID
    public var question: String
    public var createdAt: Date
    public var perspective: Perspective
    public var isLocked: Bool

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        question: String,
        createdAt: Date = Date(),
        perspective: Perspective = Perspective(),
        isLocked: Bool = false
    ) {
        self.id = id
        self.sessionID = sessionID
        self.question = question
        self.createdAt = createdAt
        self.perspective = perspective
        self.isLocked = isLocked
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
