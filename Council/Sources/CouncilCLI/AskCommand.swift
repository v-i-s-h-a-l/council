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

    @Argument(help: "The purchase question to deliberate.")
    var question: String

    @Option(help: "Directory for profile vault and databases.")
    var profileDir: String?

    @Option(help: "Inference provider: echo (default) or mlx.")
    var provider: Provider = .echo

    @Option(help: "Model identifier. Required when provider is mlx.")
    var model: String?

    @Option(help: "SHA-256 checksum of the model. Required when provider is mlx.")
    var checksum: String?

    @Flag(help: "Grant explicit consent to download the model.")
    var consentDownload = false

    @Option(help: "Output format: text, markdown, or json.")
    var format: OutputFormat = .text

    @Flag(help: "Skip saving the episodic gist and audit log.")
    var noPersist = false

    @Flag(help: "Print stage progress to stderr.")
    var verbose = false

    enum Provider: String, ExpressibleByArgument, CaseIterable {
        case echo
        case mlx
    }

    enum OutputFormat: String, ExpressibleByArgument, CaseIterable {
        case text
        case markdown
        case json
    }

    func validate() throws {
        if provider == .mlx {
            guard model != nil else {
                throw ValidationError("--model is required when --provider is mlx.")
            }
            guard checksum != nil else {
                throw ValidationError("--checksum is required when --provider is mlx.")
            }
        }
    }

    func run() async throws {
        let profileDirectory = try Self.resolveProfileDirectory(path: profileDir)
        if verbose {
            FileHandle.standardError.write(Data("Initializing runtime...\n".utf8))
        }
        let assembly = try await RuntimeAssembly(
            rootDirectory: profileDirectory,
            useSecureEnclave: false
        )
        if verbose {
            FileHandle.standardError.write(Data("Runtime initialized.\n".utf8))
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
            if verbose {
                var status = "Stage: \(state.stage.rawValue)"
                if let errorMessage = state.errorMessage {
                    status += " | Error: \(errorMessage)"
                }
                FileHandle.standardError.write(Data("\(status)\n".utf8))
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
            FileHandle.standardError.write(Data("Cancelled.\n".utf8))
            throw ExitCode(130)
        }

        guard let perspective = finalPerspective, !failed else {
            throw ExitCode(2)
        }

        let output: String
        switch format {
        case .text:
            output = PerspectiveFormatter.text(perspective)
        case .markdown:
            output = PerspectiveFormatter.markdown(perspective)
        case .json:
            output = try PerspectiveFormatter.json(perspective)
        }

        print(output)
    }

    private static func resolveProfileDirectory(path: String?) throws -> URL {
        if let path {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
            return url
        }

        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            struct ProfileDirectoryError: Error {}
            throw ProfileDirectoryError()
        }
        return appSupport.appendingPathComponent("Council", isDirectory: true)
    }

    private static func makeInferenceProvider(
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

            await manifestService.register(
                ModelManifest(id: modelID, checksum: checksum)
            )

            guard consentDownload else {
                FileHandle.standardError.write(Data(
                    "MLX provider requires explicit consent. Pass --consent-download.\n".utf8
                ))
                throw ExitCode(64)
            }
            await manifestService.grantConsent(id: modelID)

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
