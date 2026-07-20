import Testing
import CouncilCore
import CouncilTestUtilities
@testable import CouncilAgents

struct DeliberationStateMachineTests {

    @Test func fiveStageFlowProducesPerspective() async throws {
        let responses = [
            // First opinions (4 agents, concurrent; identical responses are safe)
            #"{"opinion": "Costly relative to value.", "rationale": "Utility per dollar"}"#,
            #"{"opinion": "Costly relative to value.", "rationale": "Utility per dollar"}"#,
            #"{"opinion": "Costly relative to value.", "rationale": "Utility per dollar"}"#,
            #"{"opinion": "Costly relative to value.", "rationale": "Utility per dollar"}"#,
            // Peer reviews (4 agents, sequential)
            #"{"critiques": ["Could consider alternatives"]}"#,
            #"{"critiques": ["Long-term costs unclear"]}"#,
            #"{"critiques": ["May undervalue reliability"]}"#,
            #"{"critiques": ["Joy deserves a seat at the table"]}"#,
            // Chair synthesis
            #"{"summary": "Balanced view.", "tradeOffs": ["Upfront cost vs daily utility"], "blindSpots": ["Resale value uncertainty"], "dissent": ["Joy matters"]}"#,
            // Dissent preservation (4 agents, sequential)
            #"{"objection": "Frugal view undervalues reliability.", "basis": "Total cost of ownership", "conditions": "If cheaper option fails sooner"}"#,
            #"{"objection": "No objection.", "basis": "Synthesis is fair", "conditions": ""}"#,
            #"{"objection": "Blind spot on warranty coverage.", "basis": "Risk exposure", "conditions": "If warranty is short"}"#,
            #"{"objection": "Daily joy is underweighted.", "basis": "Quality of life", "conditions": "If budget is truly affordable"}"#,
        ]

        let provider = MockInferenceProvider(cannedResponses: responses)
        let service = DeliberationService(
            provider: provider,
            council: PurchaseCouncil(),
            validators: [ConstitutionalPerspectiveValidator()],
            context: RoutableProfileContext()
        )

        let stream = await service.stateUpdates()
        let collectionTask = Task {
            var states: [DeliberationState] = []
            for await state in stream {
                states.append(state)
            }
            return states
        }

        await service.startSession(question: "Should I buy a new laptop?")
        let states = await collectionTask.value

        // Verify the final state is presentation with a perspective.
        let finalState = try #require(states.last)
        #expect(finalState.stage == .presentation)
        #expect(finalState.question == "Should I buy a new laptop?")
        let perspective = try #require(finalState.perspective)
        #expect(perspective.summary == "Balanced view.")
        #expect(!perspective.tradeOffs.isEmpty)
        #expect(!perspective.blindSpots.isEmpty)
        #expect(!perspective.dissent.isEmpty)

        // Verify stage order: the working stages must appear in sequence, not just
        // be present somewhere in the stream.
        let stageSequence = states.map(\.stage)
        #expect(stageSequence.first == .idle)
        #expect(stageSequence.last == .presentation)
        let orderedStages: [DeliberationStage] = [.firstOpinions, .peerReview, .synthesis, .dissentPreservation]
        var searchStart = stageSequence.startIndex
        for stage in orderedStages {
            let index = try #require(
                stageSequence[searchStart...].firstIndex(of: stage),
                "Stage \(stage) missing or out of order"
            )
            searchStart = stageSequence.index(after: index)
        }

        // Verify all agent outputs were recorded.
        #expect(finalState.agentOutputs.count == 13)
    }

    @Test func retryOnValidationFailureThenSucceed() async throws {
        let responses = [
            // First opinions x4
            #"{"opinion": "Costly relative to value.", "rationale": "Utility per dollar"}"#,
            #"{"opinion": "Costly relative to value.", "rationale": "Utility per dollar"}"#,
            #"{"opinion": "Costly relative to value.", "rationale": "Utility per dollar"}"#,
            #"{"opinion": "Costly relative to value.", "rationale": "Utility per dollar"}"#,
            // Peer reviews x4
            #"{"critiques": ["Could consider alternatives"]}"#,
            #"{"critiques": ["Long-term costs unclear"]}"#,
            #"{"critiques": ["May undervalue reliability"]}"#,
            #"{"critiques": ["Joy deserves a seat at the table"]}"#,
            // First synthesis: contains forbidden verdict language
            #"{"summary": "You should buy this because it is useful.", "tradeOffs": [], "blindSpots": [], "dissent": ["Frugal disagrees"]}"#,
            // Dissent preservation x4 for failed synthesis
            #"{"objection": "Verdict language is present.", "basis": "Constitution", "conditions": ""}"#,
            #"{"objection": "No objection.", "basis": "", "conditions": ""}"#,
            #"{"objection": "No objection.", "basis": "", "conditions": ""}"#,
            #"{"objection": "No objection.", "basis": "", "conditions": ""}"#,
            // Retry synthesis: valid
            #"{"summary": "Balanced retry view.", "tradeOffs": ["Cost vs utility"], "blindSpots": ["Reliability unknown"], "dissent": ["Joy matters"]}"#,
            // Dissent preservation x4 for retry synthesis
            #"{"objection": "No objection.", "basis": "", "conditions": ""}"#,
            #"{"objection": "No objection.", "basis": "", "conditions": ""}"#,
            #"{"objection": "No objection.", "basis": "", "conditions": ""}"#,
            #"{"objection": "No objection.", "basis": "", "conditions": ""}"#,
        ]

        let provider = MockInferenceProvider(cannedResponses: responses)
        let service = DeliberationService(
            provider: provider,
            council: PurchaseCouncil(),
            validators: [ConstitutionalPerspectiveValidator()],
            context: RoutableProfileContext()
        )

        let stream = await service.stateUpdates()
        let collectionTask = Task {
            var states: [DeliberationState] = []
            for await state in stream {
                states.append(state)
            }
            return states
        }

        await service.startSession(question: "Should I buy a new laptop?")
        let states = await collectionTask.value

        let finalState = try #require(states.last)
        #expect(finalState.stage == .presentation)
        let perspective = try #require(finalState.perspective)
        #expect(perspective.summary == "Balanced retry view.")
        #expect(!perspective.dissent.isEmpty)
    }
}
