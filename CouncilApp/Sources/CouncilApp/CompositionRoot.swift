import CouncilAgents
import CouncilCore
import CouncilInference
import CouncilMemory
import CouncilUI
import Foundation

/// Wires together the runtime services and the view models used by the app.
@MainActor
final class CompositionRoot {
    let inferenceProvider: MLXInferenceProvider
    let purchaseCouncil: PurchaseCouncil
    let profileVault: CryptoKitProfileVault
    let memoryStore: GRDBMemoryStore
    let auditLog: GRDBAuditLog
    let profileService: ProfileService
    let memoryService: MemoryService
    let deliberationService: DeliberationService
    let validator: ConstitutionalPerspectiveValidator

    let sessionViewModel: SessionViewModel
    let memoryInspectorViewModel: MemoryInspectorViewModel
    let modelSettingsViewModel: ModelSettingsViewModel

    init() async throws {
        // Share the profile key across the vault, memory store, and audit log.
        let keyManager = ProfileKeyManager()
        let rawKey: Data
        do {
            rawKey = try await keyManager.unwrapKey()
        } catch {
            rawKey = try await keyManager.generateKey()
        }

        self.profileVault = try CryptoKitProfileVault()
        self.purchaseCouncil = PurchaseCouncil()
        self.validator = ConstitutionalPerspectiveValidator()

        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let councilDir = appSupport.appendingPathComponent("Council", isDirectory: true)
        let dbPath = councilDir.appendingPathComponent("memory.sqlite").path

        self.memoryStore = try await GRDBMemoryStore.make(path: dbPath, profileKey: rawKey)
        self.auditLog = try await GRDBAuditLog.make(path: dbPath + ".audit", profileKey: rawKey)

        self.profileService = ProfileService(vault: profileVault)
        self.memoryService = MemoryService(store: memoryStore, auditLog: auditLog)

        let profile = try await profileService.load()
        let context = RoutableProfileContext(profile: profile)

        let manifestService = ModelManifestService()
        let modelConfig = MLXModelConfiguration.default
        let defaultModelID = modelConfig.modelConfiguration.name
        await manifestService.register(
            ModelManifest(
                id: defaultModelID,
                // Placeholder checksum for the default model. Replace with the
                // verified SHA-256 digest of the downloaded model artifacts
                // before shipping to production.
                checksum: "sha256:PLACEHOLDER_VERIFY_BEFORE_SHIP"
            )
        )
        await manifestService.grantConsent(id: defaultModelID)

        let pool = ModelContainerPool(
            modelConfiguration: modelConfig,
            manifestService: manifestService
        )
        self.inferenceProvider = MLXInferenceProvider(
            pool: pool,
            modelConfiguration: modelConfig,
            manifestService: manifestService
        )

        self.deliberationService = DeliberationService(
            provider: inferenceProvider,
            council: purchaseCouncil,
            validators: [validator],
            context: context,
            options: InferenceOptions()
        )

        self.sessionViewModel = SessionViewModel(service: deliberationService)
        self.memoryInspectorViewModel = MemoryInspectorViewModel(memoryService: memoryService)
        self.modelSettingsViewModel = ModelSettingsViewModel(
            activeRoute: .onDeviceApple,
            modelIdentifier: modelConfig.modelConfiguration.name
        )
    }
}
