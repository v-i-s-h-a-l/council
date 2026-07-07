# Design Journey

> How the Council idea took shape, what it believes, and what research informs it.

## Why Council exists

Most AI assistants are built to optimize productivity, engagement, or commerce. Council is built to help a person live with more clarity, freedom, and perspective. It is a personal, local-first, multi-agent deliberation system — a council of specialized agents that think together about your decisions, surface blind spots, and offer perspective without taking away your authority.

The project started from a simple frustration: existing tools either collect personal data for commercial ends, or they act too much on the user's behalf. Council tries to do the opposite. It keeps the runtime open and inspectable, the profile private and user-controlled, and the agent behavior bound by a public constitution.

## What Council is not

- It is not a chatbot that gives one answer.
- It is not a commercial service that monetizes attention or data.
- It is not an autonomous actor that replaces your judgment.
- It is not a surveillance device that watches you continuously.
- It is not a single worldview dressed up as neutral advice.

## Core design principles

1. **User sovereignty.** You decide. The council may advise, warn, and challenge; it may not coerce, manipulate, or act without explicit delegation.
2. **Privacy by architecture.** Your profile lives in a separate, private space. The runtime never mixes users, never phones home, and never monetizes attention.
3. **Non-manipulation.** No agent may optimize for engagement, platform growth, sales, or hidden agendas.
4. **Epistemic humility.** Agents preserve dissent, declare uncertainty, and distinguish inference from confirmed knowledge.
5. **Growth of freedom.** The council should expand your options and self-understanding, not narrow them into a filter bubble.
6. **Advise by default, act only when delegated.** Tools that affect the external world require explicit authorization.
7. **Local-first.** Run on your own hardware. Escalate to confidential compute only when necessary, with your consent.

## The multi-agent council model

Instead of one assistant with one opinion, Council summons a group of specialized agents for a given question. Each agent embodies a different lens. They deliberate, critique each other, and present the user with a structured perspective — including agreement, caveats, and dissent.

Example councils:

- **Purchase Council** — Frugal, Future Self, Systems Thinker, Pleasure Agent.
- **Travel Council** — Explorer, Budget, Family, Ethics, Historian.
- **Life Council** — Skeptic, Poet, Economist, Keeper.

The deliberation protocol follows a three-stage pattern inspired by Karpathy's `llm-council` and the Habermas Machine research:

1. **First opinions** — each agent submits its view.
2. **Peer review** — agents critique each other's views.
3. **Synthesis** — the Chair agent drafts a perspective.
4. **Dissent preservation** — any agent may register a minority note.
5. **Presentation** — the user receives the perspective, not a verdict.

## Research that shaped Council

The project sits at the intersection of several active research frontiers:

### Personal LLM agents

Li et al. frame Personal LLM Agents as a major end-user software paradigm, with core gaps in intent understanding, task planning, tool use, and personal data management. Council targets exactly these gaps ([Li et al., 2024](https://arxiv.org/abs/2401.05459)).

### Multi-agent deliberation

Google DeepMind's Habermas Machine showed that an AI mediator can synthesize group statements that humans prefer over human-mediator statements, reduce division, and incorporate minority critiques ([Tessler et al., 2024](https://www.science.org/doi/10.1126/science.adq2852)). This validates the council metaphor.

However, multi-agent deliberation also has a "deliberative illusion": discussion can produce consensus while losing critical facts. Council counters this by preserving dissent and requiring calibrated escalation rather than simple voting ([Wan et al., 2026](https://arxiv.org/abs/2606.03032); [Conformal Social Choice](https://arxiv.org/abs/2604.07667)).

### Memory architectures

Long-term memory for agents has moved beyond longer context windows to structured memory subsystems: temporal knowledge graphs, episodic gists, and agentic memory managers. Council draws on Mem0, Zep/Graphiti, A-MEM, HippoRAG, and GraphRAG for its memory layer.

### Privacy-preserving AI

Local inference, confidential cloud compute (Apple Private Cloud Compute, OpenPcc), and agent access governance (SAGA) show that privacy and capability can coexist. Council defaults to local execution and uses attested, stateless confidential nodes only for heavy reasoning.

### Constitutional governance

Anthropic's Constitutional AI and reason-based constitution, OpenAI's Model Spec, and runtime governance systems like Sovereign-OS demonstrate that governance must be explicit, versioned, and enforceable — not just a paragraph in a system prompt.

### Tool use and protocols

The Model Context Protocol (MCP) is becoming the standard way for agents to connect to tools. Google A2A complements it for agent-to-agent delegation. Council uses MCP for tools and an internal deliberation bus for agent communication.

## The future of assistants and where Council fits

The field is moving from chatbots to agentic companions. Frontier models are being packaged as goal-directed agents that plan, use tools, and act across sessions. Multi-agent teams are becoming the production baseline. Governance, memory, and privacy are moving from afterthoughts to core architecture.

Council's bet is that the winning personal assistant is not a single omniscient agent, but a **personal agent ecosystem**: an orchestrator, a memory layer, a set of specialized agents, a tool layer, and a constitution — all bound to a user profile that the user owns.

Where commercial assistants optimize for scale and engagement, Council optimizes for trust, perspective, and freedom.

## Memory and profile model

Council separates the runtime from the profile:

- **Runtime (public repo):** the code, agent templates, constitution, and architecture.
- **Profile (private repo):** values, goals, boundaries, memory, journal, and financial history.

The memory layer includes:

- **Profile vault** — encrypted, local. Core identity and sensitive history.
- **Temporal knowledge graph** — facts with validity over time.
- **Episodic gists** — compressed summaries of past sessions.
- **Purpose-bound access control** — not every agent sees every fact.

## Governance and constitution

The Council Constitution is the canonical normative scaffold. It is written for the agents as much as for humans. Key elements:

- Core principles and agent behavior rules.
- Forbidden actions (no manipulation, no cross-profile action, no hidden reasoning).
- Conflict-resolution hierarchy.
- Amendment process.

A user may add personal overrides in their private profile. The runtime enforces the constitution through a policy layer, not just prompts.

## Roadmap

See [PLAN.md](PLAN.md) for the phased development plan. The short version:

1. Foundation — publish repos, define constitution and architecture.
2. First Council — implement the Purchase Council.
3. Memory and Profile — build the profile loader and memory layer.
4. Secretary Layer — add MCP tools for email, calendar, expenses.
5. Travel and Creation Councils — purposeful travel and synthesis agents.
6. Governance and Hardening — runtime enforcement, audit trails, sycophancy checks.

## Open questions

- What language and framework should the runtime use?
- Which local inference stack should be the default?
- How should the profile be encrypted at rest?
- How do we prevent the council from becoming too agreeable (sycophancy)?
- How do we represent and reconcile plural values within one user?
- What is the right threshold for proactive vs. invoked interaction?

## How to extend Council

Council is intentionally modular. You can:

- Add new agent roles.
- Define new councils for new domains.
- Write personal constitution overrides.
- Add MCP servers for new tools.
- Swap the local inference backend.

The goal is not to give everyone the same assistant. The goal is to give everyone the same trustworthy scaffold, which they can inhabit in their own way.
