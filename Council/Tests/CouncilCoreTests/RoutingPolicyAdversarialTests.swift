import Foundation
import Testing
@testable import CouncilCore

/// Adversarial coverage for `DataClassificationPolicy.allowedComputePaths` and
/// `ModelRoutingPolicy.route` — the sole gate between user data and off-device
/// compute. A single edited switch case here silently opens an exfiltration path.
struct RoutingPolicyAdversarialTests {

    private let fullConsent: [ComputePath: Bool] = [
        .onDevice: true,
        .applePCC: true,
        .thirdPartyLocal: true,
        .thirdPartyCloud: true,
    ]

    // MARK: - A1: exhaustive classification table

    @Test func allowedComputePathsNeverIncludesThirdPartyCloud() {
        let expected: [DataClass: [ComputePath]] = [
            .credentials: [],
            .clientConfidential: [.onDevice],
            .sensitivePersonal: [.onDevice],
            .personal: [.onDevice, .applePCC, .thirdPartyLocal],
            .derivedSummary: [.onDevice, .applePCC, .thirdPartyLocal],
            .audio: [.onDevice],
            .logs: [.onDevice],
            .appLocalNonsensitive: [.onDevice],
            .modelBinary: [.onDevice],
        ]
        #expect(expected.count == 9)
        for (dataClass, paths) in expected {
            #expect(
                DataClassificationPolicy.allowedComputePaths(for: dataClass) == paths,
                "allowedComputePaths changed for \(dataClass)"
            )
            #expect(!paths.contains(.thirdPartyCloud), "\(dataClass) must never reach third-party cloud")
        }
    }

    // MARK: - A2: credentials can never be routed anywhere

    @Test func routeDeniesCredentialsOnEveryPath() {
        let outcome = ModelRoutingPolicy.route(dataClasses: [.credentials], consent: fullConsent)
        guard case .denied = outcome else {
            Issue.record("Expected .denied for credentials with full consent, got \(outcome)")
            return
        }
    }

    // MARK: - A3: mixed data classes fail closed to the strictest member

    @Test func routeWithMixedDataClassesFailsClosedToStrictest() {
        // clientConfidential only permits onDevice, so the intersection must
        // never resolve to PCC or third-party local even with full consent.
        let mixed = ModelRoutingPolicy.route(
            dataClasses: [.personal, .clientConfidential],
            consent: fullConsent
        )
        switch mixed {
        case .allowed(let path):
            #expect(path == .onDevice)
        default:
            Issue.record("Expected .allowed(.onDevice) for mixed personal+clientConfidential, got \(mixed)")
        }

        let withCredentials = ModelRoutingPolicy.route(
            dataClasses: [.personal, .credentials],
            consent: fullConsent
        )
        guard case .denied = withCredentials else {
            Issue.record("Expected .denied when credentials are mixed in, got \(withCredentials)")
            return
        }
    }

    // MARK: - A4/A5: onDevice always wins; consent gate and human-approval
    // outcomes are currently unreachable through route().

    @Test func routeAlwaysResolvesOnDeviceForNonCredentialsRegardlessOfConsent() {
        // Every DataClass except .credentials allows .onDevice, which is tried
        // first and bypasses the consent gate. Pin this so the dead-code status
        // of the consent/human-approval branches is deliberate, not accidental.
        let variants: [[ComputePath: Bool]] = [
            [:],
            [.applePCC: true],
            [.applePCC: false],
            fullConsent,
            [.onDevice: false],
        ]
        for consent in variants {
            for dataClasses in [[DataClass.personal], [.derivedSummary], [.personal, .derivedSummary]] {
                let outcome = ModelRoutingPolicy.route(dataClasses: dataClasses, consent: consent)
                switch outcome {
                case .allowed(let path):
                    #expect(path == .onDevice, "consent \(consent) unexpectedly routed \(dataClasses) off-device")
                default:
                    Issue.record("Expected .allowed(.onDevice) for \(dataClasses) consent \(consent), got \(outcome)")
                }
            }
        }
    }

    @Test func requiresHumanApprovalTableContainsEntriesUnreachableFromRoute() {
        // Pin the inconsistency between the two policy tables: these pairs return
        // true here but can never be produced by route() — .sensitivePersonal only
        // allows .onDevice, and .onDevice is always allowed and tried first for
        // .personal/.derivedSummary. If route() is ever reordered or the table
        // changes, revisit this test deliberately.
        #expect(DataClassificationPolicy.requiresHumanApproval(dataClass: .sensitivePersonal, path: .applePCC))
        #expect(DataClassificationPolicy.requiresHumanApproval(dataClass: .personal, path: .thirdPartyLocal))
        #expect(DataClassificationPolicy.requiresHumanApproval(dataClass: .derivedSummary, path: .thirdPartyLocal))
        #expect(!DataClassificationPolicy.requiresHumanApproval(dataClass: .credentials, path: .onDevice))
        #expect(!DataClassificationPolicy.requiresHumanApproval(dataClass: .personal, path: .onDevice))
        #expect(!DataClassificationPolicy.requiresHumanApproval(dataClass: .personal, path: .applePCC))
        #expect(!DataClassificationPolicy.requiresHumanApproval(dataClass: .personal, path: .thirdPartyCloud))
    }

    @Test func routeWithEmptyDataClassesAllowsOnDevice() {
        // No data to protect means no constraint; pin the vacuous-truth behavior.
        let outcome = ModelRoutingPolicy.route(dataClasses: [], consent: [:])
        switch outcome {
        case .allowed(let path):
            #expect(path == .onDevice)
        default:
            Issue.record("Expected .allowed(.onDevice) for empty dataClasses, got \(outcome)")
        }
    }

    // MARK: - A19: magic-string defaults consumed downstream

    @Test func routeDecisionAndDefaultDecisionPinMagicStringsAndDeniedRoutes() {
        let snapshot = RouteSnapshot(framework: "f", modelIdentifier: "m", route: .onDeviceApple, isLocal: true)
        let bare = RouteDecision(selectedRoute: .onDeviceApple, providerMetadata: snapshot)
        #expect(bare.consentStatus == "notRequired")
        #expect(bare.dataClassClearance == "onDeviceOnly")
        #expect(bare.deniedRoutes.isEmpty)

        let decision = ModelRoutingPolicy.defaultOnDeviceDecision()
        #expect(decision.selectedRoute == .onDeviceApple)
        #expect(decision.providerMetadata.isLocal)
        #expect(decision.providerMetadata.route == .onDeviceApple)
        #expect(decision.consentStatus == "notRequired")
        #expect(decision.dataClassClearance == "onDeviceOnly")
        #expect(decision.providerMetadata.framework == "mlx-swift-lm")
        #expect(decision.deniedRoutes.count == 3)
        #expect(decision.deniedRoutes.map(\.route) == [.applePCC, .thirdPartyLocal, .thirdPartyCloud])
        for denied in decision.deniedRoutes {
            #expect(!denied.reason.isEmpty, "DeniedRoute \(denied.route) must carry an audit-visible reason")
        }
    }
}
