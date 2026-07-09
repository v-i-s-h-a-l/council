import CouncilCore
import Foundation

/// `ProfileVault` implementation that stores the profile as AES-256-GCM encrypted JSON.
public actor CryptoKitProfileVault: ProfileVault {
    public enum VaultError: Error {
        case missingApplicationSupportDirectory
    }

    private let keyManager: ProfileKeyManager
    private let fileURL: URL
    private let fileManager: FileManager
    private let writingOptions: Data.WritingOptions

    public init(
        keyManager: ProfileKeyManager = ProfileKeyManager(),
        directoryURL: URL? = nil,
        fileManager: FileManager = .default,
        writingOptions: Data.WritingOptions = .completeFileProtectionUnlessOpen
    ) throws {
        self.keyManager = keyManager
        self.fileManager = fileManager
        self.writingOptions = writingOptions

        if let directoryURL {
            self.fileURL = directoryURL.appendingPathComponent("vault.enc")
        } else {
            guard let appSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw VaultError.missingApplicationSupportDirectory
            }
            let profileDirectory = appSupport.appendingPathComponent("Profile", isDirectory: true)
            self.fileURL = profileDirectory.appendingPathComponent("vault.enc")
        }
    }

    /// Testable initializer that accepts a custom file URL and writing options.
    init(
        keyManager: ProfileKeyManager,
        fileURL: URL,
        fileManager: FileManager = .default,
        writingOptions: Data.WritingOptions = .completeFileProtectionUnlessOpen
    ) {
        self.keyManager = keyManager
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.writingOptions = writingOptions
    }

    public var isDeviceBound: Bool {
        get async { keyManager.isDeviceBound }
    }

    public func load() async throws -> UserProfile {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return UserProfile()
        }
        let encrypted = try Data(contentsOf: fileURL)
        let key = try await keyManager.unwrapKey()
        let plaintext = try FieldEncryption.decrypt(ciphertext: encrypted, key: key)
        return try JSONDecoder().decode(UserProfile.self, from: plaintext)
    }

    public func save(_ profile: UserProfile) async throws {
        let plaintext = try JSONEncoder().encode(profile)
        let key = try await existingOrGeneratedKey()
        let encrypted = try FieldEncryption.encrypt(plaintext: plaintext, key: key)

        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        do {
            try encrypted.write(to: fileURL, options: writingOptions)
        } catch {
            // Unsigned CLI binaries and test runners may lack the entitlements to
            // apply complete file protection on some filesystems. Fall back to a
            // plain write so the profile is still persisted.
            try encrypted.write(to: fileURL)
        }

        // Defense-in-depth: ensure the encrypted vault is readable only by the owner.
        try fileManager.setAttributes(
            [FileAttributeKey.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )

        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var directoryURL = directory
        try directoryURL.setResourceValues(resourceValues)
    }

    public func exportEncryptedBlob() async throws -> Data {
        if !fileManager.fileExists(atPath: fileURL.path) {
            // Export an encrypted empty profile if no vault exists yet.
            try await save(UserProfile())
        }
        return try Data(contentsOf: fileURL)
    }

    public func replaceFromEncryptedBlob(_ data: Data) async throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try data.write(to: fileURL, options: writingOptions)
    }

    private func existingOrGeneratedKey() async throws -> Data {
        do {
            return try await keyManager.unwrapKey()
        } catch ProfileKeyManager.ProfileKeyError.missingKey {
            return try await keyManager.generateKey()
        }
    }
}
