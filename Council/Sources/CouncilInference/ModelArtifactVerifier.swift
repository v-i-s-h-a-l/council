import CryptoKit
import Foundation

/// Errors that can occur when verifying model artifact checksums.
public enum ModelArtifactVerifierError: Error, Sendable {
    case unsupportedChecksumFormat(id: String, checksum: String)
    case missingArtifacts(id: String)
    case checksumMismatch(id: String, expected: String, actual: String)
}

/// Verifies SHA-256 checksums for downloaded MLX model artifacts.
public struct ModelArtifactVerifier: Sendable {
    private static let prefix = "sha256:"

    public init() {}

    /// Verifies the artifacts in `directory` against `expectedChecksum`.
    ///
    /// The expected checksum must use the format `sha256:<hex>`.
    ///
    /// - If `model.safetensors` exists, its digest is compared to the expected value.
    /// - If only `model.safetensors.index.json` exists, the shard filenames are parsed,
    ///   sorted, and verified. The expected checksum may be a comma/semicolon-separated
    ///   list of per-shard digests (in sorted shard order), or a single combined digest
    ///   produced by hashing the concatenated shard bytes in sorted order.
    public func verify(
        id: String,
        at directory: URL,
        expectedChecksum: String
    ) throws {
        guard expectedChecksum.hasPrefix(Self.prefix) else {
            throw ModelArtifactVerifierError.unsupportedChecksumFormat(
                id: id,
                checksum: expectedChecksum
            )
        }

        let expectedHex = String(expectedChecksum.dropFirst(Self.prefix.count))

        let safetensors = directory.appendingPathComponent("model.safetensors")
        if FileManager.default.fileExists(atPath: safetensors.path) {
            let actual = try sha256Hex(for: safetensors)
            guard actual == expectedHex else {
                throw mismatch(id: id, expected: expectedChecksum, actualHex: actual)
            }
            return
        }

        let index = directory.appendingPathComponent("model.safetensors.index.json")
        guard FileManager.default.fileExists(atPath: index.path) else {
            throw ModelArtifactVerifierError.missingArtifacts(id: id)
        }

        let filenames = try shardFilenames(from: index, id: id)
        guard !filenames.isEmpty else {
            throw ModelArtifactVerifierError.missingArtifacts(id: id)
        }

        if expectedHex.contains(",") || expectedHex.contains(";") {
            let actuals = try filenames.map { try sha256Hex(for: directory.appendingPathComponent($0)) }
            let expectedParts = expectedHex
                .components(separatedBy: CharacterSet(charactersIn: ",;"))
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            guard expectedParts.count == actuals.count else {
                throw mismatch(
                    id: id,
                    expected: expectedChecksum,
                    actualHex: actuals.joined(separator: ",")
                )
            }

            for (index, actual) in actuals.enumerated() {
                guard actual == expectedParts[index] else {
                    throw mismatch(
                        id: id,
                        expected: expectedChecksum,
                        actualHex: actuals.joined(separator: ",")
                    )
                }
            }
        } else {
            var hasher = SHA256()
            for filename in filenames {
                let fileURL = directory.appendingPathComponent(filename)
                guard FileManager.default.fileExists(atPath: fileURL.path) else {
                    throw ModelArtifactVerifierError.missingArtifacts(id: id)
                }
                let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
                hasher.update(data: data)
            }
            let actual = hasher.finalize().hexString
            guard actual == expectedHex else {
                throw mismatch(id: id, expected: expectedChecksum, actualHex: actual)
            }
        }
    }

    private func shardFilenames(from indexURL: URL, id: String) throws -> [String] {
        let data = try Data(contentsOf: indexURL)
        let index = try JSONDecoder().decode(SafetensorsIndex.self, from: data)
        let filenames = Array(Set(index.weightMap.values)).sorted()
        // Reject paths that try to escape the model directory.
        for filename in filenames {
            guard !filename.contains("/"), !filename.contains("\\"), filename != "..", filename != "." else {
                throw ModelArtifactVerifierError.missingArtifacts(id: id)
            }
        }
        return filenames
    }

    private func sha256Hex(for url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).hexString
    }

    private func mismatch(id: String, expected: String, actualHex: String) -> ModelArtifactVerifierError {
        .checksumMismatch(
            id: id,
            expected: expected,
            actual: Self.prefix + actualHex
        )
    }
}

private struct SafetensorsIndex: Decodable {
    private enum CodingKeys: String, CodingKey {
        case weightMap = "weight_map"
    }

    let weightMap: [String: String]
}

extension SHA256Digest {
    fileprivate var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
