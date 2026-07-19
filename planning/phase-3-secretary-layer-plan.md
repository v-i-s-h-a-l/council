# Phase 3: Secretary Layer — Roadmap

**Parent plan:** `docs/PLAN.md` Phase 3 (Secretary Layer)
**Architecture:** `docs/ARCHITECTURE.md` — "Tools are exposed through MCP servers. Each agent is granted least-privilege access. Tool calls are logged and gated by the constitution."
**Foundation issue:** #38 (this document lands with it)

## 1. Vision

The Secretary Layer connects the Council to the user's operational life — email,
calendar, tasks, and finances — so deliberations are grounded in real context
(upcoming trips, actual spending, outstanding commitments) and so routine
secretary work (parsing statements, summarizing schedules) happens without the
user hand-feeding every fact.

The layer follows the same constitutional posture as the rest of Council:
local-first, least-privilege, every access purpose-bound and audit-logged, and
no delegated action without explicit user approval.

## 2. Decomposition into follow-on issues

Phase 3 is delivered as a chain of focused issues, each independently
reviewable and mergeable:

| # | Item | Depends on | Notes |
|---|------|-----------|-------|
| #38 | **Tool-layer foundation** (this issue) | — | `CouncilTools` target, `ToolConnector` protocol, stdio MCP client, `ToolGrant` least-privilege model, `.toolCall` audit, `council tools` CLI |
| TBD | **Tasks connector** | #38 | MCP server exposing the user's task list (read-only first). Candidate backend: Apple Reminders via EventKit on macOS (entitlement/TCC implications documented before implementation). |
| TBD | **Calendar connector** | #38 | Read-only calendar queries (today/upcoming) for deliberation context. Same EventKit/TCC considerations. |
| TBD | **Email connector** | #38 | Read-only search/fetch scoped to expense-relevant senders. Highest sensitivity: default-deny grant, explicit user opt-in per mailbox. |
| TBD | **Expense parsing from statements** | #38 | Local parsing of CSV/OFX statement files into structured expenses stored as purpose-bound temporal facts. No email dependency — statement files first, email ingestion later. |
| TBD | **Financial dashboard (CLI)** | expense parsing | `council secretary expenses summary` — spending by category/period in text/JSON. "Graphs" are CLI-native (sparklines) unless a later decision revives the app surface. |
| TBD | **Delegated actions with explicit approval** | connectors | Write-capable tool calls (create task, draft reply) gated by an interactive approval prompt + audit record of the approval decision. Design ADR required before implementation. |

## 3. Design invariants

These hold for every follow-on issue:

1. **Least privilege by construction** — a connector cannot be invoked without a
   `ToolGrant`, and grants are bound to `AccessPurpose` values, reusing the PBAC
   vocabulary from ADR-026. Denials are decided before any process is spawned or
   data is read.
2. **Read-only before write** — every connector ships read-only first. Write
   capabilities arrive only with the delegated-actions issue and its approval
   gate.
3. **Everything audited** — discovery and invocation produce `.toolCall` audit
   entries with the server, tool, and allow/deny decision. Denied calls are
   audited too, matching the per-item deny logging from issue #36.
4. **Local-first** — connectors run as local child processes over stdio. No
   remote MCP servers without a documented route decision (compute policy in
   `CouncilCore.Policy`).
5. **CLI-first** — the CLI is the primary artifact; `CouncilApp` is untouched
   unless a follow-on issue explicitly revives it.
6. **Server commands are user configuration, never model output** — the
   `--server` command is executed via `/bin/sh -c`. No council agent, model
   output, or tool result may ever populate a server command or its arguments;
   doing so would be remote-code-execution by design. Connectors configured by
   agents must reference pre-registered server identifiers instead.

## 4. MCP transport notes

- Transport: JSON-RPC 2.0 over stdio (`initialize` → `notifications/initialized`
  → `tools/list`, `tools/call`), matching the MCP specification.
- Process spawning is `#if os(macOS) || os(Linux)`-guarded (`Process` is
  unavailable on iOS; same pattern as the mlx-swift fork guard in issue #16).
- Server lifecycle: spawn per CLI invocation, terminate on completion; no
  long-lived daemons in the foundation.
- Timeouts: bounded reads on initialize/list/call so a hung server cannot wedge
  the CLI.

## 5. Open questions for follow-on issues

- EventKit connectors (tasks/calendar): entitlement and TCC behavior for an
  unsigned CLI binary needs a spike before the connector issue is scoped.
- Email: provider story (Apple Mail bridge vs. IMAP) decided in the email
  connector issue; must include a redaction story for sender/content metadata
  in audit payloads.
- Delegated actions: approval UX (terminal prompt vs. audit-then-approve) is a
  product decision for its ADR.
