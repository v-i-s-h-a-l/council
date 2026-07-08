import CouncilCore

public extension DeliberationStage {
    /// Stage-specific instructions for the agent.
    var instructions: String {
        switch self {
        case .firstOpinions:
            return """
            Submit your first opinion on the question.
            State your view, the key reasons behind it, and the uncertainties you see.
            Do not agree with other agents merely to reach consensus.
            """
        case .peerReview:
            return """
            Review the opinions submitted by the other agents.
            Identify strengths, weaknesses, assumptions, and missing considerations.
            Do not agree with other agents merely to reach consensus.
            """
        case .synthesis:
            return """
            Synthesize a balanced perspective from the prior opinions and reviews.
            Produce a summary, trade-offs, blind spots, and dissent notes.
            Preserve every substantive dissent note verbatim; do not dilute disagreement.
            """
        case .dissentPreservation:
            return """
            Critique the Chair's synthesized perspective.
            If you disagree with any part, state your objection, the basis, and the conditions under which you would change your mind.
            If you have no objection, say so explicitly and explain why.
            """
        case .presentation:
            return "Present the final perspective to the user."
        case .idle, .cancelled, .failed:
            return ""
        }
    }

    /// JSON schema expected from the agent for this stage.
    var outputSchema: String {
        switch self {
        case .firstOpinions:
            return """
            {"opinion": "string", "rationale": "string"}
            """
        case .peerReview:
            return """
            {"critiques": ["string"]}
            """
        case .synthesis:
            return """
            {"summary": "string", "tradeOffs": ["string"], "blindSpots": ["string"], "dissent": ["string"]}
            """
        case .dissentPreservation:
            return """
            {"objection": "string or empty", "basis": "string or empty", "conditions": "string or empty"}
            """
        case .presentation:
            return ""
        case .idle, .cancelled, .failed:
            return ""
        }
    }
}
