import CouncilCore
import Foundation

/// Actor-isolated service exposing profile persistence operations.
public actor ProfileService {
    private let vault: CryptoKitProfileVault

    public init(vault: CryptoKitProfileVault) {
        self.vault = vault
    }

    /// Whether the underlying vault is bound to the Secure Enclave.
    public var isDeviceBound: Bool {
        get async { await vault.isDeviceBound }
    }

    public func load() async throws -> UserProfile {
        try await vault.load()
    }

    public func save(_ profile: UserProfile) async throws {
        try await vault.save(profile)
    }

    public func exportEncryptedBlob() async throws -> Data {
        try await vault.exportEncryptedBlob()
    }
}
