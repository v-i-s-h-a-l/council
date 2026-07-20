import CryptoKit
import XCTest
@testable import CouncilInference

final class ModelManifestServiceTests: XCTestCase {
    func testConsentGrantAndRevoke() async {
        let service = makeIsolatedManifestService(ids: ["model-a"])

        await service.grantConsent(id: "model-a")
        let consented = await service.isModelConsented(id: "model-a")
        XCTAssertTrue(consented)

        await service.revokeConsent(id: "model-a")
        let revoked = await service.isModelConsented(id: "model-a")
        XCTAssertFalse(revoked)
    }

    func testUnregisteredModelIsNotConsented() async {
        let service = ModelManifestService()
        let consented = await service.isModelConsented(id: "unknown")
        XCTAssertFalse(consented)
    }

    func testChecksumRegistrationAndValidation() async {
        let service = makeIsolatedManifestService()
        let manifest = ModelManifest(
            id: "model-a",
            checksum: "sha256:abc123",
            signature: "sig:xyz789"
        )

        await service.register(manifest)

        let checksum = await service.checksum(for: "model-a")
        XCTAssertEqual(checksum, "sha256:abc123")

        let signature = await service.signature(for: "model-a")
        XCTAssertEqual(signature, "sig:xyz789")

        let valid = await service.validateChecksum(
            id: "model-a",
            against: "sha256:abc123"
        )
        XCTAssertTrue(valid)

        let invalid = await service.validateChecksum(
            id: "model-a",
            against: "sha256:bad"
        )
        XCTAssertFalse(invalid)
    }

    func testManifestsPersistAcrossInstances() async {
        // Unique suite key isolates this test's keys inside .standard defaults, so no
        // non-Sendable UserDefaults instance has to cross into the actor.
        let suiteKey = "com.council.test.\(UUID().uuidString)"
        let manifestsKey = "\(suiteKey).manifests"
        defer { UserDefaults.standard.removeObject(forKey: manifestsKey) }

        let service = ModelManifestService(suiteKey: suiteKey)
        await service.register(ModelManifest(id: "model-a", checksum: "sha256:abc123"))

        // A fresh service instance over the same suite sees the registration.
        let reloaded = ModelManifestService(suiteKey: suiteKey)
        let manifest = await reloaded.manifest(id: "model-a")
        XCTAssertEqual(manifest?.checksum, "sha256:abc123")

        // Unregistering persists too.
        await reloaded.unregister(id: "model-a")
        let third = ModelManifestService(suiteKey: suiteKey)
        let remaining = await third.allManifests()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testMissingChecksumReturnsNil() async {
        let service = makeIsolatedManifestService()
        let checksum = await service.checksum(for: "not-registered")
        XCTAssertNil(checksum)
    }

    // MARK: - ModelManifestService adversarial

    /// Tampered persisted state: if the persisted manifests blob is garbage,
    /// the service must fail closed — the entire trust registry is dropped
    /// (checksums become nil, so downloads are blocked) rather than crashing
    /// or trusting partial data. Consent lives under separate keys and
    /// survives. This silent-drop behavior is the conscious contract of the
    /// `try?` in `ModelManifestService.init`.
    func testCorruptPersistedManifestDataFailsClosed() async {
        let suiteKey = "com.council.test.\(UUID().uuidString)"
        let manifestsKey = "\(suiteKey).manifests"
        let consentKey = "\(suiteKey).consent.model-a"
        defer {
            UserDefaults.standard.removeObject(forKey: manifestsKey)
            UserDefaults.standard.removeObject(forKey: consentKey)
        }

        // Persist garbage under the manifests key, plus a live consent flag.
        UserDefaults.standard.set(Data("not a manifest payload".utf8), forKey: manifestsKey)
        UserDefaults.standard.set(true, forKey: consentKey)

        let service = ModelManifestService(suiteKey: suiteKey)

        // Fail closed: no trust material is recovered from the corrupt blob.
        let checksum = await service.checksum(for: "model-a")
        XCTAssertNil(checksum)
        let manifests = await service.allManifests()
        XCTAssertTrue(manifests.isEmpty)

        // Consent is keyed separately and is not wiped by the corrupt blob.
        let consented = await service.isModelConsented(id: "model-a")
        XCTAssertTrue(consented)

        // The service stays usable: new registrations persist normally.
        await service.register(ModelManifest(id: "model-b", checksum: "sha256:def456"))
        let reloaded = ModelManifestService(suiteKey: suiteKey)
        let recovered = await reloaded.checksum(for: "model-b")
        XCTAssertEqual(recovered, "sha256:def456")
    }

    /// Pins the current overwrite contract of `register`: re-registering a
    /// model with a bare manifest silently strips previously registered
    /// checksum/signature trust material. Callers must always re-supply
    /// trust material; `unregister` is the only removal API. If this test
    /// starts failing because register learned to merge, that is a
    /// deliberate hardening change — update this pin.
    func testReRegisterWithNilChecksumStripsTrustMaterial() async {
        let service = makeIsolatedManifestService()
        await service.register(
            ModelManifest(id: "model-a", checksum: "sha256:abc123", signature: "sig:xyz789")
        )

        await service.register(ModelManifest(id: "model-a"))

        let checksum = await service.checksum(for: "model-a")
        XCTAssertNil(checksum, "register overwrites wholesale; a nil checksum erases the registered one")
        let signature = await service.signature(for: "model-a")
        XCTAssertNil(signature, "register overwrites wholesale; a nil signature erases the registered one")
        let manifest = await service.manifest(id: "model-a")
        XCTAssertNotNil(manifest)
    }

    /// Pins the documented last-writer-wins hazard from the type's header
    /// comment: concurrent instances over one suite hold stale snapshots and
    /// overwrite each other. The RuntimeAssembly contract is a single
    /// long-lived instance per suite.
    func testConcurrentInstancesOverwriteLastWriterWins() async {
        let suiteKey = "com.council.test.\(UUID().uuidString)"
        let manifestsKey = "\(suiteKey).manifests"
        defer { UserDefaults.standard.removeObject(forKey: manifestsKey) }

        let first = ModelManifestService(suiteKey: suiteKey)
        let second = ModelManifestService(suiteKey: suiteKey)

        // Both instances loaded an empty snapshot; each persists its own
        // snapshot plus its new entry, so the second write erases the first.
        await first.register(ModelManifest(id: "model-a", checksum: "sha256:aaa"))
        await second.register(ModelManifest(id: "model-b", checksum: "sha256:bbb"))

        let reloaded = ModelManifestService(suiteKey: suiteKey)
        let manifests = await reloaded.allManifests()
        XCTAssertEqual(manifests.map(\.id), ["model-b"])
        let lost = await reloaded.checksum(for: "model-a")
        XCTAssertNil(lost, "Last writer wins: the first instance's registration is silently lost")
    }

    // MARK: - ModelArtifactVerifier

    func testArtifactVerifierValidSingleChecksum() throws {
        let directory = try makeTempDirectory()
        let data = Data("hello model".utf8)
        let expected = "sha256:\(sha256Hex(data: data))"
        try data.write(to: directory.appendingPathComponent("model.safetensors"))

        let verifier = ModelArtifactVerifier()
        XCTAssertNoThrow(
            try verifier.verify(
                id: "model-a",
                at: directory,
                expectedChecksum: expected
            )
        )
    }

    func testArtifactVerifierInvalidChecksumMismatch() throws {
        let directory = try makeTempDirectory()
        let data = Data("hello model".utf8)
        try data.write(to: directory.appendingPathComponent("model.safetensors"))

        let verifier = ModelArtifactVerifier()

        XCTAssertThrowsError(
            try verifier.verify(
                id: "model-a",
                at: directory,
                expectedChecksum: "sha256:0000000000000000000000000000000000000000000000000000000000000000"
            )
        ) { error in
            guard case .checksumMismatch = error as? ModelArtifactVerifierError else {
                XCTFail("Expected checksum mismatch error, got \(error)")
                return
            }
        }
    }

    func testArtifactVerifierMissingArtifacts() throws {
        let directory = try makeTempDirectory()

        let verifier = ModelArtifactVerifier()

        XCTAssertThrowsError(
            try verifier.verify(
                id: "model-a",
                at: directory,
                expectedChecksum: "sha256:0000000000000000000000000000000000000000000000000000000000000000"
            )
        ) { error in
            guard case .missingArtifacts = error as? ModelArtifactVerifierError else {
                XCTFail("Expected missing artifacts error, got \(error)")
                return
            }
        }
    }

    func testArtifactVerifierUnsupportedChecksumFormat() throws {
        let directory = try makeTempDirectory()
        let data = Data("hello model".utf8)
        try data.write(to: directory.appendingPathComponent("model.safetensors"))

        let verifier = ModelArtifactVerifier()

        XCTAssertThrowsError(
            try verifier.verify(
                id: "model-a",
                at: directory,
                expectedChecksum: "md5:deadbeef"
            )
        ) { error in
            guard case .unsupportedChecksumFormat = error as? ModelArtifactVerifierError else {
                XCTFail("Expected unsupported checksum format error, got \(error)")
                return
            }
        }
    }

    func testArtifactVerifierShardedListChecksum() throws {
        let directory = try makeTempDirectory()
        let shardA = Data("shard-a".utf8)
        let shardB = Data("shard-b".utf8)
        try shardA.write(to: directory.appendingPathComponent("model-00001-of-00002.safetensors"))
        try shardB.write(to: directory.appendingPathComponent("model-00002-of-00002.safetensors"))

        let index = """
        {
            "weight_map": {
                "lm_head.weight": "model-00002-of-00002.safetensors",
                "embed_tokens.weight": "model-00001-of-00002.safetensors"
            }
        }
        """
        try index.data(using: .utf8)!.write(
            to: directory.appendingPathComponent("model.safetensors.index.json")
        )

        let digestA = sha256Hex(data: shardA)
        let digestB = sha256Hex(data: shardB)
        let expected = "sha256:\(digestA),\(digestB)"

        let verifier = ModelArtifactVerifier()
        XCTAssertNoThrow(
            try verifier.verify(
                id: "sharded-model",
                at: directory,
                expectedChecksum: expected
            )
        )
    }

    func testArtifactVerifierShardedCombinedChecksum() throws {
        let directory = try makeTempDirectory()
        let shardA = Data("shard-a".utf8)
        let shardB = Data("shard-b".utf8)
        try shardA.write(to: directory.appendingPathComponent("model-00001-of-00002.safetensors"))
        try shardB.write(to: directory.appendingPathComponent("model-00002-of-00002.safetensors"))

        let index = """
        {
            "weight_map": {
                "lm_head.weight": "model-00002-of-00002.safetensors",
                "embed_tokens.weight": "model-00001-of-00002.safetensors"
            }
        }
        """
        try index.data(using: .utf8)!.write(
            to: directory.appendingPathComponent("model.safetensors.index.json")
        )

        var hasher = SHA256()
        hasher.update(data: shardA)
        hasher.update(data: shardB)
        let expected = "sha256:\(hasher.finalize().hexString)"

        let verifier = ModelArtifactVerifier()
        XCTAssertNoThrow(
            try verifier.verify(
                id: "sharded-model",
                at: directory,
                expectedChecksum: expected
            )
        )
    }

    func testArtifactVerifierShardedMissingShard() throws {
        let directory = try makeTempDirectory()
        let shardA = Data("shard-a".utf8)
        try shardA.write(to: directory.appendingPathComponent("model-00001-of-00002.safetensors"))

        let index = """
        {
            "weight_map": {
                "lm_head.weight": "model-00002-of-00002.safetensors",
                "embed_tokens.weight": "model-00001-of-00002.safetensors"
            }
        }
        """
        try index.data(using: .utf8)!.write(
            to: directory.appendingPathComponent("model.safetensors.index.json")
        )

        let verifier = ModelArtifactVerifier()

        XCTAssertThrowsError(
            try verifier.verify(
                id: "sharded-model",
                at: directory,
                expectedChecksum: "sha256:0000000000000000000000000000000000000000000000000000000000000000"
            )
        ) { error in
            guard case .missingArtifacts = error as? ModelArtifactVerifierError else {
                XCTFail("Expected missing artifacts error, got \(error)")
                return
            }
        }
    }

    // MARK: - Helpers

    /// Manifest service over a unique suite so tests never touch the
    /// production `com.council.modelManifest` keys; keys are removed on
    /// teardown.
    private func makeIsolatedManifestService(ids: [String] = []) -> ModelManifestService {
        let suiteKey = "com.council.test.\(UUID().uuidString)"
        addTeardownBlock {
            UserDefaults.standard.removeObject(forKey: "\(suiteKey).manifests")
            for id in ids {
                UserDefaults.standard.removeObject(forKey: "\(suiteKey).consent.\(id)")
            }
        }
        return ModelManifestService(suiteKey: suiteKey)
    }

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func sha256Hex(data: Data) -> String {
        SHA256.hash(data: data).hexString
    }
}

extension SHA256Digest {
    fileprivate var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
