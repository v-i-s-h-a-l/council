import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import Tokenizers
import CouncilCore

/// Errors that can occur when borrowing from a `ModelContainerPool`.
public enum ModelContainerPoolError: Error, Sendable {
    case poolExhausted
    case modelNotConsented(id: String)
    case modelChecksumMissing(id: String)
}

/// Actor that manages a fixed-size pool of `ModelContainerWorker` instances.
///
/// Workers are loaded lazily on first borrow. The pool enforces a thermal
/// budget check before handing out a worker.
public actor ModelContainerPool {
    /// Default pool size for the current platform.
    ///
    /// - macOS: 2 workers
    /// - iOS / other: 1 worker
    public static var defaultPoolSize: Int {
        #if os(macOS)
        2
        #else
        1
        #endif
    }

    public let poolSize: Int
    public let modelConfiguration: MLXModelConfiguration

    private var workers: [ModelContainerWorker?]
    private var busy: Set<Int>
    private let manifestService: ModelManifestService
    private let loadWorker: @Sendable () async throws -> ModelContainerWorker

    /// Creates a new pool.
    ///
    /// - Parameters:
    ///   - poolSize: Number of workers to keep. Defaults to platform value.
    ///   - modelConfiguration: MLX model configuration shared by all workers.
    ///   - manifestService: Service that tracks model manifests and download
    ///     consent. A worker is only loaded if the model is registered,
    ///     consented, and has a registered checksum.
    ///   - loadWorker: Optional factory for creating a worker. Tests can inject
    ///     a stub factory to avoid loading real MLX models.
    public init(
        poolSize: Int? = nil,
        modelConfiguration: MLXModelConfiguration = .default,
        manifestService: ModelManifestService = ModelManifestService(),
        loadWorker: (@Sendable () async throws -> ModelContainerWorker)? = nil
    ) {
        self.poolSize = poolSize ?? Self.defaultPoolSize
        self.modelConfiguration = modelConfiguration
        self.workers = Array(repeating: nil, count: self.poolSize)
        self.busy = []
        self.manifestService = manifestService
        self.loadWorker = loadWorker ?? { [modelConfiguration, manifestService] in
            let modelID = modelConfiguration.modelConfiguration.name
            let consented = await manifestService.isModelConsented(id: modelID)
            guard consented else {
                throw ModelContainerPoolError.modelNotConsented(id: modelID)
            }
            guard await manifestService.checksum(for: modelID) != nil else {
                throw ModelContainerPoolError.modelChecksumMissing(id: modelID)
            }
            let container = try await #huggingFaceLoadModelContainer(
                configuration: modelConfiguration.modelConfiguration
            )
            return ModelContainerWorker(container: container)
        }
    }

    /// Current thermal state of the device.
    public var thermalBudget: ProcessInfo.ThermalState {
        ProcessInfo.processInfo.thermalState
    }

    /// Borrows an available worker, loading one lazily if needed.
    ///
    /// - Throws: `DeliberationError.thermalCritical` if the thermal state is
    ///   `.critical`, or `ModelContainerPoolError.poolExhausted` if all workers
    ///   are busy.
    public func borrow() async throws -> ModelContainerWorker {
        if thermalBudget == .critical {
            throw DeliberationError.thermalCritical
        }

        for index in 0..<poolSize {
            guard !busy.contains(index) else { continue }

            if workers[index] == nil {
                workers[index] = try await loadWorker()
            }

            busy.insert(index)
            return workers[index]!
        }

        throw ModelContainerPoolError.poolExhausted
    }

    /// Returns a previously borrowed worker to the pool.
    public func `return`(_ worker: ModelContainerWorker) {
        for index in 0..<poolSize {
            if workers[index] === worker {
                busy.remove(index)
                break
            }
        }
    }
}
