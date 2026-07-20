@testable import CouncilCLI
import CouncilInference
import Foundation
import Testing

/// Adversarial tests for checksum handling and consent revocation in
/// `ModelCommand.RegisterCommand`.
@Suite("ModelCommand adversarial")
struct ModelCommandAdversarialTests {

    private static let checksumA = String(repeating: "a1", count: 32)
    private static let checksumB = String(repeating: "b2", count: 32)

    private func makeIsolatedManifestService() -> (service: ModelManifestService, manifestsKey: String) {
        // .standard defaults with a unique suite key: no non-Sendable UserDefaults
        // crosses into the actor, and tests running in parallel never share state.
        let suiteKey = "com.council.test.\(UUID().uuidString)"
        return (ModelManifestService(suiteKey: suiteKey), "\(suiteKey).manifests")
    }

    @Test("re-registering with a different checksum revokes download consent")
    func modelRegisterChecksumChangeRevokesConsent() async throws {
        let (service, manifestsKey) = makeIsolatedManifestService()
        defer { UserDefaults.standard.removeObject(forKey: manifestsKey) }

        await ModelCommand.RegisterCommand.register(
            id: "model", checksum: Self.checksumA, manifestService: service
        )
        await service.grantConsent(id: "model")
        #expect(await service.isModelConsented(id: "model"))

        // Swapping the artifacts under the same id must drop the old consent.
        await ModelCommand.RegisterCommand.register(
            id: "model", checksum: Self.checksumB, manifestService: service
        )
        #expect(await service.manifest(id: "model")?.checksum == Self.checksumB)
        #expect(await service.isModelConsented(id: "model") == false)

        // Re-registering the SAME checksum keeps the (re-granted) consent.
        await service.grantConsent(id: "model")
        await ModelCommand.RegisterCommand.register(
            id: "model", checksum: Self.checksumB, manifestService: service
        )
        #expect(await service.isModelConsented(id: "model"))
    }

    @Test("model register rejects garbage checksums")
    func modelRegisterRejectsGarbageChecksum() throws {
        // Non-hex.
        #expect(throws: (any Error).self) {
            try ModelCommand.RegisterCommand.parse(["m", "--checksum", "zzz"])
        }
        // Valid hex but far too short for SHA-256.
        #expect(throws: (any Error).self) {
            try ModelCommand.RegisterCommand.parse(["m", "--checksum", "sha256:deadbeef"])
        }
        // One character short.
        #expect(throws: (any Error).self) {
            try ModelCommand.RegisterCommand.parse([
                "m", "--checksum", String(repeating: "a", count: 63),
            ])
        }
        // Right length, non-hex characters.
        #expect(throws: (any Error).self) {
            try ModelCommand.RegisterCommand.parse([
                "m", "--checksum", String(repeating: "g", count: 64),
            ])
        }

        let bare = try ModelCommand.RegisterCommand.parse(["m", "--checksum", Self.checksumA])
        #expect(bare.checksum == Self.checksumA)
        let prefixed = try ModelCommand.RegisterCommand.parse([
            "m", "--checksum", "sha256:\(Self.checksumA)",
        ])
        #expect(prefixed.checksum == "sha256:\(Self.checksumA)")
    }

    @Test("SHA-256 checksum shape validation")
    func checksumShapeValidation() {
        #expect(isValidSHA256Checksum(String(repeating: "0123456789abcdef", count: 4)))
        #expect(isValidSHA256Checksum("sha256:" + String(repeating: "AB", count: 32)))
        #expect(!isValidSHA256Checksum(""))
        #expect(!isValidSHA256Checksum("zzz"))
        #expect(!isValidSHA256Checksum("sha256:"))
        #expect(!isValidSHA256Checksum(String(repeating: "a", count: 63)))
        #expect(!isValidSHA256Checksum(String(repeating: "a", count: 65)))
    }

    @Test("Equivalent checksum spellings normalize equal")
    func checksumDigestNormalization() {
        let bare = String(repeating: "ab", count: 32)
        #expect(normalizedSHA256Digest("sha256:\(bare)") == bare)
        #expect(normalizedSHA256Digest(bare) == bare)
        #expect(normalizedSHA256Digest("SHA256:\(bare.uppercased())") == bare)
        // Regression: prefixed/bare/uppercase spellings of the same digest used
        // to compare unequal and spuriously revoke consent.
        #expect(normalizedSHA256Digest("sha256:\(bare)") == normalizedSHA256Digest(bare))
    }
}
