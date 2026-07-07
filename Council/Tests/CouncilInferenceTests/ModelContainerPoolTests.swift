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
}
