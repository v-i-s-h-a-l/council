import Testing
import CouncilCore
@testable import CouncilAgents

struct PurchaseCouncilTests {

    @Test func exposesExpectedAgents() async throws {
        let council = PurchaseCouncil()

        #expect(council.id == "purchase-council")
        #expect(council.name == "Purchase Council")
        #expect(council.agents.count == 5)

        let ids = council.agents.map(\.id)
        #expect(ids.contains("frugal"))
        #expect(ids.contains("future-self"))
        #expect(ids.contains("systems-thinker"))
        #expect(ids.contains("pleasure"))
        #expect(ids.contains("chair"))
    }

    @Test func chairIsNeutralAndInAgentList() async throws {
        let council = PurchaseCouncil()

        #expect(council.chair.id == "chair")
        #expect(council.chair.stance == .neutral)
        #expect(council.agents.contains(where: { $0.id == council.chair.id }))
    }

    @Test func stageOrderMatchesFiveStageFlow() async throws {
        let council = PurchaseCouncil()

        #expect(council.stages == [
            .firstOpinions,
            .peerReview,
            .synthesis,
            .dissentPreservation,
            .presentation,
        ])
    }
}
