# Council Swift Rewrite — Product Requirements Document v2

**Status:** Locked (v2.1 — persistence clarified)  
**Scope:** Phase 1 — Purchase Council v1 on Apple platforms  
**Date:** 2026-07-07  
**Governance:** SDL-governed client work  
**SDL lifecycle record:** `council-swift-migration` → `/Users/vishalsingh/.stibdedlom/project-memory/v-i-s-h-a-l/council/lifecycle/council-swift-migration.json`  
**Branch:** `sdl/council-swift-migration`  
**Authority:** User provided explicit autonomous authority to proceed through full SDL lifecycle without per-step human gating.

---

## 1. Objective and scope

Rewrite the Council runtime as a native, local-first Swift universal app. The first shippable milestone is the **Purchase Council v1**: a single council that takes a user’s purchase question, runs a structured multi-agent deliberation entirely on-device, and returns a perspective — not a verdict — while keeping the user profile encrypted and under the user’s control.

This PRD covers only Phase 1. It intentionally defers MCP tool connectors, additional councils, and a full runtime constitutional enforcement engine to later phases, but it defines an explicit constitutional boundary for Phase 1 so that prompt-level guardrails and manual controls are not mistaken for runtime policy interception.

What this delivers:

- A working Swift/SwiftUI app that runs on macOS 14+ and iOS 17+.
- The Purchase Council with five agents: Frugal, Future Self, Systems Thinker, Pleasure Agent, and Chair.
- The five-stage deliberation protocol: first opinions → peer review → synthesis → dissent preservation → presentation.
- On-device LLM inference as the default compute path using `mlx-swift-lm` as the Phase 1 proving backend.
- Encrypted profile vault and a minimal Phase 1 memory layer (episodic gist + audit log + purpose-bound access control).
- A memory inspector that satisfies the constitution’s transparency requirements.
- An explicit constitutional-enforcement boundary statement and a lightweight output validator.

---

## 2. Target platforms

| Target | Policy family | Concrete OS versions | Rationale |
|--------|---------------|----------------------|-----------|
| **Primary** | Apple 26 family | iOS 17 / macOS 14 / iPadOS 17 / visionOS 1 | Source-grounded floor for `mlx-swift-lm`, `mlx-swift`, `@Observable`, Observation, `PhaseAnimator`, SwiftData, and CryptoKit. |
| **Enhanced** | Apple 27 family | iOS 18 / macOS 15 / iPadOS 18 / visionOS 2 | Used only for APIs that truly require Apple 27; any such API must have a runtime availability gate. |
| **Excluded** | — | watchOS, tvOS, Intel Macs (primary MLX route) | The primary inference stack targets Apple Silicon. Intel Macs are unsupported in v1. |

**Source-grounding table (retrieved 2026-07-07):**

| API / Framework | Minimum OS | Source |
|-----------------|------------|--------|
| `mlx-swift` | macOS 14 / iOS 17 / visionOS 1 | [Package.swift](https://raw.githubusercontent.com/ml-explore/mlx-swift/main/Package.swift) |
| `mlx-swift-lm` | macOS 14 / iOS 17 / visionOS 1 | [Package.swift](https://raw.githubusercontent.com/ml-explore/mlx-swift-lm/main/Package.swift) |
| `@Observable` / Observation | iOS 17 / macOS 14 | [Migrating to the Observable macro](https://developer.apple.com/documentation/swiftui/migrating-from-the-observable-object-protocol-to-the-observable-macro) |
| `PhaseAnimator` | iOS 17 / macOS 14 | [SwiftUI documentation](https://developer.apple.com/documentation/swiftui/phaseanimator) |
| SwiftData | iOS 17 / macOS 14 | [SwiftData documentation](https://developer.apple.com/documentation/swiftdata) |
| CryptoKit | iOS 13 / macOS 10.15 | [CryptoKit documentation](https://developer.apple.com/documentation/cryptokit) |

**Policy note:** Apple 27-family APIs are treated as beta-qualified unless an official Apple source marks them stable. Every SDK/API availability claim in this PRD or in downstream design documents must be source-grounded.

---

## 3. Feature set — Purchase Council v1

| ID | Feature | Description | Rationale |
|----|---------|-------------|-----------|
| F1 | Purchase Council session | User can start a dedicated Purchase Council session from a primary entry point. | Fulfills `PLAN.md` Phase 1 and issue #1. |
| F2 | Text input | User can type a purchase question. | Required by `PLAN.md` Phase 1. |
| F3 | Voice input (optional) | User can dictate a purchase question using on-device speech recognition; requires `supportsOnDeviceRecognition`. | Voice is explicitly optional for v1; raw audio is not retained. |
| F4 | Five agent roles | Frugal, Future Self, Systems Thinker, Pleasure Agent, and Chair. Each role has a fixed system prompt, stance, and scope. | Required by `ARCHITECTURE.md` and issue #1. |
| F5 | Five-stage deliberation protocol | Orchestrator runs first opinions → peer review → synthesis → dissent preservation → presentation in order. | Core Council behavior; required by issue #1. |
| F6 | Structured perspective output | Final output contains `summary`, `trade-offs`, `blind-spots`, and `dissent`. | Must be a perspective, not a verdict, per the constitution. |
| F7 | Agent reasoning cards | Each agent’s opinion and rationale are visible and expandable; confidence is qualitative or hidden in v1. | Supports transparency and non-manipulation. |
| F8 | Profile loading | Orchestrator loads values, goals, and boundaries from an encrypted vault inside the app sandbox / Application Support. | Required by issue #1; profile context is filtered per agent. |
| F9 | Memory persistence | Each completed session is stored as an episodic gist with linked temporal facts and an audit log. | Required by `PLAN.md` Phase 1/2; scope is intentionally minimal. |
| F10 | Memory inspector | User can inspect, edit, delete, or lock any stored memory. | Constitutional requirement (`CONSTITUTION.md`). |
| F11 | Model settings | User can see the active local model and compute route; route changes require explicit consent. | Needed for SDL routing policy and user sovereignty. |
| F12 | Kill switch | Cancel button stops the entire deliberation session, prevents downstream agent calls, and discards partial output. | Required by `ARCHITECTURE.md` security model. |
| F13 | Audit trail | Append-only log of session events (stage transitions, agent calls, route decisions) with integrity hashes. | Required by `ARCHITECTURE.md`. |
| F14 | Example session | `examples/purchase-council.md` demonstrates input → deliberation → output. | Required by issue #1 acceptance criteria. |
| F15 | Constitutional boundary statement | PRD and app include an explicit statement that Phase 1 relies on prompt design, output validation, and manual kill switch; runtime interception is Phase 5. | Closes governance gap identified in sibling review. |

### Phase scope note

`docs/PLAN.md` assigns the full memory layer (temporal facts, purpose-bound access control, memory inspector) to Phase 2. This PRD accelerates a **minimal** Phase 1 memory layer because the Council Constitution requires memory transparency (`Remember transparently.`) and the kill switch requires an audit trail. `PLAN.md` will be updated in a separate commit to reflect this acceleration.

---

## 4. Non-goals

These are explicitly out of scope for Purchase Council v1:

- MCP-based tool connectors (email, calendar, finance, travel).
- Autonomous actions or delegated purchases.
- Voice output / text-to-speech.
- Full runtime constitutional enforcement engine (runtime interception is Phase 5).
- Travel Council, Life Council, or user-defined councils.
- iCloud, CloudKit, or third-party cloud sync of the profile vault.
- Third-party cloud LLM inference by default.
- Telemetry, analytics, or crash reporting that includes prompts, memory content, or personal data.
- Multi-user or cross-profile sessions.
- Fine-tuning or LoRA training of the local model.
- Apple Private Cloud Compute as a default or silently-available route (kept as a declared, human-approved future path only).

---

## 5. Model routing policy

Council Swift follows the explicit routing order defined in `capability-apple-model-routing-policy`.

### 5.1 Routing order

1. **Apple on-device** — default and preferred. Primary backend: `mlx-swift-lm` running a 3–8 B parameter quantized instruction model locally on Apple Silicon.
2. **Apple Private Cloud Compute (PCC)** — **not available in v1** for custom `mlx-swift-lm` inference. The PRD retains it in policy only as a future route that requires: (a) an Apple Intelligence request class that supports the council workload, (b) attestation verification, (c) explicit per-session human approval, and (d) data-class clearance. It is marked speculative until source-grounded feasibility is proven.
3. **Third-party local** — permitted only when explicitly declared in settings, user-consented, and allowed by data class. Example: a local `llama.cpp` / GGUF server on the same device. Requires integrity verification and process-isolation justification.
4. **Third-party cloud** — **denied by default** for v1.

### 5.2 Decision record

Every routing decision must produce a record containing:

- `selected_route` with provider metadata (framework, model identifier, local/cloud, device/Apple PCC/third-party).
- `denied_routes` and the reason each was denied.
- `consent_status` for any non-local route.
- `data_class_clearance` referencing the data-classification decision.

### 5.3 Denial conditions

A route is denied when:

- The provider or API claim is stale or ungrounded.
- The target SDK family does not support the route.
- The data class forbids the compute path.
- Consent is missing or ambiguous for a third-party route.
- A silent fallback to a third-party cloud provider would be required.

---

## 6. Data classification

All data is classified before sync, AI, telemetry, or model routing per `capability-apple-data-classification`.

| Data asset | Data class | Allowed compute paths | Notes |
|------------|------------|----------------------|-------|
| Profile vault (values, goals, boundaries) | Sensitive personal | On-device only. | Never transmitted outside the device. |
| Financial history, journal excerpts | Client-confidential | On-device only; never routed to any language model. | Stored encrypted; excluded from all model context. |
| Temporal facts | Personal / sensitive personal | On-device; third-party local with explicit consent and data-class clearance. | Each fact carries `access_scope` for purpose-bound filtering. |
| Episodic gists / derived summaries | Derived summaries / personal | On-device; third-party local with explicit consent. | Generated by the Chair or user after deliberation. |
| Deliberation transcripts | Personal / sensitive personal | On-device only by default; discarded after gist generation unless user saves. | Not retained longer than the session gist unless saved. |
| Audio input (if used) | Audio | On-device speech recognition only. | Raw audio is not retained; transcripts are classified as personal. |
| Audit logs | Logs / app-local nonsensitive | Local storage only. | Must not contain prompts, memory excerpts, or source content. |
| Encryption keys / credentials | Credentials and secrets | Keychain / Secure Enclave only. | Never routed to any language model. |
| Crash/performance telemetry (opt-in only) | App-local nonsensitive | Aggregated, non-content metrics only. | No prompts, personal data, or source content. |
| Model weights | App-local binary | Local storage only after integrity verification. | Download requires explicit consent; checksum/signature verified. |

### 6.1 Human-approval gates

The following require an explicit deny-or-approve decision before model routing:

- Any proposed third-party local route.
- Any future Apple PCC route (v1: not implemented).
- Any future third-party cloud route (v1: denied).

Credentials, secrets, biometric, health, precise location, child/minor, regulated, and client-confidential data are **never** routed to a language model.

---

## 7. Swift stack recommendations

All claims below are source-grounded where required; Swift language, SwiftUI, concurrency, testing, and package-quality judgments are deferred to the SwiftAnvil federation and installed Swift skills.

### 7.1 UI layer

- **SwiftUI** with `@Observable` view models and MVVM.
- **Navigation:** `NavigationSplitView` on macOS/iPadOS; `NavigationStack` with a route enum on iPhone.
- **State:** view models marked `@MainActor`; heavy work dispatched to actor-isolated service classes.
- **Motion:** subtle, state-driven animations only (`matchedGeometryEffect`, spring transitions). Respect `accessibilityReduceMotion`. Motion must not be engagement-optimized or manipulative.
- **Accessibility:** VoiceOver labels, Dynamic Type, and Reduced Motion support are required.

### 7.2 Concurrency

- Swift 6 strict concurrency mode is mandatory (Xcode 16.3+ / Swift 6.3+ / swift-tools-version 6.3).
- `actor`-isolated services: `DeliberationService`, `ProfileService`, `MemoryService`.
- `async/await` and `AsyncStream` for streaming inference tokens to the UI.
- `Task` cancellation for the kill switch.

### 7.3 Inference

- **Primary:** `mlx-swift-lm` (`MLXLLM`, `MLXLMCommon`, `MLXHuggingFace`) via SwiftPM.
  - Source: [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm), [mlx-swift](https://github.com/ml-explore/mlx-swift) (retrieved 2026-07-07).
  - Note: MLX is a research-oriented proving path for v1. A Core ML conversion gate is required before any App Store release.
- **Models:** 3–8 B parameter instruction-tuned quantized models from `mlx-community` (e.g., `Qwen2.5-3B-Instruct-4bit`, `Llama-3.2-3B-Instruct-4bit`).
- **Protocol:** one shared `ModelContainer` per session; first-opinion calls may run concurrently up to a thermal budget; subsequent stages are sequential.
- **Output parsing:** typed JSON/Codable with retry budget, schema validation, and a graceful fallback to raw-text presentation if parsing fails after retries.
- **Future production path:** Core ML Tools with stateful KV cache, flexible shapes, fused SDPA, and 4-bit quantization.
- **Declared third-party local fallback:** `swift-llama-cpp` or `llmfarm_core.swift` for GGUF compatibility, only if the user opts in and verifies integrity.

### 7.4 Persistence and security

- **Profile vault:** encrypted JSON blob using CryptoKit AES-256-GCM.
- **Key management:** 256-bit symmetric key generated with `CryptoKit`; stored in Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`; default wrapping is Secure Enclave. **Key recovery:** v1 is device-bound with no escrow. The user is warned explicitly that key loss means permanent profile lockout; passphrase/biometric backup is deferred to Phase 2.
- **Structured memory:** GRDB.swift 7.9.0 for episodic gists and audit logs; sensitive values encrypted at the application level with CryptoKit AES-256-GCM.
- **File protection:** `FileProtectionType.completeUnlessOpen` on the GRDB store and external files; enable Data Protection capability in Xcode; mark user files `NSURLIsExcludedFromBackupKey`.
- **Profile directory:** restricted to the app sandbox / Application Support container. A user may *export* an encrypted vault blob, but the live vault remains inside the sandbox.

### 7.5 Testing

- **Swift Testing** for unit tests of agents, prompt builders, output parsers, and routing decisions.
- Mock `InferenceProvider`, `MemoryStore`, and `ProfileVault` for isolated tests.
- Concurrency data-race tests, key-extraction resistance tests, and sycophancy evaluation tests.
- UI tests for session creation, kill switch, and memory inspector flows.
- Performance tests measuring deliberation latency and peak memory on the lowest supported device.

### 7.6 Build and packaging

- Xcode 16.3+ / Swift 6.3+ for swift-tools-version 6.3 support, Swift 6 strict concurrency, and Apple 26 SDK.
- SwiftPM for dependency management; `Package.resolved` pinned.
- App Sandbox enabled; network entitlement only for optional model download and future opt-in features.
- Privacy manifest entries for CryptoKit, Speech (if used), and required-reason API usage.

---

## 8. Constitutional enforcement boundary (Phase 1)

The Council Constitution is the canonical normative scaffold. In Phase 1, runtime policy interception is not yet implemented. The following interim controls apply:

1. **Prompt-level guardrails:** every agent prompt includes the Constitution’s hard constraints and a reminder to return a perspective, not a verdict.
2. **Output validation:** the Chair output is validated against the perspective schema; any recommendation language is rejected and re-prompted.
3. **Manual kill switch:** the user can halt the entire session at any time.
4. **Audit trail:** every deliberation event is logged for post-hoc review.
5. **Phase 5 commitment:** a full runtime constitutional enforcement engine (action allow-list, profile-leak detector, kill-switch hooks) is scheduled for Phase 5 (`docs/PLAN.md`).

This boundary is documented in the app’s About screen and in the PRD so users and reviewers understand the limitation.

---

## 9. Measurable acceptance criteria

| ID | Criterion | Verification |
|----|-----------|--------------|
| AC1 | App builds and runs on macOS 14+ and iOS 17+ with Swift 6 strict concurrency enabled. | CI matrix build; manual smoke test. |
| AC2 | User can start a Purchase Council session from text input. | Manual test + UI test. |
| AC3 | Voice input works only when `supportsOnDeviceRecognition` is true; server fallback is blocked or requires explicit consent. | Unit test + manual test. |
| AC4 | All five agents produce role-consistent outputs for the same purchase question. | Unit test with mocked inference provider and prompt assertions. |
| AC5 | Orchestrator executes first opinions → peer review → synthesis → dissent preservation → presentation in order. | Unit test inspecting session state machine / event log. |
| AC6 | Final perspective contains non-empty `summary`, `trade-offs`, `blind-spots`, and `dissent` fields. | Parser validation test; UI inspection. |
| AC7 | Default deliberation requires no network call and completes offline after the model is cached. | Network interceptor test; airplane-mode manual test. |
| AC8 | Profile loads from the app sandbox; missing profile degrades gracefully. | Unit test with temporary directory. |
| AC9 | Profile vault file on disk is not plaintext; encryption key resides in Keychain/Secure Enclave. | File inspection test; Keychain enumeration test. |
| AC10 | Memory inspector supports inspect, edit, delete, and lock operations. “Lock” means excluded from agent context but retained. | UI test. |
| AC11 | Audit log is append-only with per-entry integrity hashes and records every deliberation stage, route decision, and cancellation. | Unit test writing to a mock log store. |
| AC12 | Cancel button stops the entire session, prevents downstream agent calls, and leaves no partial perspective persisted. | UI test + unit test of task cancellation. |
| AC13 | `examples/purchase-council.md` exists and matches the implemented deliberation output schema. | Static review. |
| AC14 | Model download requires explicit consent and verifies checksum/signature before loading. | Unit test of model manifest service. |
| AC15 | No telemetry or analytics is sent unless the user opts in, and opt-in telemetry contains no prompts, personal data, or source content. | Static analysis + runtime network trace. |
| AC16 | Deliberation latency and peak memory on the lowest supported iPhone meet go/no-go benchmarks (TBD in architecture phase). | Performance test. |

---

## 10. Open questions and risks

| # | Question / Risk | Impact | Mitigation |
|---|-----------------|--------|------------|
| 1 | **Model quality vs. size:** A 3 B parameter model may not reliably produce structured JSON or preserve dissent. | High | Start with 3 B on iOS and 7 B on macOS; add output schema validation, retries, and constrained decoding. |
| 2 | **iOS thermal and memory limits:** Sustained on-device inference drains battery and may terminate the app. | High | Keep context windows small, allow cancellation, benchmark on lowest supported device, throttle concurrent agent calls. |
| 3 | **MLX Swift production readiness:** Apple positions MLX as research-oriented. | Medium | Treat MLX as the Phase 1 proving path; require a Core ML conversion gate before App Store release. |
| 4 | **Key recovery:** Device-bound keys mean permanent lockout on key loss. | Medium | Document the risk explicitly; defer passphrase/biometric backup to Phase 2. |
| 5 | **Sycophancy / consensus pressure:** Small models may agree too readily. | Medium | Tune prompts to require explicit disagreement, include a dedicated dissent stage, and evaluate outputs qualitatively. |
| 6 | **Minimum device tier:** RAM and thermal floors are TBD. | Medium | Define in architecture phase and gate implementation on benchmark results. |

---

## 11. References

- Council project: `README.md`, `CONSTITUTION.md`, `docs/ARCHITECTURE.md`, `docs/PLAN.md`, `docs/DESIGN_JOURNEY.md`.
- SDL capabilities:
  - `capability-apple-version-policy`
  - `capability-apple-model-routing-policy`
  - `capability-apple-data-classification`
  - `capability-apple-source-grounding`
- SDL lifecycle record: `/Users/vishalsingh/.stibdedlom/project-memory/v-i-s-h-a-l/council/lifecycle/council-swift-migration.json`
- Source-grounded Apple references (retrieved 2026-07-07):
  - [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm)
  - [mlx-swift](https://github.com/ml-explore/mlx-swift)
  - [MLX Swift announcement](https://swift.org/blog/mlx-swift/)
  - [Apple ML Research — Core ML on-device Llama](https://machinelearning.apple.com/research/core-ml-on-device-llama)
  - [Core ML Tools overview](https://apple.github.io/coremltools/docs-guides/source/overview-coremltools.html)
  - [Migrating to the Observable macro](https://developer.apple.com/documentation/swiftui/migrating-from-the-observable-object-protocol-to-the-observable-macro)
  - [CryptoKit documentation](https://developer.apple.com/documentation/cryptokit)
  - [SwiftData documentation](https://developer.apple.com/documentation/swiftdata)
  - [Swift Testing documentation](https://developer.apple.com/documentation/testing)

---

*No repository files were modified to produce this PRD. The PRD was revised based on sibling-agent review from SDL governance, Swift engineering, security/privacy, UX/non-manipulation, and Apple platform/model-routing lenses.*
