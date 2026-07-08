import CouncilCore
import Foundation

/// A deterministic echo provider for headless CLI usage and testing.
///
/// `EchoInferenceProvider` does not load a model. It returns a canned,
/// schema-compliant perspective response so the `CouncilCLI` target is usable
/// on machines without Metal or when no model download is desired.
public actor EchoInferenceProvider: InferenceProvider {
    public init() {}

    public func generate(
        messages: [InferenceMessage],
        options: InferenceOptions
    ) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(Self.cannedResponse)
            continuation.finish()
        }
    }

    public var routeSnapshot: RouteSnapshot {
        RouteSnapshot(
            framework: "echo",
            modelIdentifier: "echo",
            route: .onDeviceApple,
            isLocal: true
        )
    }

    /// A minimal, schema-compliant perspective-shaped JSON string.
    private static let cannedResponse = """
    {
      "summary": "This is an echo response from the Council CLI. No model weights were loaded.",
      "tradeOffs": [
        "Echo provider does not perform real inference.",
        "Use --provider mlx with --consent-download for on-device reasoning."
      ],
      "blindSpots": [
        "No model weights were loaded.",
        "No peer-reviewed reasoning occurred."
      ],
      "dissent": [
        "Frugal: An echo response costs nothing but provides no real insight.",
        "Systems Thinker: Replace with a real inference provider before relying on this output."
      ]
    }
    """
}
