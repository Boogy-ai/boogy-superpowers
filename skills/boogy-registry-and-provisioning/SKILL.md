---
name: boogy-registry-and-provisioning
description: Use when needing functionality that might already exist in the mesh, publishing a module, or deciding whether to run your own instance of one
---

# Boogy registry & provisioning

Before building a capability, ask: **does the mesh already offer it?**
This is the first question, never a mandate — but skipping it means
rebuilding what someone already shipped.

## Modules vs services

- A **module** is the publishable artifact: an immutable, versioned
  wasm + manifest. Referenced as `boogy://<owner>/modules/<name>@<version>`
  (the `@version` is **required**; kind is literally `modules`).
- A **service** is a live, running instance — yours, owned by you,
  serving a route. You get one by *provisioning* a module, or by
  deploying directly.

## Discovery (do this first)

The platform runs a searchable **registry** at `/v1/registry/*`.
It needs **authentication, not admin scope** — any signed-in user (or
deployed service) can query it; results are scoped to what you may see
(your own + public/allowlisted-to-you modules).

```
GET /v1/registry/search?q=thumbnail            # { "results": [...] }
GET /v1/registry/modules/{owner}/{name}        # full detail (404 if not visible)
```

Filters: `q`, `category`, `mode`, `owner`, `since` (RFC3339), `limit`.
A deployed service can query it cross-service:

```rust
peer_fetch("boogy://_sys/services/registry",
           &PeerRequest::get("/v1/registry/search?q=thumbnail"))?;
```

LLM clients get MCP tools at `POST /v1/registry/mcp`: `search_modules`,
`describe_module`, `list_module_versions`.

> `boogy list` is the **operator fallback** — it hits an admin-only
> endpoint and needs admin scope. It is NOT how a developer or a service
> discovers the mesh. Use the registry.

## Provision vs consume

Found something? Decide whether to run your own instance or call a
shared one:

| Dimension | Provision your own | Consume a shared instance |
|---|---|---|
| Ops | You own upgrades, lifecycle | Zero — operator runs it |
| Data | Stays in your boundary | Crosses the operator's boundary |
| Upgrade cadence | Yours to control | Operator's; you ride their version |
| Availability | Independent | Coupled to their uptime |
| Trust | Self-contained | You trust their operator |
| Quota/cost | Bills to you (your instance) | Calls bill to **your** origin anyway |

Rule of thumb: **stateless utility** (thumbnailing, formatting) → a
shared singleton is fine; **stateful, sensitive, or isolation-critical**
→ provision your own. Note: cross-service calls bill to the *calling
origin* regardless, so "consume" doesn't offload compute cost — it
offloads operations.

## Publishing a module

```bash
boogy publish my-service.boogy.toml          # POST /v1/modules
boogy publish my-service.boogy.toml --provision   # + run your own instance
```

Publishing forces *you* as the owner (no publishing on another's
behalf). Control who may provision with `[provisioning]`:

```toml
[provisioning]
mode = "allowlist"          # public (default) | private | allowlist
allow = ["team-a", "team-b"]  # user_ids; required non-empty for allowlist
```

- `public` (**default**) — anyone may provision.
- `private` — only you (the author).
- `allowlist` — only listed user_ids.

A caller who may not provision is **404-masked** (not 403) — your private
module's existence isn't observable.

## Provision & upgrade

```bash
boogy provision boogy://owner/modules/thumbnailer@1.2.0 my-thumbs --overrides over.toml
boogy upgrade my-thumbs --to 1.3.0
```

Provision is a CREATE — re-running for an existing `service_id` is a 409;
use `upgrade` to change the pinned version. See
`boogy:deploying-boogy-services` for the build/deploy loop.

## Red flags

| Thought | Reality |
|---|---|
| "Only admins can discover services." | False — the registry (`/v1/registry/*`) is authenticated, not admin-gated. `boogy list` is just the operator fallback. |
| "Provision a copy of everything by default." | Consume shared singletons for stateless utilities; provision only when isolation, data locality, or upgrade control demands it. |
| "I'll just build the thumbnailer." | Search the registry first. Building is fine if nothing fits — but check. |
| "I'm sure the manifest field is X." | Verify mode names/defaults; don't assert config you haven't confirmed. |

## Integration

← `boogy:designing-boogy-services` (the mesh-check before designing a
new capability). ↔ `boogy:boogy-mesh-architecture` (topology, internal
mode, cross-service identity). → `boogy:deploying-boogy-services`
(build, publish, deploy mechanics).
