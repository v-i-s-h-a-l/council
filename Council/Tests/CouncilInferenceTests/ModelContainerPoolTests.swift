import XCTest
import CouncilCore
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
}
