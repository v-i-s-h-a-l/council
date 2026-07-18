import Foundation
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
            journalEntries: [JournalEntry(text: "dream vacation")]
        )

        let context = RoutableProfileContext(profile: profile)

        #expect(context.values.count == 1)
        #expect(context.goals.count == 1)
        #expect(context.boundaries.count == 1)
        // Confidential containers are intentionally not present.
    }

    @Test func legacyProfileItemsDecodeWithDefaultPBACScope() async throws {
        // Values persisted before PBAC fields existed omit accessScope/deniedPurposes;
        // they must decode to the full deliberation scope with no denials.
        let legacyJSON = """
        {"id": "00000000-0000-0000-0000-000000000001", "text": "Be frugal"}
        """
        let value = try JSONDecoder().decode(ValueStatement.self, from: Data(legacyJSON.utf8))
        #expect(value.accessScope == AccessPurpose.allDeliberation)
        #expect(value.deniedPurposes.isEmpty)

        let goal = try JSONDecoder().decode(Goal.self, from: Data(legacyJSON.utf8))
        #expect(goal.accessScope == AccessPurpose.allDeliberation)
        #expect(goal.deniedPurposes.isEmpty)

        let boundary = try JSONDecoder().decode(Boundary.self, from: Data(legacyJSON.utf8))
        #expect(boundary.accessScope == AccessPurpose.allDeliberation)
        #expect(boundary.deniedPurposes.isEmpty)
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

    @Test func temporalFactDecodesWithoutDeniedPurposes() throws {
        // Facts persisted before PBAC have no `deniedPurposes` key and must still decode.
        let json = """
        {
            "id": "A0B1C2D3-E4F5-6789-0123-456789ABCDEF",
            "subject": "user",
            "predicate": "budget",
            "object": "500",
            "accessScope": ["purchaseDeliberation"],
            "isLocked": false
        }
        """
        let fact = try JSONDecoder().decode(TemporalFact.self, from: Data(json.utf8))
        #expect(fact.accessScope == [.purchaseDeliberation])
        #expect(fact.deniedPurposes == [])
        #expect(fact.isLocked == false)
    }

    @Test func temporalFactRoundTripsDeniedPurposes() throws {
        let fact = TemporalFact(
            subject: "user",
            predicate: "ssn",
            object: "secret",
            accessScope: [.userInspection],
            deniedPurposes: [.purchaseDeliberation, .travelDeliberation]
        )
        let data = try JSONEncoder().encode(fact)
        let decoded = try JSONDecoder().decode(TemporalFact.self, from: data)
        #expect(decoded.deniedPurposes == [.purchaseDeliberation, .travelDeliberation])
        #expect(decoded.accessScope == [.userInspection])
    }
}
