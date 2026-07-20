import CouncilAgents
import CouncilCore
import CouncilMemory
import CouncilTestUtilities
import Foundation
import Testing

/// Adversarial deliberation tests that need real `MemoryService` wiring (mocks for
/// store + audit log): audit-chain completeness, persistence-failure behavior,
/// cancellation cleanup, and unbounded response accumulation.
/// Tests marked PINNED document current behavior that is known to be a gap.
struct DeliberationServiceAdversarialTests {

    // MARK: - Shared fixtures

    /// Thirteen canned responses matching the Purchase Council call order:
    /// 4 first opinions, 4 peer reviews, 1 synthesis, 4 dissent preservation.
    private static let standardResponses: [String] = [
        #"{"opinion": "Costly relative to value.", "rationale": "Utility per dollar"}"#,
        #"{"opinion": "Costly relative to value.", "rationale": "Utility per dollar"}"#,
        #"{"opinion": "Costly relative to value.", "rationale": "Utility per dollar"}"#,
        #"{"opinion": "Costly relative to value.", "rationale": "Utility per dollar"}"#,
        #"{"critiques": ["Could consider alternatives"]}"#,
        #"{"critiques": ["Long-term costs unclear"]}"#,
        #"{"critiques": ["May undervalue reliability"]}"#,
        #"{"critiques": ["Joy deserves a seat at the table"]}"#,
        #"{"summary": "Balanced view.", "tradeOffs": ["Upfront cost vs daily utility"], "blindSpots": ["Resale value uncertainty"], "dissent": ["Joy matters"]}"#,
        #"{"objection": "Frugal view undervalues reliability.", "basis": "Total cost of ownership", "conditions": "If cheaper option fails sooner"}"#,
        #"{"objection": "No objection.", "basis": "Synthesis is fair", "conditions": ""}"#,
        #"{"objection": "Blind spot on warranty coverage.", "basis": "Risk exposure", "conditions": "If warranty is short"}"#,
        #"{"objection": "Daily joy is underweighted.", "basis": "Quality of life", "conditions": "If budget is truly affordable"}"#,
    ]

    private static func collectStates(
        service: DeliberationService,
        question: String
    ) async -> [DeliberationState] {
        let stream = await service.stateUpdates()
        let collectionTask = Task {
            var states: [DeliberationState] = []
            for await state in stream {
                states.append(state)
            }
            return states
        }
        await service.startSession(question: question)
        return await collectionTask.value
    }

    // MARK: - Local failure-injection doubles

    private struct TestStorageError: Error {}

    /// Store whose `saveEpisode` always throws, to exercise the swallowed-error path.
    private actor FailingMemoryStore: MemoryStore {
        private(set) var saveEpisodeAttempts = 0

        func saveEpisode(_ episode: EpisodicGist) async throws {
            saveEpisodeAttempts += 1
            throw TestStorageError()
        }

        func episodes(matching filter: MemoryFilter) async throws -> [EpisodicGist] { [] }
        func updateEpisode(_ episode: EpisodicGist) async throws {}
        func deleteEpisode(id: UUID) async throws {}
        func lockEpisode(id: UUID, isLocked: Bool) async throws {}
        func temporalFacts(for purpose: AccessPurpose) async throws -> [TemporalFact] { [] }
        func temporalFacts(matching filter: MemoryFilter) async throws -> [TemporalFact] { [] }
        func saveFact(_ fact: TemporalFact) async throws {}
        func deleteFact(id: UUID) async throws {}
    }

    /// Audit log whose `append` always throws, to exercise the swallowed-error path.
    private actor FailingAuditLog: AuditLog {
        private(set) var appendAttempts = 0

        func append(_ entry: AuditEntry) async throws {
            appendAttempts += 1
            throw TestStorageError()
        }

        func entries(for sessionID: UUID?) async throws -> [AuditEntry] { [] }
    }

    // MARK: - Audit chain completeness

    /// A full successful session must write the complete, ordered audit sequence and
    /// persist exactly one episode whose contents match the final state. This covers
    /// the service → persistence path that previously had zero coverage.
    @Test func fullSessionWritesCompleteOrderedAuditChainAndEpisode() async throws {
        let provider = MockInferenceProvider(cannedResponses: Self.standardResponses, chunkDelayNanoseconds: 0)
        let store = MockMemoryStore()
        let auditLog = MockAuditLog()
        let memoryService = MemoryService(store: store, auditLog: auditLog)
        let service = DeliberationService(
            provider: provider,
            council: PurchaseCouncil(),
            validators: [ConstitutionalPerspectiveValidator()],
            context: RoutableProfileContext(),
            options: InferenceOptions(),
            memoryService: memoryService
        )

        let states = await Self.collectStates(service: service, question: "Should I buy a new laptop?")
        let finalState = try #require(states.last)
        #expect(finalState.stage == .presentation)

        let entries = await auditLog.entries
        let categories = entries.map(\.category)
        // PINNED GAP: the synthesis and dissent-preservation stages emit no
        // `.agentCalled`/`.stageTransition` entries today; the sequence below pins
        // the current shape, including that hole.
        let expected: [AuditCategory] = [
            .sessionStarted,
            .stageTransition, // firstOpinions
            .memoryAccess,
            .agentCalled, .agentCalled, .agentCalled, .agentCalled, // first opinions
            .stageTransition, // peerReview
            .agentCalled, .agentCalled, .agentCalled, .agentCalled, // peer reviews
            .routeDecision,
            .perspectiveProduced,
        ]
        try #require(entries.count == expected.count)
        #expect(categories == expected)

        // Every entry is attributed to the completed session.
        #expect(entries.allSatisfy { $0.sessionID == finalState.sessionID })
        #expect(entries.first?.payload["question"] == "Should I buy a new laptop?")
        #expect(entries[1].payload["stage"] == "firstOpinions")
        #expect(entries[2].payload["purpose"] == AccessPurpose.purchaseDeliberation.rawValue)
        #expect(entries[2].payload["decision"] == "allowed")
        for entry in entries[3...6] {
            #expect(entry.payload["stage"] == "firstOpinions")
        }
        #expect(entries[7].payload["stage"] == "peerReview")
        for entry in entries[8...11] {
            #expect(entry.payload["stage"] == "peerReview")
        }

        // The service itself persisted exactly one episode matching the final state.
        let episodes = try await store.episodes(matching: MemoryFilter())
        #expect(episodes.count == 1)
        let episode = try #require(episodes.first)
        #expect(episode.sessionID == finalState.sessionID)
        #expect(episode.question == "Should I buy a new laptop?")
        #expect(episode.perspective.summary == finalState.perspective?.summary)
        #expect(episode.perspective.dissent == finalState.perspective?.dissent)
    }

    // MARK: - Persistence/audit failure silence (pinned gap)

    /// PINNED GAP (Phase-1 TODO): if episode persistence and audit appends throw,
    /// the session still completes and is indistinguishable from a persisted run —
    /// same final state, no error signal, and (because audit writes also fail) no
    /// trace of the loss. This pins the gap so it cannot be forgotten or widen.
    @Test func persistenceAndAuditFailuresAreSilent_knownGap() async throws {
        let provider = MockInferenceProvider(cannedResponses: Self.standardResponses, chunkDelayNanoseconds: 0)
        let store = FailingMemoryStore()
        let auditLog = FailingAuditLog()
        let memoryService = MemoryService(store: store, auditLog: auditLog)
        let service = DeliberationService(
            provider: provider,
            council: PurchaseCouncil(),
            validators: [ConstitutionalPerspectiveValidator()],
            context: RoutableProfileContext(),
            options: InferenceOptions(),
            memoryService: memoryService
        )

        let states = await Self.collectStates(service: service, question: "Should I buy a new laptop?")
        let finalState = try #require(states.last)

        // The user sees a completed deliberation that was never saved.
        #expect(finalState.stage == .presentation)
        #expect(finalState.perspective != nil)
        #expect(finalState.errorMessage == nil)

        // Persistence and audit writes were attempted — and silently swallowed.
        #expect(await store.saveEpisodeAttempts == 1)
        #expect(await auditLog.appendAttempts > 0)
        #expect(try await store.episodes(matching: MemoryFilter()).isEmpty)
    }

    // MARK: - Retry-budget exhaustion

    /// Regression: exhausting the retry budget throws `DeliberationError.invalidPerspective`,
    /// which the sanitizer previously mis-classified as a generic "deliberationFailed"
    /// (the type name contains neither "Validation" nor "Inference"). The sanitized
    /// category must be accurate and must not leak the raw validator reason.
    @Test func retryBudgetExhaustionFailsWithSanitizedError() async throws {
        // First 8 responses valid; the always-invalid synthesis repeats from index 8.
        var responses = Array(Self.standardResponses.prefix(8))
        responses.append(#"{"summary": "You should buy this.", "tradeOffs": [], "blindSpots": [], "dissent": ["d"]}"#)
        let provider = MockInferenceProvider(cannedResponses: responses, chunkDelayNanoseconds: 0)
        let store = MockMemoryStore()
        let auditLog = MockAuditLog()
        let memoryService = MemoryService(store: store, auditLog: auditLog)
        let service = DeliberationService(
            provider: provider,
            council: PurchaseCouncil(),
            validators: [ConstitutionalPerspectiveValidator()],
            context: RoutableProfileContext(),
            options: InferenceOptions(),
            memoryService: memoryService
        )

        let states = await Self.collectStates(service: service, question: "q")
        let finalState = try #require(states.last)

        #expect(finalState.stage == .failed)
        #expect(finalState.errorMessage == "validationFailed")
        // The raw validator reason must not leak into the user-facing error.
        #expect(finalState.errorMessage?.contains("Verdict language") == false)

        // Default budget: 1 + 2 synthesis attempts, each followed by 4 dissent calls.
        #expect(await provider.calls.count == 8 + 3 * 5)

        let entries = await auditLog.entries
        let errorEntry = entries.first(where: { $0.category == .error })
        #expect(errorEntry?.payload["category"] == "validationFailed")
        #expect(errorEntry?.sessionID == finalState.sessionID)
        #expect(!entries.contains(where: { $0.category == .perspectiveProduced }))
        #expect(try await store.episodes(matching: MemoryFilter()).isEmpty)
    }

    // MARK: - Deterministic cancellation

    /// Cancels mid-dissent-preservation with a deterministic hand-off (the 20 ms
    /// chunk delay holds the stage open until the cancel lands), then asserts the
    /// terminal state, the audit trail, and a finished stream. Replaces the racy
    /// first-opinions cancellation test.
    @Test func cancelDuringDissentPreservationStopsCleanly() async throws {
        let provider = MockInferenceProvider(
            cannedResponses: Self.standardResponses,
            chunkDelayNanoseconds: 20_000_000
        )
        let store = MockMemoryStore()
        let auditLog = MockAuditLog()
        let memoryService = MemoryService(store: store, auditLog: auditLog)
        let service = DeliberationService(
            provider: provider,
            council: PurchaseCouncil(),
            validators: [ConstitutionalPerspectiveValidator()],
            context: RoutableProfileContext(),
            options: InferenceOptions(),
            memoryService: memoryService
        )

        let stream = await service.stateUpdates()
        let collectionTask = Task {
            var states: [DeliberationState] = []
            for await state in stream {
                states.append(state)
                if state.stage == .dissentPreservation {
                    Task {
                        await service.cancel()
                    }
                }
            }
            return states
        }

        await service.startSession(question: "Should I buy a new laptop?")
        let states = await collectionTask.value

        // `.cancelled` is the terminal state and the stream finished promptly.
        #expect(states.last?.stage == .cancelled)
        #expect(states.last?.perspective == nil)

        let entries = await auditLog.entries
        #expect(entries.contains(where: { $0.category == .cancellation }))
        #expect(!entries.contains(where: { $0.category == .perspectiveProduced }))
        #expect(try await store.episodes(matching: MemoryFilter()).isEmpty)
    }

    // MARK: - Unbounded accumulation (pinned gap)

    /// PINNED GAP: there is no response-size cap anywhere in the pipeline. A 1 MB
    /// synthesis lands untruncated in the final state *and* in the persisted
    /// episode. (Prompt growth across retries is additionally quadratic because the
    /// full prior-output pool is re-serialized into every chair prompt.)
    @Test func hugeResponseIsAccumulatedAndPersistedUnbounded() async throws {
        let hugeSummary = String(repeating: "a", count: 1_000_000)
        var responses = Self.standardResponses
        responses[8] = #"{"summary": ""# + hugeSummary + #"", "tradeOffs": ["t"], "blindSpots": ["b"], "dissent": ["d"]}"#
        let provider = MockInferenceProvider(cannedResponses: responses, chunkDelayNanoseconds: 0)
        let store = MockMemoryStore()
        let auditLog = MockAuditLog()
        let memoryService = MemoryService(store: store, auditLog: auditLog)
        let service = DeliberationService(
            provider: provider,
            council: PurchaseCouncil(),
            validators: [ConstitutionalPerspectiveValidator()],
            context: RoutableProfileContext(),
            options: InferenceOptions(),
            memoryService: memoryService
        )

        let states = await Self.collectStates(service: service, question: "q")
        let finalState = try #require(states.last)
        #expect(finalState.stage == .presentation)
        #expect(finalState.perspective?.summary.count == 1_000_000)

        let episodes = try await store.episodes(matching: MemoryFilter())
        #expect(episodes.first?.perspective.summary.count == 1_000_000)
    }
}
