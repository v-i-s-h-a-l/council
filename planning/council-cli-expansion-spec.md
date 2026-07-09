# Council CLI Expansion Spec

**Lifecycle Record:** `2f2f5215-5cca-48b3-8639-1342eac7df4f`  
**Task Ref:** `council-cli-expansion`  
**Branch:** `sdl/council-cli-expansion`  
**Date:** 2026-07-08

## 1. Authority and governance

This spec is governed by lifecycle record `2f2f5215-5cca-48b3-8639-1342eac7df4f` on branch `sdl/council-cli-expansion`. All implementation commits must end with the SDL trailers:

```text
Task-Ref: council-cli-expansion
Lifecycle-Record-ID: 2f2f5215-5cca-48b3-8639-1342eac7df4f
SDL-Commit-Author: capability-commit-author
```

Allowed mutation paths include this spec, `Council/Package.swift`, `COUNCIL_SWIFT_IMPLEMENTATION_SUMMARY.md`, files under `Council/Sources/CouncilCLI/`, `Council/Sources/CouncilMemory/`, `Council/Sources/CouncilCore/`, `Council/Sources/CouncilInference/ModelManifestService.swift`, `Council/Sources/CouncilTestUtilities/`, `Council/Tests/CouncilCLITests/`, and `registry/lifecycle/council-cli-expansion.json`.

## 2. Goal

Expand `CouncilCLI` beyond the single `ask` subcommand with resource-oriented management commands for **profile**, **memory**, **model**, and **audit**. The expansion preserves the local-first, privacy-sensitive posture of Council and follows Swift ArgumentParser best practices discovered through the research stage.

## 3. Research-backed design principles

1. **Noun-verb CRUD.** Resource groups (`profile`, `memory`, `model`, `audit`) expose consistent actions. Subresource commands (`profile value`, `memory fact`) keep the tree shallow and discoverable.
2. **Shared global options.** `--profile-dir`, `--verbose`, and `--format` are declared once via `@OptionGroup` and reused on every subcommand. Global options must appear **after** the subcommand name (e.g. `council profile show --profile-dir /tmp`).
3. **Local-first and privacy-preserving.** All data stays in the profile directory; model manifests and consent are local; audit payloads are encrypted at rest.
4. **Human-in-the-loop consent.** Model download consent can be granted explicitly via `council model consent <id>` and is honored by `council ask --provider mlx`; `--consent-download` remains a one-time convenience flag that also grants consent.
5. **Structured output.** `--format json` emits machine-readable JSON; text/markdown are human-readable. Diagnostics always go to `stderr`.
6. **Tamper-evident audit chain.** `council audit verify` exposes the existing HMAC-SHA256 chain verification. `council audit list` shows metadata only by default; payloads require `--include-payloads`.
7. **Filesystem hardening.** The profile directory is created/verified at `0700`; the raw key file, salt, and database files are set to `0600`; `--profile-dir` supports tilde expansion.

## 4. Command tree

```
council ask <question>              [existing default]
council profile show
          value add <text>
          value remove <id>
          goal add <text> [--timeframe <timeframe>]
          goal remove <id>
          boundary add <text>
          boundary remove <id>
council memory list [--limit <n>]
          show <id>
          search <query> [--limit <n>]
          fact add <subject> <predicate> <object> [--purpose <purpose>]
          fact list [--subject <subject>]
council model list
          register <id> --checksum <sha256:...>
          show <id>
          consent <id>
          revoke <id>
          unregister <id>
council audit list [--since <ISO8601>] [--limit <n>] [--include-payloads]
          verify
```

## 5. Shared infrastructure

### 5.1 `GlobalOptions`

```swift
struct GlobalOptions: ParsableArguments {
    @Option(help: "Directory for profile vault, memory database, and audit log.")
    var profileDir: String?

    @Flag(help: "Print progress and diagnostics to stderr.")
    var verbose = false

    @Option(help: "Output format: text, markdown, or json.")
    var format: CLIOutputFormat = .text
}
```

`CLIOutputFormat` is a top-level `ExpressibleByArgument` enum shared by all commands.

### 5.2 `CLIAssembly`

A thin helper that:
- Resolves `--profile-dir` with tilde expansion,
- Enforces `0o700` on the profile directory,
- Creates a `RuntimeAssembly(useSecureEnclave: false)`,
- Writes verbose progress to `stderr`.

It is reused by every subcommand so that `RuntimeAssembly` wiring is not duplicated.

### 5.3 `CLIEncoder`

A small wrapper around `JSONEncoder` configured with `.sortedKeys`, `.prettyPrinted` for text modes, and ISO8601 dates. Used by all `--format json` code paths.

## 6. Service-layer additions

The CLI commands require the following additions, kept minimal and testable:

### 6.1 `ProfileService`

```swift
func addValue(_ text: String) async throws -> ValueStatement
func removeValue(id: UUID) async throws
func addGoal(_ text: String, timeframe: String?) async throws -> Goal
func removeGoal(id: UUID) async throws
func addBoundary(_ text: String) async throws -> Boundary
func removeBoundary(id: UUID) async throws
```

### 6.2 `MemoryService`

```swift
func episode(id: UUID) async throws -> EpisodicGist?
func searchEpisodes(query: String, limit: Int) async throws -> [EpisodicGist]
func addFact(_ fact: TemporalFact) async throws
func facts(subject: String?) async throws -> [TemporalFact]
```

### 6.3 `AuditLog` protocol

```swift
func entries(since: Date?, limit: Int?, includePayloads: Bool) async throws -> [AuditEntry]
```

A default implementation is provided for backward compatibility. `GRDBAuditLog` implements metadata-only queries when `includePayloads` is `false`.

### 6.4 `ModelManifestService`

```swift
func unregister(id: String)
func manifest(id: String) -> ModelManifest?
func allManifests() -> [ModelManifest]
```

## 7. Subcommand specifications

### 7.1 `profile`

- **`profile show`**  
  Loads the encrypted `UserProfile` and prints values, goals, and boundaries. The `financialHistory` and `journalExcerpts` client-confidential containers are **never** printed; only their counts are shown. `--format json` emits `RoutableProfileContext`.

- **`profile value add <text>`**  
  Appends a `ValueStatement` and prints the new ID.

- **`profile value remove <id>`**  
  Removes the value with the given UUID.

- **`profile goal add <text> [--timeframe <timeframe>]`**  
  Appends a `Goal` and prints the new ID.

- **`profile goal remove <id>`**  
  Removes the goal with the given UUID.

- **`profile boundary add <text>`**  
  Appends a `Boundary` and prints the new ID.

- **`profile boundary remove <id>`**  
  Removes the boundary with the given UUID.

### 7.2 `memory`

- **`memory list [--limit <n>]`**  
  Lists recent episodic gists (id, timestamp, question) newest first. The perspective is omitted in text mode; `--format json` includes a redacted row without full perspective.

- **`memory show <id>`**  
  Displays one episodic gist, including its perspective.

- **`memory search <query> [--limit <n>]`**  
  Filters episodic gists by `question` substring.

- **`memory fact add <subject> <predicate> <object> [--purpose <purpose>]`**  
  Creates a `TemporalFact` with default `purchaseDeliberation` scope and prints the new ID.

- **`memory fact list [--subject <subject>]`**  
  Lists temporal facts, optionally filtered by subject.

### 7.3 `model`

- **`model list`**  
  Prints registered model IDs and checksums. Manifests are in-memory only for this phase; this is documented in help text.

- **`model register <id> --checksum <sha256:...>`**  
  Registers a model manifest.

- **`model show <id>`**  
  Shows the registered checksum and consent status.

- **`model consent <id>`**  
  Grants download consent for the model.

- **`model revoke <id>`**  
  Revokes download consent.

- **`model unregister <id>`**  
  Removes the manifest from the in-memory registry.

### 7.4 `audit`

- **`audit list [--since <ISO8601>] [--limit <n>] [--include-payloads]`**  
  Lists audit entries newest first. Default output is metadata only. Payloads are decrypted only when `--include-payloads` is passed.

- **`audit verify`**  
  Runs `MemoryService.verifyAuditChain()` and prints the result. Exits `0` when valid, `1` when invalid.

## 8. Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success. |
| 1 | Runtime failure (database error, I/O, audit chain invalid). |
| 2 | Deliberation completed without producing a perspective (`ask` only). |
| 64 | Validation/usage error (bad UUID, missing required flag, unknown provider). |
| 130 | Cancelled by SIGINT (`ask` only). |

## 9. Security and privacy model

- Profile directory is created/verified with `0700` permissions.
- Raw key file, salt, and database files are set to `0600`.
- Client-confidential containers are never echoed to stdout.
- Audit payloads are encrypted at rest; `audit list` decrypts only with `--include-payloads`.
- Model checksums use the existing `sha256:` prefix convention.
- No network calls are initiated by any new subcommand.
- `--profile-dir` supports tilde expansion; relative paths are resolved against the current working directory.

## 10. Testing strategy

1. **Parser tests** for each subcommand using `Command.parse([...])`.
2. **Service-level tests** for the new `ProfileService`, `MemoryService`, `AuditLog`, and `ModelManifestService` additions.
3. **Integration tests** with temporary profile directories for each resource group.
4. **Redaction tests** proving `financialHistory`/`journalExcerpts` never appear in `profile show` output.
5. **Permission tests** verifying profile directory and key-file modes.
6. **`swift build` and `swift test` must pass** before any commit is promoted.

## 11. Out of scope

- Multi-profile switching.
- Model downloading/pulling (`council model pull`). The `ask --provider mlx` path continues to use the existing HuggingFace/MLX flow.
- Encrypted audit export bundles or Merkle checkpoints.
- Persistent model manifest registry across process restarts.

## 12. Verification plan

- `cd Council && swift build` succeeds.
- `cd Council && swift test` passes all existing and new tests.
- Each new command parses correctly in a smoke test.
- `audit verify` returns `0` for a valid chain and `1` for a tampered chain.
- `profile show` never emits client-confidential container contents.
- Sibling-agent review passes across correctness, security/privacy, CLI UX, and SDL governance lenses.
- Every implementation commit carries the required SDL trailers.
