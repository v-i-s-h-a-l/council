import CouncilCore
import Foundation

/// Public entry point for running a deliberation session.
///
/// `DeliberationService` is `Sendable` and safe to hold from view models. All mutable
/// state lives inside the private `DeliberationActor`.
public final class DeliberationService: Sendable {
    private let actor: DeliberationActor

    public init(
        provider: any InferenceProvider,
        council: any Council,
        validators: [any PerspectiveValidator],
        context: RoutableProfileContext = RoutableProfileContext(),
        options: InferenceOptions = InferenceOptions()
    ) {
        self.actor = DeliberationActor(
            provider: provider,
            council: council,
            validators: validators,
            context: context,
            options: options
        )
    }

    public func startSession(question: String) async {
        await actor.startSession(question: question)
    }

    public func cancel() async {
        await actor.cancel()
    }

    public func stateUpdates() async -> AsyncStream<DeliberationState> {
        await actor.stateUpdates()
    }
}

// MARK: - Actor

private actor DeliberationActor {
    private let provider: any InferenceProvider
    private let council: any Council
    private let validators: [any PerspectiveValidator]
    private let context: RoutableProfileContext
    private let options: InferenceOptions

    private var state: DeliberationState
    private var stateContinuation: AsyncStream<DeliberationState>.Continuation?
    private var sessionTask: Task<Void, Never>?

    init(
        provider: any InferenceProvider,
        council: any Council,
        validators: [any PerspectiveValidator],
        context: RoutableProfileContext,
        options: InferenceOptions
    ) {
        self.provider = provider
        self.council = council
        self.validators = validators
        self.context = context
        self.options = options
        self.state = DeliberationState()
    }

    func stateUpdates() -> AsyncStream<DeliberationState> {
        let (stream, continuation) = AsyncStream.makeStream(of: DeliberationState.self)
        self.stateContinuation = continuation
        continuation.yield(state)
        return stream
    }

    func startSession(question: String) {
        sessionTask?.cancel()
        sessionTask = Task {
            await runDeliberation(question: question)
        }
    }

    func cancel() {
        sessionTask?.cancel()
        sessionTask = nil
        updateState { $0.stage = .cancelled }
    }

    // MARK: - State machine

    private func runDeliberation(question: String) async {
        do {
            updateState {
                $0.question = question
                $0.stage = .firstOpinions
            }

            let chair = Self.resolveChair(from: council)
            let nonChairAgents = council.agents.filter { $0.id != chair.id }

            // First opinions: run all non-chair agents concurrently.
            var firstOpinions: [AgentOutput] = []
            try await withThrowingTaskGroup(of: AgentOutput.self) { group in
                for agent in nonChairAgents {
                    group.addTask {
                        try await self.callAgent(
                            agent,
                            stage: .firstOpinions,
                            question: question,
                            priorOutputs: []
                        )
                    }
                }
                for try await output in group {
                    firstOpinions.append(output)
                    updateState { $0.agentOutputs.append(output) }
                }
            }

            // Peer review: each agent reviews all first opinions.
            updateState { $0.stage = .peerReview }
            var peerReviews: [AgentOutput] = []
            for agent in nonChairAgents {
                let output = try await callAgent(
                    agent,
                    stage: .peerReview,
                    question: question,
                    priorOutputs: firstOpinions
                )
                peerReviews.append(output)
                updateState { $0.agentOutputs.append(output) }
            }

            // Synthesis + dissent preservation + validation with retry.
            let routeDecision = await provider.routeSnapshot.asRouteDecision()
            let validatedPerspective = try await runSynthesisLoop(
                chair: chair,
                nonChairAgents: nonChairAgents,
                question: question,
                routeDecision: routeDecision,
                firstOpinions: firstOpinions,
                peerReviews: peerReviews
            )

            updateState {
                $0.stage = .presentation
                $0.perspective = validatedPerspective
            }
            stateContinuation?.finish()
        } catch is CancellationError {
            updateState { $0.stage = .cancelled }
            stateContinuation?.finish()
        } catch {
            updateState {
                $0.stage = .failed
                $0.errorMessage = error.localizedDescription
            }
            stateContinuation?.finish()
        }
    }

    private func runSynthesisLoop(
        chair: any Agent,
        nonChairAgents: [any Agent],
        question: String,
        routeDecision: RouteDecision,
        firstOpinions: [AgentOutput],
        peerReviews: [AgentOutput]
    ) async throws -> Perspective {
        var retryCount = 0
        let priorPool = firstOpinions + peerReviews
        var synthesisHistory: [AgentOutput] = []

        while true {
            updateState { $0.stage = .synthesis }
            let chairOutput = try await callAgent(
                chair,
                stage: .synthesis,
                question: question,
                priorOutputs: priorPool + synthesisHistory
            )
            updateState { $0.agentOutputs.append(chairOutput) }

            var perspective = PerspectiveParser.parsePerspective(
                question: question,
                routeDecision: routeDecision,
                auditSessionID: state.sessionID,
                from: chairOutput.opinion
            )

            // Dissent preservation: ask non-chair agents to critique the synthesis.
            updateState { $0.stage = .dissentPreservation }
            var dissentOutputs: [AgentOutput] = []
            for agent in nonChairAgents {
                let output = try await callAgent(
                    agent,
                    stage: .dissentPreservation,
                    question: question,
                    priorOutputs: [chairOutput] + priorPool
                )
                dissentOutputs.append(output)
                updateState { $0.agentOutputs.append(output) }
            }
            perspective = PerspectiveParser.incorporateDissent(
                into: perspective,
                dissentOutputs: dissentOutputs
            )

            // Validate.
            let validation = validators.reduce(PerspectiveValidationResult.valid) { result, validator in
                switch result {
                case .valid:
                    return validator.validate(perspective)
                case .invalid:
                    return result
                }
            }

            switch validation {
            case .valid:
                return perspective
            case .invalid(let reason):
                if retryCount >= options.retryBudget.maxRetries {
                    throw DeliberationError.invalidPerspective(reason)
                }
                retryCount += 1
                synthesisHistory.append(chairOutput)
                synthesisHistory.append(Self.correctionOutput(reason: reason))
            }
        }
    }

    private static func correctionOutput(reason: String) -> AgentOutput {
        AgentOutput(
            agentID: "system",
            opinion: """
            The previous synthesis was rejected by the constitutional validator: \(reason).
            Please produce a corrected synthesis that preserves every substantive dissent note, avoids verdict language, and follows the required JSON schema.
            """,
            rationale: "validation-correction",
            stance: .neutral
        )
    }

    // MARK: - Inference helper

    /// `nonisolated` so first-opinion calls can run concurrently.
    private nonisolated func callAgent(
        _ agent: any Agent,
        stage: DeliberationStage,
        question: String,
        priorOutputs: [AgentOutput]
    ) async throws -> AgentOutput {
        try Task.checkCancellation()

        let messages = agent.prompt(
            stage: stage,
            question: question,
            context: context,
            priorOutputs: priorOutputs
        )

        let stream = try await provider.generate(messages: messages, options: options)
        let raw = try await collectString(from: stream)

        return AgentOutput(
            agentID: agent.id,
            opinion: raw,
            rationale: stage.rawValue,
            stance: agent.stance
        )
    }

    private nonisolated func collectString(
        from stream: AsyncThrowingStream<String, Error>
    ) async throws -> String {
        var result = ""
        for try await token in stream {
            try Task.checkCancellation()
            result.append(token)
        }
        return result
    }

    // MARK: - Utilities

    private func updateState(_ transform: (inout DeliberationState) -> Void) {
        transform(&state)
        stateContinuation?.yield(state)
    }

    private static func resolveChair(from council: any Council) -> any Agent {
        if let purchaseCouncil = council as? PurchaseCouncil {
            return purchaseCouncil.chair
        }
        if let chair = council.agents.first(where: { $0.stance == .neutral }) {
            return chair
        }
        return council.agents.last!
    }
}

private extension RouteSnapshot {
    func asRouteDecision() -> RouteDecision {
        RouteDecision(
            selectedRoute: self.route,
            providerMetadata: self,
            deniedRoutes: [],
            consentStatus: "notRequired",
            dataClassClearance: self.isLocal ? "onDeviceOnly" : "thirdParty"
        )
    }
}
