import CouncilCore
import CouncilMemory
import CouncilTestUtilities
import Foundation
import Testing

/// Adversarial tests for `ProfileService`, the purpose-bound access control (PBAC)
/// decision point that keeps denied profile items out of agent prompts.
struct ProfileServiceAdversarialTests {
    @Test func profileAccessDecisionExcludesDeniedAndOutOfScopeItems() async throws {
        let deniedValue = ValueStatement(
            text: "Never share salary",
            deniedPurposes: [.purchaseDeliberation]
        )
        let travelOnlyGoal = Goal(
            text: "Fly to Japan",
            accessScope: [.travelDeliberation]
        )
        let openBoundary = Boundary(text: "No impulse buys")
        let profile = UserProfile(
            values: [deniedValue],
            goals: [travelOnlyGoal],
            boundaries: [openBoundary],
            financialHistory: ClientConfidentialContainer(items: ["salary: 100000"]),
            journalEntries: [JournalEntry(text: "private dream")]
        )
        let service = ProfileService(vault: MockProfileVault(profile: profile))

        let decision = try await service.profileAccessDecision(purposes: [.purchaseDeliberation])

        // Only the in-scope, not-denied boundary is routed.
        #expect(decision.context.values.isEmpty)
        #expect(decision.context.goals.isEmpty)
        #expect(decision.context.boundaries.map(\.id) == [openBoundary.id])

        // One denial per excluded item, with the element identity and the
        // requesting purposes preserved for audit.
        #expect(decision.denials.count == 2)
        #expect(decision.denials.contains {
            $0.elementType == "ValueStatement" && $0.elementID == deniedValue.id
        })
        #expect(decision.denials.contains {
            $0.elementType == "Goal" && $0.elementID == travelOnlyGoal.id
        })
        #expect(decision.denials.allSatisfy { $0.purposes == [.purchaseDeliberation] })
    }

    @Test func routableContextWithEmptyPurposesDeniesEverything() async throws {
        let profile = UserProfile(
            values: [ValueStatement(text: "Frugality")],
            goals: [Goal(text: "Save for travel")],
            boundaries: [Boundary(text: "No impulse buys")]
        )
        let service = ProfileService(vault: MockProfileVault(profile: profile))

        // Fail closed: an empty request set is disjoint with every access scope,
        // so ALL items are denied. "Empty" must not mean "unfiltered".
        let decision = try await service.profileAccessDecision(purposes: [])
        #expect(decision.context.values.isEmpty)
        #expect(decision.context.goals.isEmpty)
        #expect(decision.context.boundaries.isEmpty)
        #expect(decision.denials.count == 3)

        let context = try await service.routableContext(purposes: [])
        #expect(context.values.isEmpty)
        #expect(context.goals.isEmpty)
        #expect(context.boundaries.isEmpty)
    }

    @Test func concurrentProfileServiceAddsLoseNothing() async throws {
        let service = ProfileService(vault: MockProfileVault())

        // Regression: mutations were load→append→save sequences that suspend on the
        // vault; actor reentrancy let two concurrent mutations load the same base
        // profile so the later save silently overwrote the earlier one.
        try await withThrowingTaskGroup(of: ValueStatement.self) { group in
            for index in 0..<50 {
                group.addTask {
                    try await service.addValue("value-\(index)")
                }
            }
            for try await _ in group {}
        }

        let profile = try await service.load()
        #expect(profile.values.count == 50)
        #expect(Set(profile.values.map(\.text)).count == 50)
    }
}
