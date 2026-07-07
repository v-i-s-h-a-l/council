import Foundation
import MLXLMCommon
import CouncilCore

/// On-device MLX inference provider conforming to `InferenceProvider`.
///
/// This provider manages a `ModelContainerPool` and streams generated text
/// chunks back to callers. It reports its route as `.onDeviceApple` via
/// `mlx-swift-lm`.
public actor MLXInferenceProvider: InferenceProvider {
    private let pool: ModelContainerPool
    private let modelConfiguration: MLXModelConfiguration

    public init(
        pool: ModelContainerPool = ModelContainerPool(),
        modelConfiguration: MLXModelConfiguration = .default
    ) {
        self.pool = pool
        self.modelConfiguration = modelConfiguration
    }

    public func generate(
        messages: [InferenceMessage],
        options: InferenceOptions
    ) async throws -> AsyncThrowingStream<String, Error> {
        let worker = try await pool.borrow()
        let innerStream = try await worker.generate(messages: messages, options: options)

        return AsyncThrowingStream { continuation in
            Task {
                defer { Task { await pool.return(worker) } }
                do {
                    for try await chunk in innerStream {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public var routeSnapshot: RouteSnapshot {
        get async {
            RouteSnapshot(
                framework: "mlx-swift-lm",
                modelIdentifier: modelConfiguration.modelConfiguration.name,
                route: .onDeviceApple,
                isLocal: true
            )
        }
    }
}
