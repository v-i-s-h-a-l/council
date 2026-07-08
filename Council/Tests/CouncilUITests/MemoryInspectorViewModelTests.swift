import CouncilCore
import CouncilMemory
import CouncilTestUtilities
import CouncilUI
import Foundation
import Testing

@MainActor
struct MemoryInspectorViewModelTests {
    @Test func loadEpisodesAndFacts() async throws {
        let store = MockMemoryStore()
        let auditLog = MockAuditLog()
        let memoryService = MemoryService(store: store, auditLog: auditLog)
        let viewModel = MemoryInspectorViewModel(memoryService: memoryService)

        let episode = EpisodicGist(
            sessionID: UUID(),
            question: "Should I buy a bike?",
            perspective: Perspective(summary: "Useful but pricey.")
        )
        try await store.saveEpisode(episode)

        let fact = TemporalFact(subject: "user", predicate: "owns", object: "2019 bike")
        try await store.saveFact(fact)

        await viewModel.load()

        #expect(viewModel.episodes.count == 1)
        #expect(viewModel.facts.count == 1)
        #expect(viewModel.errorMessage == nil)
    }

    @Test func updateEpisodeAndReload() async throws {
        let store = MockMemoryStore()
        let auditLog = MockAuditLog()
        let memoryService = MemoryService(store: store, auditLog: auditLog)
        let viewModel = MemoryInspectorViewModel(memoryService: memoryService)

        var episode = EpisodicGist(
            sessionID: UUID(),
            question: "Original question",
            perspective: Perspective(summary: "Original summary.")
        )
        try await store.saveEpisode(episode)

        episode.question = "Updated question"
        episode.perspective.summary = "Updated summary."
        await viewModel.updateEpisode(episode)

        #expect(viewModel.episodes.first?.question == "Updated question")
        #expect(viewModel.episodes.first?.perspective.summary == "Updated summary.")

        let entries = try await auditLog.entries(for: episode.sessionID)
        #expect(entries.contains { $0.payload["action"] == "updateEpisode" })
    }

    @Test func lockEpisodeAndDeleteEpisode() async throws {
        let store = MockMemoryStore()
        let auditLog = MockAuditLog()
        let memoryService = MemoryService(store: store, auditLog: auditLog)
        let viewModel = MemoryInspectorViewModel(memoryService: memoryService)

        let episode = EpisodicGist(sessionID: UUID(), question: "Should I buy a bike?")
        try await store.saveEpisode(episode)

        await viewModel.lockEpisode(id: episode.id, isLocked: true)
        #expect(viewModel.episodes.first?.isLocked == true)

        await viewModel.deleteEpisode(id: episode.id)
        #expect(viewModel.episodes.isEmpty)
    }

    @Test func deleteFact() async throws {
        let store = MockMemoryStore()
        let auditLog = MockAuditLog()
        let memoryService = MemoryService(store: store, auditLog: auditLog)
        let viewModel = MemoryInspectorViewModel(memoryService: memoryService)

        let fact = TemporalFact(subject: "user", predicate: "owns", object: "2019 bike")
        try await store.saveFact(fact)

        await viewModel.deleteFact(id: fact.id)
        #expect(viewModel.facts.isEmpty)
    }
}
