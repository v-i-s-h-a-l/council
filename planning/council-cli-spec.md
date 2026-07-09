# CouncilCLI Specification

> Locked specification for the minimal command-line interface to Council.
> Lifecycle record: `b0b9d45a-5b0e-43f3-8621-2e9b4385f8a2`

## Goal

Provide a headless, terminal-based entry point to the Purchase Council so users can build, test, and script deliberations without launching the SwiftUI app.

## Scope

### In scope for v0.1.x

- One subcommand: `council ask <question>`.
- Plain-text, Markdown, and JSON output formats.
- Explicit model-download consent (`--consent-download`).
- Configurable profile directory (`--profile-dir`).
- Mock/echo inference provider by default so the CLI runs without Metal.
- Optional real MLX inference (`--provider mlx`).
- Persistence of the resulting episodic gist and audit entries unless `--no-persist` is passed.
- Signal handling for graceful cancellation (SIGINT).

### Out of scope for v0.1.x

- Subcommands for `profile`, `memory`, `model`, and `audit`.
- Interactive profile editing.
- Per-token streaming output.
- Third-party cloud providers.

## Command interface

```text
OVERVIEW: Run a local, constitution-governed Purchase Council from the terminal.

USAGE: council ask <question> [options]

ARGUMENTS:
  <question>               The purchase question to deliberate.

OPTIONS:
  --profile-dir <path>     Directory for profile vault and databases.
                           Default: ~/Library/Application Support/Council (macOS)
                                    or the platform Application Support directory.
  --provider <provider>    Inference provider: echo (default) or mlx.
  --model <id>             Model identifier. Required when provider is mlx.
  --checksum <digest>      SHA-256 checksum of the model. Required when provider is mlx.
  --consent-download       Grant explicit consent to download the model.
  --format <format>        Output format: text (default), markdown, json.
  --no-persist             Skip saving the episodic gist and audit log.
  --verbose                Print stage progress to stderr.
  -h, --help               Show help information.
```

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 64 | Argument or validation error |
| 2 | Inference or runtime error |
| 130 | Cancelled by user |

## Architecture

`CouncilCLI` is a new executable target in the `Council` package. It imports only non-UI modules:

- `CouncilCore`
- `CouncilAgents`
- `CouncilInference`
- `CouncilMemory`

Service wiring is delegated to a UI-agnostic `RuntimeAssembly` shared with `CouncilApp`. `CouncilApp.CompositionRoot` uses the same assembly and then creates view models.

## Data flow

1. Parse arguments with `swift-argument-parser`.
2. Resolve the profile directory and initialize `RuntimeAssembly` with `useSecureEnclave: false`.
3. Load the profile via `ProfileService`.
4. Register the requested model manifest and checksum.
5. If `--consent-download` is passed, grant consent.
6. Create the inference provider (`EchoInferenceProvider` or `MLXInferenceProvider`).
7. Run `DeliberationService` with `PurchaseCouncil`.
8. Consume `stateUpdates()` until `.presentation`, `.cancelled`, or `.failed`.
9. Format and print the perspective.
10. Unless `--no-persist`, save an `EpisodicGist` and append audit entries via `MemoryService`.

## Security and privacy

- The CLI uses the same encrypted profile vault and GRDB memory/audit stores as the app.
- Because unsigned command-line binaries lack the entitlements required for Secure Enclave keychain access, the CLI stores the profile encryption key in a file (`profile.key`) inside `--profile-dir`. This is documented and scoped to the CLI invocation.
- The Xcode app continues to use Secure Enclave / Keychain key binding when available.
- Model download requires explicit consent; the CLI does not auto-grant consent.
- Third-party routes are denied by default.

## Acceptance criteria

- `swift build` succeeds for the `CouncilCLI` target.
- `council ask "Should I buy X?"` prints a perspective using the echo provider.
- `council ask --provider mlx --model <id> --checksum <sha256> --consent-download` attempts real inference.
- SIGINT cancels the session and does not leave a partial perspective persisted.
- `CouncilCLITests` covers argument parsing, formatting, memory service operations, and a mocked end-to-end deliberation.
