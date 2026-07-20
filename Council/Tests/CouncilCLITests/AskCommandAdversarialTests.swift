import ArgumentParser
@testable import CouncilCLI
import CouncilInference
import Foundation
import Testing

/// Adversarial tests for the MLX consent boundary in `AskCommand`.
///
/// Each test uses a `ModelManifestService` backed by an isolated
/// `UserDefaults` suite so consent/manifest state never leaks between tests
/// or into the shared `.standard` defaults.
@Suite("AskCommand adversarial")
struct AskCommandAdversarialTests {

    private static let checksumA = "sha256:" + String(repeating: "a", count: 64)
    private static let checksumB = "sha256:" + String(repeating: "b", count: 64)

    private func makeIsolatedManifestService() -> (service: ModelManifestService, manifestsKey: String) {
        // .standard defaults with a unique suite key: no non-Sendable UserDefaults
        // crosses into the actor, and tests running in parallel never share state.
        let suiteKey = "com.council.test.\(UUID().uuidString)"
        return (ModelManifestService(suiteKey: suiteKey), "\(suiteKey).manifests")
    }

    @Test("checksum swap under a consented id does not inherit the old consent")
    func askMlxChecksumSwapDoesNotInheritConsent() async throws {
        let (service, manifestsKey) = makeIsolatedManifestService()
        defer { UserDefaults.standard.removeObject(forKey: manifestsKey) }

        // User consented to checksum A. An attacker (or a mistake) presenting
        // checksum B under the same id must be stopped, not waved through.
        await service.register(ModelManifest(id: "test-model", checksum: Self.checksumA))
        await service.grantConsent(id: "test-model")

        do {
            _ = try await AskCommand.makeInferenceProvider(
                provider: .mlx,
                model: "test-model",
                checksum: Self.checksumB,
                consentDownload: false,
                manifestService: service
            )
            Issue.record("Expected ExitCode(64): consent for checksum A must not cover checksum B")
        } catch let error as ExitCode {
            #expect(error.rawValue == 64)
        }

        // The rejected run must not have overwritten the consented manifest,
        // and consent must remain untouched (re-consent is an explicit act).
        #expect(await service.manifest(id: "test-model")?.checksum == Self.checksumA)
        #expect(await service.isModelConsented(id: "test-model"))
    }

    @Test("mlx without any consent exits 64 and registers no phantom manifest")
    func askMlxWithoutConsentExits64() async throws {
        let (service, manifestsKey) = makeIsolatedManifestService()
        defer { UserDefaults.standard.removeObject(forKey: manifestsKey) }

        do {
            _ = try await AskCommand.makeInferenceProvider(
                provider: .mlx,
                model: "fresh-model",
                checksum: Self.checksumA,
                consentDownload: false,
                manifestService: service
            )
            Issue.record("Expected ExitCode(64) for mlx without consent")
        } catch let error as ExitCode {
            #expect(error.rawValue == 64)
        }

        #expect(await service.manifest(id: "fresh-model") == nil)
    }

    @Test("echo provider ignores --model/--checksum flags explicitly")
    func askWithEchoProviderIgnoresModelChecksumFlagsExplicitly() async throws {
        let (service, manifestsKey) = makeIsolatedManifestService()
        defer { UserDefaults.standard.removeObject(forKey: manifestsKey) }

        // Pins the documented no-op: echo never touches the manifest service,
        // regardless of what model/checksum flags were passed.
        let provider = try await AskCommand.makeInferenceProvider(
            provider: .echo,
            model: "ignored-model",
            checksum: "ignored-checksum",
            consentDownload: false,
            manifestService: service
        )
        #expect(provider is EchoInferenceProvider)
        #expect(await service.allManifests().isEmpty)

        let command = try AskCommand.parse([
            "--provider", "echo",
            "--model", "ignored-model",
            "--checksum", "ignored-checksum",
            "Should I buy this?",
        ])
        #expect(command.provider == .echo)
    }

    @Test("mlx rejects malformed checksums at the CLI boundary")
    func askMlxRejectsGarbageChecksum() throws {
        #expect(throws: (any Error).self) {
            try AskCommand.parse([
                "--provider", "mlx", "--model", "m", "--checksum", "zzz", "Q",
            ])
        }
        // Right alphabet, wrong length.
        #expect(throws: (any Error).self) {
            try AskCommand.parse([
                "--provider", "mlx", "--model", "m", "--checksum", "sha256:deadbeef", "Q",
            ])
        }
        let valid = try AskCommand.parse([
            "--provider", "mlx", "--model", "m",
            "--checksum", Self.checksumA,
            "Q",
        ])
        #expect(valid.checksum == Self.checksumA)
    }
}
