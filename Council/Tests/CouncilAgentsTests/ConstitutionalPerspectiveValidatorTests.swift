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
            assertResult(result, isInvalidWithReason: PerspectiveValidationError.verdictLanguageDetected.errorDescription!)
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
        assertResult(result, isInvalidWithReason: PerspectiveValidationError.emptyDissent.errorDescription!)
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
