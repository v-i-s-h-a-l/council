import CouncilCore

/// The built-in Purchase Council.
public struct PurchaseCouncil: Council {
    public let id = "purchase-council"
    public let name = "Purchase Council"

    public let agents: [any Agent]
    public let chair: any Agent
    public let stages: [DeliberationStage] = [
        .firstOpinions,
        .peerReview,
        .synthesis,
        .dissentPreservation,
        .presentation,
    ]

    public init() {
        let frugal = FrugalAgent()
        let futureSelf = FutureSelfAgent()
        let systemsThinker = SystemsThinkerAgent()
        let pleasure = PleasureAgent()
        let chair = ChairAgent()

        self.agents = [frugal, futureSelf, systemsThinker, pleasure, chair]
        self.chair = chair
    }
}
