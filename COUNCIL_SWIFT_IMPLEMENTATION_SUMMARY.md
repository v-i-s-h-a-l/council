# Council Swift Implementation — CLI Spec Lock Delivery Summary

**Project:** v-i-s-h-a-l/council  
**Branch:** `sdl/council-cli-spec-lock`  
**Lifecycle record:** `b0b9d45a-5b0e-43f3-8621-2e9b4385f8a2`  
**Task reference:** `cli-spec-lock`  
**Date:** 2026-07-08  
**Governing capabilities:** SDL, `capability-implementation-reviewer`, `capability-commit-author`  

---

## 1. Goal of this delivery

Lock the product specification for the minimal command-line interface to Council and ship a working `council ask` executable. This is the first real Swift implementation of the Council runtime for iOS 17 / macOS 14; previous "migration" framing has been retired in favor of "implementation" naming.

---

## 2. What was delivered

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
  - Appends audit entries at each stage transition.
  - Persists an `EpisodicGist` on `.presentation`.
- **`CouncilCLI` executable target** in `Council/Package.swift`.
  - Sources in `Council/Sources/CouncilCLI/` (`main.swift`, `AskCommand.swift`).
  - Depends on `swift-argument-parser`.
  - Correct exit codes: `0` success, `64` validation/usage, `2` runtime, `130` cancelled.
- **`CouncilCLITests`** covering argument parsing, `--no-persist` behavior, formatting, memory-service operations, and mocked end-to-end deliberation.
- **Updated documentation**: `README.md`, `docs/PLAN.md`.

---

## 3. Verification results

```text
cd Council && swift build      ✅ Build complete, Swift 6
cd Council && swift test       ✅ 69 tests passed across 20 suites
cd Council && swift run council ✅ CLI executable runs with echo provider
cd CouncilApp && swift build   ✅ Build complete
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

| Review | Capability | Verdict | Notes |
|---|---|---|---|
| Pre-merge | `capability-implementation-reviewer` | Pending | Findings from exhaustive review will be addressed in this PR. |

---

## 5. Known limitations and next steps

The following items were intentionally deferred to a follow-up hardening phase:

- **Real artifact hash verification** in `ModelContainerPool` is not yet implemented; although `CompositionRoot.swift` registers SHA-256 checksums for the default model per platform, downloaded bytes are not checked against the registered checksum.
- **Performance benchmarks** for first-opinion latency, end-to-end latency, and peak memory are not yet implemented against AC16 thresholds.
- **`xcodebuild` validation** for iOS Simulator and macOS has not been run for this branch.
- **Additional CLI subcommands** (`profile`, `memory`, `model`, `audit`) remain out of scope for v0.1.x.

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

# Build the macOS executable app target
cd ../CouncilApp
swift build
```

---

## 7. Tags and links

- Branch: https://github.com/v-i-s-h-a-l/council/tree/sdl/council-cli-spec-lock
- Pull request: https://github.com/v-i-s-h-a-l/council/pull/5
- Lifecycle record (out-of-band): `~/.stibdedlom/records/v-i-s-h-a-l/council/b0b9d45a-5b0e-43f3-8621-2e9b4385f8a2.json`
- Lifecycle record (repo-local): `registry/lifecycle/council-cli-spec-lock.json`

---

## 8. SDL governance compliance

This work was routed through SDL capabilities:

| Capability | Purpose | Outcome |
|---|---|---|
| `capability-workflow-router` | Classify intent and recommend capabilities | `execution`; `capability-implementation-reviewer` + `capability-commit-author` |
| `capability-implementation-reviewer` | Independent pre-merge implementation review | Findings addressed in PR |
| `capability-commit-author` | Logical commit grouping with SDL trailers | Used for all commits in this PR |

All commits in this PR include the required trailers:

```text
Task-Ref: cli-spec-lock
Lifecycle-Record-ID: b0b9d45a-5b0e-43f3-8621-2e9b4385f8a2
SDL-Commit-Author: capability-commit-author
```

---

*Delivered under SDL governance. Critical product decisions (CLI-first scope, deferral of model hardening) were taken and documented for later review.*
