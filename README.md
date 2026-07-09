# Council

> A personal, local-first, constitution-governed multi-agent council for deliberation, perspective, and mindful action.

Council is not a chatbot. It is a deliberative system: a room of specialized agents that think about your questions from different angles, disagree when appropriate, and offer you a perspective rather than a verdict.

## Core principles

- **User sovereignty.** You decide. The council advises, challenges, and clarifies. It does not act unless you explicitly delegate.
- **Privacy by architecture.** Your profile lives in a separate, private space. The council runtime never mixes users, never phones home, and never monetizes attention.
- **Non-manipulation.** The council has no sales agenda, no engagement optimization, and no hidden persuasion.
- **Epistemic humility.** Agents preserve dissent, declare uncertainty, and surface blind spots instead of forcing consensus.
- **Local-first.** Run on your own hardware. Escalate to confidential compute only when necessary, with your consent.

## What it is for

- Purposeful travel, learning, and life direction.
- Purchase and financial decisions.
- Daily logistics — when you choose to delegate them.
- Synthesis of experiences into shareable perspective.

## What it is not for

- Replacing your judgment.
- Autonomous action without consent.
- Collecting data for advertising or platform growth.
- Pretending to know you better than you know yourself.

## Architecture

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Constitution

See [CONSTITUTION.md](CONSTITUTION.md).

## Build and run

> **CLI-first:** The `council` command-line tool is the primary artifact. `CouncilApp` is an optional SwiftUI wrapper and receives lower priority.

### Swift package

```bash
cd Council
swift build
swift test
```

### Command-line interface

```bash
cd Council
swift build
swift run council ask "Should I buy a used road bike for $800?"
```

The CLI defaults to an echo provider so it works without downloading a model. For real on-device inference:

```bash
swift run council ask "Should I buy a used road bike for $800?" \
    --provider mlx \
    --model mlx-community/Qwen2.5-7B-Instruct-4bit \
    --checksum sha256:<verified-digest> \
    --consent-download
```

> Note: The CLI stores the profile key in a file inside `--profile-dir` so it can run without keychain entitlements. The Xcode app continues to use the Secure Enclave / Keychain when available.

### macOS executable (SwiftPM)

```bash
cd CouncilApp
swift build
swift run CouncilApp
```

> Note: `swift run` launches the SwiftUI executable on macOS. It is not a signed `.app` bundle, so keychain and entitlement behaviors are limited compared with an Xcode-built app.

### Xcode project (macOS/iOS)

```bash
cd CouncilApp
./generate-project.sh
open CouncilApp.xcodeproj
```

Set the destination to **macOS 14+** or **iOS 17+** and build. The project embeds the local `Council` SwiftPM package.

> **iOS Simulator limitation:** `xcodebuild` for the generated `CouncilApp.xcodeproj` is blocked for the iOS Simulator because the upstream `mlx-swift` `encuda` executable target uses the macOS-only `Process` API and is incorrectly compiled for the simulator target. macOS `xcodebuild` succeeds. Physical-device and App Store builds may work because the plugin is host-side. `swift build` in `CouncilApp/` also works.

## Supported devices

- macOS 14 or later.
- iOS 17 or later.
- On-device MLX inference requires Apple Silicon and the Metal toolchain.

## Example session

See [examples/purchase-council.md](examples/purchase-council.md) for a sample Purchase Council question and representative perspective output.

## Plan

See [docs/PLAN.md](docs/PLAN.md).

## License

MIT
