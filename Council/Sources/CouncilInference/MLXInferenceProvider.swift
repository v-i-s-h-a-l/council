import Foundation
import MLXLMCommon
import CouncilCore

/// Errors that can occur when using `MLXInferenceProvider`.
public enum MLXInferenceProviderError: Error, Sendable {
    case modelNotConsented(id: String)
    case modelChecksumMissing(id: String)
}

/// On-device MLX inference provider conforming to `InferenceProvider`.
///
/// This provider manages a `ModelContainerPool` and streams generated text
/// chunks back to callers. It reports its route as `.onDeviceApple` via
/// `mlx-swift-lm`.
///
/// Model loading is gated by a `ModelManifestService`: the configured model
/// must be registered with a checksum and the user must have granted download
/// consent before the provider will borrow a worker.
public actor MLXInferenceProvider: InferenceProvider {
    private let pool: ModelContainerPool
    private let modelConfiguration: MLXModelConfiguration
    private let manifestService: ModelManifestService

    public init(
        pool: ModelContainerPool = ModelContainerPool(),
        modelConfiguration: MLXModelConfiguration = .default,
        manifestService: ModelManifestService = ModelManifestService()
    ) {
        self.pool = pool
        self.modelConfiguration = modelConfiguration
        self.manifestService = manifestService
    }

    public func generate(
        messages: [InferenceMessage],
        options: InferenceOptions
    ) async throws -> AsyncThrowingStream<String, Error> {
        let modelID = modelConfiguration.modelConfiguration.name
        let consented = await manifestService.isModelConsented(id: modelID)
        guard consented else {
            throw MLXInferenceProviderError.modelNotConsented(id: modelID)
        }
        guard await manifestService.checksum(for: modelID) != nil else {
            throw MLXInferenceProviderError.modelChecksumMissing(id: modelID)
        }

        let worker = try await pool.borrow()
        let innerStream = try await worker.generate(messages: messages, options: options)

        return AsyncThrowingStream { continuation in
            let producer = Task {
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
            continuation.onTermination = { _ in
                producer.cancel()
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
