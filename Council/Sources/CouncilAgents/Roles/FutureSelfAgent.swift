import CouncilCore

/// Future Self agent: aspirational, long-term stance.
public struct FutureSelfAgent: Agent {
    public let id = AgentRole.futureSelf.id
    public let name = AgentRole.futureSelf.name
    public let stance = AgentRole.futureSelf.stance
    public let role = AgentRole.futureSelf

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
