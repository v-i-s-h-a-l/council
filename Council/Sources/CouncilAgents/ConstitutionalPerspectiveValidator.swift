import CouncilCore

/// Rejects perspectives that contain forbidden verdict language or suppress dissent.
public struct ConstitutionalPerspectiveValidator: PerspectiveValidator {
    public init() {}

    public func validate(_ perspective: Perspective) -> PerspectiveValidationResult {
        let forbiddenPhrases = [
            "you should buy",
            "you should not buy",
            "buy it",
            "don't buy",
            "recommendation is",
            "verdict is",
            "the answer is yes",
            "the answer is no",
        ]

        let searchableText = [
            perspective.summary,
            perspective.tradeOffs.joined(separator: " "),
            perspective.blindSpots.joined(separator: " "),
            perspective.dissent.joined(separator: " "),
        ]
        .joined(separator: " ")
        .lowercased()
        // Normalize all whitespace runs (newlines, double spaces, NBSP, …) to single
        // spaces; otherwise "buy\nit" or "buy  it" would evade the substring checks.
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")

        if forbiddenPhrases.contains(where: searchableText.contains) {
            return .invalid(reason: PerspectiveValidationError.verdictLanguageDetected.errorDescription ?? "Verdict language detected")
        }

        if perspective.dissent.isEmpty || perspective.dissent.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return .invalid(reason: PerspectiveValidationError.emptyDissent.errorDescription ?? "Empty dissent")
        }

        return .valid
    }
}
