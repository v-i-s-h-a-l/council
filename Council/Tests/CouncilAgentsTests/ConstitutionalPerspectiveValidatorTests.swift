import Testing
import CouncilCore
@testable import CouncilAgents

struct ConstitutionalPerspectiveValidatorTests {

    let validator = ConstitutionalPerspectiveValidator()

    @Test func rejectsForbiddenVerdictPhrases() async throws {
        let phrases = [
            "you should buy this product",
            "you should not buy it",
            "buy it now",
            "don't buy this",
            "recommendation is yes",
            "verdict is no",
            "the answer is yes",
            "the answer is no",
        ]

        for phrase in phrases {
            let perspective = Perspective(
                summary: phrase,
                tradeOffs: [],
                blindSpots: [],
                dissent: ["Frugal disagrees"]
            )
            let result = validator.validate(perspective)
            assertResult(result, isInvalidWithReason: "Verdict language detected in perspective.")
        }
    }

    @Test func rejectsEmptyDissent() async throws {
        let perspective = Perspective(
            summary: "A balanced perspective with no dissent.",
            tradeOffs: [],
            blindSpots: [],
            dissent: []
        )
        let result = validator.validate(perspective)
        assertResult(result, isInvalidWithReason: "Dissent array is empty.")
    }

    @Test func acceptsValidPerspective() async throws {
        let perspective = Perspective(
            summary: "This purchase has trade-offs worth considering.",
            tradeOffs: ["Cost versus utility"],
            blindSpots: ["Unknown long-term reliability"],
            dissent: ["Pleasure agent values daily joy"]
        )
        let result = validator.validate(perspective)
        assertResultIsValid(result)
    }

    // MARK: - Adversarial additions

    /// Exercises the `.lowercased()` normalization that the pre-lowercased phrase
    /// list in `rejectsForbiddenVerdictPhrases` never reaches.
    @Test func rejectsUppercaseVerdictPhrases() async throws {
        let perspective = Perspective(
            summary: "YOU SHOULD BUY THIS LAPTOP",
            tradeOffs: [],
            blindSpots: [],
            dissent: ["Frugal disagrees"]
        )
        assertResult(
            validator.validate(perspective),
            isInvalidWithReason: "Verdict language detected in perspective."
        )
    }

    /// Regression: newlines, repeated spaces, tabs, and non-breaking spaces
    /// previously evaded the substring check and let verdict language through.
    @Test func rejectsWhitespaceEvasionOfForbiddenPhrases() async throws {
        let evasions = [
            "buy\nit now",
            "buy  it now",
            "buy\u{00A0}it now",
            "you\tshould\tbuy this",
        ]

        for phrase in evasions {
            let perspective = Perspective(
                summary: "After careful thought, \(phrase)",
                tradeOffs: [],
                blindSpots: [],
                dissent: ["Frugal disagrees"]
            )
            assertResult(
                validator.validate(perspective),
                isInvalidWithReason: "Verdict language detected in perspective."
            )
        }
    }

    /// PINNED FALSE POSITIVE: "buy it" as a bare substring matches legitimate
    /// prose, so a balanced perspective is rejected — and after the retry budget is
    /// exhausted the entire session fails. Kept green to document the over-broad
    /// phrase list until the matcher is fixed deliberately.
    @Test func legitimatePerspectiveContainingBuyItSubstringIsRejected_knownFalsePositive() async throws {
        let perspective = Perspective(
            summary: "Weigh whether to buy it outright or lease it.",
            tradeOffs: ["Ownership versus flexibility"],
            blindSpots: ["Resale value"],
            dissent: ["Frugal prefers leasing"]
        )
        assertResult(
            validator.validate(perspective),
            isInvalidWithReason: "Verdict language detected in perspective."
        )
    }

    @Test func boundaryConditions() async throws {
        // (a) PINNED GAP: an empty summary is currently accepted — the validator
        // only checks verdict language and dissent presence.
        let emptySummary = Perspective(summary: "", dissent: ["Frugal disagrees"])
        assertResultIsValid(validator.validate(emptySummary))

        // (b) Whitespace-only dissent counts as empty.
        let whitespaceDissent = Perspective(summary: "S", dissent: ["   \n "])
        assertResult(
            validator.validate(whitespaceDissent),
            isInvalidWithReason: "Dissent array is empty."
        )

        // (c) PINNED: verdict phrases inside *dissent* entries also reject the
        // perspective, because dissent text is part of the searchable corpus — a
        // dissent note that quotes verdict language trips the filter.
        let dissentQuotingVerdict = Perspective(
            summary: "Balanced view.",
            dissent: [#"Chair draft wrote "you should buy it", which was rejected"#]
        )
        assertResult(
            validator.validate(dissentQuotingVerdict),
            isInvalidWithReason: "Verdict language detected in perspective."
        )
    }
}

private func assertResult(
    _ result: PerspectiveValidationResult,
    isInvalidWithReason expectedReason: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    switch result {
    case .valid:
        Issue.record("Expected invalid result", sourceLocation: sourceLocation)
    case .invalid(let reason):
        #expect(reason == expectedReason, sourceLocation: sourceLocation)
    }
}

private func assertResultIsValid(
    _ result: PerspectiveValidationResult,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    if case .invalid(let reason) = result {
        Issue.record("Expected valid result but got invalid: \(reason)", sourceLocation: sourceLocation)
    }
}
