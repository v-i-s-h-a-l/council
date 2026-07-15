# ADR-026: Purpose-Bound Access Control for Profile and Memory Context

**Status:** Accepted  
**Lifecycle record:** `6171148c-c5fd-4d38-bd99-786de23866ac`  
**Issue:** #26  
**Date:** 2026-07-09

## Context

Council stores increasingly rich personal data:

- Values, goals, and boundaries (routable to agents)
- Journal entries (confidential, user-inspection only)
- Financial history (confidential, user-inspection only)
- Temporal facts and episodic gists (routable only for compatible deliberation purposes)
- Audit log (integrity-protected, read by audit commands)

Not every deliberation should receive every piece of context. A purchase deliberation should see budget facts and purchase-related goals, but it should not see travel goals or journal entries. Purpose-Bound Access Control (PBAC) models use the **intended purpose** of data collection to authorize access, supporting multiple purposes per element and explicit prohibitions ([Byun & Li, Purdue PBAC paper](https://www.cs.purdue.edu/homes/ninghui/papers/pbac_vldbj.pdf)). This aligns with GDPR's Purpose Limitation principle ([Lepide PBAC overview](https://www.lepide.com/blog/what-is-purpose-based-access-control-pbac/)).

## Decision

Adopt a local PBAC layer that labels every context-bearing data element with an `accessScope` (allowed purposes) and an optional `deniedPurposes` set (explicit prohibitions). Access is granted when the request purpose intersects the allow set and does not intersect the deny set.

## Policy model

### Data elements

| Element | Default accessScope | Notes |
|---|---|---|
| `ValueStatement` | `[.purchaseDeliberation, .travelDeliberation, .lifeDeliberation]` | Core identity/persona |
| `Goal` | `[.purchaseDeliberation, .travelDeliberation, .lifeDeliberation]` | May be narrowed by tags |
| `Boundary` | `[.purchaseDeliberation, .travelDeliberation, .lifeDeliberation]` | Hard constraints |
| `TemporalFact` | caller-supplied (default `[.purchaseDeliberation]`) | Set via `--purpose` on `council memory fact add` |
| `EpisodicGist` | `[.purchaseDeliberation, .travelDeliberation, .lifeDeliberation]` | May be locked by user |
| `JournalEntry` | `[.userInspection]` | Never routable to agents |
| `ClientConfidentialContainer` items | `[.userInspection]` | Never routable to agents |

### Purpose enum

The existing `AccessPurpose` enum is the vocabulary:

```swift
public enum AccessPurpose: String, Codable, Sendable {
    case purchaseDeliberation
    case travelDeliberation
    case lifeDeliberation
    case userInspection
}
```

### Access decision

For a request with purposes `R` and a data element with `accessScope: A` and `deniedPurposes: D`:

```
allow iff (R ∩ A ≠ ∅) && (R ∩ D = ∅)
```

If `R` contains `.userInspection`, only elements whose `accessScope` includes `.userInspection` are returned, and deliberation purposes are still blocked by `deniedPurposes`.

## Purpose resolution

### Deliberation purpose

`DeliberationService` resolves the deliberation purpose from the active `Council`:

- `PurchaseCouncil` → `.purchaseDeliberation`
- Future travel council → `.travelDeliberation`
- Future life council → `.lifeDeliberation`

Eventually a lightweight classifier can map free-text questions to purposes when no council type matches.

### CLI purpose

- `council memory fact add` already accepts `--purpose`.
- `council profile journal add` does not expose `--purpose`; journal entries always default to `[.userInspection]`.
- `council profile show` operates under `.userInspection` and therefore displays journal entry metadata but never the full text unless `--reveal` is passed.

## Context filtering in DeliberationService

### Current state

`DeliberationService` receives a `RoutableProfileContext` containing only values, goals, and boundaries. `MemoryService.facts(subject:)` returns all unlocked facts for a subject; `GRDBMemoryStore.temporalFacts(matching:)` already filters by purpose intersection when a `MemoryFilter(purposes:)` is supplied.

### Proposed changes

1. Add `deniedPurposes: [AccessPurpose]` to `TemporalFact` and `EpisodicGist`.
2. Add a public overload `MemoryService.facts(subject:purposes:)` that forwards purpose requirements to the store.
3. Update `GRDBMemoryStore.temporalFacts(matching:)` to apply the deny set after the allow intersection.
4. Add `ProfileService.routableContext(purposes:)` that returns values/goals/boundaries whose `accessScope` intersects the request purposes and whose `deniedPurposes` does not.
5. In `RuntimeAssembly`, resolve the deliberation purpose from the council type and load a filtered `RoutableProfileContext`.
6. Before each agent call in `DeliberationService`, load filtered memory facts and episodes using the resolved purpose.

### Audit

Every PBAC decision is logged to the audit chain:

```
category: .memoryAccess
payload: [
    "purpose": "purchaseDeliberation",
    "dataType": "TemporalFact",
    "decision": "allow",
    "count": "3"
]
```

Denied access attempts are also logged so users can inspect whether sensitive context was correctly excluded.

## Agent-native design

The primary consumer of profile and memory context is an autonomous agent. PBAC ensures:

- The agent only sees data relevant to the current deliberation purpose.
- Confidential data (journal, financial) is never surfaced in prompts.
- Explicit prohibitions let users override accidental over-sharing (e.g., a boundary tagged `work` can be denied for `.lifeDeliberation`).

## Implementation sketch

```swift
public struct ContextFilter {
    public var purposes: Set<AccessPurpose>
    public init(purposes: Set<AccessPurpose>) { self.purposes = purposes }
}

extension ProfileService {
    public func routableContext(filter: ContextFilter) async throws -> RoutableProfileContext {
        let profile = try await load()
        return RoutableProfileContext(
            values: profile.values.filter { isAllowed($0.accessScope, denied: [], filter: filter) },
            goals: profile.goals.filter { isAllowed($0.accessScope, denied: [], filter: filter) },
            boundaries: profile.boundaries.filter { isAllowed($0.accessScope, denied: [], filter: filter) }
        )
    }
}

private func isAllowed(
    _ accessScope: [AccessPurpose],
    denied: [AccessPurpose],
    filter: ContextFilter
) -> Bool {
    let allowed = !Set(accessScope).isDisjoint(with: filter.purposes)
    let blocked = !Set(denied).isDisjoint(with: filter.purposes)
    return allowed && !blocked
}
```

## Validation

- Add `PurposeBoundAccessControlTests`:
  - A fact with `accessScope: [.purchaseDeliberation]` is returned for `.purchaseDeliberation` but not `.travelDeliberation`.
  - A fact with `deniedPurposes: [.purchaseDeliberation]` is excluded even when `accessScope` allows it.
  - Journal entries are never returned for deliberation purposes.
  - `RoutableProfileContext` from `ProfileService.routableContext(filter:)` excludes denied values/goals/boundaries.
- Update `DeliberationIntegrationTests` to assert that memory facts are filtered by council type.

## References

- Byun & Li, "Purpose Based Access Control for Privacy Protection in Relational Database Systems": https://www.cs.purdue.edu/homes/ninghui/papers/pbac_vldbj.pdf
- Lepide, "What Is Purpose-Based Access Control (PBAC)?": https://www.lepide.com/blog/what-is-purpose-based-access-control-pbac/
