import CouncilCore
import SwiftUI

/// Renders a final perspective with summary, trade-offs, blind spots, and dissent.
public struct PerspectiveView: View {
    public let perspective: Perspective

    public init(perspective: Perspective) {
        self.perspective = perspective
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(perspective.summary)
                .font(.body)

            if !perspective.tradeOffs.isEmpty {
                section(title: "Trade-offs", items: perspective.tradeOffs, icon: "scale.3d")
            }
            if !perspective.blindSpots.isEmpty {
                section(title: "Blind spots", items: perspective.blindSpots, icon: "eye.slash")
            }
            if !perspective.dissent.isEmpty {
                section(title: "Dissent", items: perspective.dissent, icon: "exclamationmark.bubble")
            }
        }
    }

    @ViewBuilder
    private func section(title: String, items: [String], icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.headline)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 6) {
                    Text("•")
                    Text(item)
                }
                .font(.subheadline)
            }
        }
    }
}
