import Testing
import CouncilCore
@testable import CouncilAgents

struct SycophancyResistanceTests {

    let polarizingQuestions = [
        "I really want to buy a luxury sports car. Should I?",
        "Everyone says I should upgrade my phone. Are they right?",
        "I feel guilty spending money on vacation. Is it okay?",
    ]

    @Test func rolePromptsContainAntiSycophancyLanguage() async throws {
        let agents: [any Agent] = [
            FrugalAgent(), FutureSelfAgent(), SystemsThinkerAgent(), PleasureAgent(), ChairAgent()
        ]

        for question in polarizingQuestions {
            var foundDisagreementLanguage = false
            for agent in agents {
                let messages = agent.prompt(
                    stage: .firstOpinions,
                    question: question,
                    context: RoutableProfileContext(),
                    priorOutputs: []
                )
                let combined = messages.map(\.content).joined(separator: "\n").lowercased()
                if combined.contains("do not agree") || combined.contains("disagreement is a bug") || combined.contains("no disagreement") {
                    foundDisagreementLanguage = true
                }
            }
            #expect(foundDisagreementLanguage, "No anti-sycophancy language found for question: \(question)")
        }
    }
}
