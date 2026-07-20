import CouncilCore
import Foundation

// MARK: - Intermediate outputs

public struct FirstOpinionOutput: Codable, Sendable {
    public var opinion: String
    public var rationale: String
}

public struct PeerReviewOutput: Codable, Sendable {
    public var critiques: [String]
}

public struct SynthesisOutput: Codable, Sendable {
    public var summary: String
    public var tradeOffs: [String]
    public var blindSpots: [String]
    public var dissent: [String]

    public init(
        summary: String = "",
        tradeOffs: [String] = [],
        blindSpots: [String] = [],
        dissent: [String] = []
    ) {
        self.summary = summary
        self.tradeOffs = tradeOffs
        self.blindSpots = blindSpots
        self.dissent = dissent
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        tradeOffs = try container.decodeIfPresent([String].self, forKey: .tradeOffs) ?? []
        blindSpots = try container.decodeIfPresent([String].self, forKey: .blindSpots) ?? []
        dissent = try container.decodeIfPresent([String].self, forKey: .dissent) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case summary
        case tradeOffs
        case blindSpots
        case dissent
    }
}

public struct DissentOutput: Codable, Sendable {
    public var objection: String
    public var basis: String
    public var conditions: String
}

// MARK: - Parser

public enum PerspectiveParser {
    public static func parseFirstOpinion(from raw: String) -> FirstOpinionOutput {
        if let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(FirstOpinionOutput.self, from: data) {
            return decoded
        }
        return FirstOpinionOutput(
            opinion: raw.trimmingCharacters(in: .whitespacesAndNewlines),
            rationale: ""
        )
    }

    public static func parsePeerReview(from raw: String) -> PeerReviewOutput {
        if let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(PeerReviewOutput.self, from: data) {
            return decoded
        }
        return PeerReviewOutput(critiques: [raw.trimmingCharacters(in: .whitespacesAndNewlines)])
    }

    public static func parseSynthesis(from raw: String) -> SynthesisOutput {
        let candidate = strippingCodeFence(raw)
        if let data = candidate.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(SynthesisOutput.self, from: data) {
            return decoded
        }
        return rawTextSynthesis(raw)
    }

    public static func parseDissent(from raw: String) -> DissentOutput {
        let candidate = strippingCodeFence(raw)
        if let data = candidate.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(DissentOutput.self, from: data) {
            return decoded
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return DissentOutput(
            objection: trimmed,
            basis: "",
            conditions: ""
        )
    }

    /// Models frequently wrap JSON payloads in a Markdown code fence (```json … ```).
    /// Strip the fence so the payload can decode; anything else is returned unchanged.
    private static func strippingCodeFence(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return raw }
        var lines = trimmed.components(separatedBy: .newlines)
        lines.removeFirst()
        if let last = lines.last,
           last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    /// Parses the Chair's raw synthesis into the final `Perspective`.
    public static func parsePerspective(
        question: String,
        routeDecision: RouteDecision,
        auditSessionID: UUID,
        from raw: String
    ) -> Perspective {
        let synthesis = parseSynthesis(from: raw)
        return Perspective(
            summary: synthesis.summary,
            tradeOffs: synthesis.tradeOffs,
            blindSpots: synthesis.blindSpots,
            dissent: synthesis.dissent
        )
    }

    /// Incorporates dissent-preservation agent outputs into a perspective.
    ///
    /// Dissent-preservation agents answer with the `DissentOutput` JSON schema;
    /// each response is parsed and rendered as a readable note. Appending the raw
    /// opinion strings would leak raw JSON blobs into the UI and persisted episodes.
    public static func incorporateDissent(
        into perspective: Perspective,
        dissentOutputs: [AgentOutput]
    ) -> Perspective {
        var updated = perspective
        let notes = dissentOutputs
            .map { formattedDissentNote(from: $0.opinion) }
            .filter { !$0.isEmpty }
        updated.dissent.append(contentsOf: notes)
        return updated
    }

    /// Renders one dissent-preservation response as a readable note. Plain-text
    /// (non-JSON) responses are kept verbatim via `parseDissent`'s fallback.
    private static func formattedDissentNote(from raw: String) -> String {
        let dissent = parseDissent(from: raw)
        var parts: [String] = [dissent.objection]
        if !dissent.basis.isEmpty {
            parts.append("Basis: \(dissent.basis)")
        }
        if !dissent.conditions.isEmpty {
            parts.append("Conditions: \(dissent.conditions)")
        }
        return parts.joined(separator: "; ")
    }

    private static func rawTextSynthesis(_ raw: String) -> SynthesisOutput {
        let lines = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var summary = ""
        var tradeOffs: [String] = []
        var blindSpots: [String] = []
        var dissent: [String] = []

        var currentSection: String?
        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("summary") || lower.hasPrefix("# summary") {
                currentSection = "summary"
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count > 1 {
                    summary = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                continue
            }
            if lower.hasPrefix("trade") || lower.hasPrefix("# trade") {
                currentSection = "tradeoffs"
                continue
            }
            if lower.hasPrefix("blind") || lower.hasPrefix("# blind") {
                currentSection = "blindspots"
                continue
            }
            if lower.hasPrefix("dissent") || lower.hasPrefix("# dissent") {
                currentSection = "dissent"
                continue
            }

            let cleaned = String(line.trimmingPrefix(/^[-*•]\s+/))
            switch currentSection {
            case "summary":
                summary += (summary.isEmpty ? "" : " ") + cleaned
            case "tradeoffs":
                tradeOffs.append(cleaned)
            case "blindspots":
                blindSpots.append(cleaned)
            case "dissent":
                dissent.append(cleaned)
            default:
                if summary.isEmpty {
                    summary = cleaned
                } else {
                    tradeOffs.append(cleaned)
                }
            }
        }

        if summary.isEmpty {
            summary = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return SynthesisOutput(
            summary: summary,
            tradeOffs: tradeOffs,
            blindSpots: blindSpots,
            dissent: dissent
        )
    }
}
