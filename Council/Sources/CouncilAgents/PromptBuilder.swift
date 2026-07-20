import CouncilCore
import Foundation

/// Builds inference-message arrays for agents.
///
/// `PromptBuilder` receives only `RoutableProfileContext`, so `ClientConfidentialContainer`
/// contents can never appear in prompts. Profile items are additionally re-filtered
/// against the role's access purpose before encoding (see `filter(_:for:)`).
public enum PromptBuilder {
    /// Builds the complete message list for an agent at a given deliberation stage.
    public static func messages(
        for agent: any Agent,
        role: AgentRole,
        stage: DeliberationStage,
        question: String,
        context: RoutableProfileContext,
        priorOutputs: [AgentOutput]
    ) -> [InferenceMessage] {
        let preamble = (try? ConstitutionLoader.loadBundledText()) ?? ""
        let filteredContext = Self.filter(context, for: role.accessPurpose)
        let profileSnippet = Self.encodedString(filteredContext)
        let priorSnippet = Self.formatPriorOutputs(priorOutputs)

        return [
            InferenceMessage(role: .system, content: preamble),
            InferenceMessage(role: .system, content: role.systemPrompt),
            InferenceMessage(role: .system, content: stage.instructions),
            InferenceMessage(role: .system, content: "Return valid JSON matching: \(stage.outputSchema)"),
            InferenceMessage(role: .user, content: "Question: \(question)"),
            InferenceMessage(role: .user, content: "Access purpose: \(role.accessPurpose.rawValue)"),
            InferenceMessage(role: .user, content: "Profile context: \(profileSnippet)"),
            InferenceMessage(role: .user, content: "Prior outputs: \(priorSnippet)"),
        ]
    }

    private static func encodedString<T: Encodable>(_ value: T) -> String {
        do {
            let data = try JSONEncoder().encode(value)
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    /// Re-filters profile items against the role's access purpose as defense in depth.
    /// Callers are expected to pass a purpose-filtered context (see
    /// `ProfileService.routableContext(purposes:)`), whose filtering rule this mirrors;
    /// an unfiltered `RoutableProfileContext(profile:)` must never widen what reaches
    /// the model, so scoped-out or purpose-denied items are dropped here too.
    private static func filter(_ context: RoutableProfileContext, for purpose: AccessPurpose) -> RoutableProfileContext {
        func isAllowed(accessScope: [AccessPurpose], deniedPurposes: [AccessPurpose]) -> Bool {
            accessScope.contains(purpose) && !deniedPurposes.contains(purpose)
        }
        return RoutableProfileContext(
            values: context.values.filter {
                isAllowed(accessScope: $0.accessScope, deniedPurposes: $0.deniedPurposes)
            },
            goals: context.goals.filter {
                isAllowed(accessScope: $0.accessScope, deniedPurposes: $0.deniedPurposes)
            },
            boundaries: context.boundaries.filter {
                isAllowed(accessScope: $0.accessScope, deniedPurposes: $0.deniedPurposes)
            }
        )
    }

    private static func formatPriorOutputs(_ outputs: [AgentOutput]) -> String {
        guard !outputs.isEmpty else { return "None" }
        return outputs.map { output in
            """
            Agent: \(output.agentID)
            Stance: \(output.stance.rawValue)
            Opinion: \(output.opinion)
            Rationale: \(output.rationale)
            """
        }.joined(separator: "\n\n---\n\n")
    }
}
