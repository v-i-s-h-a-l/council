import ArgumentParser
import CouncilAgents
@testable import CouncilCLI
import CouncilCore
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
        #expect(command.format == .text)
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
        #expect(command.format == .json)
        #expect(command.profileDir == "/tmp/council-test")
        #expect(command.verbose)
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
}
