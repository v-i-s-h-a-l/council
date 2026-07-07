import CouncilCore
import Foundation
import Testing

struct PromptLeakageTests {
    @Test func routableProfileContextExcludesConfidentialContainers() async throws {
        let profile = UserProfile(
            values: [ValueStatement(text: "Frugality")],
            goals: [Goal(text: "Save for travel")],
            boundaries: [Boundary(text: "No impulse buys")],
            financialHistory: ClientConfidentialContainer(items: [
                "salary: 100000",
                "bank account: 12345",
                "credit card debt: 5000",
            ]),
            journalExcerpts: ClientConfidentialContainer(items: [
                "private dream about flying",
                "argument with a friend",
            ])
        )
        let context = RoutableProfileContext(profile: profile)

        let data = try JSONEncoder().encode(context)
        let json = String(data: data, encoding: .utf8) ?? ""

        #expect(!json.contains("salary: 100000"))
        #expect(!json.contains("bank account: 12345"))
        #expect(!json.contains("credit card debt: 5000"))
        #expect(!json.contains("private dream about flying"))
        #expect(!json.contains("argument with a friend"))
        #expect(!json.contains("financialHistory"))
        #expect(!json.contains("journalExcerpts"))
        #expect(!json.contains("ClientConfidentialContainer"))
    }

    @Test func renderedPromptFromRoutableContextNeverContainsConfidentialData() async throws {
        let profile = UserProfile(
            values: [ValueStatement(text: "Frugality")],
            goals: [Goal(text: "Save for travel")],
            boundaries: [Boundary(text: "No impulse buys")],
            financialHistory: ClientConfidentialContainer(items: ["salary: 100000"]),
            journalExcerpts: ClientConfidentialContainer(items: ["private dream"])
        )
        let context = RoutableProfileContext(profile: profile)

        // Simulate the prompt construction that agents perform: encode the routable context
        // and include it in a user message along with the question.
        let contextJSON = String(data: try JSONEncoder().encode(context), encoding: .utf8) ?? ""
        let prompt = """
            Question: Should I buy a car?
            Access purpose: purchaseDeliberation
            Profile context: \(contextJSON)
            Prior outputs: None
            """

        #expect(!prompt.contains("salary: 100000"))
        #expect(!prompt.contains("private dream"))
        #expect(!prompt.contains("ClientConfidentialContainer"))
    }
}
