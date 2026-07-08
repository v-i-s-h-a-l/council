import Testing
import Foundation
import CouncilCore
@testable import CouncilAgents

struct PerspectiveParserTests {

    @Test func parsesValidSynthesisJSON() async throws {
        let raw = """
        {
            "summary": "A balanced view.",
            "tradeOffs": ["Cost vs utility"],
            "blindSpots": ["Long-term maintenance"],
            "dissent": ["Pleasure agent sees value in joy"]
        }
        """

        let perspective = PerspectiveParser.parsePerspective(
            question: "Should I buy a bike?",
            routeDecision: ModelRoutingPolicy.defaultOnDeviceDecision(),
            auditSessionID: UUID(),
            from: raw
        )

        #expect(perspective.summary == "A balanced view.")
        #expect(perspective.tradeOffs == ["Cost vs utility"])
        #expect(perspective.blindSpots == ["Long-term maintenance"])
        #expect(perspective.dissent == ["Pleasure agent sees value in joy"])
    }

    @Test func handlesMalformedJSONWithFallback() async throws {
        let raw = "This is not JSON at all."

        let perspective = PerspectiveParser.parsePerspective(
            question: "Should I buy a bike?",
            routeDecision: ModelRoutingPolicy.defaultOnDeviceDecision(),
            auditSessionID: UUID(),
            from: raw
        )

        #expect(!perspective.summary.isEmpty)
        #expect(perspective.summary == raw)
    }

    @Test func handlesMissingFieldsGracefully() async throws {
        let raw = """
        {
            "summary": "Only a summary is provided."
        }
        """

        let perspective = PerspectiveParser.parsePerspective(
            question: "Should I buy a bike?",
            routeDecision: ModelRoutingPolicy.defaultOnDeviceDecision(),
            auditSessionID: UUID(),
            from: raw
        )

        #expect(perspective.summary == "Only a summary is provided.")
        #expect(perspective.tradeOffs.isEmpty)
        #expect(perspective.blindSpots.isEmpty)
        #expect(perspective.dissent.isEmpty)
    }

    @Test func rawTextFallbackExtractsSections() async throws {
        let raw = """
        Summary: This purchase has real trade-offs.

        Trade-offs:
        - High upfront cost
        - Long battery life

        Blind spots:
        - Resale value

        Dissent:
        - Pleasure agent emphasizes daily joy
        """

        let perspective = PerspectiveParser.parsePerspective(
            question: "Should I buy an e-bike?",
            routeDecision: ModelRoutingPolicy.defaultOnDeviceDecision(),
            auditSessionID: UUID(),
            from: raw
        )

        #expect(perspective.summary == "This purchase has real trade-offs.")
        #expect(perspective.tradeOffs.contains("High upfront cost"))
        #expect(perspective.blindSpots.contains("Resale value"))
        #expect(perspective.dissent.contains("Pleasure agent emphasizes daily joy"))
    }

    @Test func incorporateDissentAppendsNotes() async throws {
        let perspective = Perspective(
            summary: "Summary",
            tradeOffs: [],
            blindSpots: [],
            dissent: ["Existing dissent"]
        )
        let outputs = [
            AgentOutput(agentID: "frugal", opinion: "Too expensive", rationale: "", stance: .skeptical)
        ]

        let updated = PerspectiveParser.incorporateDissent(into: perspective, dissentOutputs: outputs)

        #expect(updated.dissent.count == 2)
        #expect(updated.dissent.contains("Too expensive"))
    }
}
