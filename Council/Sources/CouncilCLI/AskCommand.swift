import ArgumentParser
import CouncilAgents
import CouncilCore
import CouncilInference
import CouncilMemory
import Foundation

@available(macOS 14.0, iOS 17.0, *)
struct AskCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ask",
        abstract: "Ask the Purchase Council a question."
    )

    @OptionGroup
    var options: GlobalOptions

    @Argument(help: "The purchase question to deliberate.")
    var question: String

    @Option(help: "Inference provider: echo (default) or mlx.")
    var provider: Provider = .echo

    @Option(help: "Model identifier. Required when provider is mlx.")
    var model: String?

    @Option(help: "SHA-256 checksum of the model. Required when provider is mlx.")
    var checksum: String?

    @Flag(help: "Grant explicit consent to download the model.")
    var consentDownload = false

    @Flag(help: "Skip saving the episodic gist and audit log.")
    var noPersist = false

    enum Provider: String, ExpressibleByArgument, CaseIterable {
        case echo
        case mlx
    }

    func validate() throws {
        if provider == .mlx {
            guard model != nil else {
                throw ValidationError("--model is required when --provider is mlx.")
            }
            guard let checksum else {
                throw ValidationError("--checksum is required when --provider is mlx.")
            }
            guard isValidSHA256Checksum(checksum) else {
                throw ValidationError("--checksum must be a SHA-256 hex digest (64 hex characters, optionally prefixed with sha256:).")
            }
        }
    }

    func run() async throws {
        let assembly = try await CLIAssembly.makeRuntimeAssembly(options: options)
        if options.verbose {
            CLIAssembly.writeToStderr("Runtime initialized.\n")
        }

        let inferenceProvider = try await Self.makeInferenceProvider(
            provider: provider,
            model: model,
            checksum: checksum,
            consentDownload: consentDownload,
            manifestService: assembly.manifestService
        )

        let service = try await assembly.deliberationService(
            provider: inferenceProvider,
            options: InferenceOptions(),
            persist: !noPersist
        )

        // Subscribe to state updates before starting the session so the stream
        // continuation is captured before any state transitions finish.
        let stream = await service.stateUpdates()

        let signalSource = Self.installSignalHandler {
            Task {
                await service.cancel()
            }
        }
        defer { signalSource?.cancel() }

        await service.startSession(question: question)

        var finalPerspective: Perspective?
        var failed = false
        var cancelled = false

        for await state in stream {
            if options.verbose {
                CLIAssembly.writeToStderr("Stage: \(state.stage.rawValue)\n")
            }

            switch state.stage {
            case .presentation:
                finalPerspective = state.perspective
            case .failed:
                failed = true
            case .cancelled:
                cancelled = true
            default:
                break
            }
        }

        if cancelled {
            CLIAssembly.writeToStderr("Cancelled.\n")
            throw ExitCode(130)
        }

        guard let perspective = finalPerspective, !failed else {
            throw ExitCode(2)
        }

        let output: String
        switch options.format {
        case .text:
            output = PerspectiveFormatter.text(perspective)
        case .markdown:
            output = PerspectiveFormatter.markdown(perspective)
        case .json:
            output = try CLIEncoder.json(perspective)
        }

        print(output)
    }

    static func makeInferenceProvider(
        provider: Provider,
        model: String?,
        checksum: String?,
        consentDownload: Bool,
        manifestService: ModelManifestService
    ) async throws -> any InferenceProvider {
        switch provider {
        case .echo:
            return EchoInferenceProvider()
        case .mlx:
            let modelConfig: MLXModelConfiguration
            if let model {
                modelConfig = MLXModelConfiguration(modelIdentifier: model)
            } else {
                modelConfig = .default
            }
            let modelID = modelConfig.modelConfiguration.name

            // Consent is bound to the model artifacts it was granted for. If the
            // registered checksum changed since consent was given (model bits
            // swapped under the same id), the old consent must not be inherited:
            // require explicit re-consent instead of silently downloading a
            // different artifact than the user approved. Registration only
            // happens once consent is settled, so a rejected run leaves no
            // phantom manifest behind.
            let previous = await manifestService.manifest(id: modelID)
            let checksumChanged = previous != nil
                && previous?.checksum.map(normalizedSHA256Digest) != checksum.map(normalizedSHA256Digest)

            if consentDownload {
                await manifestService.register(
                    ModelManifest(id: modelID, checksum: checksum)
                )
                await manifestService.grantConsent(id: modelID)
            } else if checksumChanged {
                CLIAssembly.writeToStderr(
                    "Checksum for \(modelID) changed since consent was granted. Re-consent with --consent-download or run 'council model consent \(modelID)'.\n"
                )
                throw ExitCode(64)
            } else {
                guard await manifestService.isModelConsented(id: modelID) else {
                    CLIAssembly.writeToStderr(
                        "MLX provider requires explicit consent. Pass --consent-download or run 'council model consent \(modelID)'.\n"
                    )
                    throw ExitCode(64)
                }
                await manifestService.register(
                    ModelManifest(id: modelID, checksum: checksum)
                )
            }

            let pool = ModelContainerPool(
                modelConfiguration: modelConfig,
                manifestService: manifestService
            )
            return MLXInferenceProvider(
                pool: pool,
                modelConfiguration: modelConfig,
                manifestService: manifestService
            )
        }
    }

    private static func installSignalHandler(
        _ handler: @escaping () -> Void
    ) -> DispatchSourceSignal? {
        #if os(macOS)
        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        signal(SIGINT) { _ in }
        signalSource.setEventHandler(handler: handler)
        signalSource.resume()
        return signalSource
        #else
        return nil
        #endif
    }
}
