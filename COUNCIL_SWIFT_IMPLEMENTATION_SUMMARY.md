# Council Swift Implementation — CLI Spec Lock and Hardening Summary

**Project:** v-i-s-h-a-l/council  
**Branches:** `sdl/council-cli-spec-lock` (merged), `sdl/council-swift-hardening` (in progress)  
**Lifecycle records:**
- `b0b9d45a-5b0e-43f3-8621-2e9b4385f8a2` (cli-spec-lock, closed)
- `95e897a9-8011-4ba0-ae9f-114d25551c7e` (hardening, open)
**Date:** 2026-07-08  
**Governing capabilities:** SDL, `capability-implementation-reviewer`, `capability-commit-author`  

---

## 1. Goal of this delivery

Lock the product specification for the minimal command-line interface to Council, ship a working `council ask` executable, and complete the production-hardening steps for the first Swift implementation. This is the first real Swift implementation of the Council runtime for iOS 17 / macOS 14; previous "migration" framing has been retired in favor of "implementation" naming.

---

## 2. What was delivered

### CLI spec lock

- **Locked CLI specification** at `planning/council-cli-spec.md`.
  - One subcommand: `council ask <question>`.
  - Text, Markdown, and JSON output formats.
  - Explicit model-download consent (`--consent-download`).
  - Configurable profile directory (`--profile-dir`).
  - Mock/echo inference provider by default so the CLI runs without Metal.
  - Optional real MLX inference (`--provider mlx`) with required `--model` and `--checksum`.
  - Persistence of episodic gist and audit entries unless `--no-persist` is passed.
  - SIGINT handling for graceful cancellation.
- **Shared `RuntimeAssembly`** in `Council/Sources/CouncilAgents/`.
  - UI-agnostic service wiring used by both `CouncilApp.CompositionRoot` and `CouncilCLI`.
  - File-based salt resolution so unsigned CLI binaries do not block on keychain authorization dialogs.
  - Optional `persist` flag on `deliberationService(provider:options:persist:)` to support `--no-persist`.
- **MemoryService/AuditLog integration** into `DeliberationService`.
- **`CouncilCLI` executable target** in `Council/Package.swift`.
- **`CouncilCLITests`** covering argument parsing, `--no-persist` behavior, formatting, memory-service operations, and mocked end-to-end deliberation.

### Hardening

- **Real artifact hash verification** via `ModelArtifactVerifier`.
  - Verifies `model.safetensors` (single-file models) and sharded models via `model.safetensors.index.json`.
  - Wired into `ModelContainerPool.borrow()` so downloaded bytes are checked against the registered checksum.
  - Supports per-shard comma/semicolon-separated checksums or a single combined digest.
- **`CouncilBenchmarks` test target** measuring first-opinion latency, end-to-end latency, and peak resident memory against AC16 thresholds.
  - Skips automatically in the iOS Simulator and when `COUNCIL_RUN_BENCHMARKS` is unset.
  - Auto-computes and registers the model checksum on first load so arbitrary models can be benchmarked.

---

## 3. Verification results

```text
cd Council && swift build      ✅ Build complete, Swift 6
cd Council && swift test       ✅ 69 tests passed across 20 suites
cd Council && swift run council ✅ CLI executable runs with echo provider
cd CouncilApp && swift build   ✅ Build complete
xcodebuild macOS               ❌ Blocked by upstream mlx-swift CudaBuild plugin validation
xcodebuild iOS Simulator       ❌ Blocked by upstream mlx-swift CudaBuild plugin validation
```

Sample CLI run:

```bash
cd Council
.build/debug/council ask "Should I buy a used road bike?" \
    --profile-dir /tmp/council-cli-test --verbose --format text
```

Produces a deterministic echo perspective and persists the episode and audit trail.

---

## 4. Sibling-agent review

| Phase | Capability | Verdict | Notes |
|---|---|---|---|
| CLI spec lock | `capability-implementation-reviewer` | `PASS_WITH_NOTES` | Blockers addressed in PR #5. |
| Hardening | `capability-implementation-reviewer` | `PASS_WITH_NOTES` | Blockers addressed in PR #7: verification moved to load-time, sharded-model test added, lifecycle record paths corrected, docs reconciled. |

---

## 5. Known limitations and next steps

- **`xcodebuild` validation** for `CouncilApp.xcodeproj` is blocked by an upstream `mlx-swift` issue: the `CudaBuild` package plugin fails validation in both macOS and iOS Simulator builds. `swift build` in `CouncilApp/` succeeds, so the SwiftPM package itself is healthy.
- **AC16 benchmark numbers** must be collected on reference hardware (physical iPhone / Apple Silicon Mac) with `COUNCIL_RUN_BENCHMARKS=1`.
- **Additional CLI subcommands** (`profile`, `memory`, `model`, `audit`) remain out of scope for v0.1.x.
- **Runtime constitutional enforcement** remains a future phase; current enforcement is prompt-based + validator-based.

---

## 6. How to build and run

```bash
# Build the SwiftPM package
cd Council
swift build

# Run tests
swift test

# Run the CLI with the echo provider
swift run council ask "Should I buy a used road bike?"

# Run the CLI with MLX (requires a verified checksum)
swift run council ask "Should I buy a used road bike?" \
    --provider mlx \
    --model mlx-community/Qwen2.5-7B-Instruct-4bit \
    --checksum sha256:<verified-digest> \
    --consent-download

# Run on-device benchmarks
COUNCIL_RUN_BENCHMARKS=1 swift test --filter CouncilBenchmarks

# Build the macOS executable app target
cd ../CouncilApp
swift build
```

---

## 7. Tags and links

- CLI spec-lock branch: https://github.com/v-i-s-h-a-l/council/tree/sdl/council-cli-spec-lock
- CLI spec-lock PR: https://github.com/v-i-s-h-a-l/council/pull/5
- Hardening branch: https://github.com/v-i-s-h-a-l/council/tree/sdl/council-swift-hardening
- Lifecycle record (out-of-band): `~/.stibdedlom/records/v-i-s-h-a-l/council/`
- Lifecycle record (repo-local): `registry/lifecycle/`

---

## 8. SDL governance compliance

This work was routed through SDL capabilities:

| Capability | Purpose | Outcome |
|---|---|---|
| `capability-workflow-router` | Classify intent and recommend capabilities | `execution`; `capability-implementation-reviewer` + `capability-commit-author` |
| `capability-implementation-reviewer` | Independent pre-merge implementation review | `PASS_WITH_NOTES` for both phases |
| `capability-commit-author` | Logical commit grouping with SDL trailers | Used for all cli-spec-lock commits; hardening commits from this phase include trailers |

All commits in the cli-spec-lock phase and the new hardening commits include the required trailers:

```text
Task-Ref: cli-spec-lock          # or council-swift-hardening
Lifecycle-Record-ID: <record-id>
SDL-Commit-Author: capability-commit-author
```

The historical hardening commit `82d5389` predates strict SDL trailer enforcement and is retained as-is for history.

---

*Delivered under SDL governance. Critical product decisions (CLI-first scope, local-first inference, deferral of custom models) were taken and documented for later review.*
