@testable import CouncilCLI
import CouncilCore
import Foundation
import Testing

/// Adversarial tests for `MemoryCommand` JSON rendering and limit handling.
@Suite("MemoryCommand adversarial")
struct MemoryCommandAdversarialTests {

    @Test("JSON rendering of pathological persisted dates never force-crashes")
    func memoryListJsonNeverForceCrashes() throws {
        // A tampered/corrupt episode row (extreme createdAt) must render or
        // throw — never trap the process behind a `try!`.
        let episodes = [
            EpisodicGist(
                sessionID: UUID(),
                question: "tampered row",
                createdAt: .distantPast,
                perspective: Perspective(summary: "old")
            ),
            EpisodicGist(
                sessionID: UUID(),
                question: "tampered row",
                createdAt: .distantFuture,
                perspective: Perspective(summary: "future")
            ),
        ]
        let json = try episodeJSON(episodes, includePerspective: true)
        #expect(json.contains("0001-01-01T00:00:00Z"))
        #expect(json.contains("4001-01-01T00:00:00Z"))
        #expect(json.contains("tampered row"))
    }

    @Test("negative --limit is rejected on memory list and search")
    func memoryListNegativeLimitRejected() throws {
        #expect(throws: (any Error).self) {
            try MemoryCommand.ListCommand.parse(["--limit", "-1"])
        }
        #expect(throws: (any Error).self) {
            try MemoryCommand.SearchCommand.parse(["query", "--limit", "-1"])
        }

        // Zero is a valid, bounded limit: pin it as allowed.
        let zero = try MemoryCommand.ListCommand.parse(["--limit", "0"])
        #expect(zero.limit == 0)
        let ten = try MemoryCommand.SearchCommand.parse(["query", "--limit", "10"])
        #expect(ten.limit == 10)
    }
}
