import CouncilCore

/// Pleasure agent: affirmative stance toward joy and present quality of life.
public struct PleasureAgent: Agent {
    public let id = AgentRole.pleasure.id
    public let name = AgentRole.pleasure.name
    public let stance = AgentRole.pleasure.stance
    public let role = AgentRole.pleasure

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
