import CouncilCore
import CouncilMemory
import CouncilTestUtilities
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
            journalEntries: [
                JournalEntry(text: "private dream about flying"),
                JournalEntry(text: "argument with a friend"),
            ]
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
        #expect(!json.contains("journalEntries"))
        #expect(!json.contains("ClientConfidentialContainer"))
    }

    @Test func renderedPromptFromPurposeFilteredContextExcludesDeniedAndConfidentialData() async throws {
        let profile = UserProfile(
            values: [
                ValueStatement(text: "Frugality"),
                ValueStatement(text: "Secret salary talk", deniedPurposes: [.purchaseDeliberation]),
            ],
            goals: [Goal(text: "Save for travel")],
            boundaries: [Boundary(text: "No impulse buys")],
            financialHistory: ClientConfidentialContainer(items: ["salary: 100000"]),
            journalEntries: [JournalEntry(text: "private dream")]
        )
        let service = ProfileService(vault: MockProfileVault(profile: profile))

        // Differentiated from the test above: this goes through the PBAC-filtered
        // routableContext(purposes:) path that real prompt construction must use,
        // so purpose-denied items are excluded in addition to confidential ones.
        let context = try await service.routableContext(purposes: [.purchaseDeliberation])
        let contextJSON = String(data: try JSONEncoder().encode(context), encoding: .utf8) ?? ""
        let prompt = """
            Question: Should I buy a car?
            Access purpose: purchaseDeliberation
            Profile context: \(contextJSON)
            Prior outputs: None
            """

        #expect(!prompt.contains("salary: 100000"))
        #expect(!prompt.contains("private dream"))
        #expect(!prompt.contains("Secret salary talk"))
        #expect(!prompt.contains("ClientConfidentialContainer"))
        // Allowed items still reach the prompt.
        #expect(prompt.contains("Frugality"))
        #expect(prompt.contains("Save for travel"))
        #expect(prompt.contains("No impulse buys"))
    }
}
