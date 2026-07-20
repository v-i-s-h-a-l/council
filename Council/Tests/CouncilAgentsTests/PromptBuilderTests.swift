import Testing
import CouncilCore
@testable import CouncilAgents

struct PromptBuilderTests {

    @Test func promptContainsConstitutionPreamble() async throws {
        let agent = FrugalAgent()
        let messages = agent.prompt(
            stage: .firstOpinions,
            question: "Should I buy a new laptop?",
            context: RoutableProfileContext(),
            priorOutputs: []
        )

        let combined = messages.map(\.content).joined(separator: "\n")
        #expect(combined.contains("Council Constitution"))
        #expect(combined.contains("User sovereignty"))
    }

    @Test func promptContainsRoleSystemPrompt() async throws {
        let agent = FrugalAgent()
        let messages = agent.prompt(
            stage: .firstOpinions,
            question: "Should I buy a new laptop?",
            context: RoutableProfileContext(),
            priorOutputs: []
        )

        let combined = messages.map(\.content).joined(separator: "\n")
        #expect(combined.contains("Frugal agent"))
        #expect(combined.contains("skeptical"))
    }

    @Test func promptContainsStageInstructionsAndSchema() async throws {
        let agent = SystemsThinkerAgent()
        let messages = agent.prompt(
            stage: .synthesis,
            question: "Should I buy a new laptop?",
            context: RoutableProfileContext(),
            priorOutputs: []
        )

        let combined = messages.map(\.content).joined(separator: "\n")
        // The instruction text itself (not just the schema line, which always
        // contains "summary"/"tradeOffs" regardless of stage).
        #expect(combined.contains("Synthesize a balanced perspective from the prior opinions and reviews."))
        #expect(combined.contains("Preserve every substantive dissent note verbatim"))
        #expect(combined.contains("summary"))
        #expect(combined.contains("tradeOffs"))
    }

    @Test func promptDoesNotContainConfidentialContainerContents() async throws {
        let profile = UserProfile(
            values: [ValueStatement(text: "Frugality")],
            goals: [Goal(text: "Save for travel")],
            boundaries: [Boundary(text: "No impulse buys")],
            financialHistory: ClientConfidentialContainer(items: ["salary: 100000", "bank account: 12345"]),
            journalEntries: [JournalEntry(text: "private dream")]
        )
        let context = RoutableProfileContext(profile: profile)

        let agents: [any Agent] = [
            FrugalAgent(), FutureSelfAgent(), SystemsThinkerAgent(), PleasureAgent(), ChairAgent()
        ]

        for agent in agents {
            let messages = agent.prompt(
                stage: .firstOpinions,
                question: "Should I buy a car?",
                context: context,
                priorOutputs: []
            )
            let combined = messages.map(\.content).joined(separator: "\n")
            #expect(!combined.contains("salary: 100000"))
            #expect(!combined.contains("bank account: 12345"))
            #expect(!combined.contains("private dream"))
            #expect(!combined.contains("ClientConfidentialContainer"))
        }
    }

    /// Regression: `RoutableProfileContext(profile:)` is the UNFILTERED
    /// user-inspection initializer (its doc comment says "never for building agent
    /// context"). If such a context ever reaches an agent anyway, purpose-scoped
    /// and purpose-denied items must still not leak into the model prompt —
    /// `PromptBuilder` re-filters against the role's access purpose.
    @Test func scopedOutProfileItemsDoNotLeakIntoPromptsViaUnfilteredContext() async throws {
        let profile = UserProfile(
            values: [
                ValueStatement(text: "secret-inspection-only-value", accessScope: [.userInspection]),
                ValueStatement(text: "routable-value"),
            ],
            goals: [
                Goal(text: "secret-denied-goal", deniedPurposes: [.purchaseDeliberation]),
                Goal(text: "routable-goal"),
            ],
            boundaries: [
                Boundary(text: "secret-inspection-only-boundary", accessScope: [.userInspection]),
                Boundary(text: "routable-boundary"),
            ]
        )
        let context = RoutableProfileContext(profile: profile)

        let agents: [any Agent] = [
            FrugalAgent(), FutureSelfAgent(), SystemsThinkerAgent(), PleasureAgent(), ChairAgent()
        ]
        let stages: [DeliberationStage] = [.firstOpinions, .synthesis]

        for agent in agents {
            for stage in stages {
                let messages = agent.prompt(
                    stage: stage,
                    question: "Should I buy a car?",
                    context: context,
                    priorOutputs: []
                )
                let combined = messages.map(\.content).joined(separator: "\n")
                #expect(!combined.contains("secret-inspection-only-value"), "leaked for \(agent.id) at \(stage)")
                #expect(!combined.contains("secret-denied-goal"), "leaked for \(agent.id) at \(stage)")
                #expect(!combined.contains("secret-inspection-only-boundary"), "leaked for \(agent.id) at \(stage)")
                #expect(combined.contains("routable-value"))
                #expect(combined.contains("routable-goal"))
                #expect(combined.contains("routable-boundary"))
            }
        }
    }
}
