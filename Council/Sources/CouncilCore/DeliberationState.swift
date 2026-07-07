import Foundation

public enum DeliberationStage: String, Codable, Sendable, CaseIterable {
    case idle
    case firstOpinions
    case peerReview
    case synthesis
    case dissentPreservation
    case presentation
    case cancelled
    case failed
}

public enum DeliberationError: Error, Sendable {
    case noCouncil
    case inferenceCancelled
    case thermalCritical
    case invalidPerspective(String)
    case sessionAlreadyActive
}

public struct DeliberationState: Sendable {
    public var sessionID: UUID
    public var stage: DeliberationStage
    public var question: String
    public var agentOutputs: [AgentOutput]
    public var perspective: Perspective?
    public var errorMessage: String?

    public init(
        sessionID: UUID = UUID(),
        stage: DeliberationStage = .idle,
        question: String = "",
        agentOutputs: [AgentOutput] = [],
        perspective: Perspective? = nil,
        errorMessage: String? = nil
    ) {
        self.sessionID = sessionID
        self.stage = stage
        self.question = question
        self.agentOutputs = agentOutputs
        self.perspective = perspective
        self.errorMessage = errorMessage
    }
}
