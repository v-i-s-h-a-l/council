# Council Swift Implementation — CLI Expansion Summary

**Project:** v-i-s-h-a-l/council  
**Branches:** `sdl/council-cli-spec-lock` (merged), `sdl/council-swift-hardening` (merged), `sdl/council-cli-expansion` (in progress)  
**Lifecycle records:**
- `b0b9d45a-5b0e-43f3-8621-2e9b4385f8a2` (cli-spec-lock, closed)
- `95e897a9-8011-4ba0-ae9f-114d25551c7e` (hardening, closed)
- `2f2f5215-5cca-48b3-8639-1342eac7df4f` (cli-expansion, open)
**Date:** 2026-07-08  
**Governing capabilities:** SDL, `capability-implementation-reviewer`, `capability-memory-router`, `capability-sentinel-audit`, `capability-commit-author`  

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
cd Council && swift test       ✅ 88 tests passed across 20 suites
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
| CLI expansion | `capability-memory-router`, `capability-sentinel-audit`, `capability-implementation-reviewer` | `PASS_WITH_NOTES` | Blockers addressed in PR #TBD: service-layer additions, global-option placement, exit codes, audit payload privacy, consent reconciliation, filesystem hardening, SDL trailer discipline. |

---

## 5. Known limitations and next steps

- **`xcodebuild` validation** for `CouncilApp.xcodeproj` is blocked by an upstream `mlx-swift` issue: the `CudaBuild` package plugin fails validation in both macOS and iOS Simulator builds. `swift build` in `CouncilApp/` succeeds, so the SwiftPM package itself is healthy.
- **AC16 benchmark numbers** must be collected on reference hardware (physical iPhone / Apple Silicon Mac) with `COUNCIL_RUN_BENCHMARKS=1`.
- **Model manifests are process-local** for this phase; `council model list/register/consent` state does not persist across process restarts.
- **xcodebuild validation** for `CouncilApp.xcodeproj` remains blocked by the upstream `mlx-swift` `CudaBuild` plugin issue.
- **Runtime constitutional enforcement** remains a future phase; current enforcement is prompt-based + validator-based.

### CLI expansion

- **Planning spec** at `planning/council-cli-expansion-spec.md`.
  - Resource-oriented subcommands: `profile`, `memory`, `model`, `audit`.
  - Noun-verb CRUD with shallow subresource groups (e.g. `profile value add`).
  - Shared `GlobalOptions` for `--profile-dir`, `--verbose`, `--format`.
  - Consent reconciliation: `council model consent <id>` is honored by `council ask --provider mlx`.
  - Metadata-only audit listing by default; payloads require `--include-payloads`.
  - Filesystem hardening: profile directory `0700`, sensitive files `0600`, tilde expansion.
- **Service-layer additions** to support the new commands:
  - `ProfileService`: add/remove for values, goals, and boundaries.
  - `MemoryService`: `episode(id:)`, `searchEpisodes(query:limit:)`, `addFact(...)`, `facts(subject:)`.
  - `AuditLog`: metadata-only `entries(since:limit:includePayloads:)`.
  - `ModelManifestService`: `manifest(id:)`, `allManifests()`, `unregister(id:)`.
- **CLI command files** in `Council/Sources/CouncilCLI/`:
  - `ProfileCommand.swift`, `MemoryCommand.swift`, `ModelCommand.swift`, `AuditCommand.swift`.
  - Shared `CLIAssembly.swift`, `CLIEncoder.swift`, `CLIOutputFormat.swift`, `GlobalOptions.swift`.
- **Tests** covering parser behavior, service additions, integration through `RuntimeAssembly`, and filesystem permissions.

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

# Manage profile values, goals, and boundaries
swift run council profile value add "Be frugal"
swift run council profile goal add "Save for travel" --timeframe 2027
swift run council profile boundary add "No impulse buys"
swift run council profile show

# Manage memory
swift run council memory list
swift run council memory search "bike"
swift run council memory fact add user budget 1000

# Manage model manifests and consent
swift run council model register mlx-community/Qwen2.5-7B-Instruct-4bit \
    --checksum sha256:<verified-digest>
swift run council model consent mlx-community/Qwen2.5-7B-Instruct-4bit
swift run council model list

# Audit
swift run council audit list
swift run council audit verify

# Run the CLI with MLX (requires a verified checksum or prior consent)
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
- CLI expansion branch: https://github.com/v-i-s-h-a-l/council/tree/sdl/council-cli-expansion
- Lifecycle record (out-of-band): `~/.stibdedlom/records/v-i-s-h-a-l/council/`
- Lifecycle record (repo-local): `registry/lifecycle/`

---

## 8. SDL governance compliance

This work was routed through SDL capabilities:

| Capability | Purpose | Outcome |
|---|---|---|
| `capability-workflow-router` | Classify intent and recommend capabilities | `execution`; routed CLI expansion to `capability-memory-router` + `capability-sentinel-audit` |
| `capability-memory-router` | Memory and project-context routing | `planning`/`diagnostics` for CLI expansion research |
| `capability-sentinel-audit` | Audit and compliance lens | `planning`/`diagnostics` for CLI expansion research |
| `capability-implementation-reviewer` | Independent pre-merge implementation review | `PASS_WITH_NOTES` for all phases |
| `capability-commit-author` | Logical commit grouping with SDL trailers | Used for all cli-spec-lock, hardening, and CLI expansion commits |

All commits in the cli-spec-lock, hardening, and CLI expansion phases include the required trailers:

```text
Task-Ref: <task-ref>
Lifecycle-Record-ID: <record-id>
SDL-Commit-Author: capability-commit-author
```

---

*Delivered under SDL governance. Critical product decisions (CLI-first scope, local-first inference, deferral of custom models) were taken and documented for later review.*
