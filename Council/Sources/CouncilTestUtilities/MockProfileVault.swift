import CouncilCore
import Foundation

/// In-memory actor conforming to `ProfileVault` for testing.
public actor MockProfileVault: ProfileVault {
    public var profile: UserProfile

    public init(profile: UserProfile = UserProfile()) {
        self.profile = profile
    }

    public func load() async throws -> UserProfile {
        profile
    }

    public func save(_ profile: UserProfile) async throws {
        self.profile = profile
    }

    public func exportEncryptedBlob() async throws -> Data {
        let encoder = JSONEncoder()
        return try encoder.encode(profile)
    }

    public func replaceFromEncryptedBlob(_ data: Data) async throws {
        let decoder = JSONDecoder()
        self.profile = try decoder.decode(UserProfile.self, from: data)
    }
}
