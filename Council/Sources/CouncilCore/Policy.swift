import Foundation

// MARK: - Data classification

public enum DataClass: String, Codable, Sendable {
    case credentials
    case clientConfidential
    case sensitivePersonal
    case personal
    case derivedSummary
    case audio
    case logs
    case appLocalNonsensitive
    case modelBinary
}

public enum ComputePath: String, Codable, Sendable {
    case onDevice
    case applePCC
    case thirdPartyLocal
    case thirdPartyCloud
}

public struct DataClassificationPolicy {
    public static func allowedComputePaths(for dataClass: DataClass) -> [ComputePath] {
        switch dataClass {
        case .credentials:
            return []
        case .clientConfidential:
            return [.onDevice]
        case .sensitivePersonal:
            return [.onDevice]
        case .personal:
            return [.onDevice, .applePCC, .thirdPartyLocal]
        case .derivedSummary:
            return [.onDevice, .applePCC, .thirdPartyLocal]
        case .audio:
            return [.onDevice]
        case .logs:
            return [.onDevice]
        case .appLocalNonsensitive:
            return [.onDevice]
        case .modelBinary:
            return [.onDevice]
        }
    }

    public static func requiresHumanApproval(
        dataClass: DataClass,
        path: ComputePath
    ) -> Bool {
        switch (dataClass, path) {
        case (.sensitivePersonal, .applePCC),
             (.personal, .thirdPartyLocal),
             (.derivedSummary, .thirdPartyLocal):
            return true
        default:
            return false
        }
    }

    public static func classifyProfileComponent(
        values: [ValueStatement],
        goals: [Goal],
        boundaries: [Boundary]
    ) -> DataClass {
        // In v1, values/goals/boundaries are treated as sensitive personal.
        // Financial history and journal excerpts are client-confidential and
        // are stored in ClientConfidentialContainer, never routed.
        _ = (values, goals, boundaries)
        return .sensitivePersonal
    }
}

// MARK: - Model routing

public enum RouteOutcome: Sendable {
    case allowed(ComputePath)
    case denied(reason: String)
    case requiresHumanApproval(ComputePath)
}

public struct ModelRoutingPolicy {
    public static func route(
        dataClasses: [DataClass],
        consent: [ComputePath: Bool]
    ) -> RouteOutcome {
        let orderedPaths: [ComputePath] = [.onDevice, .applePCC, .thirdPartyLocal, .thirdPartyCloud]

        for path in orderedPaths {
            var pathAllowed = true
            var needsApproval = false

            for dataClass in dataClasses {
                let allowed = DataClassificationPolicy.allowedComputePaths(for: dataClass)
                guard allowed.contains(path) else {
                    pathAllowed = false
                    break
                }
                if DataClassificationPolicy.requiresHumanApproval(dataClass: dataClass, path: path) {
                    needsApproval = true
                }
            }

            guard pathAllowed else { continue }

            if path == .thirdPartyCloud || path == .thirdPartyLocal || path == .applePCC {
                guard consent[path] == true else {
                    continue
                }
            }

            if needsApproval {
                return .requiresHumanApproval(path)
            }
            return .allowed(path)
        }

        return .denied(reason: "No compute path satisfies the data classification and consent constraints.")
    }

    public static func defaultOnDeviceDecision() -> RouteDecision {
        RouteDecision(
            selectedRoute: .onDeviceApple,
            providerMetadata: RouteSnapshot(
                framework: "mlx-swift-lm",
                modelIdentifier: "local",
                route: .onDeviceApple,
                isLocal: true
            ),
            deniedRoutes: [
                (.applePCC, "PCC not available in v1 for custom council inference."),
                (.thirdPartyLocal, "No declared third-party local route."),
                (.thirdPartyCloud, "Third-party cloud denied by default in v1."),
            ],
            consentStatus: "notRequired",
            dataClassClearance: "onDeviceOnly"
        )
    }
}
