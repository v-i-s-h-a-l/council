import XCTest
import CouncilCore
import MLXLMCommon
@testable import CouncilInference

final class MLXInferenceProviderIsolationTests: XCTestCase {
    /// Build-only test ensuring `MLXInferenceProvider` can be used as an
    /// `InferenceProvider` and is therefore `Sendable` under Swift 6.
    func testProviderConformsToInferenceProvider() async {
        let provider: any InferenceProvider = MLXInferenceProvider()
        let snapshot = await provider.routeSnapshot
        XCTAssertEqual(snapshot.framework, "mlx-swift-lm")
        XCTAssertEqual(snapshot.route, .onDeviceApple)
        XCTAssertTrue(snapshot.isLocal)
    }

    /// Verifies that route metadata is isolated to the provider actor and
    /// returns the expected MLX-specific values.
    func testRouteSnapshotValues() async {
        let configuration = MLXModelConfiguration(
            modelConfiguration: MLXLMCommon.ModelConfiguration(
                id: "mlx-community/Test-Model-4bit"
            )
        )
        let provider = MLXInferenceProvider(modelConfiguration: configuration)
        let snapshot = await provider.routeSnapshot
        XCTAssertEqual(snapshot.modelIdentifier, "mlx-community/Test-Model-4bit")
    }
}
