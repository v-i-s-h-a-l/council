---
type: meta
status: shipping
created: 2026-07-07
updated: 2026-07-07
max_words: 1500
---

# Council Project Setup

> Creating the public Council runtime repository and the private profile repository.

## Current Thinking

The Council concept has moved from philosophical exploration to implementation scaffolding. The design is a local-first, multi-agent deliberation system bound to a private user profile. The runtime is public and shareable; the profile is private and never mixed with other users.

## Decision

- Public repository for the canonical Council runtime: https://github.com/v-i-s-h-a-l/council
- Private repository for the personal profile: https://github.com/v-i-s-h-a-l/council-profile
- The Council repo contains the runtime, constitution, architecture, and agent templates.
- The profile repo contains values, goals, boundaries, memory, journal, and financial history.

## Rationale

This split keeps trust mechanical. The Council code can be inspected by anyone, which supports the non-manipulation and openness goals. The profile stays under the user's sole control, which supports privacy. A clear boundary between shared logic and personal data is easier to reason about than a single mixed repository.

## Open Questions

- What language and framework should the runtime use? Python is likely for the agent ecosystem, but this is not decided.
- Should the profile repo be encrypted at rest by default, or is GitHub private enough for the first phase?
- How should the Council runtime locate and load a profile directory?
- Which local inference stack should be the default: Ollama, llama.cpp, vLLM, or something else?

## Small Observations (Don't Delete)

- The name "Council" was available on GitHub under the v-i-s-h-a-l account, which is fortunate.
- The private profile repo is intentionally minimal. Its real content will grow through use.
- The canonical constitution is a starting scaffold. Personal overrides live in the profile repo.

<!-- docbot: end -->
