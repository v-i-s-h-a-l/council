import CouncilCore
import CouncilInference
import CouncilMemory
import CryptoKit
import Foundation

/// UI-agnostic factory that wires together the Council runtime services.
///
/// `RuntimeAssembly` is used by both `CouncilApp.CompositionRoot` and the
/// `CouncilCLI` executable so that dependency wiring is not duplicated between
/// the GUI and command-line entry points.
public actor RuntimeAssembly {
    public let profileKeyManager: ProfileKeyManager
    internal let profileKey: Data
    public let profileVault: CryptoKitProfileVault
    public let profileService: ProfileService
    public let memoryStore: GRDBMemoryStore
    public let auditLog: GRDBAuditLog
    public let memoryService: MemoryService
    public let manifestService: ModelManifestService

    /// Creates an assembly rooted at the given directory.
    ///
    /// - Parameters:
    ///   - rootDirectory: Directory that will contain the encrypted profile vault,
    ///     memory database, and audit log. If `nil`, the platform Application
    ///     Support directory is used.
    ///   - useSecureEnclave: Whether to bind the profile key to the Secure Enclave.
    ///     Defaults to `true`. Set to `false` for unsigned command-line binaries
    ///     that may not have the entitlements required for SEP keychain access.
    public init(
        rootDirectory: URL? = nil,
        useSecureEnclave: Bool = true
    ) async throws {
        let root: URL
        if let rootDirectory {
            root = rootDirectory
        } else {
            guard let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw AssemblyError.missingApplicationSupportDirectory
            }
            root = appSupport.appendingPathComponent("Council", isDirectory: true)
        }

        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [FileAttributeKey.posixPermissions: 0o700]
        )

        let keyManager = ProfileKeyManager(
            useSecureEnclave: useSecureEnclave,
            keyFileURL: useSecureEnclave ? nil : root.appendingPathComponent("profile.key")
        )
        let rawKey: Data
        do {
            rawKey = try await keyManager.unwrapKey()
        } catch {
            rawKey = try await keyManager.generateKey()
        }

        self.profileKeyManager = keyManager
        self.profileKey = rawKey
        self.profileVault = try CryptoKitProfileVault(
            keyManager: keyManager,
            directoryURL: root,
            writingOptions: useSecureEnclave ? .completeFileProtectionUnlessOpen : []
        )
        self.profileService = ProfileService(vault: profileVault)

        let dbPath = root.appendingPathComponent("memory.sqlite").path
        let salt = try Self.resolveOrCreateSalt(
            at: root.appendingPathComponent("salt.bin"),
            useCompleteProtection: useSecureEnclave
        )

        // Migrate legacy plaintext database to SQLCipher if needed.
        if SQLCipherMigration.detectLegacyDatabase(at: dbPath) {
            _ = try SQLCipherMigration.migrate(
                legacyPath: dbPath,
                profileKey: rawKey,
                salt: salt
            )
        }

        self.memoryStore = try await GRDBMemoryStore.make(
            path: dbPath,
            profileKey: rawKey,
            salt: salt
        )
        self.auditLog = try await GRDBAuditLog.make(path: dbPath + ".audit", profileKey: rawKey)
        self.memoryService = MemoryService(store: memoryStore, auditLog: auditLog)
        self.manifestService = ModelManifestService()
    }

    // MARK: - Salt management

    /// Loads an existing 16-byte salt from `saltURL` or generates and persists one.
    ///
    /// Keeping salt resolution inside `RuntimeAssembly` lets the CLI run without
    /// blocking on keychain authorization dialogs that can hang in unsigned
    /// command-line binaries.
    private static func resolveOrCreateSalt(
        at saltURL: URL,
        useCompleteProtection: Bool
    ) throws -> Data {
        if FileManager.default.fileExists(atPath: saltURL.path),
           let salt = try? Data(contentsOf: saltURL),
           salt.count == 16 {
            return salt
        }

        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw SaltError.generationFailed
        }

        if useCompleteProtection {
            do {
                try salt.write(to: saltURL, options: .completeFileProtectionUnlessOpen)
            } catch {
                // Fall back to an unprotected write so the salt is still persisted.
                try salt.write(to: saltURL)
            }
        } else {
            // Unsigned CLI binaries and test runners may lack the entitlements to
            // apply complete file protection, so avoid it entirely in CLI mode.
            try salt.write(to: saltURL)
        }
        return salt
    }

    private enum SaltError: Error {
        case generationFailed
    }

    public enum AssemblyError: Error {
        case missingApplicationSupportDirectory
    }

    /// Builds a `DeliberationService` for the Purchase Council using the given
    /// inference provider.
    ///
    /// - Parameters:
    ///   - provider: The inference provider to use for agent calls.
    ///   - options: Inference options.
    ///   - persist: Whether to persist episodic gists and audit entries. Defaults
    ///     to `true`; pass `false` to run without writing to memory or audit stores.
    public func deliberationService(
        provider: any InferenceProvider,
        options: InferenceOptions = InferenceOptions(),
        persist: Bool = true
    ) async throws -> DeliberationService {
        let purposes: [AccessPurpose] = [.purchaseDeliberation]
        let decision = try await profileService.profileAccessDecision(purposes: purposes)
        let auditSink = persist ? self.memoryService : nil
        if let auditSink {
            // Record every per-item denial so users can verify what was excluded.
            for denial in decision.denials {
                try? await auditSink.appendAuditEntry(
                    category: .memoryAccess,
                    payload: [
                        "purpose": denial.purposes.map(\.rawValue).sorted().joined(separator: ","),
                        "dataElementType": denial.elementType,
                        "decision": "denied",
                        "elementID": denial.elementID.uuidString,
                    ]
                )
            }
        }

        return DeliberationService(
            provider: provider,
            council: PurchaseCouncil(),
            validators: [ConstitutionalPerspectiveValidator()],
            context: decision.context,
            options: options,
            memoryService: auditSink
        )
    }
}
