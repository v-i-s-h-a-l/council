# Council Plan

> Phased development of the Council runtime.

## Phase 0: Foundation

- Publish the public `council` repository with README, constitution, architecture, and plan.
- Create the private `council-profile` repository for personal data.
- Define the canonical council member templates and deliberation protocol.
- Choose a local inference stack and an orchestration framework.

## Phase 1: First Council

- Implement a single council: the **Purchase Council**.
- Agents: Frugal, Future Self, Systems Thinker, Pleasure Agent, Chair.
- Input: voice or text describing a purchase.
- Output: a perspective with trade-offs, blind spots, and dissent.
- Minimal memory layer: episodic gist, temporal facts, memory inspector, and audit log.
- Add a minimal **`CouncilCLI`** executable for headless `council ask` usage. See `planning/council-cli-spec.md`.
  > This is an acceleration driven by transparency: from the very first deliberation the user can inspect and edit what the council remembers and verify the audit chain.
- Runtime constitutional enforcement remains future work; the current validator runs after synthesis and rejects verdict language or suppressed dissent.

### AC16 acceptance criteria (Phase 1)

| ID | Criterion | Target |
|---|---|---|
| AC1 | Swift 6 language mode enabled across all targets | ✅ |
| AC2 | Text-input Purchase Council session produces a perspective | ✅ |
| AC3 | Voice input blocked unless on-device recognition is available | ✅ |
| AC4 | Five role-consistent agents | ✅ |
| AC5 | Five-stage protocol executes in order | ✅ |
| AC6 | Final perspective has summary, trade-offs, blind spots, and dissent | ✅ |
| AC8 | Profile loads from sandbox; missing profile degrades gracefully | ✅ |
| AC9 | Vault encrypted; key in Keychain / Secure Enclave or file fallback for CLI | ✅ |
| AC10 | Memory inspector supports inspect, edit, delete, lock | ✅ |
| AC11 | Audit log is append-only with HMAC integrity chain | ✅ |
| AC12 | Cancel stops session and leaves no partial perspective | ✅ |
| AC13 | `examples/purchase-council.md` exists and matches schema | ✅ |
| AC14 | Model download gated by `ModelManifestService` consent + verified SHA-256 checksum | ✅ |
| AC15 | No telemetry or analytics sent by default | ✅ |
| AC16 | Performance benchmark target added with first-opinion, end-to-end, and peak-memory measurement against thresholds | ✅ |

AC16 thresholds (on reference hardware):

| Platform | First-opinion latency | End-to-end latency | Peak resident memory |
|---|---|---|---|
| iOS (iPhone 12 class) | ≤ 15 s | ≤ 90 s | ≤ 2 GB |
| macOS (Apple Silicon, pool size 2) | ≤ 8 s | ≤ 90 s | ≤ 2 GB |

Run benchmarks with:

```bash
COUNCIL_RUN_BENCHMARKS=1 swift test --filter CouncilBenchmarks
```

> Note: MLX Metal inference requires a physical device or macOS host. The benchmark target skips automatically in the iOS Simulator and when `COUNCIL_RUN_BENCHMARKS` is unset.

> Build note (issue #16): upstream `mlx-swift` v0.31.5 fails to compile for iOS Simulator because its `encuda` executable target uses `Process` (macOS/Linux-only API). `Council/Package.swift` therefore points at a local fork (`/Users/vishalsingh/Documents/v-i-s-h-a-l/github/mlx-swift`, tag `0.31.5-council.1`) that guards the `Process` usage with `#if os(macOS) || os(Linux)`. To build CouncilApp, clone that fork (mlx-swift v0.31.5 + `encuda` platform guards, submodules initialized) at the referenced path, then `xcodebuild -scheme CouncilApp` succeeds for both `platform=macOS` and `platform=iOS Simulator`. Revert to the upstream URL once ml-explore/mlx-swift fixes the `encuda` target for iOS destinations.
>
> **Caveat:** SwiftPM currently resolves the identity conflict between the local path fork and `mlx-swift-lm`'s remote `mlx-swift` dependency in favor of the local path, but warns this becomes an error in a future SwiftPM version. The local fork is therefore time-boxed — upstream the `encuda` guards and revert to the URL dependency before that SwiftPM release ships.

## Phase 2: Expanded Memory and Profile
- ✅ Expand profile ingestion: values, goals, boundaries, and basic journal ingestion. (Done — PR #28, #29)
- ✅ SQLCipher full-database encryption. (Done — PR #31, ADR-025 Accepted)
- ✅ Refine purpose-bound access control for richer profile data. (Done — PR #29, ADR-026 Accepted)

## Phase 3: Secretary Layer

- Add MCP-based tool connectors for email, calendar, and tasks.
- Implement expense parsing from emails or statements.
- Add financial dashboards and spending graphs.
- Enable delegated actions with explicit approval.

## Phase 4: Travel and Creation Councils

- Build the Travel Council for purposeful journeys.
- Build the Creation Council for synthesizing experiences into shareable artifacts.
- Add research agents that gather context before travel or writing.

## Phase 5: Governance and Hardening

- Implement runtime constitutional enforcement.
- Add audit trails and sycophancy checks.
- Optimize the local-first / confidential-cloud compute split.
- Document how others can host, extend, and re-constitute their own Council.
