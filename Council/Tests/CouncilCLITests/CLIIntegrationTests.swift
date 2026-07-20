import ArgumentParser
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

    @Test("CLIAssembly hardens the profile directory and every sensitive file")
    func hardenProfileDirectoryCoversEverySensitiveFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("council-cli-integration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        // Start from a world-readable directory: hardening must tighten it,
        // not merely preserve permissions it set itself.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: root.path
        )

        let options = try GlobalOptions.parse(["--profile-dir", root.path])
        _ = try await CLIAssembly.makeRuntimeAssembly(options: options)

        let dirPermissions = try FileManager.default
            .attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
        #expect(dirPermissions?.int16Value == 0o700)

        let sensitiveFiles = [
            "profile.key", "salt.bin", "memory.sqlite", "memory.sqlite-wal",
            "memory.sqlite-shm", "memory.sqlite.audit", "memory.sqlite.audit-wal",
            "memory.sqlite.audit-shm", "vault.enc",
        ]
        var checked = 0
        for name in sensitiveFiles {
            let path = root.appendingPathComponent(name).path
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let permissions = try FileManager.default
                .attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
            #expect(permissions?.int16Value == 0o600, "\(name) must be owner-only")
            checked += 1
        }
        // The assembly must have produced real state to harden.
        #expect(checked >= 4)

        // A file whose permissions are loosened later must be repaired by the
        // next CLI invocation — the hardening pass is not one-shot.
        let keyPath = root.appendingPathComponent("profile.key").path
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: keyPath)
        _ = try await CLIAssembly.makeRuntimeAssembly(options: options)
        let repaired = try FileManager.default
            .attributesOfItem(atPath: keyPath)[.posixPermissions] as? NSNumber
        #expect(repaired?.int16Value == 0o600)
    }

    @Test("CLIAssembly follows a symlinked profile directory and hardens the target")
    func hardenProfileDirectoryFollowsSymlink() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("council-cli-integration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let real = base.appendingPathComponent("real")
        let link = base.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: real.path)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: real.path)

        let options = try GlobalOptions.parse(["--profile-dir", link.path])
        _ = try await CLIAssembly.makeRuntimeAssembly(options: options)

        // Pins follow-symlink behavior: the target directory and its key file
        // are hardened, so a symlink cannot smuggle in lax permissions.
        let dirPermissions = try FileManager.default
            .attributesOfItem(atPath: real.path)[.posixPermissions] as? NSNumber
        #expect(dirPermissions?.int16Value == 0o700)
        let keyPermissions = try FileManager.default
            .attributesOfItem(atPath: real.appendingPathComponent("profile.key").path)[.posixPermissions] as? NSNumber
        #expect(keyPermissions?.int16Value == 0o600)
    }

    @Test("memory show with an unknown id exits 1")
    func memoryShowUnknownIDExits1() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("council-cli-integration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        var command = try MemoryCommand.ShowCommand.parse([
            UUID().uuidString,
            "--profile-dir", root.path,
        ])
        do {
            try await command.run()
            Issue.record("Expected ExitCode(1) for an unknown gist id")
        } catch let error as ExitCode {
            #expect(error.rawValue == 1)
        }
    }

    @Test("model show with an unknown id exits 1")
    func modelShowUnknownIDExits1() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("council-cli-integration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        var command = try ModelCommand.ShowCommand.parse([
            "no-such-model-\(UUID().uuidString)",
            "--profile-dir", root.path,
        ])
        do {
            try await command.run()
            Issue.record("Expected ExitCode(1) for an unknown model id")
        } catch let error as ExitCode {
            #expect(error.rawValue == 1)
        }
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
