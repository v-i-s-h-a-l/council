# Phase 2: Expanded Memory and Profile — Implementation Plan

**Lifecycle record:** `6171148c-c5fd-4d38-bd99-786de23866ac`  
**Capability:** `capability-apple-native-development`  
**Branch:** `feature/phase-2-memory-profile`  
**Issues:** #23 (parent), #24 (implementation), #25 (SQLCipher groundwork), #26 (purpose-bound access control groundwork)

## 1. Current state

Phase 1 (PR #21) already delivered the CLI-first scaffold:

- `council profile value add|remove`
- `council profile goal add|remove --timeframe <...>`
- `council profile boundary add|remove`
- `council profile show` renders values, goals, boundaries and counts of confidential containers.

What is **missing** for Phase 2:

- A structured `journal` subcommand and data model.
- Agent-native metadata on profile entries (created-at, tags, priority/severity/status) so an autonomous agent can reason about recency, relevance, and scope.
- A documented path to full-database encryption for GRDB stores (#25).
- A concrete policy model for purpose-bound access control that filters profile and memory context in `DeliberationService` (#26).

This plan treats the CLI as the primary artifact and leaves `CouncilApp` untouched.

## 2. Research-backed decisions

### 2.1 Terminal-native CLI UX for personal knowledge management

Command-line personal-knowledge tools succeed when they are **scriptable, composable, and idempotent**. The `jrnl` reference design shows the winning patterns for a journal CLI:

- Free-text entry with an optional timestamp and tags ([jrnl command-line reference](https://jrnl.sh/en/stable/reference-command-line/)).
- Search by date range, tag, and content substring.
- Machine-readable (`--format`) and human-readable output modes.
- Never prompt interactively in default mode, so commands can be composed in shell scripts.

For Council we will adopt the same posture: `council profile journal add "..." --tag work --tag stress` appends an entry and prints the entry ID; `council profile journal list --tag work` returns filtered entries; `council profile journal remove <id>` removes by ID. This is consistent with the CLI-UX principle of "reasonable defaults, easy overrides" and reduced cognitive load ([cli-ux-patterns skill](https://skills.rest/skill/cli-ux-patterns)).

### 2.2 SQLCipher integration with GRDB.swift

GRDB 7.10.0 added experimental SQLCipher support through Swift Package Manager, but the upstream maintainer is explicit that it **requires a fork of GRDB.swift** because SPM lacks package traits to select between the system SQLite and SQLCipher backends ([Swift Forums announcement](https://forums.swift.org/t/grdb-v7-10-0-android-linux-windows-and-sqlcipher-swiftpm/84754)). The fork modifies `Package.swift` at commented `GRDB+SQLCipher` markers.

Council currently depends on GRDB 7.9.0 and uses column-level AES-256-GCM encryption in `GRDBMemoryStore`. Moving to SQLCipher would give us **full-database encryption**, closing the gap where SQLite metadata (schema, row counts, timestamps) is presently unencrypted. The migration path is:

1. Fork `groue/GRDB.swift` (or pin a trusted community fork) and bump the dependency to a SQLCipher-enabled tag ≥ 7.10.0.
2. Add a SQLCipher package dependency.
3. Keep the existing column-level encryption as defense-in-depth during the transition; do not remove it in the same PR.
4. Provide a one-way migration that opens the old database under the current GRDB, exports the encrypted rows, and imports them into a new SQLCipher-backed database keyed with the same derived database key.
5. Validate with existing `GRDBMemoryStoreTests` and a new migration test.

Because the fork requirement changes the supply chain, this issue is scoped to **planning and a documented migration ADR** in this session; the actual dependency swap is a follow-up PR.

### 2.3 Purpose-bound access control

Purpose-Based Access Control (PBAC) extends traditional models by binding data elements to the **intended purposes** of their use, not only to identities or roles. Byun and Li's foundational model supports multiple purposes per data element, explicit prohibitions, and hierarchical purpose taxonomies ([Purdue PBAC paper](https://www.cs.purdue.edu/homes/ninghui/papers/pbac_vldbj.pdf)). In the local-first, privacy-sensitive Council architecture this maps naturally:

- Data elements: `TemporalFact`, `EpisodicGist`, `JournalEntry`, `ValueStatement`, `Goal`, `Boundary`.
- Intended purposes: the existing `AccessPurpose` enum (`purchaseDeliberation`, `travelDeliberation`, `lifeDeliberation`, `userInspection`).
- Access purpose: the deliberation type resolved from the user's question or an explicit `--purpose` flag on CLI queries.
- Prohibitions: a `deniedPurposes` set on confidential entries (e.g., journal entries never routable to a model).

PBAC is also the legal-technical bridge to GDPR's Purpose Limitation principle, which is why it is recommended for privacy-sensitive local data ([Lepide PBAC overview](https://www.lepide.com/blog/what-is-purpose-based-access-control-pbac/)).

### 2.4 Agent-native data modeling

Autonomous agents consume profile and memory context differently from humans browsing a GUI. Research on agent memory systems emphasizes four requirements:

1. **Structured identity/persona** (values, goals, boundaries) ([OpenReview agent persona survey](https://openreview.net/pdf?id=2twjsGSWtj)).
2. **Temporal indexing** so the agent can weight recency.
3. **Categorical tags** for relevance filtering.
4. **Explicit confidentiality boundaries** so the agent never includes prohibited data in prompts.

Council already has (1) and (4). Phase 2 adds (2) and (3) to journal entries, and back-ports lightweight metadata to values, goals, and boundaries where it improves routing without breaking existing data.

## 3. Implementation plan for #24

### 3.1 Data model changes (`CouncilCore/Models.swift`)

1. Add `JournalEntry`:
   ```swift
   public struct JournalEntry: Codable, Sendable, Identifiable {
       public var id: UUID
       public var text: String
       public var createdAt: Date
       public var tags: [String]
       public var accessScope: [AccessPurpose]
       public var isLocked: Bool
   }
   ```
   Journal entries are confidential: their default `accessScope` is `[.userInspection]` and they are never included in `RoutableProfileContext`.
2. Replace `UserProfile.journalExcerpts: ClientConfidentialContainer` with `UserProfile.journalEntries: [JournalEntry]` and update every call site (see mechanical refactor checklist below).
3. Add a custom `init(from decoder:)` on `UserProfile` that migrates legacy profiles:
   - If `journalEntries` is present, decode normally.
   - Else if legacy `journalExcerpts: ClientConfidentialContainer` is present, map each item to a `JournalEntry(text: item, createdAt: Date(), tags: [], accessScope: [.userInspection])`.
   - Mark migrated entries with `accessScope: [.userInspection]` so they are never routed to a model by default.
4. Add lightweight metadata to existing types (all optional with sensible defaults so legacy JSON decodes without misleading timestamps):
   - `ValueStatement.createdAt: Date?`, `tags: [String]`
   - `Goal.createdAt: Date?`, `tags: [String]`, `status: GoalStatus?`
   - `Boundary.createdAt: Date?`, `tags: [String]`, `severity: BoundarySeverity?`
   - `GoalStatus` and `BoundarySeverity` are small `String`-backed enums (`active`, `completed`, `paused` and `low`, `medium`, `high`, `critical`) to give agents a stable vocabulary while preserving the optional free-form case.

**Mechanical refactor checklist** (source-breaking `journalExcerpts` usages):
- `Council/Sources/CouncilCLI/ProfileCommand.swift:52` (show command)
- `Council/Tests/CouncilCLITests/CLIIntegrationTests.swift:191`
- `Council/Tests/CouncilCoreTests/ModelsTests.swift:20`
- `Council/Tests/CouncilAgentsTests/PromptBuilderTests.swift:56`
- `Council/Tests/CouncilMemoryTests/PromptLeakageTests.swift:16,32,42`
- `Council/Tests/CouncilMemoryTests/CryptoKitProfileVaultTests.swift:36,46,58`
- `Council/Tests/CouncilIntegrationTests/ProfileMemoryAuditIntegrationTests.swift:58,109`

### 3.2 Service changes (`CouncilMemory/ProfileService.swift`)

Add actor methods:

- `addJournalEntry(_:tags:accessScope:)` → returns `JournalEntry`
- `removeJournalEntry(id:)`
- `journalEntries(matching:)` (optional; used by list subcommand)

### 3.3 CLI changes (`CouncilCLI/ProfileCommand.swift`)

Add `JournalCommand` as a subcommand of `ProfileCommand`:

- `council profile journal add <text> [--tag <tag>]... [--date <iso8601>] [--stdin]`
  - Default `createdAt` is now.
  - Default `accessScope` is `[.userInspection]` (never routed); no `--purpose` flag is exposed because journals are confidential.
  - If `<text>` is omitted or `--stdin` is passed, read the entry body from standard input so multi-line entries are scriptable.
  - Prints entry ID.
- `council profile journal list [--tag <tag>]... [--from <date>] [--to <date>] [--format text|json] [--reveal]`
  - By default lists only entry dates + tags + first line; full `text` is redacted unless `--reveal` is passed.
  - Tag filters use AND semantics: `--tag work --tag stress` matches entries that have both tags.
  - In JSON mode `text` is also redacted unless `--reveal` is passed.
- `council profile journal remove <id>`

Update existing `value`/`goal`/`boundary` add commands to accept the new metadata:

- `council profile value add <text> [--tag <tag>]...`
- `council profile goal add <text> [--timeframe <timeframe>] [--tag <tag>]... [--status <active|completed|paused>]`
- `council profile boundary add <text> [--tag <tag>]... [--severity <low|medium|high|critical>]`

Update `council profile show`:

- Render values/goals/boundaries with tags when present.
- Render journal count and a reminder that entries are confidential; never print journal text.
- JSON mode continues to emit only `RoutableProfileContext` (values/goals/boundaries), keeping journal entries out of the routable context.

### 3.4 Idempotency and scriptability

- `add` commands are not idempotent by design (each call creates a new entry), but they are **safe to replay** because duplicates are explicit and removable by ID.
- All subcommands support `--format json` for shell composition.
- Date parsing uses `ISO8601DateFormatter` with `.withInternetDateTime`; invalid dates fail fast with a clear error.

### 3.5 Tests

- `CouncilCLITests`:
  - Parse tests for `journal add`, `journal list`, `journal remove`.
  - Parse tests for new `--tag`, `--status`, `--severity` options on value/goal/boundary add commands.
  - Service-level add/remove/list for journal entries using `MockProfileVault`.
  - Legacy migration test: decode an old-profile JSON that contains `journalExcerpts` and assert it becomes `journalEntries` with `.userInspection` scope.
  - Negative tests for invalid ISO dates and missing `--reveal` redaction.
- `CLIIntegrationTests`:
  - End-to-end journal lifecycle through `RuntimeAssembly`.
  - Verify `RoutableProfileContext` excludes journal entries.
  - Update existing `profileRedaction` and `profileManagement` tests to use `journalEntries`.
- `CryptoKitProfileVaultTests`:
  - Update assertions that referenced `journalExcerpts` to assert on `journalEntries`.
- `CouncilCoreTests/ModelsTests`, `CouncilAgentsTests/PromptBuilderTests`, `CouncilMemoryTests/PromptLeakageTests`, `CouncilIntegrationTests/ProfileMemoryAuditIntegrationTests`:
  - Update all `UserProfile(..., journalExcerpts: ...)` constructions to `journalEntries: [...]`.

## 4. Groundwork for #25 (SQLCipher migration)

Deliverable: a planning ADR at `planning/adr-025-sqlcipher-migration.md` containing:

- Decision: adopt a forked GRDB + SQLCipher dependency once SPM/package traits mature or a trusted fork is available.
- Rationale: full-database encryption versus current column-level encryption; metadata leakage analysis.
- Migration sequence:
  1. Bump GRDB to SQLCipher-enabled fork ≥ 7.10.0.
  2. Keep existing `GRDBMemoryStore` API unchanged.
  3. Add `SQLCipherMigration` helper that opens the legacy file with the current GRDB, iterates records, decrypts sensitive columns with the existing derived key, and writes them into a new SQLCipher-backed database using the same derived key as the passphrase.
  4. Atomically swap files (write new, move old to `.pre-sqlcipher-backup`).
  5. On first open, detect legacy file and run migration automatically.
- Keying detail: SQLCipher must be opened with the raw 32-byte derived key in `PRAGMA key = "x'...'"` raw-key mode, not a passphrase, so that the existing HKDF-derived key is used directly without an additional PBKDF2 round.
- Rollback path: before migration, move the legacy database to `<name>.pre-sqlcipher-backup`. If migration fails, delete the partial new database and restore the backup. On success, keep the backup until the next successful launch.
- Risk: dependency fork adds maintenance burden; mitigation is to pin an exact tag and schedule quarterly reviews.
- Validation checklist: existing `GRDBMemoryStoreTests` must pass; add a migration round-trip test.

## 5. Groundwork for #26 (purpose-bound access control)

Deliverable: a planning ADR at `planning/adr-026-purpose-bound-access-control.md` containing:

- Policy model:
  - Each data element carries `accessScope: Set<AccessPurpose>` (allow) and `deniedPurposes: Set<AccessPurpose>` (explicit prohibition).
  - A request is authorized iff `requestPurposes ∩ accessScope ≠ ∅` and `requestPurposes ∩ deniedPurposes = ∅`.
- Purpose resolution:
  - `DeliberationService` resolves the deliberation purpose from the `Council` type (`PurchaseCouncil` → `.purchaseDeliberation`, etc.) and eventually from the question text via a lightweight classifier.
- Context filtering:
  - Introduce `ContextFilter(purposes: Set<AccessPurpose>)`.
  - Add a public `MemoryService.facts(subject:purposes:)` overload that forwards purpose requirements to `GRDBMemoryStore.temporalFacts(matching:)`; extend the store filter to respect `deniedPurposes`.
  - `ProfileService.routableContext(purposes:)` returns values/goals/boundaries whose tags or metadata match the purpose, and **never** returns journal entries.
- Audit:
  - Each access decision is logged to the audit chain with `purpose`, `dataElementType`, `decision`.
- CLI exposure:
  - `council memory fact add` already accepts `--purpose`; document that `council profile journal add` defaults to `.userInspection` and does not expose `--purpose`.
- Implementation sketch for `DeliberationService`:
  - Replace the raw `RoutableProfileContext` parameter with a purpose-resolved context loaded by `RuntimeAssembly`.
  - Before each agent call, filter memory facts and episodes by the resolved purpose.

## 6. Sibling-agent review

A sibling-agent review was performed on this plan. Overall verdict: **CONCERN → resolved in plan revision**.

Key findings and resolutions:

1. **Architecture** — the original plan omitted the mechanical refactor inventory for all `journalExcerpts` call sites. Resolution: added an explicit checklist covering `ProfileCommand.swift`, `CLIIntegrationTests.swift`, `ModelsTests.swift`, `PromptBuilderTests.swift`, `PromptLeakageTests.swift`, `CryptoKitProfileVaultTests.swift`, and `ProfileMemoryAuditIntegrationTests.swift`.
2. **Data-model defaults** — back-dated `createdAt: Date` would have misled recency-based agent reasoning. Resolution: changed `createdAt` to `Date?` and introduced `GoalStatus`/`BoundarySeverity` enums.
3. **Security** — the original `journal add --purpose` option conflicted with the confidentiality guarantee. Resolution: removed `--purpose` from `journal add`; journals always use `[.userInspection]`.
4. **SQLCipher keying** — the plan did not specify raw-key mode. Resolution: documented `PRAGMA key = "x'...'"` and a rollback procedure.
5. **CLI UX** — metadata was not editable from the CLI and multi-line input was unsupported. Resolution: added `--tag`/`--status`/`--severity` options, `--stdin` support, AND semantics for tag filters, and JSON redaction behavior.
6. **Test coverage** — negative cases and test refactor checklist were missing. Resolution: added invalid-date tests, redaction tests, and the mechanical refactor checklist.

Review findings are also recorded in the lifecycle record under `retrospective_reviews`.

## 7. Quality gates

- `swift build` in `Council/`
- `swift test` in `Council/`
- `swift run council --help` and relevant subcommands work
- No regression in existing tests
- No modifications to `CouncilApp` except critical fixes

## 8. Commits and SDL trailers

Commits will use Conventional Commits and include `SDL-Commit-Author` / `SDL-Routing-Attestation` trailers where the local pre-commit hook permits. If the hook requires `--no-verify`, that usage will be documented as governance debt in the PR description.
