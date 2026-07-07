# Council Architecture

> High-level design for a local-first, multi-agent deliberation system.

## Overview

Council is composed of four layers:

1. **Orchestrator** — loads the user profile, selects the relevant council, manages the session, and enforces the constitution.
2. **Council Chamber** — the deliberation space where specialized agents reason together.
3. **Memory Layer** — structured, profile-bound storage for facts, preferences, history, and synthesis.
4. **Tool Layer** — MCP-based connectors to external services (calendar, email, finance, travel, web).

## The Council Chamber

A council is a summoned group of agents. Example councils:

- **Purchase Council** — Frugal, Future Self, Systems Thinker, Pleasure Agent.
- **Travel Council** — Explorer, Budget, Family, Ethics, Historian.
- **Life Council** — Skeptic, Poet, Economist, Keeper.

Each council session follows a deliberation protocol:

1. **First opinions** — each agent submits its view.
2. **Peer review** — agents critique each other's views.
3. **Synthesis** — the Chair agent drafts a perspective.
4. **Dissent preservation** — any agent may register a minority note.
5. **Presentation** — the user receives the perspective, not a verdict.

## Memory layer

- **Profile vault** — encrypted, local. Values, goals, boundaries, financial history, journal excerpts.
- **Temporal knowledge graph** — facts with validity over time.
- **Episodic gists** — compressed summaries of past sessions.
- **Purpose-bound access control** — not every agent sees every fact.

## Tool layer

Tools are exposed through MCP servers. Each agent is granted least-privilege access. Tool calls are logged and gated by the constitution.

## Compute model

- Routine deliberation runs locally on open-weight models.
- Heavy reasoning may escalate to an attested confidential cloud node with no retention.
- The profile never leaves the local trust boundary unencrypted.

## Security model

- Profile isolation: one profile per session.
- Runtime policy enforcement: the constitution intercepts actions.
- Audit trail: every deliberation, tool call, and decision is logged.
- Kill switch: the user can halt any agent or the entire council.
