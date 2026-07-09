# Council Swift Rewrite — Architecture Document v2

**Status:** Locked architecture v2.1 for Phase 1 — Purchase Council v1  
**Date:** 2026-07-07  
**Governance:** SDL-governed client work  
**Scope:** Swift 6, SwiftUI, Apple platforms (iOS 17 / macOS 14 / iPadOS 17 / visionOS 1+)  
**Authority:** Locked PRD `council-swift-implementation-prd-v2.1.md`  
**Revisions:** v2.1 incorporates sibling-agent review feedback from the PRD v1/v2 review and the architecture v1 review.

> **Historical note:** This document was renamed from `council-swift-migration-architecture-v2.1.md` to `council-swift-implementation-architecture-v2.1.md` after the project retired the "migration" framing in favor of "implementation" naming.

---

## 1. Design principles

The Swift architecture translates the Council Constitution and the locked PRD into code-level boundaries. Every major decision below is traceable to one of these principles.

| Principle | Constitutional / PRD source | Architectural consequence |
|-----------|----------------------------|---------------------------|
| **User sovereignty** | Constitution §2, §9 | The app produces a `Perspective`, never a verdict. The final decision object contains only maps, trade-offs, blind-spots, and dissent. |
| **Non-manipulation** | Constitution §3 | UI is state-driven, not engagement-optimized. Animations respect `accessibilityReduceMotion`. No agent is permitted to optimize for conversion, platform growth, or sales. |
| **Privacy by architecture** | Constitution §4, PRD §6 | Profile vault is encrypted inside the sandbox; keys live in Keychain / Secure Enclave. Default compute path is Apple on-device only. |
| **Epistemic humility** | Constitution §5 | Agents declare uncertainty; dissent is a first-class field in the output schema; the Chair cannot suppress minority notes. |
| **Growth of freedom** | Constitution §6 | Prompts are tuned to expand options and surface blind spots, not collapse the user into a single recommendation. |
| **Transparency** | Constitution §12 | A memory inspector exposes every stored fact, gist, and audit entry; the user can inspect, edit, delete, or lock. |
| **Local-first by default** | PRD §5.1 | `InferenceProvider` defaults to an on-device MLX stack. Third-party routes require explicit per-feature consent and data-class clearance. |
| **Kill switch** | PRD F12 | A single `Task` tree owns a deliberation; cancellation discards partial output and stops all downstream inference. |
| **Source-grounding** | PRD §2 policy note | Every OS/SDK/API claim is pinned to a minimum version with a source reference; Apple 27-family APIs are availability-gated. |
| **Constitutional versioning** | PRD §8, Constitution preamble | The runtime loads the canonical constitution text from a bundled, versioned Markdown file. Upgrading the constitution is manual and user-approved. |

### 1.1 Constitutional versioning

- The canonical Phase 1 text is shipped as `Resources/Constitution.v1.md` in `CouncilCore` and loaded at runtime by `ConstitutionService`.
- Prompts reference the live bundled text, not hard-coded strings, so the same binary always deliberates against the same normative scaffold.
- A future constitution change requires a new bundled file (e.g., `Constitution.v2.md`), a runtime version check, and an explicit user-approval flow before the new text is used for deliberation. Migrations are never automatic.

---

## 2. Module/package structure

Council is delivered as a SwiftPM package (`Council`) plus a thin Xcode app target (`CouncilApp`) for entitlements, assets, and platform-specific entry points.

```
Council/
├── Package.swift
├── Sources/
│   ├── CouncilCore/          # Domain models, protocols, constitution types
│   ├── CouncilAgents/        # Agent definitions, prompts, orchestration
│   ├── CouncilInference/     # Concrete inference providers (MLX, mock/test)
│   ├── CouncilMemory/        # Profile vault, memory store, audit log
│   ├── CouncilUI/            # SwiftUI views + @Observable view models
│   └── CouncilApp/           # App entry point, entitlements, resources
└── Tests/
    ├── CouncilCoreTests/
    ├── CouncilAgentsTests/
    ├── CouncilInferenceTests/
    ├── CouncilMemoryTests/
    ├── CouncilUITests/
    └── CouncilPerformanceTests/
```

### Target dependency graph

```
CouncilApp
├── CouncilUI
│   ├── CouncilAgents
│   │   └── CouncilCore
│   ├── CouncilMemory
│   │   └── CouncilCore
│   └── CouncilCore
└── CouncilInference
    └── CouncilCore

CouncilAgents
└── CouncilCore

CouncilMemory
└── CouncilCore

CouncilInference
└── CouncilCore
```

`CouncilApp` also imports `CouncilInference` **only** in `CompositionRoot` to construct the concrete `MLXInferenceProvider` and inject it into `CouncilAgents` as `any InferenceProvider`. `CouncilAgents` has **no** compile-time dependency on `CouncilInference`.

### Target responsibilities

| Target | Responsibility | Public surface |
|--------|---------------|----------------|
| `CouncilCore` | Domain models, protocols, constitution text, routing policy, data-classification types, result types. | `InferenceProvider`, `Agent`, `Council`, `DeliberationSession`, `Perspective`, `ProfileVault`, `MemoryStore`, `AuditLog`, `DataClass`, `RouteDecision`, `RoutableProfileContext`. |
| `CouncilAgents` | Agent role definitions, prompt builders, the deliberation state machine, output parsers, orchestrator, output validators. | `PurchaseCouncil`, `AgentRole`, `DeliberationService`, `PromptBuilder`, `PerspectiveParser`, `PerspectiveValidator`, `ConstitutionalPerspectiveValidator`. |
| `CouncilInference` | Concrete inference providers: `MLXInferenceProvider`, mock/test providers, model container lifecycle, token streaming, route-decision records. | `MLXInferenceProvider`, `ModelContainerPool`, `InferenceOptions`, `ModelManifestService`. |
| `CouncilMemory` | Encrypted profile vault, GRDB stores with CryptoKit field encryption, audit log, key management, purpose-bound access control. | `GRDBMemoryStore`, `GRDBAuditLog`, `CryptoKitProfileVault`, `ProfileKeyManager`. |
| `CouncilUI` | SwiftUI views, `@Observable` view models, navigation, session UI, agent cards, memory inspector, model-settings sheet. | `SessionViewModel`, `SessionView`, `AgentCardView`, `MemoryInspectorView`, `ModelSettingsView`. |
| `CouncilApp` | `App` protocol conformance, entitlements, privacy manifest, assets, platform entry points, dependency wiring. | `CouncilApp`, `CompositionRoot`. |

### Why not one target?

Separation enforces the layered architecture at build time: `CouncilCore` has no framework dependencies; `CouncilUI` cannot import `CouncilInference` directly; `CouncilMemory` cannot import `CouncilAgents`; and `CouncilAgents` cannot see `MLXInferenceProvider` or `ModelContainer`. This prevents accidental violations of the security model (e.g., UI code holding a model container, or an agent depending on a concrete inference implementation) and makes unit testing with mocks trivial.

---

## 3. Layered architecture

```
┌─────────────────────────────────────────┐
│  App Layer (CouncilApp)                 │  App entry, composition root, entitlements
├─────────────────────────────────────────┤
│  UI Layer (CouncilUI)                   │  SwiftUI views, @Observable view models
├─────────────────────────────────────────┤
│  Service / Use-Case Layer (CouncilAgents│  DeliberationService, PromptBuilder, Parser,
│                                         │  PerspectiveValidator
├─────────────────────────────────────────┤
│  Domain Layer (CouncilCore)             │  Models, protocols, constitution, policy,
│                                         │  InferenceProvider abstraction
├─────────────────────────────────────────┤
│  Infrastructure Layer                   │
│   ├── CouncilInference (MLX, model)     │  On-device inference, token streaming
│   ├── CouncilMemory (GRDB + CryptoKit)  │  Persistence, encryption, audit
│   └── CryptoKit / Keychain              │  Keys, Secure Enclave wrapping
└─────────────────────────────────────────┘
```

### Dependency rule

Arrows point downward. Higher layers depend on protocols defined in `CouncilCore`; lower layers conform to those protocols. The `CompositionRoot` in `CouncilApp` injects concrete implementations.

| Layer | Examples | Rules |
|-------|----------|-------|
| App | `CouncilApp`, `CompositionRoot` | Wires concrete types; sets entitlements; owns the `Logger`. Imports `CouncilInference` only to instantiate the injected provider. |
| UI | `SessionView`, `SessionViewModel` | `@MainActor` by default; converts user intent into service calls; renders `AsyncStream` output. |
| Service | `DeliberationService`, `PromptBuilder`, `PerspectiveValidator` | Actor-isolated; owns the deliberation state machine; never leaks infrastructure types. |
| Domain | `Perspective`, `Agent`, `RouteDecision`, `RoutableProfileContext` | Pure `Sendable` structs/protocols; no `Foundation` UI or framework dependencies beyond `CryptoKit` for data classes. |
| Infrastructure | `MLXInferenceProvider`, `GRDBMemoryStore`, `CryptoKitProfileVault` | Implements domain protocols; runs on dedicated actors; handles cancellation, encryption, and file I/O. |

---

## 4. Core types and protocols

All protocols live in `CouncilCore` and are `Sendable` where appropriate.

### 4.1 `InferenceProvider`

```swift
public protocol InferenceProvider: Sendable {
    /// Stream tokens for a single completion.
    func generate(
        messages: [InferenceMessage],
        options: InferenceOptions
    ) async throws -> AsyncThrowingStream<String, Error>

    /// Route metadata used by the audit log and settings UI.
    var routeSnapshot: RouteSnapshot { get async }
}

public struct InferenceMessage: Sendable {
    public let role: MessageRole  // system, user, assistant
    public let content: String
}

public struct InferenceOptions: Sendable {
    public var temperature: Double
    public var maxTokens: Int
    public var stopSequences: [String]
    public var jsonMode: Bool
    public var retryBudget: RetryBudget
}
```

### 4.2 `ProfileVault`

```swift
public protocol ProfileVault: Sendable {
    func load() async throws -> UserProfile
    func save(_ profile: UserProfile) async throws
    func exportEncryptedBlob() async throws -> Data
    func replaceFromEncryptedBlob(_ data: Data) async throws
}

public struct UserProfile: Codable, Sendable {
    public var values: [ValueStatement]
    public var goals: [Goal]
    public var boundaries: [Boundary]
    public var financialHistory: ClientConfidentialContainer?  // never routed to LLM
    public var journalExcerpts: ClientConfidentialContainer?   // never routed to LLM
}
```

### 4.3 `RoutableProfileContext`

Agents must not receive the full `UserProfile`, because that type contains `ClientConfidentialContainer` fields by construction. The orchestrator passes only a purpose-bound `RoutableProfileContext`.

```swift
public struct RoutableProfileContext: Codable, Sendable {
    public let values: [ValueStatement]
    public let goals: [Goal]
    public let boundaries: [Boundary]
    public let accessPurpose: AccessPurpose
}

public extension UserProfile {
    func routableContext(for purpose: AccessPurpose) -> RoutableProfileContext {
        RoutableProfileContext(
            values: values,
            goals: goals,
            boundaries: boundaries,
            accessPurpose: purpose
        )
    }
}
```

### 4.4 `MemoryStore`

```swift
public protocol MemoryStore: Sendable {
    func saveEpisode(_ episode: EpisodicGist) async throws
    func episodes(matching filter: MemoryFilter) async throws -> [EpisodicGist]
    func updateEpisode(_ episode: EpisodicGist) async throws
    func deleteEpisode(id: UUID) async throws
    func lockEpisode(id: UUID) async throws

    func temporalFacts(for purpose: AccessPurpose) async throws -> [TemporalFact]
    func saveFact(_ fact: TemporalFact) async throws
}
```

### 4.5 `AuditLog`

```swift
public protocol AuditLog: Sendable {
    func append(_ entry: AuditEntry) async throws
    func entries(for sessionID: UUID?) async throws -> [AuditEntry]
}

public struct AuditEntry: Codable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let timestamp: Date
    public let category: AuditCategory
    public let payload: AuditPayload
    public let previousHash: String
    public let hmac: String  // HMAC-SHA-256 of canonical serialization
}
```

### 4.6 `Agent`

```swift
public protocol Agent: Sendable {
    var role: AgentRole { get }
    var accessPurpose: AccessPurpose { get }

    /// Build the complete prompt for this agent at a given stage.
    /// Receives only `RoutableProfileContext`, so `ClientConfidentialContainer`
    /// is inaccessible by construction.
    func prompt(
        question: String,
        profile: RoutableProfileContext,
        memory: [TemporalFact],
        stage: DeliberationStage,
        context: DeliberationContext
    ) throws -> [InferenceMessage]
}

public struct AgentRole: Hashable, Sendable {
    public let id: String
    public let name: String
    public let stance: String
    public let scope: String
}
```

### 4.7 `PerspectiveValidator`

```swift
public protocol PerspectiveValidator: Sendable {
    /// Throws `PerspectiveValidationError` if the perspective violates
    /// constitutional constraints (e.g., verdict language, suppressed dissent).
    func validate(_ perspective: Perspective, question: String) throws
}

public struct ConstitutionalPerspectiveValidator: PerspectiveValidator {
    public init() {}

    public func validate(_ perspective: Perspective, question: String) throws {
        let lowercased = perspective.summary.lowercased()
        let forbiddenVerdictPhrases = [
            "you should buy", "you should not buy", "buy it", "don't buy",
            "recommendation is", "verdict is", "the answer is yes",
            "the answer is no"
        ]
        if forbiddenVerdictPhrases.contains(where: lowercased.contains) {
            throw PerspectiveValidationError.verdictLanguageDetected
        }
        if perspective.dissent.isEmpty {
            throw PerspectiveValidationError.emptyDissent
        }
    }
}
```

### 4.8 `Council`

```swift
public protocol Council: Sendable {
    var id: String { get }
    var name: String { get }
    var agents: [any Agent] { get }
    var chair: any Agent { get }
    var stages: [DeliberationStage] { get }
}
```

### 4.9 `DeliberationSession`

```swift
public struct DeliberationSession: Identifiable, Sendable {
    public let id: UUID
    public let councilID: String
    public let question: String
    public let startedAt: Date
    public internal(set) var state: DeliberationState
    public internal(set) var events: [DeliberationEvent]
}
```

### 4.10 `Perspective`

```swift
public struct Perspective: Codable, Sendable {
    public let summary: String
    public let tradeOffs: [TradeOff]
    public let blindSpots: [BlindSpot]
    public let dissent: [DissentNote]
    public let chairConfidence: Confidence?  // nil in v1; reserved
    public let routeDecision: RouteDecision
    public let auditSessionID: UUID
}
```

---

## 5. Deliberation state machine

The five-stage protocol is implemented as a deterministic state machine owned by `DeliberationService` and executed on a private `DeliberationActor`.

### 5.1 `DeliberationService` vs. `DeliberationActor`

- `DeliberationService` is a **public, nonisolated struct/class** held by view models. It exposes the API the UI layer calls.
- `DeliberationActor` is a **private actor** inside `DeliberationService` that owns the mutable state machine, the current `Task`, and the state stream continuation.
- View models call `DeliberationService` methods; the service forwards to the actor with `await`, crossing the actor boundary cleanly.

```swift
public final class DeliberationService: Sendable {
    private let actor: DeliberationActor

    public init(
        provider: any InferenceProvider,
        council: any Council,
        memory: any MemoryStore,
        audit: any AuditLog,
        validators: [any PerspectiveValidator]
    ) {
        self.actor = DeliberationActor(
            provider: provider,
            council: council,
            memory: memory,
            audit: audit,
            validators: validators
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

private actor DeliberationActor {
    private var sessionTask: Task<Void, Never>?
    private var stateContinuation: AsyncStream<DeliberationState>.Continuation?
    private let provider: any InferenceProvider
    private let council: any Council
    private let memory: any MemoryStore
    private let audit: any AuditLog
    private let validators: [any PerspectiveValidator]

    init(...) { ... }

    func stateUpdates() -> AsyncStream<DeliberationState> {
        AsyncStream { continuation in
            self.stateContinuation = continuation
        }
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
    }
}
```

### 5.2 States

```swift
public enum DeliberationState: Sendable, Equatable {
    case idle
    case preparing
    case firstOpinions(progress: FirstOpinionsProgress)
    case peerReview(progress: PeerReviewProgress)
    case synthesis(progress: SynthesisProgress)
    case dissentPreservation(progress: DissentProgress)
    case presentation(Perspective)
    case cancelled
    case failed(DeliberationError)
}
```

### 5.3 Events

```swift
public enum DeliberationEvent: Sendable {
    case started(question: String)
    case profileLoaded
    case routeSelected(RouteDecision)
    case agentCalled(AgentRole, stage: DeliberationStage)
    case agentCompleted(AgentRole, stage: DeliberationStage)
    case stageAdvanced(DeliberationStage)
    case perspectiveParsed(Perspective)
    case perspectiveValidationFailed(PerspectiveValidationError)
    case cancelled
    case failed(DeliberationError)
}
```

### 5.4 Transitions

| From | Event | To | Guard / side effect |
|------|-------|----|---------------------|
| `idle` | user starts session | `preparing` | Validate question non-empty; load profile; select inference route. |
| `preparing` | profile + route ready | `firstOpinions` | Run non-chair agents. Concurrency is achieved via a pool of model containers or by sequential inference with prompt/parse overlap. |
| `firstOpinions` | all agents complete | `peerReview` | Each agent reviews every other agent’s opinion. |
| `peerReview` | reviews complete | `synthesis` | Chair drafts perspective. |
| `synthesis` | perspective parsed | `dissentPreservation` | Run `PerspectiveValidator`; if it fails, emit `perspectiveValidationFailed` and retry up to the retry budget. |
| `dissentPreservation` | dissent collected | `presentation` | Final `Perspective` struct emitted; memory + audit persisted. |
| any | cancel | `cancelled` | `Task` cancellation propagates; partial output discarded. |
| any | unrecoverable error | `failed` | Error logged; state frozen for inspection. |

### 5.5 Validator integration

```swift
private func validatePerspective(_ perspective: Perspective, question: String) throws {
    for validator in validators {
        try validator.validate(perspective, question: question)
    }
}
```

If validation fails, the state machine emits `.perspectiveValidationFailed(...)` and re-prompts the Chair with an explicit correction instruction (up to `InferenceOptions.retryBudget`). If retries are exhausted, the session moves to `.failed(.perspectiveValidationFailure)`.

### 5.6 Implementation notes

- The state machine is a private `actor` (`DeliberationActor`) inside `DeliberationService`.
- State transitions emit an `AsyncStream<DeliberationState>` consumed by the view model.
- Cancellation is cooperative: every `await inferenceProvider.generate(...)` checks `Task.isCancelled` between tokens and throws `CancellationError`.
- Retries are per-stage and bounded; a failure after retries moves the whole session to `failed`.

---

## 6. Agent design

### 6.1 Built-in agents (Purchase Council v1)

| ID | Name | Stance | Access purpose |
|----|------|--------|----------------|
| `frugal` | Frugal | Minimize spend, maximize utility per dollar. | `purchaseEvaluation` |
| `future-self` | Future Self | Protect long-term values, regrets, and goals. | `valuesAndGoals` |
| `systems-thinker` | Systems Thinker | Surface hidden costs, second-order effects, and maintenance burden. | `purchaseEvaluation` |
| `pleasure` | Pleasure Agent | Champion joy, aesthetics, and present quality of life without guilt; framed as options, not a recommendation. | `purchaseEvaluation` |
| `chair` | Chair | Synthesize a balanced perspective, preserve dissent, never decide for the user. | `synthesis` (limited profile access) |

### 6.2 Prompt construction

Every prompt is built by `PromptBuilder` and follows a strict template:

1. **Constitutional preamble** — loaded from the bundled `Constitution.v1.md`; identical for all agents; includes hard constraints and the perspective-not-verdict rule.
2. **Role system prompt** — fixed per `AgentRole`.
3. **Filtered profile context** — only `RoutableProfileContext` fields whose `accessPurpose` matches the agent’s purpose.
4. **Stage instructions** — e.g., “submit your first opinion” vs. “critique the opinions below.”
5. **Structured output schema** — JSON/Codable schema for that stage.
6. **Question** — the user’s original purchase question.
7. **Working memory** — previous stage outputs, redacted where necessary.

```swift
public struct PromptBuilder {
    public func messages(
        for agent: any Agent,
        stage: DeliberationStage,
        question: String,
        profile: UserProfile,
        memory: [TemporalFact],
        context: DeliberationContext
    ) throws -> [InferenceMessage] {
        let routableProfile = profile.routableContext(for: agent.accessPurpose)
        let filteredFacts = memory.filter { $0.accessScope.allows(agent.accessPurpose) }
        return [
            .system(constitutionPreamble),
            .system(agent.role.systemPrompt),
            .system(stage.instructions),
            .user(question),
            .user("Profile context: \(routableProfile.jsonSnippet)"),
            .user("Relevant memory: \(filteredFacts.jsonSnippet)"),
            .user("Working context: \(context.redactedForAgent(agent))"),
            .system("Return valid JSON matching: \(stage.outputSchema)")
        ]
    }
}
```

Because `Agent.prompt` takes `RoutableProfileContext`, no agent implementation can accidentally reference `UserProfile.financialHistory` or `UserProfile.journalExcerpts`. The type system enforces the data-class boundary.

### 6.3 Profile context filtering

- `AccessPurpose` is an enum: `purchaseEvaluation`, `valuesAndGoals`, `synthesis`, `none`.
- `ClientConfidentialContainer` fields (`financialHistory`, `journalExcerpts`) are excluded from every agent context in Phase 1; they are stored for the memory inspector only.
- A fact can be `locked`; locked facts are excluded from agent context but retained in storage.
- The Chair has the most restricted access: only high-level values/goals and synthesized notes from previous stages, never raw confidential containers.

### 6.4 Dissent preservation

- The `dissentPreservation` stage explicitly asks each agent: “If you disagree with any part of the Chair’s synthesis, state your objection, the basis, and the conditions under which you would change your mind.”
- The Chair prompt includes: “You must include every substantive dissent note in the final `dissent` array verbatim. Do not dilute or explain away dissent.”
- `ConstitutionalPerspectiveValidator` rejects perspectives with an empty `dissent` array unless all agents explicitly affirm (which itself must be recorded in the audit log).

### 6.5 Sycophancy resistance

- Agents are addressed by role, not by the user, reducing ingratiation.
- The Chair is instructed to consider the user’s question independently of apparent preference.
- System prompts include: “Do not agree with other agents merely to reach consensus. A council with no disagreement is a bug.”
- The Pleasure Agent is explicitly constrained to frame its output as “options to consider,” not as a recommendation or purchase directive.

---

## 7. Inference abstraction

### 7.1 Protocol design

`InferenceProvider` (see §4.1) is the only abstraction the orchestrator knows. This allows tests and future routes to swap providers without touching `CouncilAgents`.

### 7.2 `MLXInferenceProvider`

The Phase 1 default provider wraps `mlx-swift-lm` 3.31.4. It is **actor-isolated**; the model container(s) it owns are never exposed across actor boundaries. The stream returned from `generate` is `Sendable` and can be consumed by the view model on `@MainActor`.

```swift
import MLXLMCommon

public actor MLXInferenceProvider: InferenceProvider {
    private let modelConfiguration: ModelConfiguration
    private let pool: ModelContainerPool

    public init(
        configuration: ModelConfiguration,
        // Platform-specific default: 2 on macOS, 1 on iOS.
        poolSize: Int = 2
    ) {
        self.modelConfiguration = configuration
        self.pool = ModelContainerPool(configuration: configuration, size: poolSize)
    }

    public func generate(
        messages: [InferenceMessage],
        options: InferenceOptions
    ) async throws -> AsyncThrowingStream<String, Error> {
        let container = try await pool.borrow()
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()

        Task {
            defer { Task { await pool.return(container) } }
            do {
                let mlxMessages: [Message] = messages.map { .init(role: $0.role.rawValue, content: $0.content) }
                let userInput = UserInput(messages: mlxMessages)

                let processor = await container.processor
                let lmInput = try await processor.prepare(input: userInput)

                let tokenStream = try await container.generate(
                    input: lmInput,
                    parameters: options.mlxParameters
                )

                for try await generation in tokenStream {
                    try Task.checkCancellation()
                    if let text = generation.chunk {
                        continuation.yield(text)
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }

        return stream
    }
}
```

Key concurrency rules:
- `MLXInferenceProvider` is an actor. Containers are borrowed and returned through the actor.
- `ModelContainer` is `Sendable` in `mlx-swift-lm` 3.31.4, but each container wraps a `SerialAccessContainer` for model context access. The `ModelContainerPool` is used primarily for **memory and thermal budgeting**, not because a single container is unsafe.
- The returned `AsyncThrowingStream` is `Sendable`; token production happens on the provider’s actor, but consumption can happen anywhere.
- First-opinion concurrency is achieved either by:
  1. Using a `ModelContainerPool` with `poolSize > 1` so independent agents borrow distinct containers (macOS default: 2), or
  2. Running agents sequentially but overlapping prompt construction/parsing for the next agent while the current one generates.
- **iOS default `poolSize` is 1** to stay within the 2 GB peak-memory budget on a 4 GB RAM reference device. macOS may use 2.

### 7.3 Model container lifecycle

- One `ModelContainerPool` per `MLXInferenceProvider` instance.
- `DeliberationService` holds one provider per session, so all agent calls share the pool.
- Container loading is lazy, cancellable, and reported through the audit log.
- Model download is gated by `ModelManifestService`: explicit user consent + checksum/signature verification.

### 7.4 Token streaming and cancellation

- `generate` returns `AsyncThrowingStream<String, Error>`.
- The view model appends tokens to a `String` bound to the UI.
- `Task.checkCancellation()` is called before every yield; cancellation tears down the MLX stream and the continuation.
- A session-wide `Task` owns the state machine; cancelling it propagates to every child inference task.

### 7.5 Route decision and denial record

Every inference call produces a `RouteDecision`:

```swift
public struct RouteDecision: Codable, Sendable {
    public let selectedRoute: RouteSnapshot
    public let deniedRoutes: [DeniedRoute]
    public let consentStatus: ConsentStatus
    public let dataClassClearance: DataClassClearance
}
```

In Phase 1:
- `selectedRoute` is always Apple on-device / MLX.
- `deniedRoutes` includes Apple PCC (not implemented), third-party local (requires opt-in), and third-party cloud (denied by default).
- The record is written to the audit log and embedded in the final `Perspective`.

### 7.6 Future routes

- **Core ML conversion gate:** Before App Store release, MLX models must pass through a Core ML conversion with stateful KV cache, flexible shapes, fused SDPA, and 4-bit quantization. `CoreMLInferenceProvider` will conform to `InferenceProvider`.
- **Third-party local:** A `LlamaCppInferenceProvider` is sketched but disabled by default.
- **Apple PCC:** Reserved for Phase 5; requires attestation verification and explicit per-session approval.

---

## 8. Memory and profile layer

### 8.1 Encrypted profile vault (`CryptoKitProfileVault`)

- Stores `UserProfile` as an AES-256-GCM encrypted JSON blob in `Application Support/Profile/vault.enc`.
- The directory is marked with `NSURLIsExcludedFromBackupKey` so iCloud/iTunes backups skip it.
- File protection: `FileProtectionType.completeUnlessOpen`.
- v1 is device-bound with no escrow. The onboarding flow warns the user explicitly that key loss means permanent lockout.
- Export produces an encrypted blob that can only be decrypted by the same key; it is **not** a plaintext backup.

### 8.2 GRDB schema with field-level CryptoKit encryption

The structured memory store uses a GRDB 7.9.0 build. The whole database file is unencrypted at rest; sensitive columns are encrypted with CryptoKit AES-256-GCM using keys derived from the profile key via HKDF. The database directory is marked with `NSURLIsExcludedFromBackupKey`.

```sql
-- Episodic gists
CREATE TABLE episodic_gists (
    id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL,
    council_id TEXT NOT NULL,
    question TEXT NOT NULL,
    summary TEXT NOT NULL,
    trade_offs_json TEXT NOT NULL,
    blind_spots_json TEXT NOT NULL,
    dissent_json TEXT NOT NULL,
    created_at REAL NOT NULL,
    is_locked INTEGER NOT NULL DEFAULT 0
);

-- Temporal facts
CREATE TABLE temporal_facts (
    id TEXT PRIMARY KEY,
    subject TEXT NOT NULL,
    predicate TEXT NOT NULL,
    object TEXT NOT NULL,
    valid_from REAL,
    valid_until REAL,
    access_scope TEXT NOT NULL,
    source_session_id TEXT,
    is_locked INTEGER NOT NULL DEFAULT 0
);

-- Audit log
CREATE TABLE audit_log (
    id TEXT PRIMARY KEY,
    session_id TEXT,
    timestamp REAL NOT NULL,
    category TEXT NOT NULL,
    payload_json TEXT NOT NULL,
    previous_hash TEXT NOT NULL,
    hmac TEXT NOT NULL
);
```

### 8.3 Key management

#### Secure Enclave profile-key wrapping (default on SEP-capable devices)

1. Generate an ECC P-256 private key inside the Secure Enclave:
   ```swift
   let sePrivateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey()
   ```
2. Generate a random 256-bit AES profile key in memory:
   ```swift
   let profileKey = SymmetricKey(size: .bits256)
   ```
3. Wrap the profile key with ECIES:
   - Create an ephemeral P-256 key-agreement key pair.
   - Derive a shared secret with the Secure Enclave public key.
   - Use HKDF-SHA256 (info = `"com.council.profile.wrap.v1"`) to derive a 256-bit wrapping key.
   - Encrypt the profile key with AES-256-GCM.
   - Persist the ephemeral public key, ciphertext, tag, and Secure Enclave public key in the Keychain.
4. At runtime, the Secure Enclave unwraps the profile key. The private key handle never leaves the enclave.

#### Non-SEP fallback

On devices without a Secure Enclave, generate the AES profile key directly and store it in the Keychain with:

```swift
kSecAttrAccessible = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
```

The onboarding flow must show an explicit warning that the profile key is protected only by the Keychain and the device passcode.

#### Memory/database key derivation

The GRDB field-encryption key is derived from the profile key using HKDF:

```swift
let salt: Data = persistedSalt ?? SecureRandom.bytes(count: 16)
let info = Data("com.council.memory.database.v1".utf8)
let dbKey = HKDF<SHA256>.deriveKey(
    inputKeyMaterial: profileKey,
    salt: salt,
    info: info,
    outputByteCount: 32
)
```

- The 16-byte salt is persisted alongside the database file (salt is not secret) but is also stored in the Keychain as defense in depth.
- The info string is hard-coded and versioned.

#### Key inventory

| Key | Storage | Purpose |
|-----|---------|---------|
| Secure Enclave P-256 key | Secure Enclave + Keychain metadata | Wrap/unwrap the profile key |
| Wrapped profile key | Keychain | AES-GCM encryption of `vault.enc` |
| Profile key (plaintext) | Memory only while vault is unlocked | Encrypt/decrypt profile vault |
| Database salt | File metadata + Keychain | HKDF salt for field-encryption key |
| GRDB field-encryption key | Derived in memory from profile key | Field-level encryption of sensitive columns |
| Audit integrity key | HKDF from memory key (info = `"com.council.audit.integrity.v1"`) | HMAC-SHA-256 audit chain |

### 8.4 Purpose-bound access control

- Every `TemporalFact` carries an `AccessScope` set of `AccessPurpose` values.
- `MemoryStore.temporalFacts(for:)` returns only facts whose scope includes the requested purpose.
- `Agent.accessPurpose` is fixed at compile time for built-in agents.
- Locked facts are excluded from every purpose but retained in the database for the memory inspector.

### 8.5 Audit log integrity

Each audit entry stores `previousHash` and an HMAC-SHA-256 `hmac` over a canonical serialization of:

```
{
  "id": "<uuid>",
  "timestamp": "<ISO-8601>",
  "category": "<category>",
  "payload": "<canonical-json>",
  "previousHash": "<base64>"
}
```

Serialization rules:
- JSON object with keys in lexicographic order.
- No whitespace.
- `payload` itself is canonicalized (sorted keys, stable encoding).

The integrity key is derived from the profile/memory key:

```swift
let integrityKey = HKDF<SHA256>.deriveKey(
    inputKeyMaterial: profileKey,
    salt: Data(),
    info: Data("com.council.audit.integrity.v1".utf8),
    outputByteCount: 32
)
```

The first entry’s `previousHash` is the SHA-256 of a hard-coded genesis string shipped in the app bundle. Verification walks the chain, recomputing the HMAC for each entry and confirming `previousHash` equals the previous entry’s `hmac`. Any mismatch is surfaced to the user and the memory inspector.

Threat model:
- Detects tampering within the app’s trust boundary (e.g., a bug or compromised process that rewrites history).
- Does **not** prevent a root/administrator from deleting the entire database file. “Immutable” in Phase 1 means append-only with integrity verification, not deletion prevention.

---

## 9. Security boundaries

### 9.1 Sandbox containment

- App Sandbox enabled.
- Network entitlement is **optional** and used only for model download / future opt-in features.
- File access is restricted to the app container (`Application Support`, `Caches`, `tmp`).
- Live profile vault never leaves the sandbox; only an encrypted export blob can cross the boundary via user action.

### 9.2 Data-class enforcement

| Data class | Allowed paths | Enforcement |
|------------|--------------|-------------|
| Sensitive personal (profile) | On-device only | `ProfileVault` interface; no network code can import it. |
| Client-confidential (finance/journal) | Memory storage only; never LLM | `ClientConfidentialContainer` is never serialized into prompts; `Agent` receives `RoutableProfileContext` only. |
| Temporal facts / episodic gists | On-device; third-party local with explicit consent | `AccessScope` filtering; route decision gates. |
| Deliberation transcripts | On-device only by default; discarded after gist | `DeliberationService` deletes working context after session. |
| Audio input | On-device speech only | `SFSpeechRecognizer` is checked for `supportsOnDeviceRecognition`; server fallback is blocked/disabled. |
| Audit logs | Local only | No export path; integrity chain verified locally. |
| Keys/credentials | Keychain / Secure Enclave | Never serialized, never routed to any model. |

### 9.3 Export/import rules

- Export is explicit, user-initiated, and produces an encrypted blob.
- Import can only replace the vault from a blob encrypted with the same device key; cross-device restore is deferred to Phase 2.
- No plaintext export of profile, memory, or transcripts is permitted.
- The export flow uses a user-selected save location; `CouncilApp` therefore includes `com.apple.security.files.user-selected.read-write` in addition to `read-only`.

### 9.4 Constitutional boundary statement (Phase 1)

The app’s About screen and onboarding state:

> “Phase 1 relies on prompt-level guardrails, output validation, a manual kill switch, and an audit trail. A full runtime constitutional enforcement engine is scheduled for a later phase.”

This satisfies PRD §8 and closes the governance gap identified in SDL review.

---

## 10. Concurrency model

### 10.1 Swift 6 strict concurrency

- `SWIFT_STRICT_CONCURRENCY = complete` in every target.
- `SWIFT_VERSION = 6.0`.
- All global mutable state is actor-isolated or `Sendable` constants.
- Protocols that cross isolation boundaries are marked `Sendable`.

### 10.2 Actor layout

| Actor | Target | Responsibility |
|-------|--------|----------------|
| `DeliberationActor` | `CouncilAgents` | Owns the state machine; serializes stage transitions. Wrapped by public `DeliberationService`. |
| `MLXInferenceProvider` | `CouncilInference` | Isolates model container pool and MLX calls. Returns `Sendable` streams. |
| `ProfileService` | `CouncilMemory` | Reads/writes encrypted vault; wraps `CryptoKitProfileVault`. |
| `MemoryService` | `CouncilMemory` | Serializes GRDB access; wraps `MemoryStore` + `AuditLog`. |

### 10.3 `MainActor` usage

- View models (`SessionViewModel`, `MemoryInspectorViewModel`) are `@MainActor`.
- UI-bound `AsyncStream` subscriptions are received on `@MainActor`.
- Heavy work (inference, persistence, prompt building) never runs on `MainActor`.

### 10.4 Task cancellation

```swift
public final class SessionViewModel {
    private var deliberationTask: Task<Void, Never>?

    func start(question: String) {
        deliberationTask = Task {
            await service.startSession(question: question)
        }
    }

    func cancel() {
        deliberationTask?.cancel()
        deliberationTask = nil
    }
}
```

- `DeliberationService.startSession` holds a single `Task` and propagates cancellation through every child.
- `MLXInferenceProvider.generate` checks `Task.isCancelled` between tokens.
- Cancellation discards partial output; no `Perspective` is persisted.

### 10.5 Thermal and memory throttling

- First-opinion agent calls run concurrently up to a configurable `thermalBudget`:
  - **iOS default: 1 concurrent inference** (`poolSize = 1`) to stay within the 2 GB peak-memory budget on a 4 GB RAM reference device.
  - **macOS default: 2 concurrent inferences** (`poolSize = 2`) when memory permits.
- Subsequent stages are sequential to reduce peak memory and thermals.
- `ProcessInfo.thermalState` is monitored:
  - `.critical` pauses inference immediately and transitions the session to `.failed(.thermalCritical)` after a short grace period.
  - `.serious` lowers the concurrency budget to 1 on macOS and keeps iOS at 1.
  - `.fair` and `.nominal` use the normal budget.

### 10.6 Performance criteria (go/no-go)

Lowest-supported reference device: **iPhone 12 / 4 GB RAM**.

| Metric | Threshold | Measurement |
|--------|-----------|-------------|
| First-opinion latency | `< 15 s` per agent on a 3 B quantized model (iOS, sequential) | Time from prompt submission to first usable token, averaged over 5 runs. |
| Peak memory | `< 2 GB` during a full session on iOS | Xcode Memory Graph / `os_signpost` peak resident set. |
| Thermal response | Pause at `.critical` | Manual test with thermal simulation. |
| End-to-end latency | `< 90 s` for a complete Purchase Council session on iOS | From start to `.presentation`. |
| macOS latency | `< 8 s` per agent with `poolSize = 2` | Time from prompt submission to first usable token, averaged over 5 runs. |

If the reference device misses any threshold, the implementation must lower the model size, reduce first-opinion concurrency, or gate release until the criteria are met.

---

## 11. UI architecture

### 11.1 View model pattern

View models are `@Observable` classes marked `@MainActor`:

```swift
@MainActor
@Observable
public final class SessionViewModel {
    public private(set) var sessionState: DeliberationState = .idle
    public private(set) var streamingText: String = ""
    public private(set) var error: DeliberationError?

    private let service: DeliberationService
    private var stateTask: Task<Void, Never>?

    public init(service: DeliberationService) {
        self.service = service
    }

    public func start(question: String) { ... }
    public func cancel() { ... }
}
```

### 11.2 Navigation

- **macOS / iPadOS:** `NavigationSplitView` with a sidebar of councils and memory inspector; detail pane shows the active session.
- **iOS:** `NavigationStack` driven by a `Route` enum:
  ```swift
  enum Route: Hashable {
      case councils
      case session(councilID: String)
      case memoryInspector
      case modelSettings
      case about
  }
  ```

### 11.3 Session views

| View | Purpose |
|------|---------|
| `SessionView` | Question input, start/cancel, stage indicator, final perspective. |
| `AgentCardView` | Expandable card showing an agent’s opinion or dissent. |
| `StageIndicatorView` | Visual progress through the five stages; respects reduced motion. |
| `PerspectiveView` | Renders `summary`, `tradeOffs`, `blindSpots`, `dissent`. |
| `MemoryInspectorView` | Lists episodic gists and facts; supports edit, delete, lock. |
| `ModelSettingsView` | Shows active route, model identifier, compute path; route changes require explicit consent. |
| `AboutView` | Constitutional boundary statement, privacy summary, version info. |

### 11.4 Accessibility

- VoiceOver labels on every agent card and stage indicator.
- Dynamic Type support throughout.
- `accessibilityReduceMotion` gates all non-essential motion.
- Color is never the sole indicator of state.

### 11.5 Non-manipulation guardrails

- No infinite scroll, auto-playing animations, or reward sounds.
- Agent cards are ordered by deliberation stage, not by persuasiveness.
- The final screen uses neutral language (“Perspective”) and never a directive (“You should buy”).

### 11.6 Voice input on-device check

Voice input is optional and gated by `SFSpeechRecognizer`:

```swift
func isVoiceInputAvailable() async -> Bool {
    let status = await SFSpeechRecognizer.requestAuthorization()
    guard status == .authorized,
          let recognizer = SFSpeechRecognizer(),
          recognizer.supportsOnDeviceRecognition else {
        return false
    }
    return true
}
```

- If `supportsOnDeviceRecognition` is `false`, the microphone button is disabled and the user sees an explanation.
- Server-based speech recognition is **blocked** in Phase 1; raw audio is never retained; transcripts are classified as personal and discarded after gist generation unless the user explicitly saves them.

---

## 12. Testing strategy

### 12.1 Unit tests

| Target | Focus |
|--------|-------|
| `CouncilCoreTests` | Data classification, routing decisions, `Perspective` validation, constitution text parsing, `RoutableProfileContext` boundary. |
| `CouncilAgentsTests` | Prompt builder output, stage transitions, parser success/failure, dissent preservation, role consistency, `PerspectiveValidator` rejection of verdict language and empty dissent. |
| `CouncilInferenceTests` | Mock provider behavior, model manifest validation, token streaming, cancellation, `MLXInferenceProvider` actor isolation. |
| `CouncilMemoryTests` | Encryption/decryption, GRDB schema migrations, audit chain integrity, purpose-bound filtering, Secure Enclave wrapping fallback. |

### 12.2 Integration tests

- `DeliberationService` with a mocked `InferenceProvider` that returns canned JSON; verifies the full five-stage flow including `PerspectiveValidator` failure and retry.
- `ProfileService` + `MemoryService` integration with an in-memory GRDB database.
- Route decision recording across services.

### 12.3 UI tests

- Start a session from text input.
- Kill switch stops inference and leaves no partial perspective.
- Memory inspector supports inspect, edit, delete, and lock.
- Model settings require explicit consent to change route.
- Voice input button is disabled when `supportsOnDeviceRecognition` is false.

### 12.4 Performance tests

- First-opinion latency per agent on the reference device (`< 15 s`).
- Peak memory during first-opinion concurrency (`< 2 GB`).
- Thermal-state response (pause at `.critical`).
- End-to-end deliberation latency (`< 90 s`).

### 12.5 Security / privacy tests

- Key-extraction resistance: no key material in heap dumps or logs.
- Profile vault file is not plaintext.
- Network interceptor confirms no prompt, profile, or memory content leaves the device by default.
- `ClientConfidentialContainer` never appears in agent prompts.
- Audit HMAC chain verifies and detects tampering.

### 12.6 Sycophancy evaluation

- Fixed test questions with known polarizing framings.
- Assert that at least one agent disagrees with an implied user preference in a significant subset of cases.
- Assert that dissent notes are non-empty when agents are seeded with conflicting stances.
- Assert that `ConstitutionalPerspectiveValidator` rejects seeded verdict language.

---

## 13. Build and dependencies

### 13.1 SwiftPM dependencies

```swift
// Package.swift (excerpt)
// swift-tools-version:6.3
import PackageDescription

let package = Package(
    name: "Council",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .visionOS(.v1),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.31.5"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.31.4"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        // GRDB with application-level CryptoKit field encryption in Phase 1.
        // Full SQLCipher whole-database encryption is a Phase 2 optimization.
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.9.0"),
    ],
    targets: [
        // ...
    ]
)
```

Target dependency examples:

```swift
.target(
    name: "CouncilInference",
    dependencies: [
        "CouncilCore",
        .product(name: "MLXLLM", package: "mlx-swift-lm"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
        .product(name: "HuggingFace", package: "swift-huggingface"),
        .product(name: "Tokenizers", package: "swift-transformers"),
    ]
),
.target(
    name: "CouncilMemory",
    dependencies: [
        "CouncilCore",
        .product(name: "GRDB", package: "GRDB.swift"),
    ]
)
```

If the team prefers to maintain its own fork, fork `groue/GRDB.swift` and add application-level CryptoKit field encryption; full SQLCipher integration remains a Phase 2 option. In that case there is still exactly one GRDB dependency in the package graph.

### 13.2 Xcode project setup

- Xcode 16.3+ / Swift 6.3+ required for swift-tools-version 6.3, Swift 6 strict concurrency, and Apple 26 SDK.
- Swift language version: `SWIFT_VERSION = 6.0`.
- Strict concurrency: `SWIFT_STRICT_CONCURRENCY = complete`.
- Targets: `CouncilApp` (iOS/macOS/visionOS), test targets, and the SwiftPM package.

### 13.3 Entitlements

```xml
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.files.user-selected.read-only</key><true/>
<key>com.apple.security.files.user-selected.read-write</key><true/>
<!-- Network is optional and used only for model download / future opt-in -->
<key>com.apple.security.network.client</key><true/>
```

### 13.4 Capabilities

- Data Protection: `FileProtectionType.completeUnlessOpen`.
- Keychain Sharing: disabled in v1 (device-bound keys).
- Speech Recognition: added only if voice input is enabled; requires `NSSpeechRecognitionUsageDescription`.

### 13.5 Privacy manifest

Required entries:
- `NSPrivacyCollectedDataTypes` — none by default; opt-in telemetry declared separately.
- `NSPrivacyAccessedAPICategories` — justify usage of `NSFileTimestampAPI`, `NSDiskSpaceAPI`, `NSUserDefaultsAPI` if used.
- `NSPrivacyTracking` — false.

---

## 14. Risks and mitigations

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| **MLX build complexity / research status** | High | Medium | Treat MLX as Phase 1 proving path only. Gate App Store release on Core ML conversion. Pin `Package.resolved`. Build CI matrix for macOS + iOS. |
| **Model output reliability (3 B parameter)** | High | High | Use 7 B on macOS, 3 B on iOS. Add schema validation, retries, constrained decoding, `PerspectiveValidator`, and graceful raw-text fallback. |
| **iOS thermal throttling / memory pressure** | High | High | Limit iOS concurrent first-opinion calls to 1 (macOS may use 2). Monitor `ProcessInfo.thermalState`. Benchmark on iPhone 12 / 4 GB RAM; go/no-go criteria: `< 15 s` per agent, `< 2 GB` peak memory, pause at `.critical`. |
| **Sycophancy / consensus pressure** | Medium | High | Prompts require explicit disagreement; dedicated dissent stage; `ConstitutionalPerspectiveValidator` rejects empty dissent; qualitative sycophancy evaluation tests. |
| **Key loss = permanent profile lockout** | Medium | Medium | Onboarding warning; defer passphrase/biometric backup to Phase 2; allow encrypted export. |
| **GRDB/CryptoKit field-encryption binary size and complexity** | Medium | Low | Use vanilla GRDB 7.9.0 with field-level CryptoKit encryption; evaluate SQLCipher whole-database encryption or SwiftData in Phase 2. |
| **Apple 27-only API drift** | Low | Medium | Availability-gate every Apple 27 API; keep Apple 26 the baseline; source-ground every claim. |
| **Prompt leakage of confidential data** | High | Low | `RoutableProfileContext` excludes `ClientConfidentialContainer` by construction; unit tests grep prompt output for forbidden substrings. |

---

## 15. Implementation-sequence sketch

The following order is recommended for the first engineering sprint:

1. `CouncilCore`: protocols, domain models, constitution text, routing policy, data classes, `RoutableProfileContext`.
2. `CouncilInference`: `InferenceProvider` protocol + `MockInferenceProvider`; actor-isolated `MLXInferenceProvider` with `Sendable` stream and container pool.
3. `CouncilMemory`: encrypted profile vault, GRDB store, audit log, key manager (Secure Enclave + fallback).
4. `CouncilAgents`: `PromptBuilder`, agent roles, `PerspectiveValidator`, deliberation state machine with `DeliberationService`/`DeliberationActor` split, output parser.
5. `CouncilUI`: view models, session view, agent cards, kill switch, voice-input availability check.
6. `CouncilApp`: composition root, entitlements, privacy manifest, onboarding.
7. Tests: unit → integration → UI → performance → security.

---

## 16. References

- Locked PRD: `council-swift-implementation-prd-v2.1.md`
- Council Constitution: `CONSTITUTION.md`
- Existing architecture: `docs/ARCHITECTURE.md`
- Plan: `docs/PLAN.md`
- SDL lifecycle record: `1caffbbf-a9b1-42dd-bb5b-14b94f43c675.json` (originally `council-swift-migration.json`)
- Source-grounded Apple references listed in PRD §11.

---

*This architecture document was produced without modifying any repository files. It is ready to guide the implementation plan for Purchase Council v1.*
