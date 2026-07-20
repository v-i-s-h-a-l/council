import Testing
import Foundation
import CouncilCore
@testable import CouncilAgents

/// Adversarial coverage for `PerspectiveFormatter`, which previously had a single
/// happy-path test (in CouncilCLITests) and none in this module.
struct PerspectiveFormatterAdversarialTests {

    @Test func emptyPerspectiveRendersOnlySummarySection() async throws {
        let perspective = Perspective()

        let text = PerspectiveFormatter.text(perspective)
        #expect(text.contains("Summary"))
        #expect(!text.contains("Trade-offs"))
        #expect(!text.contains("Blind spots"))
        #expect(!text.contains("Dissent"))

        let markdown = PerspectiveFormatter.markdown(perspective)
        #expect(markdown.contains("## Summary"))
        #expect(!markdown.contains("## Trade-offs"))
        #expect(!markdown.contains("## Blind spots"))
        #expect(!markdown.contains("## Dissent"))
    }

    @Test func jsonRoundTripsThroughCodable() async throws {
        let perspective = Perspective(
            summary: "Summary",
            tradeOffs: ["t1", "t2"],
            blindSpots: ["b1"],
            dissent: ["d1", "d2", "d3"]
        )

        let json = try PerspectiveFormatter.json(perspective)
        let data = try #require(json.data(using: .utf8))
        let decoded = try JSONDecoder().decode(Perspective.self, from: data)

        #expect(decoded.summary == perspective.summary)
        #expect(decoded.tradeOffs == perspective.tradeOffs)
        #expect(decoded.blindSpots == perspective.blindSpots)
        #expect(decoded.dissent == perspective.dissent)
    }

    /// PINNED: entries are embedded verbatim. An entry containing a newline (or a
    /// leading bullet marker) breaks the one-line-per-item layout — the formatter
    /// does no escaping or indentation. Both renderers share the behavior.
    @Test func entriesContainingNewlinesBreakOneLinePerItemLayout() async throws {
        let perspective = Perspective(
            summary: "Summary",
            dissent: ["line one\nline two", "- looks like a bullet"]
        )

        let text = PerspectiveFormatter.text(perspective)
        #expect(text.contains("• line one\nline two"))
        #expect(text.contains("• - looks like a bullet"))

        let markdown = PerspectiveFormatter.markdown(perspective)
        #expect(markdown.contains("- line one\nline two"))
    }

    /// A dissent array an order of magnitude beyond anything a model should produce
    /// still renders without crashing (documents unbounded growth is tolerated).
    @Test func veryLargeDissentArrayRendersWithoutCrashing() async throws {
        let perspective = Perspective(
            summary: "Summary",
            dissent: (0..<10_000).map { "dissent note \($0)" }
        )

        let text = PerspectiveFormatter.text(perspective)
        #expect(text.contains("dissent note 0"))
        #expect(text.contains("dissent note 9999"))
    }
}
