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

    @Test("Profile management through RuntimeAssembly")
    func profileManagement() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("council-cli-integration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let assembly = try await RuntimeAssembly(
            rootDirectory: root,
            useSecureEnclave: false
        )

        let value = try await assembly.profileService.addValue("Be mindful")
        let goal = try await assembly.profileService.addGoal("Travel", timeframe: "2027")
        let boundary = try await assembly.profileService.addBoundary("No impulse buys")

        var profile = try await assembly.profileService.load()
        #expect(profile.values.count == 1)
        #expect(profile.goals.count == 1)
        #expect(profile.boundaries.count == 1)

        try await assembly.profileService.removeValue(id: value.id)
        try await assembly.profileService.removeGoal(id: goal.id)
        try await assembly.profileService.removeBoundary(id: boundary.id)

        profile = try await assembly.profileService.load()
        #expect(profile.values.isEmpty)
        #expect(profile.goals.isEmpty)
        #expect(profile.boundaries.isEmpty)
    }

    @Test("Memory management through RuntimeAssembly")
    func memoryManagement() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("council-cli-integration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let assembly = try await RuntimeAssembly(
            rootDirectory: root,
            useSecureEnclave: false
        )

        let sessionID = UUID()
        try await assembly.memoryService.recordEpisode(
            sessionID: sessionID,
            question: "Bike or car?",
            perspective: Perspective(summary: "Bike.")
        )

        let fact = try await assembly.memoryService.addFact(
            subject: "user",
            predicate: "budget",
            object: "500"
        )

        let episodes = try await assembly.memoryService.searchEpisodes(query: "Bike", limit: 10)
        #expect(episodes.count == 1)

        let facts = try await assembly.memoryService.facts(subject: "user")
        #expect(facts.count == 1)
        #expect(facts.first?.id == fact.id)
    }

    @Test("Audit verification through RuntimeAssembly")
    func auditVerification() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("council-cli-integration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let assembly = try await RuntimeAssembly(
            rootDirectory: root,
            useSecureEnclave: false
        )

        try await assembly.memoryService.appendAuditEntry(
            category: .sessionStarted,
            payload: ["question": "test"]
        )

        let entries = try await assembly.memoryService.auditLog.entries(
            since: nil,
            limit: nil,
            includePayloads: false
        )
        #expect(entries.count == 1)
        #expect(entries.first?.payload.isEmpty == true)

        #expect(try await assembly.memoryService.verifyAuditChain())
    }

    @Test("Profile directory and key file are hardened")
    func profileDirectoryPermissions() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("council-cli-integration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await RuntimeAssembly(
            rootDirectory: root,
            useSecureEnclave: false
        )

        let dirAttributes = try FileManager.default.attributesOfItem(atPath: root.path)
        let dirPermissions = dirAttributes[.posixPermissions] as? NSNumber
        #expect(dirPermissions?.int16Value == 0o700)

        let keyAttributes = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent("profile.key").path
        )
        let keyPermissions = keyAttributes[.posixPermissions] as? NSNumber
        #expect(keyPermissions?.int16Value == 0o600)
    }

    @Test("RoutableProfileContext excludes confidential containers")
    func profileRedaction() async throws {
        let profile = UserProfile(
            values: [ValueStatement(text: "Value")],
            financialHistory: ClientConfidentialContainer(items: ["salary"]),
            journalExcerpts: ClientConfidentialContainer(items: ["diary"])
        )
        let context = RoutableProfileContext(profile: profile)
        #expect(context.values.count == 1)
        // RoutableProfileContext intentionally omits financialHistory and journalExcerpts.
    }
}
