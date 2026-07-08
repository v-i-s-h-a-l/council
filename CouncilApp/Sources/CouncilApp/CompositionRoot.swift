import CouncilAgents
import CouncilCore
import CouncilInference
import CouncilMemory
import CouncilUI
import Foundation

/// Wires together the runtime services and the view models used by the app.
@MainActor
final class CompositionRoot {
    let assembly: RuntimeAssembly
    let inferenceProvider: MLXInferenceProvider
    let purchaseCouncil: PurchaseCouncil
    let validator: ConstitutionalPerspectiveValidator
    let deliberationService: DeliberationService

    let sessionViewModel: SessionViewModel
    let memoryInspectorViewModel: MemoryInspectorViewModel
    let modelSettingsViewModel: ModelSettingsViewModel

    init() async throws {
        self.assembly = try await RuntimeAssembly()

        self.purchaseCouncil = PurchaseCouncil()
        self.validator = ConstitutionalPerspectiveValidator()

        let manifestService = await assembly.manifestService
        let modelConfig = MLXModelConfiguration.default
        let defaultModelID = modelConfig.modelConfiguration.name

        #if os(iOS)
        let defaultChecksum = "sha256:f212cf6fb9923281a09c135e05d43a052ee5ef7121f5b1dc0b0fb2de80f97cfd"
        #elseif os(macOS)
        let defaultChecksum = "sha256:86110f368236b53cf4c2336f991a85703b17bcc60bb75f292b4002ec0219f071"
        #else
        let defaultChecksum = "sha256:f212cf6fb9923281a09c135e05d43a052ee5ef7121f5b1dc0b0fb2de80f97cfd"
        #endif

        await manifestService.register(
            ModelManifest(
                id: defaultModelID,
                checksum: defaultChecksum
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

        self.deliberationService = try await assembly.deliberationService(
            provider: inferenceProvider,
            options: InferenceOptions()
        )

        self.sessionViewModel = SessionViewModel(service: deliberationService)
        self.memoryInspectorViewModel = MemoryInspectorViewModel(memoryService: await assembly.memoryService)
        self.modelSettingsViewModel = ModelSettingsViewModel(
            activeRoute: .onDeviceApple,
            modelIdentifier: modelConfig.modelConfiguration.name
        )
    }
}
