import CouncilCore
import Foundation

/// Test-only mock inference provider returning canned strings or JSON.
public actor MockInferenceProvider: InferenceProvider {
    public var routeSnapshot: RouteSnapshot {
        RouteSnapshot(
            framework: "mock",
            modelIdentifier: "mock",
            route: .onDeviceApple,
            isLocal: true
        )
    }

    private let cannedResponses: [String]
    private let chunkDelayNanoseconds: UInt64
    private var callIndex: Int = 0
    public private(set) var calls: [[InferenceMessage]] = []
    public private(set) var cancellationCount: Int = 0

    /// Creates a mock provider.
    ///
    /// - Parameters:
    ///   - cannedResponses: Responses to yield in order, one per `generate` call.
    ///   - chunkDelayNanoseconds: Artificial delay after yielding each chunk
    ///     before finishing the stream. Useful for testing cancellation because
    ///     the producer remains active after the first chunk. Defaults to 1 ms.
    public init(
        cannedResponses: [String] = [""],
        chunkDelayNanoseconds: UInt64 = 1_000_000
    ) {
        self.cannedResponses = cannedResponses
        self.chunkDelayNanoseconds = chunkDelayNanoseconds
    }

    public func generate(
        messages: [InferenceMessage],
        options: InferenceOptions
    ) async throws -> AsyncThrowingStream<String, Error> {
        calls.append(messages)
        let response = cannedResponses[min(callIndex, cannedResponses.count - 1)]
        callIndex += 1

        return AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    try Task.checkCancellation()
                    continuation.yield(response)
                    if chunkDelayNanoseconds > 0 {
                        try await Task.sleep(nanoseconds: chunkDelayNanoseconds)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { [weak self] _ in
                producer.cancel()
                guard let self else { return }
                Task {
                    await self.recordCancellation()
                }
            }
        }
    }

    private func recordCancellation() {
        cancellationCount += 1
    }
}
