import Foundation
import MLXLMCommon
import CouncilCore

/// Errors that can occur inside a `ModelContainerWorker`.
public enum ModelContainerWorkerError: Error, Sendable {
    case noContainer
}

/// Actor that owns exactly one `MLXLMCommon.ModelContainer` and exposes
/// streaming generation on top of it.
///
/// All access to the container is serialized through this actor.
public actor ModelContainerWorker {
    private let container: MLXLMCommon.ModelContainer?
    private let stubGenerate: (
        @Sendable (
            [InferenceMessage],
            InferenceOptions
        ) async throws -> AsyncThrowingStream<String, Error>
    )?
    private let modelDirectoryProvider: (@Sendable () async throws -> URL)?

    /// Creates a worker backed by a real MLX model container.
    public init(container: MLXLMCommon.ModelContainer) {
        self.container = container
        self.stubGenerate = nil
        self.modelDirectoryProvider = nil
    }

    /// Internal initializer for tests that need a stub worker without loading
    /// a real MLX model.
    internal init(
        stubGenerate: @escaping @Sendable (
            [InferenceMessage],
            InferenceOptions
        ) async throws -> AsyncThrowingStream<String, Error>
    ) {
        self.container = nil
        self.stubGenerate = stubGenerate
        self.modelDirectoryProvider = nil
    }

    /// Internal initializer for tests that exercise artifact verification
    /// without loading a real MLX model.
    internal init(
        modelDirectory: @escaping @Sendable () async throws -> URL,
        stubGenerate: @escaping @Sendable (
            [InferenceMessage],
            InferenceOptions
        ) async throws -> AsyncThrowingStream<String, Error>
    ) {
        self.container = nil
        self.stubGenerate = stubGenerate
        self.modelDirectoryProvider = modelDirectory
    }

    /// Returns `true` if the worker wraps a real model container (or a test
    /// equivalent) and can therefore provide a model directory for verification.
    public func hasRealContainer() -> Bool {
        container != nil || modelDirectoryProvider != nil
    }

    /// Resolves the local directory containing the downloaded model artifacts.
    public func modelDirectory() async throws -> URL {
        if let modelDirectoryProvider {
            return try await modelDirectoryProvider()
        }

        guard let container else {
            throw ModelContainerWorkerError.noContainer
        }

        return try await container.modelDirectory
    }

    /// Generates a streaming text response for the provided messages.
    ///
    /// - Parameters:
    ///   - messages: Conversation messages.
    ///   - options: Council inference options.
    /// - Returns: An async stream of text chunks.
    public func generate(
        messages: [InferenceMessage],
        options: InferenceOptions
    ) async throws -> AsyncThrowingStream<String, Error> {
        if let stubGenerate {
            return try await stubGenerate(messages, options)
        }

        guard let container else {
            throw ModelContainerWorkerError.noContainer
        }

        let stream = try await container.perform { context in
            let mlxMessages: [MLXLMCommon.Message] = messages.map { message in
                [
                    "role": message.role.rawValue,
                    "content": message.content,
                ]
            }
            let userInput = MLXLMCommon.UserInput(messages: mlxMessages)
            let lmInput = try await context.processor.prepare(input: userInput)
            return try MLXLMCommon.generate(
                input: lmInput,
                parameters: options.mlxParameters,
                context: context
            )
        }

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await generation in stream {
                        try Task.checkCancellation()
                        if let chunk = generation.chunk {
                            continuation.yield(chunk)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
