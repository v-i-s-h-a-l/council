import CouncilCore

/// Chair: neutral synthesizer that preserves dissent.
public struct ChairAgent: Agent {
    public let id = AgentRole.chair.id
    public let name = AgentRole.chair.name
    public let stance = AgentRole.chair.stance
    public let role = AgentRole.chair

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
