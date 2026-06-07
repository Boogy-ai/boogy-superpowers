---
name: using-boogy
description: Use when building, modifying, debugging, or reviewing anything that runs on Boogy — services, agent backends, MCP tools, or multi-service meshes
---

# Using Boogy

Boogy has hard invariants and a specific SDK surface. Do NOT build from
memory. Before ANY Boogy work, scan the catalog below: if there is even
a 1% chance a skill applies, read it BEFORE acting. When no skill
covers your task, work against the SDK reference docs — never invent
APIs.

**Design-first hard gate.** For a new service or feature, answer the
design questions — service kind, surface (REST / MCP / RPC),
capabilities, ingress mode, data sketch — BEFORE writing any code or
scaffolding. The `designing-boogy-services` skill runs this
questionnaire once installed; until then, answer them yourself first.

## Skill catalog

*Catalog grows as skills ship; current entries below.*

| Skill | Read when... |
|-------|--------------|
| `using-boogy` | starting any Boogy work — routes you to the right skill |
| `designing-boogy-services` | starting a new service or major feature — runs the design questionnaire before any code |
| `boogy-capability-limits` | a requirement might not be supported, or designing any new service/feature |
| `scaffolding-a-service` | starting implementation of a designed service — project, manifest, build loop |
| `testing-boogy-services` | testing a service, or before claiming one works — the test pyramid + deploy-and-exercise |
| `deploying-boogy-services` | deploying, updating, or removing a deployed service — CLI commands, config, deploy errors |

No matching skill yet (data modeling, auth, transactions, jobs, mesh,
surfaces)? Say so explicitly and work from the SDK reference docs rather
than guessing.

## Red flags

| Thought | Reality |
|---------|---------|
| "It's a small service, I'll just start from the template." | Small services still need ingress mode and capabilities decided. Design, then scaffold. |
| "I know the SDK from training data." | The SDK surface is specific and moves. Confirm every call against the docs; never fabricate signatures. |
| "This endpoint is too simple to need the catalog." | Simple endpoints still hit store/query/auth invariants. Scan first; if no skill fits, say what you're relying on. |
