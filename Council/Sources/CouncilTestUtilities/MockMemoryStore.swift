import CouncilCore
import Foundation

/// In-memory actor conforming to `MemoryStore` for testing.
public actor MockMemoryStore: MemoryStore {
    private var episodes: [EpisodicGist] = []
    private var facts: [TemporalFact] = []

    public init() {}

    public func saveEpisode(_ episode: EpisodicGist) async throws {
        episodes.append(episode)
    }

    public func episodes(matching filter: MemoryFilter) async throws -> [EpisodicGist] {
        episodes.filter { episode in
            if let locked = filter.locked, locked != episode.isLocked { return false }
            if let subject = filter.subject, !episode.question.contains(subject) { return false }
            return true
        }
    }

    public func updateEpisode(_ episode: EpisodicGist) async throws {
        if let index = episodes.firstIndex(where: { $0.id == episode.id }) {
            episodes[index] = episode
        }
    }

    public func deleteEpisode(id: UUID) async throws {
        episodes.removeAll { $0.id == id }
    }

    public func lockEpisode(id: UUID, isLocked: Bool) async throws {
        if let index = episodes.firstIndex(where: { $0.id == id }) {
            episodes[index] = EpisodicGist(
                id: episodes[index].id,
                sessionID: episodes[index].sessionID,
                question: episodes[index].question,
                createdAt: episodes[index].createdAt,
                perspective: episodes[index].perspective,
                isLocked: isLocked
            )
        }
    }

    public func temporalFacts(for purpose: AccessPurpose) async throws -> [TemporalFact] {
        try await temporalFacts(matching: MemoryFilter(purposes: [purpose]))
    }

    public func temporalFacts(matching filter: MemoryFilter) async throws -> [TemporalFact] {
        facts.filter { fact in
            if let purposes = filter.purposes {
                let purposeSet = Set(purposes)
                let scopeSet = Set(fact.accessScope)
                guard !purposeSet.isDisjoint(with: scopeSet) else { return false }
                guard purposeSet.isDisjoint(with: Set(fact.deniedPurposes)) else { return false }
            }
            if let locked = filter.locked, locked != fact.isLocked { return false }
            if let subject = filter.subject, fact.subject != subject { return false }
            return true
        }
    }

    public func saveFact(_ fact: TemporalFact) async throws {
        if let index = facts.firstIndex(where: { $0.id == fact.id }) {
            facts[index] = fact
        } else {
            facts.append(fact)
        }
    }

    public func deleteFact(id: UUID) async throws {
        facts.removeAll { $0.id == id }
    }
}
