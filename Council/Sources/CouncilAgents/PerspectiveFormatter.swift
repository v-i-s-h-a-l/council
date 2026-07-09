import CouncilCore
import Foundation

/// Formats a `Perspective` for terminal or UI presentation.
public enum PerspectiveFormatter: Sendable {
    /// Returns a plain-text rendering suitable for terminal output.
    public static func text(_ perspective: Perspective) -> String {
        var lines: [String] = []
        lines.append("Summary")
        lines.append(String(repeating: "-", count: 7))
        lines.append(perspective.summary)
        lines.append("")

        if !perspective.tradeOffs.isEmpty {
            lines.append("Trade-offs")
            lines.append(String(repeating: "-", count: 10))
            for tradeOff in perspective.tradeOffs {
                lines.append("• \(tradeOff)")
            }
            lines.append("")
        }

        if !perspective.blindSpots.isEmpty {
            lines.append("Blind spots")
            lines.append(String(repeating: "-", count: 11))
            for blindSpot in perspective.blindSpots {
                lines.append("• \(blindSpot)")
            }
            lines.append("")
        }

        if !perspective.dissent.isEmpty {
            lines.append("Dissent")
            lines.append(String(repeating: "-", count: 7))
            for note in perspective.dissent {
                lines.append("• \(note)")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Returns a Markdown rendering.
    public static func markdown(_ perspective: Perspective) -> String {
        var lines: [String] = []
        lines.append("## Summary")
        lines.append("")
        lines.append(perspective.summary)
        lines.append("")

        if !perspective.tradeOffs.isEmpty {
            lines.append("## Trade-offs")
            lines.append("")
            for tradeOff in perspective.tradeOffs {
                lines.append("- \(tradeOff)")
            }
            lines.append("")
        }

        if !perspective.blindSpots.isEmpty {
            lines.append("## Blind spots")
            lines.append("")
            for blindSpot in perspective.blindSpots {
                lines.append("- \(blindSpot)")
            }
            lines.append("")
        }

        if !perspective.dissent.isEmpty {
            lines.append("## Dissent")
            lines.append("")
            for note in perspective.dissent {
                lines.append("- \(note)")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Returns a JSON rendering.
    public static func json(_ perspective: Perspective) throws -> String {
        let data = try JSONEncoder().encode(perspective)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
