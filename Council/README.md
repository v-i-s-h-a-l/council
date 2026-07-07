# Council Swift Package

SwiftPM package for the Council runtime.

## Targets

- `CouncilCore` — domain models, protocols, constitution, routing policy, data classification.
- `CouncilAgents` — agent definitions, prompt builders, deliberation state machine.
- `CouncilInference` — `InferenceProvider` implementations, including the MLX on-device provider.
- `CouncilMemory` — encrypted profile vault, memory store, audit log.
- `CouncilUI` — SwiftUI views and view models.

## Requirements

- Xcode 16.3+
- Swift 6.3+
- iOS 17+ / macOS 14+ / visionOS 1+

## Build

```bash
cd Council
swift build
swift test
```
