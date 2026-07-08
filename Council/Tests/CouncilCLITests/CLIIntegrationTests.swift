import CouncilAgents
import CouncilCore
import CouncilInference
import Foundation
import Testing

@Suite("CLIIntegration")
struct CLIIntegrationTests {
    @Test("RuntimeAssembly initializes with file-based key")
    func assemblyInit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("council-cli-integration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let assembly = try await RuntimeAssembly(
            rootDirectory: root,
            useSecureEnclave: false
        )
        let profile = try await assembly.profileService.load()
        #expect(profile.values.isEmpty)
    }

    @Test("Echo deliberation completes and persists")
    func echoDeliberation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("council-cli-integration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let assembly = try await RuntimeAssembly(
            rootDirectory: root,
            useSecureEnclave: false
        )
        let service = try await assembly.deliberationService(provider: EchoInferenceProvider())

        let stream = await service.stateUpdates()
        await service.startSession(question: "Should I test?")

        var gotPerspective = false
        for await state in stream {
            if state.stage == .presentation {
                gotPerspective = true
                #expect(state.perspective != nil)
            }
        }
        #expect(gotPerspective)

        let episodes = try await assembly.memoryService.recentEpisodes()
        #expect(episodes.count == 1)
        #expect(episodes.first?.question == "Should I test?")
    }

    @Test("Echo deliberation with persist=false skips persistence")
    func echoDeliberationNoPersist() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("council-cli-integration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let assembly = try await RuntimeAssembly(
            rootDirectory: root,
            useSecureEnclave: false
        )
        let service = try await assembly.deliberationService(
            provider: EchoInferenceProvider(),
            persist: false
        )

        let stream = await service.stateUpdates()
        await service.startSession(question: "Should I skip persistence?")

        var gotPerspective = false
        for await state in stream {
            if state.stage == .presentation {
                gotPerspective = true
            }
        }
        #expect(gotPerspective)

        let episodes = try await assembly.memoryService.recentEpisodes()
        #expect(episodes.isEmpty)
    }
}
