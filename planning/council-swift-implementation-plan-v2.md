# Council Swift Rewrite — Implementation Plan v2

**Status:** Locked for implementation  
**Scope:** Purchase Council v1 on iOS 17 / macOS 14 / iPadOS 17 / visionOS 1  
**Date:** 2026-07-07  
**Authority:** Locked PRD `council-swift-implementation-prd-v2.1.md`, locked architecture `council-swift-implementation-architecture-v2.1.md`  
**Branch:** `sdl/council-swift-migration`  
**SDL lifecycle record:** `council-swift-migration`

> **Historical note:** This document was renamed from `council-swift-migration-implementation-plan-v2.md` to `council-swift-implementation-plan-v2.md` after the project retired the "migration" framing in favor of "implementation" naming. The original SDL lifecycle record and branch names referenced inside the document are preserved as historical artifacts.

---

## 1. Overview

This plan turns the locked PRD and architecture into a concrete, phased implementation. The work is organized into four delivery phases. Each phase is self-contained: it builds, tests, and can be reviewed before the next phase starts. Phases are delivered as small, reviewable conventional commits grouped by functional area. Significant milestones are tagged.

**Terminology note:** The locked PRD defines *Phase 1* as the complete Purchase Council v1 deliverable, which includes a minimal memory layer (episodic gist, temporal facts, memory inspector, and audit log). The four phases below are *internal implementation sprints* that together deliver PRD Phase 1. Where this plan says “Phase 1/2/3/4,” it refers to implementation sprints unless explicitly stated otherwise.

### High-level phase map

| Implementation sprint | Focus | Tag | PRD scope delivered |
|---|---|---|---|
| 1 | SwiftPM package scaffold + core domain protocols/types | `v0.1.0-phase1` | PRD Phase 1 foundation |
| 2 | Purchase Council agents + deliberation loop + MLX inference | `v0.1.0-phase2` | PRD Phase 1 deliberation |
| 3 | Encrypted profile vault + GRDB/CryptoKit memory + audit log | `v0.1.0-phase3` | PRD Phase 1 memory + persistence |
| 4 | SwiftUI app + example session + tests + documentation | `v0.1.0-purchase-council` | PRD Phase 1 complete |

### Repository layout

The Swift implementation lives alongside the existing project documentation:

```
/Users/vishalsingh/Documents/v-i-s-h-a-l/github/council-sdl-swift-migration/
├── Council/                         # SwiftPM package
│   ├── Package.swift
│   ├── Package.resolved
│   ├── Sources/
│   │   ├── CouncilCore/
│   │   ├── CouncilAgents/
│   │   ├── CouncilInference/
│   │   ├── CouncilMemory/
│   │   └── CouncilUI/
│   └── Tests/
│       ├── CouncilCoreTests/
│       ├── CouncilAgentsTests/
│       ├── CouncilInferenceTests/
│       ├── CouncilMemoryTests/
│       └── CouncilIntegrationTests/
├── CouncilApp/                      # Thin Xcode app target
│   ├── CouncilApp.xcodeproj
│   ├── CouncilApp/
│   │   ├── CouncilApp.swift
│   │   ├── CompositionRoot.swift
│   │   ├── Info.plist
│   │   ├── CouncilApp.entitlements
│   │   ├── PrivacyInfo.xcprivacy
│   │   └── Assets.xcassets
│   ├── CouncilAppTests/             # Swift unit tests that require XCTest host if needed
│   └── CouncilAppUITests/           # Xcode UI tests (not in SwiftPM)
├── docs/
│   └── PLAN.md                      # updated for PRD Phase 1 memory acceleration
├── examples/
│   └── purchase-council.md
└── README.md                        # updated with build/run instructions
```

The `Council/` SwiftPM package contains the library targets and integration tests; `CouncilApp/` is the Xcode project that embeds the local package, declares entitlements, assets, and the privacy manifest, and wires concrete dependencies in `CompositionRoot.swift`. UI tests live in the Xcode app target because SwiftPM `XCTest` cannot drive the app lifecycle.

### Commit strategy

- Use [Conventional Commits](https://www.conventionalcommits.org/) with scope: `core`, `agents`, `inference`, `memory`, `ui`, `app`, `docs`, `test`, `chore`.
- Every commit message ends with the SDL lifecycle footer:
  ```
  Refs: council-swift-migration
  ```
- Each phase ends with a tag. Tags are lightweight but annotated is acceptable.
- No force-pushes to `sdl/council-swift-migration`. Rebase locally if needed, then merge/rebase-push.

### Tooling assumptions

- Xcode 16.3+ / Swift 6.3+ toolchain.
- Swift 6 language mode enabled via `.swiftLanguageMode(.v6)`.
- Apple Silicon Mac for MLX development; Intel Macs are unsupported for the MLX proving path.
- Optional but recommended: `swiftlint` or `swift-format` for style checks (not blocking in Phase 1 unless CI enforces it).

---

## 2. Phase 1: Swift project scaffold + core runtime

**Goal:** A buildable SwiftPM package with Swift 6 strict concurrency enabled and all core domain types/protocols in place. No inference, memory, or UI code yet.

### 2.1 Directory structure

Create the SwiftPM package and test target skeletons:

```bash
mkdir -p Council/Sources/CouncilCore
mkdir -p Council/Sources/CouncilAgents
mkdir -p Council/Sources/CouncilInference
mkdir -p Council/Sources/CouncilMemory
mkdir -p Council/Sources/CouncilUI
mkdir -p Council/Tests/CouncilCoreTests
mkdir -p Council/Tests/CouncilAgentsTests
mkdir -p Council/Tests/CouncilInferenceTests
mkdir -p Council/Tests/CouncilMemoryTests
mkdir -p Council/Tests/CouncilIntegrationTests
```

### 2.2 `Council/Package.swift`

Create `Council/Package.swift` with the following design:

- `swift-tools-version:6.3` (required by `mlx-swift`).
- Platforms: `.iOS(.v17)`, `.macOS(.v14)`, `.visionOS(.v1)`. **Do not include `.macCatalyst(.v17)`** because MLX does not support macCatalyst.
- Dependencies pinned to exact versions:
  - `mlx-swift` `0.31.5`
  - `mlx-swift-lm` `3.31.4` (which itself depends on `mlx-swift` `.upToNextMinor(from: "0.31.4")`)
  - `GRDB.swift` `7.9.0`
- Targets:
  - `CouncilCore` — no external dependencies.
  - `CouncilAgents` — depends on `CouncilCore`.
  - `CouncilInference` — depends on `CouncilCore`, products `MLXLLM`, `MLXLMCommon`, `MLXHuggingFace` from `mlx-swift-lm`, `MLX` from `mlx-swift`, and `HuggingFace` / `Tokenizers` from the Hugging Face integration packages.
  - `CouncilMemory` — depends on `CouncilCore`, product `GRDB` from `GRDB.swift`.
  - `CouncilUI` — depends on `CouncilCore`, `CouncilAgents`, `CouncilMemory`.
  - `CouncilIntegrationTests` — depends on all library targets; marked as an executable test target.
- Every target sets:
  - `swiftSettings: [.swiftLanguageMode(.v6)]`.
- Add a `CouncilTestUtilities` internal target for shared mocks/fakes if needed.

Example `Package.swift` excerpt:

```swift
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
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.9.0"),
    ],
    targets: [
        .target(name: "CouncilCore"),
        .target(name: "CouncilAgents", dependencies: ["CouncilCore"]),
        .target(
            name: "CouncilInference",
            dependencies: [
                "CouncilCore",
                .product(name: "MLX", package: "mlx-swift"),
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
        ),
        .target(
            name: "CouncilUI",
            dependencies: ["CouncilCore", "CouncilAgents", "CouncilMemory"]
        ),
        .testTarget(name: "CouncilCoreTests", dependencies: ["CouncilCore"]),
        .testTarget(name: "CouncilAgentsTests", dependencies: ["CouncilAgents", "CouncilTestUtilities"]),
        .testTarget(name: "CouncilInferenceTests", dependencies: ["CouncilInference", "CouncilTestUtilities"]),
        .testTarget(name: "CouncilMemoryTests", dependencies: ["CouncilMemory", "CouncilTestUtilities"]),
        .testTarget(
            name: "CouncilIntegrationTests",
            dependencies: [
                "CouncilCore",
                "CouncilAgents",
                "CouncilInference",
                "CouncilMemory",
                "CouncilTestUtilities",
            ]
        ),
    ]
)
```

### 2.3 Core domain types

Implement in `Council/Sources/CouncilCore/`:

| File | Contents |
|---|---|
| `Resources/Constitution.v1.md` | Bundled canonical constitution text (copied from repo `CONSTITUTION.md`). |
| `ConstitutionService.swift` | Loads bundled constitution text by version; exposes `version` and `text`. |
| `InferenceProvider.swift` | `InferenceProvider` protocol, `InferenceMessage`, `InferenceOptions`, `RetryBudget`, `MessageRole`. |
| `RouteDecision.swift` | `RouteSnapshot`, `DeniedRoute`, `ConsentStatus`, `DataClassClearance`, `RouteDecision`. |
| `DataClass.swift` | `DataClass`, `AccessPurpose`, `AccessScope`. |
| `Agent.swift` | `Agent` protocol, `AgentRole`, `DeliberationStage`, `DeliberationContext`. |
| `Council.swift` | `Council` protocol. |
| `Perspective.swift` | `Perspective`, `TradeOff`, `BlindSpot`, `DissentNote`, `Confidence`. |
| `DeliberationSession.swift` | `DeliberationSession`, `DeliberationState`, `DeliberationEvent`, `DeliberationError`. |
| `UserProfile.swift` | `UserProfile`, `ValueStatement`, `Goal`, `Boundary`, `ClientConfidentialContainer`. |
| `RoutableProfileContext.swift` | `RoutableProfileContext` and `UserProfile.routableContext(for:)`. |
| `ProfileVault.swift` | `ProfileVault` protocol. |
| `MemoryStore.swift` | `MemoryStore` protocol, `EpisodicGist`, `TemporalFact`, `MemoryFilter`. |
| `AuditLog.swift` | `AuditLog` protocol, `AuditEntry`, `AuditCategory`, `AuditPayload`. |

All public types crossing isolation boundaries must be `Sendable`. Value types should be `Codable` where persistence is expected. `ClientConfidentialContainer` must be `Codable, Sendable` but never conform to `CustomStringConvertible` that would leak contents.

### 2.4 Initial tests

In `Council/Tests/CouncilCoreTests/`:

- `DataClassTests.swift` — verify data-class hierarchy and allowed compute paths.
- `RoutableProfileContextTests.swift` — verify `financialHistory`/`journalExcerpts` are never included in the routable context.
- `ConstitutionServiceTests.swift` — verify bundled constitution loads and version matches.
- `RouteDecisionTests.swift` — verify denial reason encoding and route snapshot metadata.

### 2.5 Commit group

```text
chore: scaffold SwiftPM package and core protocols

- Add Council/Package.swift with Swift 6 language mode and pinned deps.
- Add CouncilCore target with domain models, protocols, and bundled Constitution.v1.md.
- Add CouncilAgents, CouncilInference, CouncilMemory, CouncilUI target skeletons.
- Add CouncilIntegrationTests target to Package.swift.
- Add CouncilCore unit tests for data class, routable context, and route decisions.

Refs: council-swift-migration
```

### 2.6 Phase 1 verification criteria

Before tagging `v0.1.0-phase1`, the following must pass:

1. `cd Council && swift build` succeeds for all targets on an Apple Silicon Mac.
2. `swift test --filter CouncilCoreTests` passes.
3. No Swift 6 strict-concurrency warnings or errors.
4. `Package.resolved` is committed and reproducible (`swift package resolve` produces identical output).
5. `README.md` is updated with build instructions (done in same commit or a follow-up `docs:` commit within Phase 1).
6. Sibling-agent review confirms the module dependency graph matches architecture §2.

---

## 3. Phase 2: Purchase Council agents + deliberation loop

**Goal:** A working deliberation runtime using the five Purchase Council agents, a deterministic state machine, output parsing/validation, and a streaming MLX inference provider.

### 3.1 Agent layer (`CouncilAgents`)

Implement in `Council/Sources/CouncilAgents/`:

| File | Contents |
|---|---|
| `AgentRole.swift` | Static role definitions for `frugal`, `futureSelf`, `systemsThinker`, `pleasure`, `chair` with fixed system prompts, stances, and access purposes. |
| `Roles/FrugalAgent.swift` | Conforms to `Agent`; access purpose `.purchaseEvaluation`. |
| `Roles/FutureSelfAgent.swift` | Access purpose `.valuesAndGoals`. |
| `Roles/SystemsThinkerAgent.swift` | Access purpose `.purchaseEvaluation`. |
| `Roles/PleasureAgent.swift` | Access purpose `.purchaseEvaluation`; explicitly frames output as options, not recommendations. |
| `Roles/ChairAgent.swift` | Access purpose `.synthesis`; restricted profile access. |
| `PurchaseCouncil.swift` | `PurchaseCouncil: Council` exposing the five agents and five-stage pipeline. |
| `PromptBuilder.swift` | Builds prompt arrays from constitution preamble, role prompt, filtered `RoutableProfileContext`, stage instructions, output schema, question, and working memory. |
| `DeliberationStage.swift` | `DeliberationStage` enum with stage instructions and output schemas. |
| `DeliberationState.swift` | `DeliberationState` enum with associated progress values. |
| `DeliberationEvent.swift` | `DeliberationEvent` enum. |
| `DeliberationService.swift` | Public `DeliberationService` + private `DeliberationActor` state machine. |
| `PerspectiveParser.swift` | Parses raw model output into typed stage outputs and final `Perspective`; includes retry budget and graceful raw-text fallback. |
| `PerspectiveValidation.swift` | `PerspectiveValidationError` enum. |
| `ConstitutionalPerspectiveValidator.swift` | Rejects verdict language and empty dissent. |

Key implementation rules:

- `PromptBuilder` must receive `UserProfile` and produce `RoutableProfileContext` inside the builder so that `ClientConfidentialContainer` cannot leak into prompts.
- `Agent.prompt` must take `RoutableProfileContext`, not `UserProfile`.
- The state machine must run the stages in order: first opinions → peer review → synthesis → dissent preservation → presentation.
- First-opinion agent calls are backed by the `ModelContainerPool`; each borrowed container is managed by its own isolated worker/queue. The default pool size is 2 on macOS and 1 on iOS, limited further by thermal state.
- Cancellation must propagate through every `await` and stop downstream agent calls.

### 3.2 Concurrency model

`MLXLMCommon.ModelContainer` is `Sendable` in `mlx-swift-lm` 3.31.4, but each container wraps a `SerialAccessContainer` for model-context access. The `ModelContainerPool` is used primarily for memory and thermal budgeting, not because a single container is unsafe. Use one of the following concrete models:

**Option A (preferred): `ModelContainerPool` with isolated workers**

- `ModelContainerPool` owns `poolSize` independent `ModelContainerWorker` instances.
- Each worker is either an `actor` or serial `DispatchQueue` that owns exactly one `ModelContainer`.
- `borrow()` returns a `Sendable` ticket/handle (e.g., a value type carrying the worker ID) and the worker reference is never exposed across isolation boundaries.
- `generate` on the worker serializes container access; concurrent first-opinion calls use distinct workers.
- `return(_:)` releases the worker back to the pool.
- Default `poolSize`: 2 on macOS, 1 on iOS.

**Option B (fallback): sequential with prompt/parse overlap**

- Drop the first-opinion concurrency claim entirely.
- Run the four non-chair agents sequentially.
- Overlap prompt construction for agent *n+1* while agent *n* is generating, and parse agent *n* output while agent *n+1* is generating.
- Document the simpler model and revisit concurrency when MLX container isolation is proven safe.

Whichever option is chosen, the implementation must:

- Never expose a raw `ModelContainer` across actor boundaries.
- Keep `MLXInferenceProvider` actor-isolated for stream/token ownership.
- Gate first-opinion concurrency with `thermalBudget` and `poolSize` configuration.
- Document the chosen option in `docs/ARCHITECTURE.md` and `README.md`.

### 3.3 Inference layer (`CouncilInference`)

Implement in `Council/Sources/CouncilInference/`:

| File | Contents |
|---|---|
| `MLXInferenceProvider.swift` | Actor-isolated `MLXInferenceProvider: InferenceProvider` with streaming token output. |
| `ModelContainerPool.swift` | Pool with borrow/return; default size 2 on macOS, 1 on iOS; each slot backed by an isolated worker. |
| `ModelContainerWorker.swift` | Isolated wrapper around one non-`Sendable` `ModelContainer`. |
| `MLXModelConfiguration.swift` | Wrapper around `ModelConfiguration` with default `mlx-community` model IDs. |
| `InferenceOptions+MLX.swift` | Conversion from `InferenceOptions` to MLX generate parameters. |
| `RouteSnapshot+MLX.swift` | MLX-specific route metadata. |
| `ModelManifestService.swift` | Declares available models, checksums/signatures, and download consent. |
| `MockInferenceProvider.swift` | Test-only mock returning canned strings or JSON. |

Implementation rules:

- `MLXInferenceProvider` is an `actor`.
- `generate` returns `AsyncThrowingStream<String, Error>` and checks `Task.isCancelled` between yields.
- `ModelContainerPool` must not expose non-`Sendable` containers across actor boundaries.
- Default models: 3 B quantized on iOS (`Qwen2.5-3B-Instruct-4bit` or `Llama-3.2-3B-Instruct-4bit`), 7 B on macOS.

### 3.4 Tests

In `Council/Tests/CouncilAgentsTests/`:

- `PromptBuilderTests.swift` — assert prompts contain constitution, role, stage schema; assert no `ClientConfidentialContainer` substrings.
- `PurchaseCouncilTests.swift` — verify agent list, chair, and stage order.
- `DeliberationStateMachineTests.swift` — mocked five-stage flow; verify state transitions and event log.
- `PerspectiveParserTests.swift` — success, malformed JSON, missing fields, raw-text fallback.
- `ConstitutionalPerspectiveValidatorTests.swift` — reject verdict phrases and empty dissent; accept valid perspective.
- `SycophancyResistanceTests.swift` — seeded polarizing questions; assert at least one agent output contains disagreement language.

In `Council/Tests/CouncilInferenceTests/`:

- `MockInferenceProviderTests.swift` — verify stream and cancellation.
- `ModelManifestServiceTests.swift` — checksum/signature validation and consent gate.
- `MLXInferenceProviderIsolationTests.swift` — build-only actor isolation checks; functional MLX tests run on Apple Silicon macOS.
- `ModelContainerPoolTests.swift` — verify borrow/return isolation and thermal-budget limits.

### 3.5 Commit groups

Group 1 — agents and state machine:

```text
feat: add Council agents and deliberation state machine

- Add AgentRole and five Purchase Council agent implementations.
- Add PromptBuilder with constitutional preamble and profile filtering.
- Add DeliberationService + DeliberationActor five-stage state machine.
- Add PerspectiveParser, PerspectiveValidationError, and
  ConstitutionalPerspectiveValidator.
- Add CouncilAgents unit tests.

Refs: council-swift-migration
```

Group 2 — MLX provider:

```text
feat: add MLX inference provider with streaming

- Add actor-isolated MLXInferenceProvider returning AsyncThrowingStream.
- Add ModelContainerPool with configurable size and isolated workers.
- Add ModelContainerWorker that owns a single non-Sendable ModelContainer.
- Add MLXModelConfiguration and InferenceOptions conversion.
- Add ModelManifestService for download consent and integrity checks.
- Add MockInferenceProvider for tests.

Refs: council-swift-migration
```

Group 3 — parser and validator (can be merged with group 1 if small):

```text
feat: add perspective parser and constitutional validator

- Implement PerspectiveParser with schema validation, retry budget, and
  raw-text fallback.
- Implement ConstitutionalPerspectiveValidator rejecting verdict language
  and empty dissent.

Refs: council-swift-migration
```

Group 4 — tests:

```text
test: add agent and deliberation unit tests

- Add PromptBuilder, state machine, parser, validator, and sycophancy
  resistance tests.
- Add MockInferenceProvider, ModelManifestService, and ModelContainerPool
  tests.

Refs: council-swift-migration
```

### 3.6 Phase 2 verification criteria

1. `swift test` passes for `CouncilCoreTests`, `CouncilAgentsTests`, and `CouncilInferenceTests`.
2. A mocked end-to-end deliberation test runs the five stages in order and produces a valid `Perspective`.
3. `ConstitutionalPerspectiveValidator` rejects the seeded verdict phrases from architecture §4.7.
4. `MLXInferenceProvider` builds without strict-concurrency warnings (functional MLX inference validated manually on Apple Silicon).
5. `Package.resolved` updated and committed.
6. Thermal budget and cancellation paths are covered by unit tests.
7. If Option A is selected, a unit test verifies that two simultaneous first-opinion calls use distinct workers and do not data-race.

---

## 4. Phase 3: Profile/memory layer + persistence

**Goal:** Encrypted profile vault, GRDB-backed memory store with application-level CryptoKit encryption of sensitive columns, append-only audit log with HMAC chain, and purpose-bound `RoutableProfileContext` integration.

**Persistence approach for PRD Phase 1:** Use `GRDB.swift` 7.9.0 with application-level CryptoKit field encryption for sensitive columns (profile vault blob, temporal-fact values, episodic-gist content). Full-database SQLCipher encryption is documented as a Phase 2 follow-up. Do not add a `GRDB-SQLCipher` dependency in PRD Phase 1.

### 4.1 Encrypted profile vault (`CouncilMemory`)

Implement in `Council/Sources/CouncilMemory/`:

| File | Contents |
|---|---|
| `CryptoKitProfileVault.swift` | `CryptoKitProfileVault: ProfileVault`; AES-256-GCM encryption of JSON blob. |
| `ProfileKeyManager.swift` | Generates/profile key; Secure Enclave ECIES wrapping on SEP-capable devices; Keychain fallback. |
| `SecureEnclaveWrapping.swift` | ECIES wrap/unwrap helper using ephemeral P-256 key agreement and HKDF. |
| `KeychainItem.swift` | Keychain read/write wrapper with correct accessibility flags. |
| `ProfileService.swift` | Actor-isolated service exposing `load()`, `save()`, `exportEncryptedBlob()`. |

Rules:

- Vault file path: `Application Support/Profile/vault.enc`.
- Directory marked `NSURLIsExcludedFromBackupKey`.
- File protection: `completeUnlessOpen`.
- Onboarding warning about device-bound keys and permanent lockout is a UI responsibility but `ProfileService` exposes a `isDeviceBound` flag.

### 4.2 Structured memory + audit log

Implement in `Council/Sources/CouncilMemory/`:

| File | Contents |
|---|---|
| `GRDBMemoryStore.swift` | `GRDBMemoryStore: MemoryStore` using GRDB.swift. |
| `AuditLog.swift` | `AuditLog` protocol implementation with HMAC-SHA-256 chain. |
| `DatabaseSchema.swift` | GRDB record types and schema definitions for `episodic_gists`, `temporal_facts`, `audit_log`. |
| `DatabaseMigrator.swift` | GRDB migrator with versioned schema. |
| `MemoryService.swift` | Actor-isolated service wrapping `MemoryStore` + `AuditLog`. |
| `FieldEncryption.swift` | CryptoKit AES-256-GCM helpers for encrypting/decrypting columns at rest. |

Rules:

- Database key derived from profile key via HKDF with persisted salt.
- Audit HMAC key derived via HKDF with info `"com.council.audit.integrity.v1"`.
- First audit entry uses the SHA-256 of the bundled genesis string.
- Canonical JSON serialization for HMAC uses lexicographically sorted keys and no whitespace.
- Sensitive columns (`summary`, `trade_offs_json`, `blind_spots_json`, `dissent_json`, temporal-fact `object`, etc.) are encrypted at the application level before persistence.
- Locked facts/gists are excluded from agent context but retained in storage.

### 4.3 Purpose-bound context

Ensure `RoutableProfileContext` is consumed correctly:

- `UserProfile.routableContext(for:)` in `CouncilCore`.
- `MemoryStore.temporalFacts(for:)` returns facts filtered by `AccessScope`.
- `PromptBuilder` filters facts by agent access purpose.
- Add unit test that constructs a profile with `financialHistory` and proves it never appears in prompt strings.

### 4.4 Memory inspector view model

In `Council/Sources/CouncilUI/ViewModels/`:

| File | Contents |
|---|---|
| `MemoryInspectorViewModel.swift` | `@MainActor @Observable` view model exposing episodes and facts; supports inspect, edit, delete, lock. |

It depends only on `MemoryService` protocols, not concrete stores.

### 4.5 Tests

In `Council/Tests/CouncilMemoryTests/`:

- `CryptoKitProfileVaultTests.swift` — round-trip save/load, missing vault graceful degradation, export/import.
- `ProfileKeyManagerTests.swift` — key generation, Secure Enclave wrapping fallback, Keychain retrieval.
- `GRDBMemoryStoreTests.swift` — CRUD on gists and facts; purpose-bound filtering; locked facts; encrypted columns.
- `AuditLogTests.swift` — append-only chain, tamper detection, genesis verification.
- `ProfileMemoryIntegrationTests.swift` — profile service + memory service + audit log in an in-memory GRDB database.
- `PromptLeakageTests.swift` — assert `ClientConfidentialContainer` content never appears in rendered prompts.

In `Council/Tests/CouncilIntegrationTests/`:

- `ProfileMemoryAuditIntegrationTests.swift` — full profile → memory → audit wiring through a test composition root.

### 4.6 Commit groups

Group 1 — vault and keys:

```text
feat: add encrypted profile vault and key management

- Add CryptoKitProfileVault with AES-256-GCM encryption.
- Add ProfileKeyManager with Secure Enclave ECIES wrapping and Keychain fallback.
- Add ProfileService actor and keychain helpers.
- Add ProfileService/vault unit tests.

Refs: council-swift-migration
```

Group 2 — store and audit log:

```text
feat: add GRDB memory store and audit log

- Add GRDBMemoryStore for episodic gists and temporal facts.
- Add AuditLog with HMAC-SHA-256 integrity chain.
- Add DatabaseSchema, DatabaseMigrator, and FieldEncryption helpers.
- Add MemoryService actor.
- Add memory and audit log unit tests.

Refs: council-swift-migration
```

Group 3 — purpose-bound context:

```text
feat: add purpose-bound profile context

- Enforce AccessPurpose filtering in PromptBuilder and MemoryStore queries.
- Ensure locked facts are retained but excluded from agent context.
- Add prompt-leakage tests for ClientConfidentialContainer.

Refs: council-swift-migration
```

Group 4 — view model and security tests:

```text
test: add memory and security unit tests

- Add MemoryInspectorViewModel tests using mock MemoryStore.
- Add key-extraction resistance and profile-vault encryption tests.
- Add data-class boundary verification tests.
- Add ProfileMemoryAudit integration tests.

Refs: council-swift-migration
```

### 4.7 Phase 3 verification criteria

1. `swift test` passes for all memory, security, and integration tests.
2. Encrypted vault file is not plaintext; unit test verifies ciphertext differs from raw JSON.
3. Audit log chain verifies and detects a tampered entry.
4. `RoutableProfileContext` excludes `ClientConfidentialContainer` by construction.
5. `MemoryInspectorViewModel` unit tests pass with mocked stores.
6. Build succeeds on both macOS and iOS Simulator destinations.
7. A migration note for SQLCipher full-database encryption is added to `docs/ARCHITECTURE.md` or `docs/PLAN.md` under the Phase 2 persistence roadmap.

---

## 5. Phase 4: UI + example session + tests

**Goal:** A runnable SwiftUI app with session UI, agent cards, memory inspector, model settings, onboarding/about screens, example documentation, and final test coverage.

### 5.1 Xcode app target (`CouncilApp/`)

Create or update:

| File | Contents |
|---|---|
| `CouncilApp.xcodeproj` | Xcode 16 project embedding the local `Council` SwiftPM package. |
| `CouncilApp/CouncilApp.swift` | `@main struct CouncilApp: App`. |
| `CouncilApp/CompositionRoot.swift` | Wires `MLXInferenceProvider`, `PurchaseCouncil`, `CryptoKitProfileVault`, `GRDBMemoryStore`, `AuditLog`, and `DeliberationService`. |
| `CouncilApp/Info.plist` | Required reason APIs, speech recognition usage description if voice input is enabled. |
| `CouncilApp/CouncilApp.entitlements` | App Sandbox, user-selected read-only, user-selected read-write, optional network client. |
| `CouncilApp/PrivacyInfo.xcprivacy` | NSPrivacyTracking=false; collected data types; accessed API categories. |
| `CouncilApp/Assets.xcassets` | App icons and accent color. |
| `CouncilAppTests/` | Swift tests that require a test host, if any. |
| `CouncilAppUITests/` | Xcode UI tests for session, kill switch, memory inspector, settings, and voice input. |

### 5.2 UI layer (`CouncilUI`)

Implement in `Council/Sources/CouncilUI/`:

| File | Contents |
|---|---|
| `ViewModels/SessionViewModel.swift` | `@MainActor @Observable`; owns `DeliberationService`; consumes `AsyncStream<DeliberationState>`; exposes `streamingText`, `sessionState`, `error`; supports start/cancel. |
| `ViewModels/MemoryInspectorViewModel.swift` | As defined in Phase 3; now wired in previews/tests. |
| `ViewModels/ModelSettingsViewModel.swift` | Exposes active route, model ID, compute path; requires explicit consent for route changes. |
| `Navigation/Route.swift` | `Route` enum for iOS `NavigationStack`. |
| `Views/SessionView.swift` | Question input, start/cancel, stage indicator, final perspective. |
| `Views/AgentCardView.swift` | Expandable agent opinion/dissent card. |
| `Views/StageIndicatorView.swift` | Five-stage progress; respects `accessibilityReduceMotion`. |
| `Views/PerspectiveView.swift` | Renders summary, trade-offs, blind spots, dissent. |
| `Views/MemoryInspectorView.swift` | Lists gists/facts; edit, delete, lock. |
| `Views/ModelSettingsView.swift` | Route display and consent-gated route changes. |
| `Views/AboutView.swift` | Constitutional boundary statement, privacy summary, version. |
| `Views/VoiceInputButton.swift` | Enabled only when `supportsOnDeviceRecognition` is true. |

UI rules:

- `NavigationSplitView` on macOS/iPadOS; `NavigationStack` with `Route` enum on iOS.
- All animations gated by `accessibilityReduceMotion`.
- Voice input uses `SFSpeechRecognizer` with `supportsOnDeviceRecognition` check; server fallback is blocked.
- Kill switch is always visible during deliberation and calls `SessionViewModel.cancel()`.

### 5.3 Example session

Create `examples/purchase-council.md` with:

- Sample purchase question.
- Expected agent opinions (Frugal, Future Self, Systems Thinker, Pleasure Agent).
- Chair synthesis showing `summary`, `trade-offs`, `blind-spots`, and `dissent`.
- A note that this is a representative output, not deterministic.

### 5.4 Documentation update

Update `docs/PLAN.md`:

- Move the minimal memory layer (episodic gist, temporal facts, memory inspector, audit log) into **PRD Phase 1** with an explicit note that this is an acceleration driven by the Constitution’s transparency requirement.
- Keep the next planning phase focused on expanded profile ingestion, journal ingestion, richer temporal reasoning, and SQLCipher full-database encryption.
- Mention that runtime constitutional enforcement remains a future phase.

Also update `README.md` with build/run instructions, supported devices, and link to `examples/purchase-council.md`.

### 5.5 Tests

In `CouncilApp/CouncilAppUITests/` (Xcode target, **not** SwiftPM `CouncilUITests`):

- `SessionFlowTests.swift` — start a session from text input, verify perspective rendered.
- `KillSwitchTests.swift` — cancel stops inference and leaves no persisted perspective.
- `MemoryInspectorFlowTests.swift` — inspect, edit, delete, lock a gist/fact.
- `ModelSettingsConsentTests.swift` — route change requires explicit consent.
- `VoiceInputAvailabilityTests.swift` — microphone button disabled when on-device recognition is unavailable.

In `Council/Tests/CouncilIntegrationTests/`:

- `DeliberationIntegrationTests.swift` — full flow with mocked provider and in-memory memory/audit stores.
- `ProfileMemoryIntegrationTests.swift` — profile, memory, and audit wiring through a test composition root.

In `Council/Tests/CouncilPerformanceTests/`:

- `DeliberationPerformanceTests.swift` — measure first-opinion latency and end-to-end latency; assert thresholds.
- `MemoryPeakTests.swift` — measure peak memory during first-opinion concurrency.
- `ThermalResponseTests.swift` — verify pause at `.critical` thermal state (manual or simulated).

### 5.6 Commit groups

Group 1 — session and agent cards:

```text
feat: add SwiftUI session and agent card views

- Add SessionViewModel with AsyncStream state consumption.
- Add SessionView, AgentCardView, StageIndicatorView, PerspectiveView.
- Add VoiceInputButton with on-device recognition check.
- Add CouncilUI unit and preview tests.

Refs: council-swift-migration
```

Group 2 — memory inspector and settings:

```text
feat: add memory inspector and model settings UI

- Add MemoryInspectorView with edit/delete/lock actions.
- Add ModelSettingsView with consent-gated route changes.
- Add AboutView with constitutional boundary statement.

Refs: council-swift-migration
```

Group 3 — app wiring and entitlements:

```text
feat: wire app composition root and entitlements

- Add CouncilApp Xcode target embedding the Council package.
- Add CompositionRoot wiring concrete providers and services.
- Add entitlements, Info.plist, and PrivacyInfo.xcprivacy.
- Add app icons and launch assets.

Refs: council-swift-migration
```

Group 4 — Xcode UI tests:

```text
test: add CouncilApp UITests for session, kill switch, and settings

- Add CouncilAppUITests target in Xcode (not SwiftPM).
- Add SessionFlowTests, KillSwitchTests, MemoryInspectorFlowTests,
  ModelSettingsConsentTests, and VoiceInputAvailabilityTests.

Refs: council-swift-migration
```

Group 5 — example session:

```text
docs: add purchase council example session

- Add examples/purchase-council.md with sample input and perspective output.
- Update README.md with build/run instructions.

Refs: council-swift-migration
```

Group 6 — integration and performance tests:

```text
test: add integration and performance tests

- Add DeliberationIntegrationTests with mocked inference provider.
- Add ProfileMemoryIntegrationTests through test composition root.
- Add performance tests for latency, peak memory, and thermal response.

Refs: council-swift-migration
```

Group 7 — plan update:

```text
docs: update PLAN.md for PRD Phase 1 memory scope

- Move minimal memory layer and audit log into PRD Phase 1.
- Clarify next phase focus on expanded profile/journal ingestion and
  SQLCipher full-database encryption.
- Note runtime constitutional enforcement remains a future phase.

Refs: council-swift-migration
```

### 5.7 Phase 4 verification criteria

1. `CouncilApp` builds and runs on macOS 14+ and iOS 17+.
2. `CouncilAppUITests` pass on iOS Simulator and macOS (macOS UI tests may be run locally).
3. Integration tests pass with mocked inference.
4. Performance tests meet thresholds on the reference device (iPhone 12 / 4 GB RAM) or the implementation is gated until they do.
5. `examples/purchase-council.md` matches the implemented output schema.
6. `docs/PLAN.md` accurately reflects PRD Phase 1 memory acceleration.
7. Privacy manifest and entitlements are complete and reviewed.

---

## 6. Per-phase verification criteria

In addition to the phase-specific criteria above, every phase must satisfy:

1. **Build:** `cd Council && swift build` succeeds on Apple Silicon macOS with `.swiftLanguageMode(.v6)` and zero warnings treated as errors.
2. **Tests:** `swift test` passes for all targets introduced or modified in the phase.
3. **Lint:** Optional `swiftlint` / `swift-format` passes if configured; at minimum no obvious style regressions.
4. **Diff review:** Commit diff is reviewed by a sibling agent or the user before the phase tag is pushed.
5. **SDL lifecycle:** Every commit references `council-swift-migration` and the phase tag is recorded in the lifecycle record.

---

## 7. Commit and tagging policy

### Conventional commit format

```text
<type>(<scope>): <short summary>

<body>

Refs: council-swift-migration
```

Allowed types: `feat`, `fix`, `test`, `docs`, `chore`, `refactor`, `perf`, `security`.

Allowed scopes: `core`, `agents`, `inference`, `memory`, `ui`, `app`, `docs`, `test`, `build`.

### Example messages

```text
feat(agents): implement five-stage deliberation actor

- Serializes stage transitions via DeliberationActor.
- Emits AsyncStream<DeliberationState> for UI consumption.
- Propagates Task cancellation to all child inference calls.

Refs: council-swift-migration
```

```text
test(memory): add audit log HMAC chain tests

- Verify append-only ordering and tamper detection.
- Verify genesis hash matches bundled value.

Refs: council-swift-migration
```

### Tags

| Tag | When |
|---|---|
| `v0.1.0-phase1` | After Phase 1 verification criteria pass. |
| `v0.1.0-phase2` | After Phase 2 verification criteria pass. |
| `v0.1.0-phase3` | After Phase 3 verification criteria pass. |
| `v0.1.0-purchase-council` | After Phase 4 verification criteria pass and the milestone is accepted. |

Tag creation:

```bash
git tag -a v0.1.0-phase1 -m "Phase 1: SwiftPM scaffold and core protocols"
git push origin sdl/council-swift-migration --tags
```

After tagging, update the SDL lifecycle record `council-swift-migration.json` under `commits`/`tags` with the tag and commit hash.

---

## 8. Risk mitigation

| Risk | Mitigation |
|---|---|
| **MLX build issues** | Pin exact versions (`mlx-swift` 0.31.5, `mlx-swift-lm` 3.31.4). Use SwiftPM tools version 6.3. Build CI matrix for macOS 14/15 and iOS 17 Simulator. Treat MLX as Phase 1 proving path only; gate App Store release on Core ML conversion. Keep `ModelContainerPool` and provider isolated so swapping to `CoreMLInferenceProvider` later is a one-file change. |
| **Model output reliability** | Use 7 B on macOS, 3 B on iOS. Add schema validation, retry budget, constrained decoding where supported, `ConstitutionalPerspectiveValidator`, and raw-text fallback. Add sycophancy evaluation tests and qualitative spot-checks. |
| **Swift 6 strict concurrency** | Enable `.swiftLanguageMode(.v6)` from day one. Make all domain types `Sendable`. Use actors for mutable state (`DeliberationActor`, `MLXInferenceProvider`, `ProfileService`, `MemoryService`). Never use global mutable state. Run `swift build` with warnings-as-errors in CI. |
| **MLX container concurrency** | Do not share a single non-`Sendable` `ModelContainer` across concurrent calls. Use a `ModelContainerPool` with isolated workers (preferred) or sequential inference with prompt/parse overlap (fallback). Document the chosen model. |
| **Thermal throttling / memory pressure** | Limit first-opinion concurrency to 1 on iOS (2 on macOS). Monitor `ProcessInfo.thermalState`; pause at `.critical`, lower budget at `.serious`. Benchmark on iPhone 12 / 4 GB RAM. If thresholds are missed, reduce model size, concurrency, or context window before release. |
| **Key loss lockout** | Onboarding warning that v1 is device-bound with no escrow. Allow encrypted export. Defer passphrase/biometric backup to a later phase. |
| **Profile data leakage** | `RoutableProfileContext` excludes `ClientConfidentialContainer` by construction. Add prompt-leakage unit tests. Never pass full `UserProfile` to an `Agent`. |
| **Audit tampering** | Append-only HMAC chain derived from memory key. Unit tests verify chain integrity and tamper detection. Clearly document that deletion prevention is out of scope in PRD Phase 1. |
| **Persistence encryption gaps** | PRD Phase 1 uses GRDB.swift 7.9.0 with application-level CryptoKit field encryption. Full-database SQLCipher encryption is scheduled for the next phase and documented in the roadmap. |
| **Apple 27 API drift** | Keep Apple 26 the baseline. Availability-gate every Apple 27-only API. Source-ground any new API claim before it is used. |

---

## 9. Final verification checklist

Before declaring the `v0.1.0-purchase-council` milestone complete, run and verify:

- [ ] `cd Council && swift build` succeeds for macOS and iOS Simulator.
- [ ] `cd Council && swift test` passes (unit, integration, security tests).
- [ ] `CouncilApp` builds and archives in Xcode 16.3+ for macOS and iOS.
- [ ] `CouncilAppUITests` pass on iOS Simulator and macOS.
- [ ] No strict-concurrency warnings or errors.
- [ ] `Package.resolved` is committed and reproducible.
- [ ] AC1: Swift 6 language mode enabled across all targets.
- [ ] AC2: User can start a Purchase Council session from text input (manual + UI test).
- [ ] AC3: Voice input blocked unless `supportsOnDeviceRecognition` is true.
- [ ] AC4: All five agents produce role-consistent outputs (unit test with mock provider).
- [ ] AC5: Five-stage protocol executes in order (state-machine test).
- [ ] AC6: Final perspective has non-empty `summary`, `trade-offs`, `blind-spots`, `dissent`.
- [ ] AC7: Default deliberation completes offline after model download (network interceptor test).
- [ ] AC8: Profile loads from sandbox; missing profile degrades gracefully.
- [ ] AC9: Vault file is encrypted; key lives in Keychain / Secure Enclave.
- [ ] AC10: Memory inspector supports inspect, edit, delete, lock.
- [ ] AC11: Audit log is append-only with integrity hashes covering stages, routes, cancellations.
- [ ] AC12: Cancel stops session and leaves no partial perspective.
- [ ] AC13: `examples/purchase-council.md` exists and matches output schema.
- [ ] AC14: Model download requires explicit consent and verifies integrity.
- [ ] AC15: No telemetry or analytics is sent by default; opt-in telemetry contains no prompts or personal data.
- [ ] AC16: Performance thresholds met on reference device or release is gated.
- [ ] `docs/PLAN.md` updated for PRD Phase 1 memory acceleration.
- [ ] `README.md` updated with build/run instructions.
- [ ] Privacy manifest and entitlements reviewed and committed.
- [ ] Final tag `v0.1.0-purchase-council` created and pushed.
- [ ] SDL lifecycle record updated with final commit/tag hashes.

---

## 10. Implementation order summary

1. **Phase 1:** Scaffold SwiftPM package and `CouncilCore` protocols/types. Tag `v0.1.0-phase1`.
2. **Phase 2:** Build `CouncilAgents` (Purchase Council, state machine, parser, validator) and `CouncilInference` (MLX provider, pool, worker, manifest). Tag `v0.1.0-phase2`.
3. **Phase 3:** Build `CouncilMemory` (vault, keys, GRDB store with CryptoKit field encryption, audit log) and wire purpose-bound context. Tag `v0.1.0-phase3`.
4. **Phase 4:** Build `CouncilUI`, `CouncilApp`, `CouncilAppUITests`, example session, update docs, add final test matrix. Tag `v0.1.0-purchase-council`.

No repository files are mutated by this plan document. The plan is ready for execution in the `sdl/council-swift-migration` worktree.
