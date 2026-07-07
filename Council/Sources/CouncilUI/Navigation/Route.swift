import Foundation

/// Navigation destinations used by the iOS `NavigationStack`.
public enum Route: Hashable, Sendable {
    case session
    case memory
    case settings
    case about
}
