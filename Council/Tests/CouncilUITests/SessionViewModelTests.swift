import CouncilAgents
import CouncilCore
import CouncilTestUtilities
import CouncilUI
import Foundation
import Testing

@MainActor
struct SessionViewModelTests {
    /// Thirteen canned responses matching the Purchase Council call order.
    private static func perspectiveResponses() -> [String] {
        [
            // First opinions
            "This seems expensive.",
            "Will this matter in five years?",
            "Total cost of ownership matters.",
            "This brings joy.",
            // Peer reviews
            "{\"critiques\":[\"price\"]}",
            "{\"critiques\":[\"longevity\"]}",
            "{\"critiques\":[\"maintenance\"]}",
            "{\"critiques\":[\"impulse\"]}",
            // Synthesis
            """
            {"summary":"A balanced view.",\
            "tradeOffs":["cost","utility"],\
            "blindSpots":["resale"],\
            "dissent":["Wait for a sale"]}
            """,
            // Dissent preservation
            "{\"objection\":\"Wait for a sale.\",\"basis\":\"Price\",\"conditions\":\"If not urgent\"}",
            "{\"objection\":\"Align with goals.\",\"basis\":\"Values\",\"conditions\":\"If budget allows\"}",
            "{\"objection\":\"Check repairability.\",\"basis\":\"Longevity\",\"conditions\":\"Before buying\"}",
            "{\"objection\":\"Borrow first.\",\"basis\":\"Trial\",\"conditions\":\"If possible\"}",
        ]
    }

    @Test func startSessionProducesPerspective() async throws {
        let provider = MockInferenceProvider(
            cannedResponses: Self.perspectiveResponses(),
            chunkDelayNanoseconds: 0
        )
        let service = DeliberationService(
            provider: provider,
            council: PurchaseCouncil(),
            validators: [ConstitutionalPerspectiveValidator()]
        )
        let viewModel = SessionViewModel(service: service)
        viewModel.question = "Should I buy a used bike?"

        viewModel.start()

        while viewModel.isRunning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(viewModel.sessionState == .presentation)
        #expect(viewModel.perspective?.summary == "A balanced view.")
        #expect(viewModel.perspective?.dissent.isEmpty == false)
        #expect(viewModel.error == nil)
    }

    @Test func cancelSessionStopsRunning() async throws {
        let provider = MockInferenceProvider(
            cannedResponses: ["delay"],
            chunkDelayNanoseconds: 100_000_000
        )
        let service = DeliberationService(
            provider: provider,
            council: PurchaseCouncil(),
            validators: []
        )
        let viewModel = SessionViewModel(service: service)
        viewModel.question = "Should I buy a used bike?"

        viewModel.start()
        try await Task.sleep(nanoseconds: 10_000_000)
        viewModel.cancel()

        #expect(!viewModel.isRunning)
    }
}
