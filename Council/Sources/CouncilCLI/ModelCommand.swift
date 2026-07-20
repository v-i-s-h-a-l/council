import ArgumentParser
import CouncilAgents
import CouncilInference
import Foundation

@available(macOS 14.0, iOS 17.0, *)
struct ModelCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "model",
        abstract: "Manage model manifests and download consent.",
        subcommands: [ListCommand.self, RegisterCommand.self, ShowCommand.self, ConsentCommand.self, RevokeCommand.self, UnregisterCommand.self]
    )
}

// MARK: - List

@available(macOS 14.0, iOS 17.0, *)
extension ModelCommand {
    struct ListCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List registered model manifests."
        )

        @OptionGroup
        var options: GlobalOptions

        func run() async throws {
            let assembly = try await CLIAssembly.makeRuntimeAssembly(options: options)
            let manifests = await assembly.manifestService.allManifests()
            switch options.format {
            case .text, .markdown:
                if manifests.isEmpty {
                    CLIAssembly.writeToStderr("No models registered.\n")
                    CLIAssembly.writeToStderr("Note: model manifests are process-local for this phase.\n")
                    return
                }
                for manifest in manifests {
                    let consented = await assembly.manifestService.isModelConsented(id: manifest.id) ? "yes" : "no"
                    print("\(manifest.id)\t\(manifest.checksum ?? "-")\tconsent: \(consented)")
                }
            case .json:
                var rows: [ModelRow] = []
                for manifest in manifests {
                    let consented = await assembly.manifestService.isModelConsented(id: manifest.id)
                    rows.append(ModelRow(
                        id: manifest.id,
                        checksum: manifest.checksum,
                        signature: manifest.signature,
                        consented: consented
                    ))
                }
                print(try CLIEncoder.json(rows))
            }
        }
    }
}

// MARK: - Register

@available(macOS 14.0, iOS 17.0, *)
extension ModelCommand {
    struct RegisterCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "register",
            abstract: "Register a model manifest with a checksum."
        )

        @OptionGroup
        var options: GlobalOptions

        @Argument(help: "The model identifier.")
        var id: String

        @Option(help: "SHA-256 checksum of the model artifacts.")
        var checksum: String

        func validate() throws {
            guard isValidSHA256Checksum(checksum) else {
                throw ValidationError("--checksum must be a SHA-256 hex digest (64 hex characters, optionally prefixed with sha256:).")
            }
        }

        func run() async throws {
            let assembly = try await CLIAssembly.makeRuntimeAssembly(options: options)
            await Self.register(id: id, checksum: checksum, manifestService: assembly.manifestService)
        }

        /// Registers a model manifest. Re-registering an id with a different
        /// checksum revokes download consent: consent is bound to the artifacts
        /// it was granted for, so swapped artifacts must be re-consented
        /// explicitly instead of inheriting the old approval.
        static func register(id: String, checksum: String, manifestService: ModelManifestService) async {
            let previous = await manifestService.manifest(id: id)
            await manifestService.register(ModelManifest(id: id, checksum: checksum))
            if let previous,
               normalizedSHA256Digest(previous.checksum ?? "") != normalizedSHA256Digest(checksum) {
                await manifestService.revokeConsent(id: id)
                CLIAssembly.writeToStderr(
                    "Checksum for \(id) changed; download consent revoked. Re-consent with 'council model consent \(id)'.\n"
                )
            }
        }
    }
}

// MARK: - Show

@available(macOS 14.0, iOS 17.0, *)
extension ModelCommand {
    struct ShowCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Show a registered model manifest."
        )

        @OptionGroup
        var options: GlobalOptions

        @Argument(help: "The model identifier.")
        var id: String

        func run() async throws {
            let assembly = try await CLIAssembly.makeRuntimeAssembly(options: options)
            guard let manifest = await assembly.manifestService.manifest(id: id) else {
                CLIAssembly.writeToStderr("No model registered with id \(id).\n")
                throw ExitCode(1)
            }
            switch options.format {
            case .text, .markdown:
                print("id: \(manifest.id)")
                print("checksum: \(manifest.checksum ?? "-")")
                print("signature: \(manifest.signature ?? "-")")
                print("consented: \(await assembly.manifestService.isModelConsented(id: manifest.id) ? "yes" : "no")")
            case .json:
                let row = ModelRow(
                    id: manifest.id,
                    checksum: manifest.checksum,
                    signature: manifest.signature,
                    consented: await assembly.manifestService.isModelConsented(id: manifest.id)
                )
                print(try CLIEncoder.json(row))
            }
        }
    }
}

// MARK: - Consent / Revoke / Unregister

@available(macOS 14.0, iOS 17.0, *)
extension ModelCommand {
    struct ConsentCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "consent",
            abstract: "Grant download consent for a model."
        )

        @OptionGroup
        var options: GlobalOptions

        @Argument(help: "The model identifier.")
        var id: String

        func run() async throws {
            let assembly = try await CLIAssembly.makeRuntimeAssembly(options: options)
            await assembly.manifestService.grantConsent(id: id)
        }
    }

    struct RevokeCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "revoke",
            abstract: "Revoke download consent for a model."
        )

        @OptionGroup
        var options: GlobalOptions

        @Argument(help: "The model identifier.")
        var id: String

        func run() async throws {
            let assembly = try await CLIAssembly.makeRuntimeAssembly(options: options)
            await assembly.manifestService.revokeConsent(id: id)
        }
    }

    struct UnregisterCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "unregister",
            abstract: "Unregister a model manifest."
        )

        @OptionGroup
        var options: GlobalOptions

        @Argument(help: "The model identifier.")
        var id: String

        func run() async throws {
            let assembly = try await CLIAssembly.makeRuntimeAssembly(options: options)
            await assembly.manifestService.unregister(id: id)
        }
    }
}

private struct ModelRow: Encodable {
    let id: String
    let checksum: String?
    let signature: String?
    let consented: Bool
}

/// Returns whether `value` is a well-formed SHA-256 checksum: exactly 64 hex
/// characters, optionally prefixed with `sha256:`. Rejecting malformed
/// checksums at the CLI boundary keeps typos from surfacing opaquely at model
/// load time.
func isValidSHA256Checksum(_ value: String) -> Bool {
    let hex = value.hasPrefix("sha256:") ? String(value.dropFirst("sha256:".count)) : value
    return hex.count == 64 && hex.allSatisfy { $0.isHexDigit }
}

/// Returns the digest without its optional `sha256:` prefix, lowercased, so
/// equivalent spellings of the same checksum compare equal (prefixed vs. bare
/// vs. uppercase must not read as a checksum "change" and spuriously revoke
/// consent).
func normalizedSHA256Digest(_ value: String) -> String {
    let lowered = value.lowercased()
    return lowered.hasPrefix("sha256:") ? String(lowered.dropFirst("sha256:".count)) : lowered
}
