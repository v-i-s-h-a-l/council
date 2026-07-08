import CouncilCore
import SwiftUI

/// Expandable card displaying an agent's output.
public struct AgentCardView: View {
    public let output: AgentOutput
    public var reduceMotion: Bool = false

    @State private var isExpanded: Bool = false

    public init(output: AgentOutput, reduceMotion: Bool = false) {
        self.output = output
        self.reduceMotion = reduceMotion
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: {
                withAnimation(reduceMotion ? nil : .default) {
                    isExpanded.toggle()
                }
            }) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(output.agentID)
                            .font(.headline)
                        Text(stanceLabel(output.stance))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text(output.opinion)
                        .font(.body)
                    if !output.rationale.isEmpty {
                        Text("Rationale: \(output.rationale)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func stanceLabel(_ stance: AgentStance) -> String {
        switch stance {
        case .skeptical:
            return "Skeptical"
        case .aspirational:
            return "Aspirational"
        case .analytical:
            return "Analytical"
        case .affirmative:
            return "Affirmative"
        case .neutral:
            return "Neutral (Chair)"
        }
    }
}
