import CouncilCore

/// Frugal agent: skeptical stance on unnecessary spending.
public struct FrugalAgent: Agent {
    public let id = AgentRole.frugal.id
    public let name = AgentRole.frugal.name
    public let stance = AgentRole.frugal.stance
    public let role = AgentRole.frugal

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
