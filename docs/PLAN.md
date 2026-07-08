# Council Plan

> Phased development of the Council runtime.

## Phase 0: Foundation

- Publish the public `council` repository with README, constitution, architecture, and plan.
- Create the private `council-profile` repository for personal data.
- Define the canonical council member templates and deliberation protocol.
- Choose a local inference stack and an orchestration framework.

## Phase 1: First Council

- Implement a single council: the **Purchase Council**.
- Agents: Frugal, Future Self, Systems Thinker, Pleasure Agent, Chair.
- Input: voice or text describing a purchase.
- Output: a perspective with trade-offs, blind spots, and dissent.
- Minimal memory layer: episodic gist, temporal facts, memory inspector, and audit log.
- Add a minimal **`CouncilCLI`** executable for headless `council ask` usage. See `planning/council-cli-spec.md`.
  > This is an acceleration driven by transparency: from the very first deliberation the user can inspect and edit what the council remembers and verify the audit chain.
- Runtime constitutional enforcement remains future work; the current validator runs after synthesis and rejects verdict language or suppressed dissent.

## Phase 2: Expanded Memory and Profile

- Expand profile ingestion: values, goals, boundaries, and basic journal ingestion.
- SQLCipher full-database encryption.
- Refine purpose-bound access control for richer profile data.

## Phase 3: Secretary Layer

- Add MCP-based tool connectors for email, calendar, and tasks.
- Implement expense parsing from emails or statements.
- Add financial dashboards and spending graphs.
- Enable delegated actions with explicit approval.

## Phase 4: Travel and Creation Councils

- Build the Travel Council for purposeful journeys.
- Build the Creation Council for synthesizing experiences into shareable artifacts.
- Add research agents that gather context before travel or writing.

## Phase 5: Governance and Hardening

- Implement runtime constitutional enforcement.
- Add audit trails and sycophancy checks.
- Optimize the local-first / confidential-cloud compute split.
- Document how others can host, extend, and re-constitute their own Council.
