import XCTest
import CouncilCore
import MLXLMCommon
@testable import CouncilInference

private struct StubGenerateError: Error {}

final class MLXInferenceProviderIsolationTests: XCTestCase {
    /// Ensures `MLXInferenceProvider` can be used as an `InferenceProvider`
    /// (and is therefore `Sendable` under Swift 6) and that its route
    /// metadata is isolated to the provider actor with the expected
    /// MLX-specific values.
    func testRouteSnapshotValues() async {
        let configuration = MLXModelConfiguration(
            modelConfiguration: MLXLMCommon.ModelConfiguration(
                id: "mlx-community/Test-Model-4bit"
            )
        )
        let provider: any InferenceProvider = MLXInferenceProvider(modelConfiguration: configuration)
        let snapshot = await provider.routeSnapshot
        XCTAssertEqual(snapshot.framework, "mlx-swift-lm")
        XCTAssertEqual(snapshot.modelIdentifier, "mlx-community/Test-Model-4bit")
        XCTAssertEqual(snapshot.route, .onDeviceApple)
        XCTAssertTrue(snapshot.isLocal)
    }

    /// Drift guard: `MLXInferenceProvider.routeSnapshot` inlines its values
    /// instead of using the `RouteSnapshot.mlx()` factory — two sources of
    /// the same truth that must not diverge.
    func testProviderRouteSnapshotMatchesMLXFactory() async {
        let modelID = "mlx-community/Test-Model-4bit"
        let configuration = MLXModelConfiguration(
            modelConfiguration: MLXLMCommon.ModelConfiguration(id: modelID)
        )
        let provider = MLXInferenceProvider(modelConfiguration: configuration)
        let snapshot = await provider.routeSnapshot
        let factory = RouteSnapshot.mlx(modelIdentifier: modelID)
        XCTAssertEqual(snapshot.framework, factory.framework)
        XCTAssertEqual(snapshot.modelIdentifier, factory.modelIdentifier)
        XCTAssertEqual(snapshot.route, factory.route)
        XCTAssertEqual(snapshot.isLocal, factory.isLocal)
    }

    /// Regression test for a pool-slot leak: when `worker.generate` threw,
    /// the borrowed worker was never returned to the pool (the returning
    /// `defer` only existed inside the stream producer, which never ran), so
    /// `poolSize` failures permanently exhausted the pool.
    func testGenerateThrowingWorkerDoesNotLeakPoolSlot() async {
        let modelID = "test/throwing-generate-model"
        let manifestService = makeIsolatedManifestService(ids: [modelID])
        await manifestService.register(ModelManifest(id: modelID, checksum: "sha256:abc"))
        await manifestService.grantConsent(id: modelID)

        let modelConfig = MLXModelConfiguration(
            modelConfiguration: MLXLMCommon.ModelConfiguration(id: modelID)
        )
        let pool = ModelContainerPool(
            poolSize: 1,
            modelConfiguration: modelConfig,
            manifestService: manifestService,
            loadWorker: {
                ModelContainerWorker { _, _ in
                    throw StubGenerateError()
                }
            }
        )
        let provider = MLXInferenceProvider(
            pool: pool,
            modelConfiguration: modelConfig,
            manifestService: manifestService
        )

        // Every failed generate must free the slot for the next attempt; the
        // second attempt must fail with the worker's own error again, not
        // with `poolExhausted`.
        for _ in 0..<2 {
            do {
                _ = try await provider.generate(messages: [], options: InferenceOptions())
                XCTFail("Expected stub generate to throw")
            } catch ModelContainerPoolError.poolExhausted {
                XCTFail("Worker leaked: pool slot stayed busy after generate threw")
            } catch {
                XCTAssertTrue(error is StubGenerateError, "Expected StubGenerateError, got \(error)")
            }
        }
    }

    /// Positive path for worker return: terminating the returned stream early
    /// must cancel the producer and run the `defer` that returns the worker,
    /// so a subsequent generate on a poolSize-1 pool can proceed.
    func testStreamTerminationReturnsWorkerToPool() async throws {
        let modelID = "test/stream-termination-model"
        let manifestService = makeIsolatedManifestService(ids: [modelID])
        await manifestService.register(ModelManifest(id: modelID, checksum: "sha256:abc"))
        await manifestService.grantConsent(id: modelID)

        let modelConfig = MLXModelConfiguration(
            modelConfiguration: MLXLMCommon.ModelConfiguration(id: modelID)
        )
        let pool = ModelContainerPool(
            poolSize: 1,
            modelConfiguration: modelConfig,
            manifestService: manifestService,
            loadWorker: {
                ModelContainerWorker { _, _ in
                    AsyncThrowingStream { continuation in
                        let producer = Task {
                            continuation.yield("chunk-1")
                            do {
                                // Keep the stream open so termination, not
                                // completion, is what returns the worker.
                                try await Task.sleep(nanoseconds: 10_000_000_000)
                                continuation.yield("chunk-2")
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
            }
        )
        let provider = MLXInferenceProvider(
            pool: pool,
            modelConfiguration: modelConfig,
            manifestService: manifestService
        )

        let stream = try await provider.generate(messages: [], options: InferenceOptions())

        // Early exit must happen via task cancellation — `break` out of a
        // for-await loop does NOT terminate an AsyncThrowingStream (documented
        // Swift behavior), so it cannot be what returns the worker. Consume in
        // a child task and cancel it, mirroring how DeliberationService cancels.
        let consumer = Task { () -> [String] in
            var chunks: [String] = []
            for try await chunk in stream {
                chunks.append(chunk)
            }
            return chunks
        }
        // Let the producer deliver the first chunk, then cancel mid-stream.
        try await Task.sleep(nanoseconds: 100_000_000) // 100 ms
        consumer.cancel()
        let chunks = (try? await consumer.value) ?? []
        XCTAssertEqual(chunks, ["chunk-1"])

        // The producer's defer returns the worker from a detached task, so
        // poll briefly for the slot to become available again.
        var reused = false
        for _ in 0..<100 where !reused {
            do {
                let second = try await provider.generate(messages: [], options: InferenceOptions())
                for try await _ in second { break }
                reused = true
            } catch ModelContainerPoolError.poolExhausted {
                try await Task.sleep(nanoseconds: 10_000_000) // 10 ms
            }
        }
        XCTAssertTrue(reused, "Worker was not returned to the pool after early stream termination")
    }

    /// Pins the consent-enforcement boundary (see also
    /// `testPoolBorrowAfterConsentRevokedStillServesPooledWorker`): the
    /// provider checks consent on every `generate` call, so revocation takes
    /// effect for new calls even while a worker remains pooled. Note this
    /// does not stop a stream already in flight.
    func testGenerateAfterConsentRevokedThrows() async throws {
        let modelID = "test/revoke-consent-provider-model"
        let manifestService = makeIsolatedManifestService(ids: [modelID])
        await manifestService.register(ModelManifest(id: modelID, checksum: "sha256:abc"))
        await manifestService.grantConsent(id: modelID)

        let modelConfig = MLXModelConfiguration(
            modelConfiguration: MLXLMCommon.ModelConfiguration(id: modelID)
        )
        let pool = ModelContainerPool(
            poolSize: 1,
            modelConfiguration: modelConfig,
            manifestService: manifestService,
            loadWorker: {
                ModelContainerWorker { _, _ in
                    AsyncThrowingStream { continuation in
                        continuation.yield("warm")
                        continuation.finish()
                    }
                }
            }
        )
        let provider = MLXInferenceProvider(
            pool: pool,
            modelConfiguration: modelConfig,
            manifestService: manifestService
        )

        // Warm the pool so a worker is loaded and pooled underneath.
        let first = try await provider.generate(messages: [], options: InferenceOptions())
        for try await _ in first {}

        await manifestService.revokeConsent(id: modelID)

        do {
            _ = try await provider.generate(messages: [], options: InferenceOptions())
            XCTFail("Expected modelNotConsented after consent revocation")
        } catch MLXInferenceProviderError.modelNotConsented(let id) {
            XCTAssertEqual(id, modelID)
        }
    }

    /// Consent without a registered checksum must fail closed at the
    /// provider's pre-borrow gate.
    func testGenerateWithoutRegisteredChecksumThrows() async {
        let modelID = "test/no-checksum-provider-model"
        let manifestService = makeIsolatedManifestService(ids: [modelID])
        await manifestService.grantConsent(id: modelID)

        let modelConfig = MLXModelConfiguration(
            modelConfiguration: MLXLMCommon.ModelConfiguration(id: modelID)
        )
        let pool = ModelContainerPool(
            poolSize: 1,
            modelConfiguration: modelConfig,
            manifestService: manifestService,
            loadWorker: {
                ModelContainerWorker { _, _ in
                    AsyncThrowingStream { continuation in
                        continuation.yield("unreachable")
                        continuation.finish()
                    }
                }
            }
        )
        let provider = MLXInferenceProvider(
            pool: pool,
            modelConfiguration: modelConfig,
            manifestService: manifestService
        )

        do {
            _ = try await provider.generate(messages: [], options: InferenceOptions())
            XCTFail("Expected modelChecksumMissing error")
        } catch MLXInferenceProviderError.modelChecksumMissing(let id) {
            XCTAssertEqual(id, modelID)
        } catch {
            XCTFail("Expected modelChecksumMissing, got \(error)")
        }
    }

    // MARK: - Helpers

    /// Manifest service over a unique suite so tests never touch the
    /// production `com.council.modelManifest` keys; keys are removed on
    /// teardown.
    private func makeIsolatedManifestService(ids: [String] = []) -> ModelManifestService {
        let suiteKey = "com.council.test.\(UUID().uuidString)"
        addTeardownBlock {
            UserDefaults.standard.removeObject(forKey: "\(suiteKey).manifests")
            for id in ids {
                UserDefaults.standard.removeObject(forKey: "\(suiteKey).consent.\(id)")
            }
        }
        return ModelManifestService(suiteKey: suiteKey)
    }
}
