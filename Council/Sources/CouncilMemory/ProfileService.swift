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

    // MARK: - Value management

    @discardableResult
    public func addValue(_ text: String) async throws -> ValueStatement {
        var profile = try await load()
        let statement = ValueStatement(text: text)
        profile.values.append(statement)
        try await save(profile)
        return statement
    }

    public func removeValue(id: UUID) async throws {
        var profile = try await load()
        profile.values.removeAll { $0.id == id }
        try await save(profile)
    }

    // MARK: - Goal management

    @discardableResult
    public func addGoal(_ text: String, timeframe: String? = nil) async throws -> Goal {
        var profile = try await load()
        let goal = Goal(text: text, timeframe: timeframe)
        profile.goals.append(goal)
        try await save(profile)
        return goal
    }

    public func removeGoal(id: UUID) async throws {
        var profile = try await load()
        profile.goals.removeAll { $0.id == id }
        try await save(profile)
    }

    // MARK: - Boundary management

    @discardableResult
    public func addBoundary(_ text: String) async throws -> Boundary {
        var profile = try await load()
        let boundary = Boundary(text: text)
        profile.boundaries.append(boundary)
        try await save(profile)
        return boundary
    }

    public func removeBoundary(id: UUID) async throws {
        var profile = try await load()
        profile.boundaries.removeAll { $0.id == id }
        try await save(profile)
    }
}
