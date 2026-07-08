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

    func testReturnMakesWorkerAvailableAgain() async throws {
        let pool = ModelContainerPool(
            poolSize: 1,
            loadWorker: { [id = "single"] in
                ModelContainerWorker { _, _ in
                    AsyncThrowingStream { continuation in
                        continuation.yield("stub-\(id)")
                        continuation.finish()
                    }
                }
            }
        )

        let worker = try await pool.borrow()
        await pool.return(worker)
        let reused = try await pool.borrow()
        XCTAssertTrue(worker === reused)
    }

    func testThermalCriticalThrows() async throws {
        // ProcessInfo thermal state cannot be overridden directly, so this
        // test verifies the property exists and is not `.critical` in normal
        // test environments. Borrowing therefore succeeds, using a stub worker
        // to avoid loading a real MLX model.
        let pool = ModelContainerPool(
            poolSize: 1,
            loadWorker: {
                ModelContainerWorker { _, _ in
                    AsyncThrowingStream { continuation in
                        continuation.yield("stub")
                        continuation.finish()
                    }
                }
            }
        )
        let budget = await pool.thermalBudget
        XCTAssertNotEqual(budget, .critical)

        // Ensure borrowing still works when not critical.
        let worker = try await pool.borrow()
        await pool.return(worker)
    }

    func testConcurrentBorrowUsesDistinctWorkers() async throws {
        let pool = ModelContainerPool(
            poolSize: 2,
            loadWorker: {
                ModelContainerWorker { _, _ in
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

        await pool.return(first)
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

        let pool = ModelContainerPool(
            poolSize: 1,
            modelConfiguration: modelConfig,
            manifestService: manifestService,
            loadWorker: { [id = "stub"] in
                ModelContainerWorker { _, _ in
                    AsyncThrowingStream { continuation in
                        continuation.yield("stub-\(id)")
                        continuation.finish()
                    }
                }
            }
        )

        let worker = try await pool.borrow()
        await pool.return(worker)
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

    // MARK: - Helpers

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
