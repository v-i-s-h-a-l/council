import CouncilCore

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
    private var callIndex: Int = 0
    public private(set) var calls: [[InferenceMessage]] = []

    public init(cannedResponses: [String] = [""]) {
        self.cannedResponses = cannedResponses
    }

    public func generate(
        messages: [InferenceMessage],
        options: InferenceOptions
    ) async throws -> AsyncThrowingStream<String, Error> {
        calls.append(messages)
        let response = cannedResponses[min(callIndex, cannedResponses.count - 1)]
        callIndex += 1
        return AsyncThrowingStream { continuation in
            continuation.yield(response)
            continuation.finish()
        }
    }
}
