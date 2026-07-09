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
        #expect(combined.contains("Synthesize"))
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
}
