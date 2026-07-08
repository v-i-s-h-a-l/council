import Foundation

/// Manifest entry for a downloadable model.
public struct ModelManifest: Sendable, Codable, Identifiable {
    public let id: String
    public let checksum: String?
    public let signature: String?

    public init(id: String, checksum: String? = nil, signature: String? = nil) {
        self.id = id
        self.checksum = checksum
        self.signature = signature
    }
}

/// Service that tracks available models, their checksums/signatures, and the
/// user's download consent.
///
/// Consent is persisted in `UserDefaults` under a dedicated suite key prefix so
/// it is isolated from other app settings.
public actor ModelManifestService {
    private let defaults: UserDefaults
    private let suiteKey: String
    private let consentKeyPrefix: String
    private var manifests: [String: ModelManifest] = [:]

    public init(
        defaults: UserDefaults = .standard,
        suiteKey: String = "com.council.modelManifest"
    ) {
        self.defaults = defaults
        self.suiteKey = suiteKey
        self.consentKeyPrefix = "\(suiteKey).consent."
    }

    /// Registers a model manifest.
    public func register(_ manifest: ModelManifest) {
        manifests[manifest.id] = manifest
    }

    /// Returns whether the user has granted download consent for a model.
    public func isModelConsented(id: String) -> Bool {
        defaults.bool(forKey: consentKeyPrefix + id)
    }

    /// Grants download consent for a model.
    public func grantConsent(id: String) {
        defaults.set(true, forKey: consentKeyPrefix + id)
    }

    /// Revokes download consent for a model.
    public func revokeConsent(id: String) {
        defaults.set(false, forKey: consentKeyPrefix + id)
    }

    /// Returns the registered checksum for a model identifier, if any.
    public func checksum(for id: String) -> String? {
        manifests[id]?.checksum
    }

    /// Returns the registered signature for a model identifier, if any.
    public func signature(for id: String) -> String? {
        manifests[id]?.signature
    }

    /// Validates a candidate checksum against the registered manifest.
    public func validateChecksum(id: String, against value: String) -> Bool {
        checksum(for: id) == value
    }
}
