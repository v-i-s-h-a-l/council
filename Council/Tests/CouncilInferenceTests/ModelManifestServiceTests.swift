import CryptoKit
import XCTest
@testable import CouncilInference

final class ModelManifestServiceTests: XCTestCase {
    func testConsentGrantAndRevoke() async {
        let service = ModelManifestService()

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
        let service = ModelManifestService()
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

    func testMissingChecksumReturnsNil() async {
        let service = ModelManifestService()
        let checksum = await service.checksum(for: "not-registered")
        XCTAssertNil(checksum)
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
