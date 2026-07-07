import CouncilCore
import Foundation
import Observation

/// View model for model route settings with consent-gated changes.
@MainActor
@Observable
public final class ModelSettingsViewModel {
    public private(set) var activeRoute: ComputeRoute
    public private(set) var modelIdentifier: String
    public private(set) var computePath: String
    public var pendingRoute: ComputeRoute?
    public var consentRequired: Bool = false

    private let defaults: UserDefaults
    private let routeKey: String
    private let consentKey: String

    public init(
        activeRoute: ComputeRoute,
        modelIdentifier: String,
        defaults: UserDefaults = .standard,
        suiteKey: String = "com.council.modelSettings"
    ) {
        self.defaults = defaults
        self.routeKey = "\(suiteKey).activeRoute"
        self.consentKey = "\(suiteKey).routeChangeConsent"

        let resolvedRoute: ComputeRoute
        if let saved = defaults.string(forKey: self.routeKey),
           let route = ComputeRoute(rawValue: saved) {
            resolvedRoute = route
        } else {
            resolvedRoute = activeRoute
        }
        self.activeRoute = resolvedRoute
        self.modelIdentifier = modelIdentifier
        self.computePath = Self.label(for: resolvedRoute)
    }

    /// Requests a route change. The change is not applied until explicit consent is granted.
    public func requestRouteChange(_ route: ComputeRoute) {
        guard route != activeRoute else { return }
        pendingRoute = route
        consentRequired = true
    }

    /// Applies the pending route change and records consent.
    public func grantConsent() {
        guard let route = pendingRoute else { return }
        activeRoute = route
        computePath = Self.label(for: route)
        defaults.set(route.rawValue, forKey: routeKey)
        defaults.set(true, forKey: consentKey)
        pendingRoute = nil
        consentRequired = false
    }

    /// Rejects the pending route change.
    public func denyConsent() {
        pendingRoute = nil
        consentRequired = false
    }

    /// Human-readable label for a compute route.
    public static func label(for route: ComputeRoute) -> String {
        switch route {
        case .onDeviceApple:
            return "On-device Apple"
        case .applePCC:
            return "Apple Private Cloud Compute"
        case .thirdPartyLocal:
            return "Third-party local"
        case .thirdPartyCloud:
            return "Third-party cloud"
        }
    }
}
