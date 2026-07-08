import Foundation
import CouncilCore

extension RouteSnapshot {
    /// Creates an MLX-specific route snapshot.
    ///
    /// - Parameter modelIdentifier: The model identifier to report.
    /// - Returns: A `RouteSnapshot` with framework `mlx-swift-lm` and route
    ///   `.onDeviceApple`.
    public static func mlx(modelIdentifier: String) -> RouteSnapshot {
        RouteSnapshot(
            framework: "mlx-swift-lm",
            modelIdentifier: modelIdentifier,
            route: .onDeviceApple,
            isLocal: true
        )
    }
}
