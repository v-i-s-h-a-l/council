import Testing
import CouncilCore
@testable import CouncilAgents

struct SycophancyResistanceTests {

    /// Every agent's own composed prompt must carry anti-sycophancy language.
    /// The previous version OR-ed over all five agents (so 4 of 5 role prompts
    /// could lose the language and stay green), accepted phrases that live in the
    /// shared stage instructions (so even all 5 losing it stayed green), and looped
    /// over questions nothing depended on. The phrases asserted here appear only in
    /// role system prompts, never in stage instructions.
    @Test func everyRolePromptContainsAntiSycophancyLanguage() async throws {
        let cases: [(agent: any Agent, phrase: String)] = [
            (FrugalAgent(), "no disagreement"),
            (FutureSelfAgent(), "no disagreement"),
            (SystemsThinkerAgent(), "no disagreement"),
            (PleasureAgent(), "no disagreement"),
            (ChairAgent(), "do not collapse disagreement"),
        ]

        for (agent, phrase) in cases {
            let messages = agent.prompt(
                stage: .firstOpinions,
                question: "I really want to buy a luxury sports car. Should I?",
                context: RoutableProfileContext(),
                priorOutputs: []
            )
            let combined = messages.map(\.content).joined(separator: "\n").lowercased()
            #expect(
                combined.contains(phrase),
                "Agent \(agent.id) lost anti-sycophancy language (\(phrase))"
            )
        }
    }
}
