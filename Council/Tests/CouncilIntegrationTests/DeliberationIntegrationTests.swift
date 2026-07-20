import CouncilAgents
import CouncilCore
import CouncilMemory
import CouncilTestUtilities
import Foundation
import Testing

/// End-to-end deliberation integration tests using mocked inference and in-memory stores.
struct DeliberationIntegrationTests {
    /// Thirteen canned responses matching the Purchase Council call order:
    /// 4 first opinions, 4 peer reviews, 1 synthesis, 4 dissent preservation.
    private static func perspectiveResponses() -> [String] {
        [
            // First opinions
            "This seems expensive; consider used alternatives.",
            "Will this matter in five years?",
            "Total cost of ownership includes maintenance and resale.",
            "This brings immediate joy and utility.",
            // Peer reviews
            "{\"critiques\":[\"price is high\",\"quality uncertain\"]}",
            "{\"critiques\":[\"longevity matters\",\"future regret possible\"]}",
            "{\"critiques\":[\"maintenance cost ignored\",\"ecosystem lock-in\"]}",
            "{\"critiques\":[\"joy is valid\",\"impulse risk\"]}",
            // Synthesis
            """
            {"summary":"A balanced view: useful but not urgent.",\
            "tradeOffs":["upfront cost","daily utility"],\
            "blindSpots":["resale value","warranty"],\
            "dissent":["Could find a cheaper used option"]}
            """,
            // Dissent preservation
            "{\"objection\":\"Wait for a sale.\",\"basis\":\"Price elasticity\",\"conditions\":\"If not time-sensitive\"}",
            "{\"objection\":\"Buy only if it advances a goal.\",\"basis\":\"Values alignment\",\"conditions\":\"If budget allows\"}",
            "{\"objection\":\"Check repairability score.\",\"basis\":\"Longevity\",\"conditions\":\"Before deciding\"}",
            "{\"objection\":\"Rent or borrow first.\",\"basis\":\"Trial\",\"conditions\":\"If available\"}",
        ]
    }

    @Test func deliberationRecordsPurposeBoundAccessDecision() async throws {
        let provider = MockInferenceProvider(
            cannedResponses: Self.perspectiveResponses(),
            chunkDelayNanoseconds: 0
        )
        let store = MockMemoryStore()
        let auditLog = MockAuditLog()
        let memoryService = MemoryService(store: store, auditLog: auditLog)
        let service = DeliberationService(
            provider: provider,
            council: PurchaseCouncil(),
            validators: [ConstitutionalPerspectiveValidator()],
            context: RoutableProfileContext(),
            options: InferenceOptions(),
            memoryService: memoryService
        )

        let stream = await service.stateUpdates()
        await service.startSession(question: "Should I buy a used bike?")
        for await _ in stream {}

        let entries = await auditLog.entries
        let access = entries.first { $0.category == .memoryAccess }
        #expect(access != nil)
        #expect(access?.payload["purpose"] == AccessPurpose.purchaseDeliberation.rawValue)
        #expect(access?.payload["dataElementType"] == "RoutableProfileContext")
        #expect(access?.payload["decision"] == "allowed")
    }
}
