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

    /// Creates a mock provider.
    ///
    /// - Parameters:
    ///   - cannedResponses: Responses to yield in order, one per `generate` call.
    ///   - chunkDelayNanoseconds: Artificial delay before yielding each chunk,
    ///     useful for testing cancellation. Defaults to 1 ms.
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
                    if chunkDelayNanoseconds > 0 {
                        try await Task.sleep(nanoseconds: chunkDelayNanoseconds)
                    }
                    try Task.checkCancellation()
                    continuation.yield(response)
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
