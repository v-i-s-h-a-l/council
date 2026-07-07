import CouncilCore

/// Systems Thinker agent: analytical stance on hidden costs and second-order effects.
public struct SystemsThinkerAgent: Agent {
    public let id = AgentRole.systemsThinker.id
    public let name = AgentRole.systemsThinker.name
    public let stance = AgentRole.systemsThinker.stance
    public let role = AgentRole.systemsThinker

    public init() {}

    public func prompt(
        stage: DeliberationStage,
        question: String,
        context: RoutableProfileContext,
        priorOutputs: [AgentOutput]
    ) -> [InferenceMessage] {
        PromptBuilder.messages(
            for: self,
            role: role,
            stage: stage,
            question: question,
            context: context,
            priorOutputs: priorOutputs
        )
    }
}
