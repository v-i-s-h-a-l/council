import CouncilCore
import Foundation

/// Builds inference-message arrays for agents.
///
/// `PromptBuilder` receives only `RoutableProfileContext`, so `ClientConfidentialContainer`
/// contents can never appear in prompts.
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
        let profileSnippet = Self.encodedString(context)
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
