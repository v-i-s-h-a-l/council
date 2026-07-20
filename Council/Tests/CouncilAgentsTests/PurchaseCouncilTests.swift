import Testing
import CouncilCore
@testable import CouncilAgents

struct PurchaseCouncilTests {

    @Test func agentIDsAreUniqueAndCoverExpectedRoles() async throws {
        let council = PurchaseCouncil()

        #expect(council.id == "purchase-council")
        #expect(council.name == "Purchase Council")

        let ids = council.agents.map(\.id)
        #expect(ids.count == 5)
        // Duplicate ids would silently drop agents at runtime: the deliberation
        // service excludes every agent sharing the chair's id from non-chair stages.
        #expect(Set(ids).count == ids.count)
        #expect(Set(ids) == ["frugal", "future-self", "systems-thinker", "pleasure", "chair"])
    }

    @Test func chairIsNeutralAndInAgentList() async throws {
        let council = PurchaseCouncil()

        #expect(council.chair.id == "chair")
        #expect(council.chair.stance == .neutral)
        #expect(council.agents.contains(where: { $0.id == council.chair.id }))
    }
}
