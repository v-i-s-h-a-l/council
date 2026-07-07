import Foundation

// MARK: - Inference

public protocol InferenceProvider: Sendable {
    func generate(
        messages: [InferenceMessage],
        options: InferenceOptions
    ) async throws -> AsyncThrowingStream<String, Error>

    var routeSnapshot: RouteSnapshot { get async }
}

// MARK: - Profile

public protocol ProfileVault: Sendable {
    func load() async throws -> UserProfile
    func save(_ profile: UserProfile) async throws
    func exportEncryptedBlob() async throws -> Data
    func replaceFromEncryptedBlob(_ data: Data) async throws
}

// MARK: - Memory

public struct MemoryFilter: Sendable {
    public var purposes: [AccessPurpose]?
    public var locked: Bool?
    public var subject: String?

    public init(
        purposes: [AccessPurpose]? = nil,
        locked: Bool? = nil,
        subject: String? = nil
    ) {
        self.purposes = purposes
        self.locked = locked
        self.subject = subject
    }
}

public protocol MemoryStore: Sendable {
    func saveEpisode(_ episode: EpisodicGist) async throws
    func episodes(matching filter: MemoryFilter) async throws -> [EpisodicGist]
    func updateEpisode(_ episode: EpisodicGist) async throws
    func deleteEpisode(id: UUID) async throws
    func lockEpisode(id: UUID, isLocked: Bool) async throws

    func temporalFacts(for purpose: AccessPurpose) async throws -> [TemporalFact]
    func temporalFacts(matching filter: MemoryFilter) async throws -> [TemporalFact]
    func saveFact(_ fact: TemporalFact) async throws
    func deleteFact(id: UUID) async throws
}

// MARK: - Audit

public protocol AuditLog: Sendable {
    func append(_ entry: AuditEntry) async throws
    func entries(for sessionID: UUID?) async throws -> [AuditEntry]
}

// MARK: - Agent

public enum AgentStance: String, Codable, Sendable {
    case skeptical
    case aspirational
    case analytical
    case affirmative
    case neutral
}

public struct AgentOutput: Codable, Sendable {
    public var agentID: String
    public var opinion: String
    public var rationale: String
    public var stance: AgentStance

    public init(
        agentID: String,
        opinion: String,
        rationale: String,
        stance: AgentStance
    ) {
        self.agentID = agentID
        self.opinion = opinion
        self.rationale = rationale
        self.stance = stance
    }
}

public protocol Agent: Sendable {
    var id: String { get }
    var name: String { get }
    var stance: AgentStance { get }

    func prompt(
        stage: DeliberationStage,
        question: String,
        context: RoutableProfileContext,
        priorOutputs: [AgentOutput]
    ) -> [InferenceMessage]
}

// MARK: - Council

public protocol Council: Sendable {
    var id: String { get }
    var name: String { get }
    var agents: [any Agent] { get }
}

// MARK: - Validation

public protocol PerspectiveValidator: Sendable {
    func validate(_ perspective: Perspective) -> PerspectiveValidationResult
}

public enum PerspectiveValidationResult: Sendable {
    case valid
    case invalid(reason: String)
}
