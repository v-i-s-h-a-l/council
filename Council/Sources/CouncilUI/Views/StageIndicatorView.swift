import CouncilCore
import SwiftUI

/// Five-stage deliberation progress indicator.
public struct StageIndicatorView: View {
    public let currentStage: DeliberationStage
    public let reduceMotion: Bool

    public static let orderedStages: [DeliberationStage] = [
        .firstOpinions,
        .peerReview,
        .synthesis,
        .dissentPreservation,
        .presentation,
    ]

    public init(currentStage: DeliberationStage, reduceMotion: Bool = false) {
        self.currentStage = currentStage
        self.reduceMotion = reduceMotion
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(Self.orderedStages, id: \.self) { stage in
                StageStep(
                    stage: stage,
                    isActive: stage == currentStage,
                    isCompleted: isCompleted(stage)
                )
                if stage != Self.orderedStages.last {
                    Spacer()
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut, value: currentStage)
    }

    private func isCompleted(_ stage: DeliberationStage) -> Bool {
        guard let currentIndex = Self.orderedStages.firstIndex(of: currentStage),
              let stageIndex = Self.orderedStages.firstIndex(of: stage) else {
            return false
        }
        return stageIndex < currentIndex
    }
}

private struct StageStep: View {
    let stage: DeliberationStage
    let isActive: Bool
    let isCompleted: Bool

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(isActive ? Color.accentColor : (isCompleted ? Color.green : Color.gray.opacity(0.3)))
                    .frame(width: 24, height: 24)
                if isCompleted && !isActive {
                    Image(systemName: "checkmark")
                        .font(.caption2)
                        .foregroundStyle(.white)
                } else {
                    Text("\(stageNumber)")
                        .font(.caption2)
                        .foregroundStyle(isActive ? .white : .primary)
                }
            }
            Text(stageName)
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(isActive ? .primary : .secondary)
        }
    }

    private var stageNumber: Int {
        StageIndicatorView.orderedStages.firstIndex(of: stage).map { $0 + 1 } ?? 0
    }

    private var stageName: String {
        switch stage {
        case .firstOpinions:
            return "Opinions"
        case .peerReview:
            return "Review"
        case .synthesis:
            return "Synthesis"
        case .dissentPreservation:
            return "Dissent"
        case .presentation:
            return "Perspective"
        default:
            return ""
        }
    }
}
