import CouncilAgents
@testable import CouncilCLI
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

    @Test("Journal management through RuntimeAssembly")
    func journalManagement() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("council-cli-integration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let assembly = try await RuntimeAssembly(
            rootDirectory: root,
            useSecureEnclave: false
        )

        let entry = try await assembly.profileService.addJournalEntry(
            "Reflection",
            tags: ["evening"]
        )
        var profile = try await assembly.profileService.load()
        #expect(profile.journalEntries.count == 1)
        #expect(profile.journalEntries.first?.text == "Reflection")

        let filtered = try await assembly.profileService.journalEntries(tags: ["evening"])
        #expect(filtered.count == 1)
        #expect(filtered.first?.id == entry.id)

        try await assembly.profileService.removeJournalEntry(id: entry.id)
        profile = try await assembly.profileService.load()
        #expect(profile.journalEntries.isEmpty)
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

    @Test("Deliberation assembly logs per-item profile denials")
    func deliberationAssemblyLogsProfileDenials() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("council-cli-integration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let assembly = try await RuntimeAssembly(
            rootDirectory: root,
            useSecureEnclave: false
        )

        let denied = try await assembly.profileService.addGoal(
            "Retire abroad",
            deniedPurposes: [.purchaseDeliberation]
        )
        try await assembly.profileService.addValue("Be frugal")

        // Building the deliberation service resolves purpose-bound profile context and
        // records one audit entry per denied item.
        let service = try await assembly.deliberationService(provider: EchoInferenceProvider())
        _ = service

        let entries = try await assembly.memoryService.auditLog.entries(
            since: nil,
            limit: nil,
            includePayloads: true
        )
        let denials = entries.filter {
            $0.category == .memoryAccess && $0.payload["decision"] == "denied"
        }
        #expect(denials.count == 1)
        #expect(denials.first?.payload["dataElementType"] == "Goal")
        #expect(denials.first?.payload["elementID"] == denied.id.uuidString)
        #expect(denials.first?.payload["purpose"] == "purchaseDeliberation")
    }

    @Test("RoutableProfileContext excludes confidential containers")
    func profileRedaction() async throws {
        let profile = UserProfile(
            values: [ValueStatement(text: "Value")],
            financialHistory: ClientConfidentialContainer(items: ["salary"]),
            journalEntries: [JournalEntry(text: "diary")]
        )
        let context = RoutableProfileContext(profile: profile)
        #expect(context.values.count == 1)
        // RoutableProfileContext intentionally omits financialHistory and journalEntries.
    }

    @Test("tools list through CLI writes toolCall audit entries")
    func toolsListWritesAuditEntries() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("council-cli-integration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let fixture = try makeFixtureMCPServer(in: root)
        var command = try ToolsCommand.ListCommand.parse([
            "--server", "python3 \(fixture.path)",
            "--profile-dir", root.path,
        ])
        try await command.run()

        let assembly = try await RuntimeAssembly(rootDirectory: root, useSecureEnclave: false)
        let entries = try await assembly.memoryService.auditLog.entries(
            since: nil,
            limit: nil,
            includePayloads: true
        )
        let toolCalls = entries.filter { $0.category == .toolCall }
        #expect(toolCalls.count == 1)
        #expect(toolCalls.first?.payload["operation"] == "listTools")
        #expect(toolCalls.first?.payload["decision"] == "allowed")
        // Only the executable basename is persisted, never the full command line.
        #expect(toolCalls.first?.payload["server"] == "python3")
        #expect(try await assembly.memoryService.verifyAuditChain())
    }

    /// Writes a minimal newline-delimited JSON-RPC MCP fixture server.
    private func makeFixtureMCPServer(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = """
        import sys, json

        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except Exception:
                continue
            method = msg.get("method")
            if method == "initialize":
                resp = {"jsonrpc": "2.0", "id": msg["id"], "result": {"protocolVersion": "2024-11-05", "capabilities": {}, "serverInfo": {"name": "fixture", "version": "0.0.1"}}}
            elif method == "notifications/initialized":
                continue
            elif method == "tools/list":
                resp = {"jsonrpc": "2.0", "id": msg["id"], "result": {"tools": [
                    {"name": "echo", "description": "Echo back the input", "inputSchema": {"type": "object"}}
                ]}}
            else:
                resp = {"jsonrpc": "2.0", "id": msg.get("id"), "error": {"code": -32601, "message": "unknown method"}}
            sys.stdout.write(json.dumps(resp) + "\\n")
            sys.stdout.flush()
        """
        let path = directory.appendingPathComponent("fixture_server.py")
        try script.write(to: path, atomically: true, encoding: .utf8)
        return path
    }
}
