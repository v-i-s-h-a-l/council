import XCTest
import CouncilCore
import CouncilTestUtilities

final class MockInferenceProviderTests: XCTestCase {
    func testMockStreamYieldsCannedResponse() async throws {
        let provider = MockInferenceProvider(cannedResponses: ["hello, council"])
        let stream = try await provider.generate(
            messages: [InferenceMessage(role: .user, content: "hi")],
            options: InferenceOptions()
        )

        var chunks: [String] = []
        for try await chunk in stream {
            chunks.append(chunk)
        }

        XCTAssertEqual(chunks, ["hello, council"])

        let calls = await provider.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.first?.content, "hi")
    }

    func testMockStreamRespectsCancellation() async throws {
        let provider = MockInferenceProvider(
            cannedResponses: ["first"],
            chunkDelayNanoseconds: 10_000_000_000  // 10 s
        )

        let start = Date()
        let stream = try await provider.generate(
            messages: [],
            options: InferenceOptions()
        )

        // Consume the first chunk, then terminate the stream early. The
        // stream's termination handler should cancel the still-sleeping
        // producer task, so the elapsed time must be far less than 10 s.
        var chunks: [String] = []
        for try await chunk in stream {
            chunks.append(chunk)
            break
        }

        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(chunks, ["first"])
        XCTAssertLessThan(elapsed, 2.0, "Producer sleep was not cancelled")
    }
}
