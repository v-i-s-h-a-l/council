import Testing
@testable import CouncilCore

struct ModelsTests {

    @Test func perspectiveDefaultsAreEmpty() async throws {
        let perspective = Perspective()
        #expect(perspective.summary.isEmpty)
        #expect(perspective.tradeOffs.isEmpty)
        #expect(perspective.blindSpots.isEmpty)
        #expect(perspective.dissent.isEmpty)
    }

    @Test func routableProfileContextExcludesConfidential() async throws {
        let profile = UserProfile(
            values: [ValueStatement(text: "Frugality")],
            goals: [Goal(text: "Save for travel")],
            boundaries: [Boundary(text: "No impulse buys")],
            financialHistory: ClientConfidentialContainer(items: ["salary: 100000"]),
            journalExcerpts: ClientConfidentialContainer(items: ["dream vacation"])
        )

        let context = RoutableProfileContext(profile: profile)

        #expect(context.values.count == 1)
        #expect(context.goals.count == 1)
        #expect(context.boundaries.count == 1)
        // Confidential containers are intentionally not present.
    }

    @Test func modelRoutingPolicyDefaultsToOnDevice() async throws {
        let decision = ModelRoutingPolicy.defaultOnDeviceDecision()
        #expect(decision.selectedRoute == .onDeviceApple)
        #expect(decision.providerMetadata.isLocal)
    }

    @Test func dataClassificationDeniesCloudForSensitive() async throws {
        let paths = DataClassificationPolicy.allowedComputePaths(for: .sensitivePersonal)
        #expect(paths == [.onDevice])
    }
}
