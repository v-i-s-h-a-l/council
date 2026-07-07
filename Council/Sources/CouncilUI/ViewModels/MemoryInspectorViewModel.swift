import CouncilCore
import CouncilMemory
import Foundation
import Observation
import SwiftUI

/// View model for inspecting and managing memory episodes and facts.
@MainActor
@Observable
public final class MemoryInspectorViewModel {
    public var episodes: [EpisodicGist] = []
    public var facts: [TemporalFact] = []
    public var errorMessage: String?

    private let memoryService: MemoryService

    public init(memoryService: MemoryService) {
        self.memoryService = memoryService
    }

    /// Loads all episodes and facts.
    public func load() async {
        do {
            episodes = try await memoryService.store.episodes(matching: MemoryFilter())
            facts = try await memoryService.store.temporalFacts(matching: MemoryFilter())
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Updates an existing episode and reloads the list.
    public func updateEpisode(_ episode: EpisodicGist) async {
        do {
            try await memoryService.store.updateEpisode(episode)
            try await memoryService.auditLog.append(
                AuditEntry(
                    sessionID: episode.sessionID,
                    category: .memoryAccess,
                    payload: ["action": "updateEpisode", "id": episode.id.uuidString]
                )
            )
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Locks or unlocks an episode.
    public func lockEpisode(id: UUID, isLocked: Bool) async {
        do {
            try await memoryService.store.lockEpisode(id: id, isLocked: isLocked)
            try await memoryService.auditLog.append(
                AuditEntry(
                    category: .memoryAccess,
                    payload: ["action": "lockEpisode", "id": id.uuidString, "isLocked": String(isLocked)]
                )
            )
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Deletes an episode and reloads the list.
    public func deleteEpisode(id: UUID) async {
        do {
            try await memoryService.store.deleteEpisode(id: id)
            try await memoryService.auditLog.append(
                AuditEntry(
                    category: .memoryAccess,
                    payload: ["action": "deleteEpisode", "id": id.uuidString]
                )
            )
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Deletes a fact and reloads the list.
    public func deleteFact(id: UUID) async {
        do {
            try await memoryService.store.deleteFact(id: id)
            try await memoryService.auditLog.append(
                AuditEntry(
                    category: .memoryAccess,
                    payload: ["action": "deleteFact", "id": id.uuidString]
                )
            )
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
