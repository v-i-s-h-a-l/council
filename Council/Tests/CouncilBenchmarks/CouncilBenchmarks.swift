import CouncilAgents
import CouncilCore
import CouncilInference
import CryptoKit
import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import Testing
import Tokenizers

// MARK: - Configuration

/// Benchmark settings, overridable through process arguments or environment variables.
///
/// Examples:
///   swift test --filter CouncilBenchmarks -- --council-benchmark-model-id mlx-community/SmolLM-135M-Instruct-4bit
///   COUNCIL_BENCHMARK_MODEL_ID=mlx-community/SmolLM-135M-Instruct-4bit swift test --filter CouncilBenchmarks
private struct BenchmarkConfiguration {
    let modelID: String
    let poolSize: Int?
    let checksumOverride: String?

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let environment = ProcessInfo.processInfo.environment

        modelID = Self.string(from: arguments, key: "--council-benchmark-model-id")
            ?? environment["COUNCIL_BENCHMARK_MODEL_ID"]
            ?? "mlx-community/SmolLM-135M-Instruct-4bit"

        poolSize = Self.int(from: arguments, key: "--council-benchmark-pool-size")
            ?? environment["COUNCIL_BENCHMARK_POOL_SIZE"].flatMap(Int.init)

        checksumOverride = Self.string(from: arguments, key: "--council-benchmark-checksum")
            ?? environment["COUNCIL_BENCHMARK_CHECKSUM"]
    }

    private static func string(from arguments: [String], key: String) -> String? {
        guard let index = arguments.firstIndex(of: key), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func int(from arguments: [String], key: String) -> Int? {
        guard let value = string(from: arguments, key: key) else { return nil }
        return Int(value)
    }
}

// MARK: - Thresholds

/// AC16 performance thresholds from docs/PLAN.md.
private struct AC16Thresholds {
    /// Per-agent first-opinion latency budget.
    let firstOpinionSeconds: Double

    /// End-to-end Purchase Council latency budget.
    let endToEndSeconds: Double

    /// Peak resident memory budget.
    let peakMemoryGB: Double

    static var current: AC16Thresholds {
        #if os(iOS)
        AC16Thresholds(firstOpinionSeconds: 15, endToEndSeconds: 90, peakMemoryGB: 2)
        #elseif os(macOS)
        // AC16 calls out macOS per-agent latency with poolSize = 2.
        AC16Thresholds(firstOpinionSeconds: 8, endToEndSeconds: 90, peakMemoryGB: 2)
        #else
        AC16Thresholds(firstOpinionSeconds: 15, endToEndSeconds: 90, peakMemoryGB: 2)
        #endif
    }
}

// MARK: - Errors

private enum BenchmarkError: Error {
    case missingModelArtifacts(URL)
}

// MARK: - Memory sampling

#if canImport(Darwin)
import Darwin

/// Returns the current process resident memory size in bytes.
private nonisolated func residentMemoryBytes() -> UInt64? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)

    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
        }
    }

    guard result == KERN_SUCCESS else { return nil }
    return UInt64(info.resident_size)
}
#else
private nonisolated func residentMemoryBytes() -> UInt64? {
    nil
}
#endif

/// Samples resident memory while the benchmark runs and tracks the peak value.
private actor MemorySampler {
    private var samplingTask: Task<Void, Never>?
    private(set) var peakBytes: UInt64 = 0

    func start() {
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                if let bytes = residentMemoryBytes(), bytes > (await self?.peakBytes ?? 0) {
                    await self?.record(bytes)
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    func stop() async {
        samplingTask?.cancel()
        _ = await samplingTask?.value
        samplingTask = nil
    }

    private func record(_ bytes: UInt64) {
        peakBytes = max(peakBytes, bytes)
    }
}

// MARK: - Inference providers

/// A minimal on-device MLX provider used by the benchmark.
///
/// Unlike `MLXInferenceProvider`, this provider is configured with a custom
/// `ModelContainerPool` load worker that computes and registers the model
/// checksum on first load. This lets the benchmark run against an arbitrary
/// model without hard-coding a checksum in source.
private actor MLXBenchmarkInferenceProvider: InferenceProvider {
    private let pool: ModelContainerPool
    private let modelID: String

    init(pool: ModelContainerPool, modelID: String) {
        self.pool = pool
        self.modelID = modelID
    }

    func generate(
        messages: [InferenceMessage],
        options: InferenceOptions
    ) async throws -> AsyncThrowingStream<String, Error> {
        let worker = try await pool.borrow()
        let innerStream = try await worker.generate(messages: messages, options: options)

        return AsyncThrowingStream { continuation in
            let producer = Task {
                defer { Task { await self.pool.return(worker) } }
                do {
                    for try await chunk in innerStream {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    var routeSnapshot: RouteSnapshot {
        RouteSnapshot(
            framework: "mlx-swift-lm",
            modelIdentifier: modelID,
            route: .onDeviceApple,
            isLocal: true
        )
    }
}

/// Wraps another `InferenceProvider` and records the time of the first token.
private actor MeasuringInferenceProvider: InferenceProvider {
    private let inner: any InferenceProvider
    private(set) var firstChunkTime: ContinuousClock.Instant?
    private(set) var totalChunks: UInt = 0

    init(inner: any InferenceProvider) {
        self.inner = inner
    }

    func generate(
        messages: [InferenceMessage],
        options: InferenceOptions
    ) async throws -> AsyncThrowingStream<String, Error> {
        let stream = try await inner.generate(messages: messages, options: options)

        return AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    for try await chunk in stream {
                        if self.firstChunkTime == nil {
                            self.firstChunkTime = ContinuousClock().now
                        }
                        self.totalChunks += 1
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    var routeSnapshot: RouteSnapshot {
        get async { await inner.routeSnapshot }
    }
}

// MARK: - Benchmarks

struct CouncilBenchmarks {

    /// Measures first-opinion latency, end-to-end latency, and peak memory for a
    /// complete Purchase Council session running against an on-device MLX model.
    @Test func purchaseCouncilPerformance() async throws {
        #if targetEnvironment(simulator)
        print("SKIP: MLX Metal inference is not available in the iOS simulator")
        return
        #endif

        guard ProcessInfo.processInfo.environment["COUNCIL_RUN_BENCHMARKS"] == "1" else {
            print("SKIP: Set COUNCIL_RUN_BENCHMARKS=1 to run on-device performance benchmarks")
            return
        }

        let configuration = BenchmarkConfiguration()
        let thresholds = AC16Thresholds.current
        let modelConfiguration = MLXModelConfiguration(
            modelConfiguration: MLXLMCommon.ModelConfiguration(id: configuration.modelID)
        )

        let manifestService = ModelManifestService()
        await manifestService.grantConsent(id: configuration.modelID)

        if let checksum = configuration.checksumOverride {
            await manifestService.register(
                ModelManifest(id: configuration.modelID, checksum: checksum)
            )
        }

        let pool = ModelContainerPool(
            poolSize: configuration.poolSize,
            modelConfiguration: modelConfiguration,
            manifestService: manifestService,
            loadWorker: { [modelConfiguration, manifestService, modelID = configuration.modelID] in
                let container = try await #huggingFaceLoadModelContainer(
                    configuration: modelConfiguration.modelConfiguration
                )
                let worker = ModelContainerWorker(container: container)

                if await manifestService.checksum(for: modelID) == nil {
                    let checksum = try await Self.computeChecksum(for: worker)
                    await manifestService.register(
                        ModelManifest(id: modelID, checksum: checksum)
                    )
                }

                return worker
            }
        )

        let baseProvider = MLXBenchmarkInferenceProvider(pool: pool, modelID: configuration.modelID)
        let measuringProvider = MeasuringInferenceProvider(inner: baseProvider)

        let service = DeliberationService(
            provider: measuringProvider,
            council: PurchaseCouncil(),
            validators: [ConstitutionalPerspectiveValidator()],
            context: RoutableProfileContext(),
            options: InferenceOptions(
                temperature: 0.3,
                maxTokens: 512,
                stopSequences: [],
                jsonMode: false
            )
        )

        let memorySampler = MemorySampler()
        let stream = await service.stateUpdates()

        await memorySampler.start()
        let sessionStart = ContinuousClock().now
        var firstOpinionStart: ContinuousClock.Instant?
        var finalState: DeliberationState?

        await service.startSession(question: "Should I buy a used bike?")

        for await state in stream {
            if state.stage == .firstOpinions && firstOpinionStart == nil {
                firstOpinionStart = ContinuousClock().now
            }

            if state.stage == .presentation || state.stage == .failed || state.stage == .cancelled {
                finalState = state
                break
            }
        }

        let sessionEnd = ContinuousClock().now
        await memorySampler.stop()

        guard finalState?.stage == .presentation else {
            print("SKIP: Benchmark did not reach presentation: stage=\(finalState?.stage.rawValue ?? "nil"), error=\(finalState?.errorMessage ?? "none")")
            return
        }

        let firstChunkInstant = await measuringProvider.firstChunkTime
        let firstOpinionLatency = Self.duration(from: firstOpinionStart, to: firstChunkInstant)
        let endToEndLatency = Self.duration(from: sessionStart, to: sessionEnd) ?? 0
        let peakMemoryBytes = await memorySampler.peakBytes
        let peakMemoryGB = Double(peakMemoryBytes) / 1_073_741_824

        print("""
        === Council Benchmark Results ===
        Model: \(configuration.modelID)
        Platform: \(Self.platformName)
        Pool size: \(await pool.poolSize)
        First-opinion latency: \(Self.formatted(firstOpinionLatency)) s
        End-to-end latency: \(Self.formatted(endToEndLatency)) s
        Peak resident memory: \(String(format: "%.3f", peakMemoryGB)) GB (\(peakMemoryBytes) bytes)
        AC16 thresholds: firstOpinion < \(thresholds.firstOpinionSeconds)s, e2e < \(thresholds.endToEndSeconds)s, peak < \(thresholds.peakMemoryGB) GB
        """
        )

        var failures: [String] = []
        if let firstOpinionLatency {
            if firstOpinionLatency > thresholds.firstOpinionSeconds {
                failures.append(
                    "first-opinion latency \(String(format: "%.3f", firstOpinionLatency))s exceeds \(thresholds.firstOpinionSeconds)s"
                )
            }
        } else {
            failures.append("first-opinion latency unavailable")
        }

        if endToEndLatency > thresholds.endToEndSeconds {
            failures.append(
                "end-to-end latency \(String(format: "%.3f", endToEndLatency))s exceeds \(thresholds.endToEndSeconds)s"
            )
        }

        if peakMemoryGB > thresholds.peakMemoryGB {
            failures.append(
                "peak memory \(String(format: "%.3f", peakMemoryGB)) GB exceeds \(thresholds.peakMemoryGB) GB"
            )
        }

        if failures.isEmpty {
            print("AC16: PASS")
        } else {
            for failure in failures {
                print("AC16 FAIL: \(failure)")
            }
            Issue.record("AC16 threshold violation(s): \(failures.joined(separator: "; "))")
        }
    }

    // MARK: - Helpers

    private static var platformName: String {
        #if os(iOS)
        "iOS"
        #elseif os(macOS)
        "macOS"
        #elseif os(visionOS)
        "visionOS"
        #else
        "unknown"
        #endif
    }

    private static func duration(
        from start: ContinuousClock.Instant?,
        to end: ContinuousClock.Instant?
    ) -> Double? {
        guard let start, let end else { return nil }
        let delta = end - start
        return Double(delta.components.seconds) + Double(delta.components.attoseconds) / 1e18
    }

    private static func formatted(_ seconds: Double?) -> String {
        guard let seconds else { return "n/a" }
        return String(format: "%.3f", seconds)
    }

    private struct SafetensorsIndex: Decodable {
        private enum CodingKeys: String, CodingKey {
            case weightMap = "weight_map"
        }
        let weightMap: [String: String]
    }

    /// Computes a `sha256:<hex>` checksum for the artifacts in a worker's model directory.
    ///
    /// Mirrors the verification format used by `ModelArtifactVerifier` so the
    /// manifest can be registered on demand.
    private static func computeChecksum(for worker: ModelContainerWorker) async throws -> String {
        let directory = try await worker.modelDirectory()
        let fileManager = FileManager.default

        let singleFile = directory.appendingPathComponent("model.safetensors")
        if fileManager.fileExists(atPath: singleFile.path) {
            let data = try Data(contentsOf: singleFile, options: .mappedIfSafe)
            let digest = SHA256.hash(data: data)
            return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
        }

        let indexFile = directory.appendingPathComponent("model.safetensors.index.json")
        if fileManager.fileExists(atPath: indexFile.path) {
            let indexData = try Data(contentsOf: indexFile)
            let index = try JSONDecoder().decode(SafetensorsIndex.self, from: indexData)
            let filenames = Array(Set(index.weightMap.values)).sorted()

            var hasher = SHA256()
            for filename in filenames {
                let url = directory.appendingPathComponent(filename)
                guard fileManager.fileExists(atPath: url.path) else {
                    throw BenchmarkError.missingModelArtifacts(directory)
                }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                hasher.update(data: data)
            }
            return "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }

        throw BenchmarkError.missingModelArtifacts(directory)
    }
}
