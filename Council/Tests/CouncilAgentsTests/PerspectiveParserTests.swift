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

    // MARK: - Adversarial additions

    /// Regression: models very commonly wrap JSON in a ```json fence; the payload
    /// must decode instead of degrading into the raw-text fallback (which filed the
    /// fence lines as summary/trade-offs and then failed validation on empty dissent).
    @Test func synthesisWrappedInMarkdownCodeFenceParsesAsJSON() async throws {
        let raw = """
        ```json
        {"summary": "Fenced summary.", "tradeOffs": ["t"], "blindSpots": [], "dissent": ["d"]}
        ```
        """

        let perspective = PerspectiveParser.parsePerspective(
            question: "Should I buy a bike?",
            routeDecision: ModelRoutingPolicy.defaultOnDeviceDecision(),
            auditSessionID: UUID(),
            from: raw
        )

        #expect(perspective.summary == "Fenced summary.")
        #expect(perspective.tradeOffs == ["t"])
        #expect(perspective.dissent == ["d"])
    }

    @Test func dissentWrappedInMarkdownCodeFenceParsesAsJSON() async throws {
        let raw = """
        ```
        {"objection": "Too costly.", "basis": "Budget", "conditions": "If price drops"}
        ```
        """

        let dissent = PerspectiveParser.parseDissent(from: raw)

        #expect(dissent.objection == "Too costly.")
        #expect(dissent.basis == "Budget")
        #expect(dissent.conditions == "If price drops")
    }

    /// Regression: dissent-preservation responses follow the `DissentOutput` schema;
    /// incorporating them must render readable notes, not raw JSON blobs (which used
    /// to corrupt both UI output and persisted episodes).
    @Test func incorporateDissentRendersReadableNotesFromJSON() async throws {
        let perspective = Perspective(summary: "Summary", dissent: ["Existing dissent"])
        let outputs = [
            AgentOutput(
                agentID: "frugal",
                opinion: #"{"objection": "Undervalues reliability.", "basis": "TCO", "conditions": "If it fails early"}"#,
                rationale: "",
                stance: .skeptical
            ),
        ]

        let updated = PerspectiveParser.incorporateDissent(into: perspective, dissentOutputs: outputs)

        #expect(updated.dissent.count == 2)
        let note = try #require(updated.dissent.last)
        #expect(!note.hasPrefix("{"))
        #expect(!note.contains(#""objection""#))
        #expect(note.contains("Undervalues reliability."))
        #expect(note.contains("Basis: TCO"))
        #expect(note.contains("Conditions: If it fails early"))
    }

    /// PINNED: a type mismatch anywhere fails the whole decode and the JSON source
    /// is then treated as prose, so the summary silently becomes the raw JSON line.
    @Test func synthesisJSONWithWrongTypesFallsBackToRawText() async throws {
        let raw = #"{"summary": 123, "tradeOffs": "not-an-array"}"#

        let synthesis = PerspectiveParser.parseSynthesis(from: raw)

        #expect(synthesis.summary.contains(#""summary": 123"#))
        #expect(synthesis.dissent.isEmpty)
    }

    /// PINNED boundary behavior: with no section headers, the first prose line
    /// becomes the summary and every later line is silently filed as a "trade-off".
    @Test func multiLinePlainProseFilesExtraLinesAsTradeOffs() async throws {
        let raw = """
        The laptop is expensive but durable.
        It also has excellent resale value.
        """

        let synthesis = PerspectiveParser.parseSynthesis(from: raw)

        #expect(synthesis.summary == "The laptop is expensive but durable.")
        #expect(synthesis.tradeOffs == ["It also has excellent resale value."])
    }

    /// PINNED: `question`, `routeDecision`, and `auditSessionID` are accepted but
    /// ignored — the implied audit traceability does not exist. If the parameters
    /// are ever wired up (or deleted), this test must be revisited.
    @Test func parsePerspectiveIgnoresMetadataParameters() async throws {
        let raw = #"{"summary": "S", "tradeOffs": ["t"], "blindSpots": ["b"], "dissent": ["d"]}"#
        let onDevice = ModelRoutingPolicy.defaultOnDeviceDecision()
        let cloud = RouteDecision(
            selectedRoute: .thirdPartyCloud,
            providerMetadata: RouteSnapshot(
                framework: "other",
                modelIdentifier: "other",
                route: .thirdPartyCloud,
                isLocal: false
            )
        )

        let first = PerspectiveParser.parsePerspective(
            question: "question one",
            routeDecision: onDevice,
            auditSessionID: UUID(),
            from: raw
        )
        let second = PerspectiveParser.parsePerspective(
            question: "a completely different question",
            routeDecision: cloud,
            auditSessionID: UUID(),
            from: raw
        )

        #expect(first.summary == second.summary)
        #expect(first.tradeOffs == second.tradeOffs)
        #expect(first.blindSpots == second.blindSpots)
        #expect(first.dissent == second.dissent)
    }

    /// PINNED off-by-one in the (currently unused) public fallback: empty input
    /// yields `[""]` rather than `[]`.
    @Test func parsePeerReviewEmptyStringYieldsSingleEmptyCritique() async throws {
        #expect(PerspectiveParser.parsePeerReview(from: "").critiques == [""])
        #expect(PerspectiveParser.parsePeerReview(from: "   \n ").critiques == [""])
    }

    @Test func parseFirstOpinionEmptyStringYieldsEmptyOpinion() async throws {
        let opinion = PerspectiveParser.parseFirstOpinion(from: "")
        #expect(opinion.opinion == "")
        #expect(opinion.rationale == "")
    }
}
