import CryptoKit
import XCTest
@testable import CouncilInference

final class ModelArtifactVerifierAdversarialTests: XCTestCase {
    /// Regression test: a truncated/garbage `model.safetensors.index.json`
    /// used to make `JSONDecoder.decode` throw a raw `DecodingError` out of
    /// `verify()` — an undocumented error type that `ModelContainerPool`
    /// did not map. It must now surface as `missingArtifacts`.
    func testCorruptIndexJSONThrowsVerifierError() throws {
        let directory = try makeTempDirectory()
        try Data("this is not json {".utf8).write(
            to: directory.appendingPathComponent("model.safetensors.index.json")
        )

        let verifier = ModelArtifactVerifier()
        XCTAssertThrowsError(
            try verifier.verify(
                id: "model-a",
                at: directory,
                expectedChecksum: "sha256:\(String(repeating: "0", count: 64))"
            )
        ) { error in
            XCTAssertFalse(error is DecodingError, "Raw DecodingError leaked out of verify()")
            guard case .missingArtifacts = error as? ModelArtifactVerifierError else {
                XCTFail("Expected missing artifacts error, got \(error)")
                return
            }
        }
    }

    /// Regression test: in the per-shard list-checksum path, a missing shard
    /// file used to leak a raw `CocoaError` from `Data(contentsOf:)`. It must
    /// surface as `missingArtifacts` like the combined-digest path already
    /// does.
    func testMissingShardInListChecksumThrowsVerifierError() throws {
        let directory = try makeTempDirectory()
        let shardA = Data("shard-a".utf8)
        try shardA.write(to: directory.appendingPathComponent("model-00001-of-00002.safetensors"))
        // The index references model-00002-of-00002.safetensors, which is absent.
        try writeIndex(
            [
                "embed_tokens.weight": "model-00001-of-00002.safetensors",
                "lm_head.weight": "model-00002-of-00002.safetensors",
            ],
            to: directory
        )

        let expected = "sha256:\(sha256Hex(data: shardA)),\(sha256Hex(data: Data("shard-b".utf8)))"
        let verifier = ModelArtifactVerifier()
        XCTAssertThrowsError(
            try verifier.verify(id: "sharded-model", at: directory, expectedChecksum: expected)
        ) { error in
            guard case .missingArtifacts = error as? ModelArtifactVerifierError else {
                XCTFail("Expected missing artifacts error, got \(error)")
                return
            }
        }
    }

    /// A syntactically valid index with an empty weight map yields no shard
    /// filenames and must fail closed.
    func testEmptyWeightMapThrowsMissingArtifacts() throws {
        let directory = try makeTempDirectory()
        try writeIndex([:], to: directory)

        let verifier = ModelArtifactVerifier()
        XCTAssertThrowsError(
            try verifier.verify(
                id: "model-a",
                at: directory,
                expectedChecksum: "sha256:\(String(repeating: "0", count: 64))"
            )
        ) { error in
            guard case .missingArtifacts = error as? ModelArtifactVerifierError else {
                XCTFail("Expected missing artifacts error, got \(error)")
                return
            }
        }
    }

    /// The traversal guard rejects shard names that could escape the model
    /// directory via path components. Each of these must fail closed.
    func testRejectsPathTraversalShardNames() throws {
        let maliciousNames = [
            "..",
            ".",
            "../evil.safetensors",
            "nested/model.safetensors",
            "evil\\..\\model.safetensors",
        ]

        for name in maliciousNames {
            let directory = try makeTempDirectory()
            try writeIndex(["layer.weight": name], to: directory)

            let verifier = ModelArtifactVerifier()
            XCTAssertThrowsError(
                try verifier.verify(
                    id: "model-a",
                    at: directory,
                    expectedChecksum: "sha256:\(String(repeating: "0", count: 64))"
                ),
                "Shard name '\(name)' should be rejected"
            ) { error in
                guard case .missingArtifacts = error as? ModelArtifactVerifierError else {
                    XCTFail("Expected missing artifacts error for '\(name)', got \(error)")
                    return
                }
            }
        }
    }

    /// Documents an accepted boundary of the traversal guard: it inspects
    /// shard *names* only, and `Data(contentsOf:)` follows symlinks, so a
    /// symlinked shard resolves outside the model directory. This behavior
    /// is load-bearing, not an oversight: swift-huggingface's HubCache
    /// stores snapshot entries as symlinks into a content-addressed blob
    /// store, so rejecting symlinks would break verification of every
    /// legitimately downloaded model. If this ever changes, the change must
    /// resolve links and confine them to the model directory rather than
    /// rejecting them outright.
    func testFollowsSymlinkedShard_DocumentedBehavior() throws {
        let directory = try makeTempDirectory()
        let outside = try makeTempDirectory()

        let shardBytes = Data("external shard bytes".utf8)
        let outsideFile = outside.appendingPathComponent("external.bin")
        try shardBytes.write(to: outsideFile)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("model-00001-of-00001.safetensors"),
            withDestinationURL: outsideFile
        )
        try writeIndex(["layer.weight": "model-00001-of-00001.safetensors"], to: directory)

        let verifier = ModelArtifactVerifier()
        XCTAssertNoThrow(
            try verifier.verify(
                id: "model-a",
                at: directory,
                expectedChecksum: "sha256:\(sha256Hex(data: shardBytes))"
            )
        )
    }

    /// List digests are matched positionally against sorted shard names, so
    /// a manifest carrying the same digests in swapped order must fail.
    func testShardedListChecksumSwappedOrderFails() throws {
        let directory = try makeTempDirectory()
        let shardA = Data("shard-a".utf8)
        let shardB = Data("shard-b".utf8)
        try shardA.write(to: directory.appendingPathComponent("model-00001-of-00002.safetensors"))
        try shardB.write(to: directory.appendingPathComponent("model-00002-of-00002.safetensors"))
        try writeIndex(
            [
                "embed_tokens.weight": "model-00001-of-00002.safetensors",
                "lm_head.weight": "model-00002-of-00002.safetensors",
            ],
            to: directory
        )

        // Sorted shard order is 00001, 00002; the list swaps the digests.
        let expected = "sha256:\(sha256Hex(data: shardB)),\(sha256Hex(data: shardA))"
        let verifier = ModelArtifactVerifier()
        XCTAssertThrowsError(
            try verifier.verify(id: "sharded-model", at: directory, expectedChecksum: expected)
        ) { error in
            guard case .checksumMismatch = error as? ModelArtifactVerifierError else {
                XCTFail("Expected checksum mismatch error, got \(error)")
                return
            }
        }
    }

    /// The count guard rejects manifests whose digest list does not match
    /// the number of shards — both fewer and more digests must fail.
    func testShardedListChecksumCountMismatchFails() throws {
        let directory = try makeTempDirectory()
        let shardA = Data("shard-a".utf8)
        let shardB = Data("shard-b".utf8)
        try shardA.write(to: directory.appendingPathComponent("model-00001-of-00002.safetensors"))
        try shardB.write(to: directory.appendingPathComponent("model-00002-of-00002.safetensors"))
        try writeIndex(
            [
                "embed_tokens.weight": "model-00001-of-00002.safetensors",
                "lm_head.weight": "model-00002-of-00002.safetensors",
            ],
            to: directory
        )

        let digestA = sha256Hex(data: shardA)
        let digestB = sha256Hex(data: shardB)
        let digestC = sha256Hex(data: Data("shard-c".utf8))
        // The trailing separator keeps the checksum on the list path while
        // providing only one digest for two shards.
        let fewerDigests = "sha256:\(digestA);"
        let moreDigests = "sha256:\(digestA),\(digestB),\(digestC)"

        let verifier = ModelArtifactVerifier()
        for expected in [fewerDigests, moreDigests] {
            XCTAssertThrowsError(
                try verifier.verify(id: "sharded-model", at: directory, expectedChecksum: expected),
                "Digest count mismatch should fail for \(expected)"
            ) { error in
                guard case .checksumMismatch = error as? ModelArtifactVerifierError else {
                    XCTFail("Expected checksum mismatch error, got \(error)")
                    return
                }
            }
        }
    }

    /// Pins the strict comparison contract of the single-file path: the
    /// digest comparison is case-sensitive and untrimmed (unlike the list
    /// path, which trims whitespace). Manifests must carry lowercase hex.
    func testSingleChecksumComparisonIsCaseSensitive_DocumentedContract() throws {
        let directory = try makeTempDirectory()
        let data = Data("hello model".utf8)
        try data.write(to: directory.appendingPathComponent("model.safetensors"))

        let uppercase = "sha256:" + sha256Hex(data: data).uppercased()
        let verifier = ModelArtifactVerifier()
        XCTAssertThrowsError(
            try verifier.verify(id: "model-a", at: directory, expectedChecksum: uppercase)
        ) { error in
            guard case .checksumMismatch = error as? ModelArtifactVerifierError else {
                XCTFail("Expected checksum mismatch error, got \(error)")
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

    private func writeIndex(_ weightMap: [String: String], to directory: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: ["weight_map": weightMap],
            options: [.sortedKeys]
        )
        try data.write(to: directory.appendingPathComponent("model.safetensors.index.json"))
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
