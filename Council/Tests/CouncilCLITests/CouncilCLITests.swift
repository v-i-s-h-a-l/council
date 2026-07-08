import ArgumentParser
import CouncilAgents
@testable import CouncilCLI
import CouncilCore
import CouncilInference
import CouncilMemory
import CouncilTestUtilities
import Foundation
import Testing

@Suite("CouncilCLI")
struct CouncilCLITests {

    @Test("ask command parses required question")
    func parsesQuestion() throws {
        let command = try AskCommand.parse(["Should I buy this?"])
        #expect(command.question == "Should I buy this?")
        #expect(command.provider == .echo)
        #expect(command.options.format == .text)
        #expect(!command.consentDownload)
    }

    @Test("ask command parses options")
    func parsesOptions() throws {
        let command = try AskCommand.parse([
            "--provider", "mlx",
            "--model", "mlx-community/test",
            "--checksum", "sha256:deadbeef",
            "--consent-download",
            "--format", "json",
            "--profile-dir", "/tmp/council-test",
            "--verbose",
            "--no-persist",
            "Should I buy this?",
        ])
        #expect(command.provider == .mlx)
        #expect(command.model == "mlx-community/test")
        #expect(command.checksum == "sha256:deadbeef")
        #expect(command.consentDownload)
        #expect(command.options.format == .json)
        #expect(command.options.profileDir == "/tmp/council-test")
        #expect(command.options.verbose)
        #expect(command.noPersist)
    }

    @Test("mlx provider requires --model")
    func mlxRequiresModel() {
        #expect(throws: (any Error).self) {
            try AskCommand.parse([
                "--provider", "mlx",
                "--checksum", "sha256:deadbeef",
                "Should I buy this?",
            ])
        }
    }

    @Test("mlx provider requires --checksum")
    func mlxRequiresChecksum() {
        #expect(throws: (any Error).self) {
            try AskCommand.parse([
                "--provider", "mlx",
                "--model", "mlx-community/test",
                "Should I buy this?",
            ])
        }
    }

    @Test("invalid provider is rejected")
    func rejectsInvalidProvider() {
        #expect(throws: (any Error).self) {
            try AskCommand.parse(["--provider", "invalid", "Should I buy this?"])
        }
    }

    @Test("perspective formatter produces text output")
    func textFormatter() {
        let perspective = Perspective(
            summary: "Summary text.",
            tradeOffs: ["Trade-off one."],
            blindSpots: ["Blind spot one."],
            dissent: ["Dissent one."]
        )
        let output = PerspectiveFormatter.text(perspective)
        #expect(output.contains("Summary"))
        #expect(output.contains("Trade-off one."))
        #expect(output.contains("Blind spot one."))
        #expect(output.contains("Dissent one."))
    }

    @Test("MemoryService records episode and appends audit")
    func memoryServiceOperations() async throws {
        let store = MockMemoryStore()
        let auditLog = MockAuditLog()
        let service = MemoryService(store: store, auditLog: auditLog)

        let sessionID = UUID()
        let perspective = Perspective(summary: "Test.")
        try await service.recordEpisode(
            sessionID: sessionID,
            question: "Should I test?",
            perspective: perspective
        )
        try await service.appendAuditEntry(
            category: .sessionStarted,
            sessionID: sessionID,
            payload: ["question": "Should I test?"]
        )

        let episodes = try await service.recentEpisodes()
        #expect(episodes.count == 1)
        #expect(episodes.first?.question == "Should I test?")

        let auditEntries = await auditLog.entries
        #expect(auditEntries.count == 1)
        #expect(auditEntries.first?.category == .sessionStarted)
    }

    // MARK: - New command parsing

    @Test("profile show parses")
    func profileShowParses() throws {
        let command = try ProfileCommand.ShowCommand.parse([])
        #expect(command.options.format == .text)
    }

    @Test("profile value add parses")
    func profileValueAddParses() throws {
        let command = try ProfileCommand.ValueCommand.AddCommand.parse(["Be frugal"])
        #expect(command.text == "Be frugal")
    }

    @Test("profile value remove parses UUID")
    func profileValueRemoveParses() throws {
        let id = UUID()
        let command = try ProfileCommand.ValueCommand.RemoveCommand.parse([id.uuidString])
        #expect(command.id == id)
    }

    @Test("memory list parses limit")
    func memoryListParses() throws {
        let command = try MemoryCommand.ListCommand.parse(["--limit", "10"])
        #expect(command.limit == 10)
    }

    @Test("memory fact add parses purpose")
    func memoryFactAddParses() throws {
        let command = try MemoryCommand.FactCommand.AddCommand.parse([
            "user", "budget", "1000", "--purpose", "purchaseDeliberation",
        ])
        #expect(command.subject == "user")
        #expect(command.predicate == "budget")
        #expect(command.object == "1000")
        #expect(command.purpose == .purchaseDeliberation)
    }

    @Test("model register parses checksum")
    func modelRegisterParses() throws {
        let command = try ModelCommand.RegisterCommand.parse([
            "mlx-community/test", "--checksum", "sha256:deadbeef",
        ])
        #expect(command.id == "mlx-community/test")
        #expect(command.checksum == "sha256:deadbeef")
    }

    @Test("audit list parses include-payloads")
    func auditListParses() throws {
        let command = try AuditCommand.ListCommand.parse(["--include-payloads", "--limit", "5"])
        #expect(command.includePayloads)
        #expect(command.limit == 5)
    }

    // MARK: - Service additions

    @Test("ProfileService adds and removes values")
    func profileServiceValueManagement() async throws {
        let vault = MockProfileVault()
        let service = ProfileService(vault: vault)
        let value = try await service.addValue("Be mindful")
        #expect(value.text == "Be mindful")

        var profile = try await service.load()
        #expect(profile.values.count == 1)

        try await service.removeValue(id: value.id)
        profile = try await service.load()
        #expect(profile.values.isEmpty)
    }

    @Test("ProfileService adds and removes goals")
    func profileServiceGoalManagement() async throws {
        let vault = MockProfileVault()
        let service = ProfileService(vault: vault)
        let goal = try await service.addGoal("Save for travel", timeframe: "2027")
        #expect(goal.timeframe == "2027")

        try await service.removeGoal(id: goal.id)
        let profile = try await service.load()
        #expect(profile.goals.isEmpty)
    }

    @Test("ProfileService adds and removes boundaries")
    func profileServiceBoundaryManagement() async throws {
        let vault = MockProfileVault()
        let service = ProfileService(vault: vault)
        let boundary = try await service.addBoundary("No impulse buys")
        #expect(boundary.text == "No impulse buys")

        try await service.removeBoundary(id: boundary.id)
        let profile = try await service.load()
        #expect(profile.boundaries.isEmpty)
    }

    @Test("MemoryService searches episodes")
    func memoryServiceSearchEpisodes() async throws {
        let store = MockMemoryStore()
        let auditLog = MockAuditLog()
        let service = MemoryService(store: store, auditLog: auditLog)

        try await service.recordEpisode(
            sessionID: UUID(),
            question: "Should I buy a bike?",
            perspective: Perspective(summary: "No.")
        )
        try await service.recordEpisode(
            sessionID: UUID(),
            question: "Should I buy a car?",
            perspective: Perspective(summary: "Maybe.")
        )

        let bikeResults = try await service.searchEpisodes(query: "bike", limit: 10)
        #expect(bikeResults.count == 1)
        #expect(bikeResults.first?.question.contains("bike") == true)
    }

    @Test("MemoryService manages facts")
    func memoryServiceFactManagement() async throws {
        let store = MockMemoryStore()
        let auditLog = MockAuditLog()
        let service = MemoryService(store: store, auditLog: auditLog)

        let fact = try await service.addFact(
            subject: "user",
            predicate: "budget",
            object: "500"
        )
        #expect(fact.subject == "user")

        let facts = try await service.facts(subject: "user")
        #expect(facts.count == 1)
        #expect(facts.first?.object == "500")
    }

    @Test("ModelManifestService lists and unregisters manifests")
    func modelManifestServiceListAndUnregister() async {
        let service = ModelManifestService()
        await service.register(ModelManifest(id: "a", checksum: "sha256:1"))
        await service.register(ModelManifest(id: "b", checksum: "sha256:2"))

        let manifests = await service.allManifests()
        #expect(manifests.count == 2)

        await service.unregister(id: "a")
        let remaining = await service.allManifests()
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == "b")
    }

    @Test("MockAuditLog metadata-only entries omit payloads")
    func mockAuditLogMetadataOnlyEntries() async throws {
        let auditLog = MockAuditLog()
        let entry = AuditEntry(
            category: .sessionStarted,
            payload: ["question": "secret"]
        )
        try await auditLog.append(entry)

        let metadata = try await auditLog.entries(since: nil, limit: nil, includePayloads: false)
        #expect(metadata.first?.payload.isEmpty == true)

        let full = try await auditLog.entries(since: nil, limit: nil, includePayloads: true)
        #expect(full.first?.payload["question"] == "secret")
    }
}
