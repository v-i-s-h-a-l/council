import CouncilAgents
import CouncilCore
import Foundation
import Observation
import SwiftUI

/// View model for a deliberation session.
@MainActor
@Observable
public final class SessionViewModel {
    public var question: String = ""
    public var streamingText: String = ""
    public var sessionState: DeliberationStage = .idle
    public var agentOutputs: [AgentOutput] = []
    public var error: String?
    public var isRunning: Bool = false
    public var perspective: Perspective?
    public var reduceMotion: Bool = false

    private let service: DeliberationService
    private var stateTask: Task<Void, Never>?

    public init(service: DeliberationService, reduceMotion: Bool = false) {
        self.service = service
        self.reduceMotion = reduceMotion
    }

    /// Starts a new deliberation session with the current question.
    public func start() {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }

        question = trimmed
        isRunning = true
        error = nil
        perspective = nil
        streamingText = ""
        sessionState = .idle
        agentOutputs = []

        stateTask?.cancel()
        stateTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.service.stateUpdates()
            await self.service.startSession(question: trimmed)

            for await state in stream {
                self.apply(state: state)
            }
        }
    }

    /// Cancels the active session and tears down the state consumer.
    public func cancel() {
        stateTask?.cancel()
        stateTask = nil
        Task { [weak self] in
            guard let self else { return }
            await self.service.cancel()
        }
        isRunning = false
    }

    private func apply(state: DeliberationState) {
        withAnimation(reduceMotion ? nil : .default) {
            sessionState = state.stage
            agentOutputs = state.agentOutputs
            if let errorMessage = state.errorMessage {
                error = errorMessage
            }
            if let perspective = state.perspective {
                self.perspective = perspective
                streamingText = perspective.summary
            } else if let latest = state.agentOutputs.last {
                streamingText = latest.opinion
            } else {
                streamingText = stageDescription(state.stage)
            }
            if state.stage == .presentation || state.stage == .cancelled || state.stage == .failed {
                isRunning = false
            }
        }
    }

    private func stageDescription(_ stage: DeliberationStage) -> String {
        switch stage {
        case .idle:
            return "Ask the council a question."
        case .firstOpinions:
            return "Collecting first opinions..."
        case .peerReview:
            return "Agents are reviewing each other..."
        case .synthesis:
            return "The chair is synthesizing a perspective..."
        case .dissentPreservation:
            return "Preserving dissent..."
        case .presentation:
            return "Perspective ready."
        case .cancelled:
            return "Session cancelled."
        case .failed:
            return "Session failed."
        }
    }
}
