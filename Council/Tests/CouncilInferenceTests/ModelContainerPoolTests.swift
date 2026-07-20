import CryptoKit
import XCTest
import CouncilCore
import MLXLMCommon
@testable import CouncilInference

final class ModelContainerPoolTests: XCTestCase {
    private func makeStubWorker(id: String) -> ModelContainerWorker {
        ModelContainerWorker { _, _ in
            AsyncThrowingStream { continuation in
                continuation.yield("stub-\(id)")
                continuation.finish()
            }
        }
    }

    func testBorrowReturnsDistinctWorkersUpToPoolSize() async throws {
        let pool = ModelContainerPool(
            poolSize: 2,
            loadWorker: {
                ModelContainerWorker { _, _ in
                    AsyncThrowingStream { continuation in
                        continuation.yield("chunk")
                        continuation.finish()
                    }
                }
            }
        )

        let first = try await pool.borrow()
        let second = try await pool.borrow()
        XCTAssertTrue(first !== second)

        // A third borrow should fail because the pool is exhausted.
        do {
            _ = try await pool.borrow()
            XCTFail("Expected pool exhausted error")
        } catch ModelContainerPoolError.poolExhausted {
            // Expected.
        }

        await pool.return(first)
        let third = try await pool.borrow()
        XCTAssertTrue(third === first)
    }

    func testConcurrentBorrowUsesDistinctWorkers() async throws {
        let loadCounter = LoadCounter()
        let pool = ModelContainerPool(
            poolSize: 2,
            loadWorker: {
                await loadCounter.increment()
                return ModelContainerWorker { _, _ in
                    AsyncThrowingStream { continuation in
                        continuation.yield("concurrent-stub")
                        continuation.finish()
                    }
                }
            }
        )

        let first = try await withThrowingTaskGroup(of: ModelContainerWorker.self) { group in
            group.addTask { try await pool.borrow() }
            group.addTask { try await pool.borrow() }
            let workerA = try await group.next()!
            let workerB = try await group.next()!
            XCTAssertTrue(workerA !== workerB, "Concurrent borrows must return distinct worker references")
            await pool.return(workerB)
            return workerA
        }

        // Exactly one load per borrow, and each load lands in its own
        // reserved slot. (The reentrant double-load race this guards is
        // pinned deterministically by
        // `testConcurrentBorrowEmptyPoolDoesNotDoubleLoadSlot`.)
        let loadCount = await loadCounter.count
        XCTAssertEqual(loadCount, 2, "Two concurrent borrows over two slots must load exactly two workers")

        await pool.return(first)
    }

    func testThermalCriticalThrows() async throws {
        // The thermal state provider is injected so the `.critical` branch is
        // actually exercised; `ProcessInfo.thermalState` cannot be stubbed.
        let loadCounter = LoadCounter()
        let pool = ModelContainerPool(
            poolSize: 1,
            loadWorker: {
                await loadCounter.increment()
                return ModelContainerWorker { _, _ in
                    AsyncThrowingStream { continuation in
                        continuation.yield("stub")
                        continuation.finish()
                    }
                }
            },
            thermalStateProvider: { .critical }
        )
        let budget = await pool.thermalBudget
        XCTAssertEqual(budget, .critical)

        do {
            _ = try await pool.borrow()
            XCTFail("Expected thermalCritical error")
        } catch DeliberationError.thermalCritical {
            // Expected.
        }

        let loadCount = await loadCounter.count
        XCTAssertEqual(loadCount, 0, "No model load may start while the thermal state is critical")
    }

    func testBorrowWithoutConsentThrows() async {
        let manifestService = ModelManifestService()
        let modelConfig = MLXModelConfiguration(
            modelConfiguration: MLXLMCommon.ModelConfiguration(id: "test/uncensored-model")
        )
        await manifestService.register(
            ModelManifest(id: modelConfig.modelConfiguration.name, checksum: "sha256:abc")
        )

        let pool = ModelContainerPool(
            poolSize: 1,
            modelConfiguration: modelConfig,
            manifestService: manifestService
        )

        do {
            _ = try await pool.borrow()
            XCTFail("Expected modelNotConsented error")
        } catch ModelContainerPoolError.modelNotConsented(let id) {
            XCTAssertEqual(id, modelConfig.modelConfiguration.name)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testBorrowWithoutRegisteredChecksumThrows() async {
        let manifestService = ModelManifestService()
        let modelConfig = MLXModelConfiguration(
            modelConfiguration: MLXLMCommon.ModelConfiguration(id: "test/no-checksum-model")
        )
        await manifestService.grantConsent(id: modelConfig.modelConfiguration.name)

        let pool = ModelContainerPool(
            poolSize: 1,
            modelConfiguration: modelConfig,
            manifestService: manifestService
        )

        do {
            _ = try await pool.borrow()
            XCTFail("Expected modelChecksumMissing error")
        } catch ModelContainerPoolError.modelChecksumMissing(let id) {
            XCTAssertEqual(id, modelConfig.modelConfiguration.name)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testBorrowWithStubWorkerSkipsVerification() async throws {
        let manifestService = ModelManifestService()
        let modelConfig = MLXModelConfiguration(
            modelConfiguration: MLXLMCommon.ModelConfiguration(id: "test/stub-model")
        )
        await manifestService.grantConsent(id: modelConfig.modelConfiguration.name)

        let loadCounter = LoadCounter()
        let pool = ModelContainerPool(
            poolSize: 1,
            modelConfiguration: modelConfig,
            manifestService: manifestService,
            loadWorker: {
                await loadCounter.increment()
                return ModelContainerWorker { _, _ in
                    AsyncThrowingStream { continuation in
                        continuation.yield("stub-stub")
                        continuation.finish()
                    }
                }
            }
        )

        // No checksum is registered for this model. If verification ran against
        // the stub worker, borrow would throw `modelChecksumMissing`; a stub
        // worker (no real container) must skip verification entirely.
        let worker = try await pool.borrow()
        let hasRealContainer = await worker.hasRealContainer()
        XCTAssertFalse(hasRealContainer)
        await pool.return(worker)

        // The worker is pooled after the skipped verification: a second borrow
        // reuses it without loading again.
        let reused = try await pool.borrow()
        XCTAssertTrue(reused === worker)
        await pool.return(reused)

        let loadCount = await loadCounter.count
        XCTAssertEqual(loadCount, 1)
    }

    func testBorrowVerifiesRealContainerAndPasses() async throws {
        let directory = try makeTempDirectory()
        let data = Data("verified model".utf8)
        try data.write(to: directory.appendingPathComponent("model.safetensors"))

        let manifestService = ModelManifestService()
        let modelConfig = MLXModelConfiguration(
            modelConfiguration: MLXLMCommon.ModelConfiguration(id: "test/verified-model")
        )
        await manifestService.register(
            ModelManifest(
                id: modelConfig.modelConfiguration.name,
                checksum: "sha256:\(sha256Hex(data: data))"
            )
        )
        await manifestService.grantConsent(id: modelConfig.modelConfiguration.name)

        let pool = ModelContainerPool(
            poolSize: 1,
            modelConfiguration: modelConfig,
            manifestService: manifestService,
            loadWorker: {
                ModelContainerWorker(
                    modelDirectory: { directory },
                    stubGenerate: { _, _ in
                        AsyncThrowingStream { continuation in
                            continuation.yield("verified-stub")
                            continuation.finish()
                        }
                    }
                )
            }
        )

        let worker = try await pool.borrow()
        await pool.return(worker)
    }

    func testBorrowVerifiesRealContainerAndFails() async throws {
        let directory = try makeTempDirectory()
        let data = Data("verified model".utf8)
        try data.write(to: directory.appendingPathComponent("model.safetensors"))

        let manifestService = ModelManifestService()
        let modelConfig = MLXModelConfiguration(
            modelConfiguration: MLXLMCommon.ModelConfiguration(id: "test/bad-checksum-model")
        )
        await manifestService.register(
            ModelManifest(
                id: modelConfig.modelConfiguration.name,
                checksum: "sha256:0000000000000000000000000000000000000000000000000000000000000000"
            )
        )
        await manifestService.grantConsent(id: modelConfig.modelConfiguration.name)

        let loadCounter = LoadCounter()
        let pool = ModelContainerPool(
            poolSize: 1,
            modelConfiguration: modelConfig,
            manifestService: manifestService,
            loadWorker: {
                await loadCounter.increment()
                return ModelContainerWorker(
                    modelDirectory: { directory },
                    stubGenerate: { _, _ in
                        AsyncThrowingStream { continuation in
                            continuation.yield("bad-stub")
                            continuation.finish()
                        }
                    }
                )
            }
        )

        do {
            _ = try await pool.borrow()
            XCTFail("Expected modelChecksumMismatch error")
        } catch ModelContainerPoolError.modelChecksumMismatch(let id, let expected, let actual) {
            XCTAssertEqual(id, modelConfig.modelConfiguration.name)
            XCTAssertEqual(expected, "sha256:0000000000000000000000000000000000000000000000000000000000000000")
            XCTAssertTrue(actual.hasPrefix("sha256:"))
        }

        // The failed worker slot should have been cleared, so the next borrow
        // attempts to load again.
        do {
            _ = try await pool.borrow()
            XCTFail("Expected modelChecksumMismatch error on retry")
        } catch ModelContainerPoolError.modelChecksumMismatch {
            // Expected.
        }

        let loadCount = await loadCounter.count
        XCTAssertEqual(loadCount, 2)
    }

    func testBorrowClearsSlotWhenChecksumMissingAfterLoad() async throws {
        let directory = try makeTempDirectory()
        let data = Data("verified model".utf8)
        try data.write(to: directory.appendingPathComponent("model.safetensors"))

        let manifestService = ModelManifestService()
        let modelConfig = MLXModelConfiguration(
            modelConfiguration: MLXLMCommon.ModelConfiguration(id: "test/missing-checksum-after-load")
        )
        // Grant consent but do not register a checksum. The worker will load
        // (because the default loadWorker only checks consent/checksum before
        // container creation; our injected loadWorker bypasses that), then
        // verification will discover the missing checksum and clear the slot.
        await manifestService.grantConsent(id: modelConfig.modelConfiguration.name)

        let loadCounter = LoadCounter()
        let pool = ModelContainerPool(
            poolSize: 1,
            modelConfiguration: modelConfig,
            manifestService: manifestService,
            loadWorker: {
                await loadCounter.increment()
                return ModelContainerWorker(
                    modelDirectory: { directory },
                    stubGenerate: { _, _ in
                        AsyncThrowingStream { continuation in
                            continuation.yield("stub")
                            continuation.finish()
                        }
                    }
                )
            }
        )

        do {
            _ = try await pool.borrow()
            XCTFail("Expected modelChecksumMissing error")
        } catch ModelContainerPoolError.modelChecksumMissing(let id) {
            XCTAssertEqual(id, modelConfig.modelConfiguration.name)
        }

        // The slot should have been cleared, so the next borrow tries to load again.
        do {
            _ = try await pool.borrow()
            XCTFail("Expected modelChecksumMissing error on retry")
        } catch ModelContainerPoolError.modelChecksumMissing {
            // Expected.
        }

        let loadCount = await loadCounter.count
        XCTAssertEqual(loadCount, 2)
    }

    func testBorrowVerifiesShardedModelAndPasses() async throws {
        let directory = try makeTempDirectory()

        let shardA = Data("shard a bytes".utf8)
        let shardB = Data("shard b bytes".utf8)
        try shardA.write(to: directory.appendingPathComponent("model-00001-of-00002.safetensors"))
        try shardB.write(to: directory.appendingPathComponent("model-00002-of-00002.safetensors"))

        let index: [String: Any] = [
            "weight_map": [
                "layer1.weight": "model-00001-of-00002.safetensors",
                "layer2.weight": "model-00002-of-00002.safetensors",
            ]
        ]
        let indexData = try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys])
        try indexData.write(to: directory.appendingPathComponent("model.safetensors.index.json"))

        var hasher = SHA256()
        hasher.update(data: shardA)
        hasher.update(data: shardB)
        let combinedChecksum = "sha256:" + hasher.finalize().hexString

        let manifestService = ModelManifestService()
        let modelConfig = MLXModelConfiguration(
            modelConfiguration: MLXLMCommon.ModelConfiguration(id: "test/sharded-model")
        )
        await manifestService.register(
            ModelManifest(id: modelConfig.modelConfiguration.name, checksum: combinedChecksum)
        )
        await manifestService.grantConsent(id: modelConfig.modelConfiguration.name)

        let pool = ModelContainerPool(
            poolSize: 1,
            modelConfiguration: modelConfig,
            manifestService: manifestService,
            loadWorker: {
                ModelContainerWorker(
                    modelDirectory: { directory },
                    stubGenerate: { _, _ in
                        AsyncThrowingStream { continuation in
                            continuation.yield("sharded-stub")
                            continuation.finish()
                        }
                    }
                )
            }
        )

        let worker = try await pool.borrow()
        await pool.return(worker)

        // A second borrow should not re-verify (no extra loads).
        let worker2 = try await pool.borrow()
        await pool.return(worker2)
    }

    // MARK: - Adversarial

    /// Regression test for the reentrant double-load race: `borrow()` used to
    /// suspend on `loadWorker()` while the slot was still nil and unreserved,
    /// so a concurrent second borrow loaded a second worker into the same slot
    /// and the later resumption overwrote `workers[index]` — two live workers
    /// sharing one busy bit, and a multi-GB model loaded twice. The slot is now
    /// reserved before the first suspension point.
    func testConcurrentBorrowEmptyPoolDoesNotDoubleLoadSlot() async throws {
        let loadCounter = LoadCounter()
        let gate = LoadGate()
        let pool = ModelContainerPool(
            poolSize: 1,
            loadWorker: {
                await loadCounter.increment()
                await gate.markStarted()
                await gate.waitUntilReleased()
                return ModelContainerWorker { _, _ in
                    AsyncThrowingStream { continuation in
                        continuation.yield("raced-stub")
                        continuation.finish()
                    }
                }
            }
        )

        // The first borrow enters `loadWorker()` and suspends inside it.
        let firstBorrow = Task { try await pool.borrow() }
        await gate.waitUntilStarted()

        // While the first borrow is suspended mid-load, a second borrow must
        // not start another load into the same slot. With the slot reserved,
        // it fails fast with `poolExhausted` instead.
        let secondBorrow = Task { try await pool.borrow() }

        await gate.release()

        let first = try await firstBorrow.value

        let loadCount = await loadCounter.count
        XCTAssertEqual(loadCount, 1, "A reentrant borrow must not load a second worker into the same slot")

        do {
            let duplicate = try await secondBorrow.value
            await pool.return(duplicate)
            XCTFail("Second borrow loaded a duplicate worker into the reserved slot")
        } catch ModelContainerPoolError.poolExhausted {
            // Expected: the only slot is reserved by the in-flight load.
        } catch {
            XCTFail("Expected poolExhausted, got \(error)")
        }

        // Bookkeeping stays consistent: return then re-borrow yields the same
        // worker with no additional load.
        await pool.return(first)
        let reused = try await pool.borrow()
        XCTAssertTrue(reused === first)
        let finalLoadCount = await loadCounter.count
        XCTAssertEqual(finalLoadCount, 1)
        await pool.return(reused)
    }

    /// Regression test: a corrupt `model.safetensors.index.json` used to make
    /// `JSONDecoder.decode` throw a raw `DecodingError` out of
    /// `ModelArtifactVerifier.shardFilenames`, which `borrow()` did not map —
    /// an undocumented error type escaped the pool. It is now surfaced as
    /// `modelChecksumMismatch` ("missing artifacts").
    func testBorrowWithCorruptIndexJSONThrowsChecksumMismatch() async throws {
        let directory = try makeTempDirectory()
        let garbage = Data("this is not json {".utf8)
        try garbage.write(to: directory.appendingPathComponent("model.safetensors.index.json"))

        let manifestService = makeIsolatedManifestService(ids: ["test/corrupt-index-model"])
        let modelConfig = MLXModelConfiguration(
            modelConfiguration: MLXLMCommon.ModelConfiguration(id: "test/corrupt-index-model")
        )
        let expected = "sha256:0000000000000000000000000000000000000000000000000000000000000000"
        await manifestService.register(
            ModelManifest(id: modelConfig.modelConfiguration.name, checksum: expected)
        )
        await manifestService.grantConsent(id: modelConfig.modelConfiguration.name)

        let pool = ModelContainerPool(
            poolSize: 1,
            modelConfiguration: modelConfig,
            manifestService: manifestService,
            loadWorker: {
                ModelContainerWorker(
                    modelDirectory: { directory },
                    stubGenerate: { _, _ in
                        AsyncThrowingStream { continuation in
                            continuation.yield("corrupt-index-stub")
                            continuation.finish()
                        }
                    }
                )
            }
        )

        do {
            _ = try await pool.borrow()
            XCTFail("Expected modelChecksumMismatch error")
        } catch ModelContainerPoolError.modelChecksumMismatch(let id, let expectedChecksum, let actual) {
            XCTAssertEqual(id, modelConfig.modelConfiguration.name)
            XCTAssertEqual(expectedChecksum, expected)
            XCTAssertEqual(actual, "sha256:missing artifacts")
        } catch {
            XCTFail("Corrupt index leaked an unmapped error type: \(error)")
        }
    }

    /// Pins the documented consent-enforcement boundary: `ModelContainerPool`
    /// checks consent only inside the default `loadWorker` at first load;
    /// `borrow()` itself never re-validates consent for a pooled worker. The
    /// per-call consent gate lives in `MLXInferenceProvider.generate` (covered
    /// by `testGenerateAfterConsentRevokedThrows`). If this test starts
    /// failing because borrow() learned to re-check consent, that is a
    /// deliberate hardening change — update this pin.
    func testPoolBorrowAfterConsentRevokedStillServesPooledWorker() async throws {
        let manifestService = makeIsolatedManifestService(ids: ["test/revoked-consent-model"])
        let modelConfig = MLXModelConfiguration(
            modelConfiguration: MLXLMCommon.ModelConfiguration(id: "test/revoked-consent-model")
        )
        await manifestService.grantConsent(id: modelConfig.modelConfiguration.name)

        let pool = ModelContainerPool(
            poolSize: 1,
            modelConfiguration: modelConfig,
            manifestService: manifestService,
            loadWorker: {
                ModelContainerWorker { _, _ in
                    AsyncThrowingStream { continuation in
                        continuation.yield("pooled-stub")
                        continuation.finish()
                    }
                }
            }
        )

        let worker = try await pool.borrow()
        await pool.return(worker)

        // Revoking consent does not invalidate an already-pooled worker.
        await manifestService.revokeConsent(id: modelConfig.modelConfiguration.name)
        let reused = try await pool.borrow()
        XCTAssertTrue(reused === worker)
        await pool.return(reused)
    }

    /// Boundary: poolSize 0 can never hand out a worker. A negative poolSize
    /// would crash `Array(repeating:count:)` on a precondition; that input is
    /// invalid by contract and intentionally not exercised here.
    func testPoolSizeZeroAlwaysThrowsExhausted() async {
        let loadCounter = LoadCounter()
        let pool = ModelContainerPool(
            poolSize: 0,
            loadWorker: {
                await loadCounter.increment()
                return ModelContainerWorker { _, _ in
                    AsyncThrowingStream { continuation in
                        continuation.finish()
                    }
                }
            }
        )

        do {
            _ = try await pool.borrow()
            XCTFail("Expected poolExhausted error")
        } catch ModelContainerPoolError.poolExhausted {
            // Expected.
        } catch {
            XCTFail("Expected poolExhausted, got \(error)")
        }

        let loadCount = await loadCounter.count
        XCTAssertEqual(loadCount, 0)
    }

    /// Pins `return(_:)` leniency: returning a worker the pool never handed
    /// out, or returning the same worker twice, must be a silent no-op that
    /// leaves the busy set intact.
    func testReturnUnknownOrDoubleReturnedWorkerIsNoOp() async throws {
        let pool = ModelContainerPool(
            poolSize: 1,
            loadWorker: {
                ModelContainerWorker { _, _ in
                    AsyncThrowingStream { continuation in
                        continuation.yield("return-stub")
                        continuation.finish()
                    }
                }
            }
        )

        let worker = try await pool.borrow()

        let outsider = ModelContainerWorker { _, _ in
            AsyncThrowingStream { continuation in
                continuation.yield("outsider")
                continuation.finish()
            }
        }

        // Unknown worker: no-op (the slot must stay busy; if it were cleared
        // by mistake, the borrow below would hand out a second worker).
        await pool.return(outsider)

        // Double return of the real worker: first clears the slot, second is a no-op.
        await pool.return(worker)
        await pool.return(worker)

        let reused = try await pool.borrow()
        XCTAssertTrue(reused === worker)
        await pool.return(reused)
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

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func sha256Hex(data: Data) -> String {
        SHA256.hash(data: data).hexString
    }
}

extension SHA256Digest {
    fileprivate var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private actor LoadCounter {
    var count = 0

    func increment() {
        count += 1
    }
}

/// Two-phase gate for deterministic actor-reentrancy tests: signals when a
/// load has started, and holds the load until explicitly released.
private actor LoadGate {
    private var hasStarted = false
    private var isReleased = false
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var releasedContinuation: CheckedContinuation<Void, Never>?

    func markStarted() {
        hasStarted = true
        startedContinuation?.resume()
        startedContinuation = nil
    }

    func waitUntilStarted() async {
        if hasStarted { return }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func waitUntilReleased() async {
        if isReleased { return }
        await withCheckedContinuation { continuation in
            releasedContinuation = continuation
        }
    }

    func release() {
        isReleased = true
        releasedContinuation?.resume()
        releasedContinuation = nil
    }
}
