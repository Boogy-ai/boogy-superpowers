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

```rust boogy-snippet
use boogy_sdk::peer::PeerRequest;

fn search_mesh() -> Result<(), ApiError> {
    let resp = peer_fetch("boogy://_sys/services/registry",
                          &PeerRequest::get("/v1/registry/search?q=thumbnail"))?;
    Ok(())
}
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

### Per-instance mount path

A provision-time override can relocate where a service answers by setting
`[routing] path`:

```toml
# over.toml
[routing]
path = "/personal-notes"
```

This changes the **external** URL of this instance only — one module can
run as several instances at distinct mounts (e.g. `/personal-notes` and
`/company-notes` from the same `notes` module). The guest still serves its
own module routes unchanged; the host rewrites the mount prefix
transparently on the way in, and the served `openapi.json`/`openrpc.json`
paths are remapped to the mount so clients see the real URLs. Arbitrary
multi-segment paths are allowed (`/team/notes`, `/api/v2/notes`). Mount
paths are unique per owner — a mount that equals or overlaps another of
your services' mounts is rejected with **409**. Omit the override (or keep
the module's own `path`) and nothing changes.

### Two tiers: module-intrinsic vs deployment config

A manifest has two kinds of fields, and only one kind is yours to set
when you provision someone else's module.

**Module-intrinsic** — fixed by the module author; the provisioner can
**never** change or widen them:

- `[capabilities]` — what the code is allowed to touch (`store`, `peer`,
  `outbound_http`, …). The author grants these; you cannot add one.
- declared realtime channels (`[[websockets.channels]]`) — names + access
  class the code publishes on.
- declared secret **names** (`[secrets]`) — which secrets the code reads.
- routing **methods** and the module's internal base path — the route
  shape the code answers on.

**Deployment config** — set per instance, by you, at provision time:

- service id and mount path (the external URL — see above).
- `[ingress]` — mode, rate limits, delegation.
- `[limits]` — sized for *your* instance, within the platform caps (you
  may raise or lower; see `boogy:boogy-capability-limits`).
- `[outbound] allowed_hosts` — the egress allowlist for your instance.
- secret **values** — you bind your own values for the declared names;
  they never travel in the manifest (bound through the per-service secret
  endpoint, KMS-wrapped). The module author's names tell you *what* to
  provide, not the value.

So: the author decides what the code *can* do; you decide how *your*
instance is sized, exposed, rate-limited, and what egress + secret values
it runs with.

## Red flags

| Thought | Reality |
|---|---|
| "Only admins can discover services." | False — the registry (`/v1/registry/*`) is authenticated, not admin-gated. `boogy list` is just the operator fallback. |
| "Provision a copy of everything by default." | Consume shared singletons for stateless utilities; provision only when isolation, data locality, or upgrade control demands it. |
| "I'll just build the thumbnailer." | Search the registry first. Building is fine if nothing fits — but check. |
| "I'm sure the manifest field is X." | Verify mode names/defaults; don't assert config you haven't confirmed. |

## Platform API reference

The platform API is self-describing: `GET <host>/openapi.json` returns
an OpenAPI 3.1 document covering the full deploy lifecycle (`/_agents/*`,
`/_admin/*`, `/v1/*`) — anonymous fetch OK, no token required.

## Integration

← `boogy:designing-boogy-services` (the mesh-check before designing a
new capability). ↔ `boogy:boogy-mesh-architecture` (topology, internal
mode, cross-service identity). → `boogy:deploying-boogy-services`
(build, publish, deploy mechanics).
