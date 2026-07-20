import CouncilCore
import CouncilMemory
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
        options: InferenceOptions = InferenceOptions(),
        memoryService: MemoryService? = nil
    ) {
        self.actor = DeliberationActor(
            provider: provider,
            council: council,
            validators: validators,
            context: context,
            options: options,
            memoryService: memoryService
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
    private let memoryService: MemoryService?

    private var state: DeliberationState
    private var stateContinuation: AsyncStream<DeliberationState>.Continuation?
    private var sessionTask: Task<Void, Never>?

    init(
        provider: any InferenceProvider,
        council: any Council,
        validators: [any PerspectiveValidator],
        context: RoutableProfileContext,
        options: InferenceOptions,
        memoryService: MemoryService? = nil
    ) {
        self.provider = provider
        self.council = council
        self.validators = validators
        self.context = context
        self.options = options
        self.memoryService = memoryService
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
        // Reset per-session state so a restarted session never inherits the previous
        // session's ID (which would corrupt audit attribution), its agent outputs,
        // or its perspective. The fresh state is yielded so subscribers see the reset.
        state = DeliberationState()
        stateContinuation?.yield(state)
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
        // Capture this session's identity. If a newer session starts while this one
        // is still winding down, every stale state mutation, audit write, and stream
        // operation from this task must be dropped so it cannot corrupt or terminate
        // the new session's feed.
        let sessionID = state.sessionID
        do {
            await appendAudit(
                category: .sessionStarted,
                sessionID: sessionID,
                payload: ["question": question]
            )
            updateStateIfCurrent(session: sessionID) {
                $0.question = question
                $0.stage = .firstOpinions
            }
            await appendAudit(category: .stageTransition, sessionID: sessionID, payload: ["stage": "firstOpinions"])

            let chair = try Self.resolveChair(from: council)
            let nonChairAgents = council.agents.filter { $0.id != chair.id }
            let purpose = Self.resolvePurpose(from: council)
            await appendAudit(
                category: .memoryAccess,
                sessionID: sessionID,
                payload: [
                    "purpose": purpose.rawValue,
                    "dataElementType": "RoutableProfileContext",
                    "decision": "allowed",
                ]
            )

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
                    updateStateIfCurrent(session: sessionID) { $0.agentOutputs.append(output) }
                    await appendAudit(
                        category: .agentCalled,
                        sessionID: sessionID,
                        payload: ["stage": "firstOpinions", "agentID": output.agentID]
                    )
                }
            }

            // Peer review: each agent reviews all first opinions.
            updateStateIfCurrent(session: sessionID) { $0.stage = .peerReview }
            await appendAudit(category: .stageTransition, sessionID: sessionID, payload: ["stage": "peerReview"])
            var peerReviews: [AgentOutput] = []
            for agent in nonChairAgents {
                let output = try await callAgent(
                    agent,
                    stage: .peerReview,
                    question: question,
                    priorOutputs: firstOpinions
                )
                peerReviews.append(output)
                updateStateIfCurrent(session: sessionID) { $0.agentOutputs.append(output) }
                await appendAudit(
                    category: .agentCalled,
                    sessionID: sessionID,
                    payload: ["stage": "peerReview", "agentID": output.agentID]
                )
            }

            // Synthesis + dissent preservation + validation with retry.
            let routeDecision = await provider.routeSnapshot.asRouteDecision()
            await appendAudit(
                category: .routeDecision,
                sessionID: sessionID,
                payload: [
                    "route": routeDecision.selectedRoute.rawValue,
                    "model": routeDecision.providerMetadata.modelIdentifier,
                ]
            )
            let validatedPerspective = try await runSynthesisLoop(
                chair: chair,
                nonChairAgents: nonChairAgents,
                question: question,
                routeDecision: routeDecision,
                sessionID: sessionID,
                firstOpinions: firstOpinions,
                peerReviews: peerReviews
            )

            // A newer session may have superseded this one while it was running;
            // in that case this task must not touch the shared state or stream.
            guard state.sessionID == sessionID else { return }
            updateState {
                $0.stage = .presentation
                $0.perspective = validatedPerspective
            }
            await persistResult(sessionID: sessionID, question: question, perspective: validatedPerspective)
            await appendAudit(
                category: .perspectiveProduced,
                sessionID: sessionID,
                payload: ["summaryLength": "\(validatedPerspective.summary.count)"]
            )
            stateContinuation?.finish()
        } catch is CancellationError {
            guard state.sessionID == sessionID else { return }
            updateState { $0.stage = .cancelled }
            await appendAudit(category: .cancellation, sessionID: sessionID, payload: [:])
            stateContinuation?.finish()
        } catch {
            guard state.sessionID == sessionID else { return }
            let safeError = Self.sanitizedErrorDescription(error)
            updateState {
                $0.stage = .failed
                $0.errorMessage = safeError
            }
            await appendAudit(
                category: .error,
                sessionID: sessionID,
                payload: ["category": safeError]
            )
            stateContinuation?.finish()
        }
    }

    private static func sanitizedErrorDescription(_ error: Error) -> String {
        // Avoid recording raw provider error strings that may contain paths,
        // model identifiers, or other sensitive details. Surface only a stable
        // category derived from the error type.
        if error is CancellationError {
            return "cancelled"
        }
        // Classify our own error type explicitly: relying on the type *name*
        // containing substrings like "Validation" silently mis-categorizes
        // e.g. `DeliberationError.invalidPerspective` as a generic failure.
        if let deliberationError = error as? DeliberationError {
            switch deliberationError {
            case .invalidPerspective:
                return "validationFailed"
            case .thermalCritical:
                return "thermalLimit"
            case .inferenceCancelled:
                return "cancelled"
            case .noCouncil, .sessionAlreadyActive:
                return "deliberationFailed"
            }
        }
        let typeName = String(describing: type(of: error))
        if typeName.contains("Thermal") {
            return "thermalLimit"
        }
        if typeName.contains("Validation") {
            return "validationFailed"
        }
        if typeName.contains("Inference") || typeName.contains("MLX") || typeName.contains("Model") {
            return "inferenceFailed"
        }
        return "deliberationFailed"
    }

    private func runSynthesisLoop(
        chair: any Agent,
        nonChairAgents: [any Agent],
        question: String,
        routeDecision: RouteDecision,
        sessionID: UUID,
        firstOpinions: [AgentOutput],
        peerReviews: [AgentOutput]
    ) async throws -> Perspective {
        var retryCount = 0
        let priorPool = firstOpinions + peerReviews
        var synthesisHistory: [AgentOutput] = []

        while true {
            updateStateIfCurrent(session: sessionID) { $0.stage = .synthesis }
            let chairOutput = try await callAgent(
                chair,
                stage: .synthesis,
                question: question,
                priorOutputs: priorPool + synthesisHistory
            )
            updateStateIfCurrent(session: sessionID) { $0.agentOutputs.append(chairOutput) }

            var perspective = PerspectiveParser.parsePerspective(
                question: question,
                routeDecision: routeDecision,
                auditSessionID: sessionID,
                from: chairOutput.opinion
            )

            // Dissent preservation: ask non-chair agents to critique the synthesis.
            updateStateIfCurrent(session: sessionID) { $0.stage = .dissentPreservation }
            var dissentOutputs: [AgentOutput] = []
            for agent in nonChairAgents {
                let output = try await callAgent(
                    agent,
                    stage: .dissentPreservation,
                    question: question,
                    priorOutputs: [chairOutput] + priorPool
                )
                dissentOutputs.append(output)
                updateStateIfCurrent(session: sessionID) { $0.agentOutputs.append(output) }
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

    /// Applies `transform` only when `session` is still the current session.
    /// A superseded session's task must not mutate (or emit) the new session's state.
    private func updateStateIfCurrent(session: UUID, _ transform: (inout DeliberationState) -> Void) {
        guard state.sessionID == session else { return }
        updateState(transform)
    }

    private static func resolvePurpose(from council: any Council) -> AccessPurpose {
        if council is PurchaseCouncil {
            return .purchaseDeliberation
        }
        // Future councils extend this mapping (e.g. TravelCouncil -> .travelDeliberation).
        return .purchaseDeliberation
    }

    private static func resolveChair(from council: any Council) throws -> any Agent {
        if let purchaseCouncil = council as? PurchaseCouncil {
            return purchaseCouncil.chair
        }
        if let chair = council.agents.first(where: { $0.stance == .neutral }) {
            return chair
        }
        if let last = council.agents.last {
            return last
        }
        // An empty council previously crashed the process here via `agents.last!`.
        throw DeliberationError.noCouncil
    }

    private func appendAudit(category: AuditCategory, sessionID: UUID, payload: [String: String]) async {
        guard let memoryService else { return }
        do {
            try await memoryService.appendAuditEntry(
                category: category,
                sessionID: sessionID,
                payload: payload
            )
        } catch {
            // Audit failures are non-fatal but should not be silently ignored in production.
            // For Phase 1 we tolerate them to keep deliberation available.
        }
    }

    private func persistResult(sessionID: UUID, question: String, perspective: Perspective) async {
        guard let memoryService else { return }
        do {
            try await memoryService.recordEpisode(
                sessionID: sessionID,
                question: question,
                perspective: perspective
            )
        } catch {
            // Persistence failures are non-fatal in Phase 1.
        }
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
