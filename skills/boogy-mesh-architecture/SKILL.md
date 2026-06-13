---
name: boogy-mesh-architecture
description: Use when composing multiple Boogy services, deciding whether to split a service, or passing identity/data between services
---

# Boogy mesh architecture

Boogy services compose into a mesh. A **healthy mesh emerges from
healthy individual services** — so the questions are: should this be
one service or several? how do they talk? how does identity flow? and:
does the mesh already offer what I'm about to build?

## When to split (and when not)

| Split when | Don't split for |
|---|---|
| Independent **scaling** (one part is hot, the rest idle) | Code organization alone — use modules/files |
| Separate **ownership** / team boundary | "Every feature deserves its own service" |
| **Reuse** by other services or teams | A part that's never called independently |
| **Blast-radius** isolation (failure/data domain) | Splitting before you have a real seam |

Default to one service. Split at a real seam, not by reflex.

## Topology patterns (one-liner each)

- **Shared internal service** — a callee-only capability (auth, pricing)
  others call; `mode = "internal"`.
- **Pipeline** — A → B → C, each stage a hop in the same request tree.
- **Hub** — one entry service fans out to several internal services.

## Internal mode + allowed_origins

A callee-only service uses:

```toml
[ingress]
mode = "internal"
allowed_origins = ["boogy://acme/services/orders"]
```

`internal` rejects all human/anonymous callers — only listed workloads
get through. Matcher syntax (verified):

- `boogy://<owner>/services/<name>` — exact workload.
- `boogy://<owner>/*` — any service owned by `<owner>`.
- `*`, `boogy://*`, `boogy://*/*` — any workload (all three spellings
  mean the same wildcard).

`allowed_origins` is **required non-empty** for `internal`; an empty
list silently denies everything (the validator catches it at deploy).

## Identity between services

Calls go through `peer::fetch`. The host **strips identity-bearing
headers on every hop** (case-insensitive): `Authorization`, `Cookie`,
`X-Boogy-Caller`, `X-Boogy-Workload`. Forwarding a user's token does
nothing — it's removed by design. To convey who the call is for:

- **Non-authoritative info** (a display name, a hint, an id the callee
  doesn't make trust decisions on): pass it as a normal payload field
  or path param.
- **Authoritative acting-as-a-user** (the callee must *authorize* as
  that user): use OBO delegation — the platform propagates the user's
  identity for you; the callee opts in and keys on the principal. See
  `boogy:boogy-obo-delegation`.

## Knowing your OWN identity: `self_identity()`

A service can ask the host who *it* is:

```rust boogy-snippet
fn who_am_i() {
    // wit_glue! emits this; no [capabilities] grant needed — knowing your
    // own identity is benign (conceptually like reading the clock).
    let me = self_identity(); // ServiceIdentity { owner: String, service_id: String }
    let _ = (me.owner, me.service_id);
}
```

The value is **host-pinned and unspoofable** — set from the matched
route at the HTTP edge, from the **callee's** workload on a `peer::fetch`
hop (a callee reads ITS OWN identity, never the caller's), or from the
job target in a background job. It can never be derived from guest input
or an inbound header, so it is **safe to authorize on**.

### Pattern: owner-aware authorization

The high-value use is gating "is this caller one of **my owner's** apps?"
Compare the *attested caller's* workload owner to your own:

```rust boogy-snippet
fn admit_same_owner_only(req: &mut Req<'_>) -> Result<(), ApiError> {
    // The attested caller (host-set; identity-bearing headers are stripped
    // on every hop, so this can't be forged). The raw Identity exposes the
    // delegation `actor` too — on a delegated hop, the calling WORKLOAD is
    // in `actor`, the user in `principal`.
    let me = self_identity();
    let caller = bindings::boogy::platform::auth::current_identity(); // Option<Identity>
    // Parse the caller's workload `boogy://<owner>/services/<name>` (from
    // principal, or actor on a delegated hop) and compare <owner> to
    // `me.owner` — admit only same-owner apps.
    let caller_owner = caller
        .as_ref()
        .and_then(|i| i.actor.as_deref().or(Some(i.principal.as_str())))
        .and_then(|wl| wl.strip_prefix("boogy://"))
        .and_then(|rest| rest.split('/').next());
    match caller_owner {
        Some(owner) if owner == me.owner => Ok(()),
        _ => Err(ApiError::forbidden("only this owner's apps may call")),
    }
}
```

**Two ways to express "only my owner's apps", pick by where the rule
belongs:**

| Approach | When |
|---|---|
| **Declarative** — `mode = "internal"` (or `mixed`) with `allowed_origins = ["boogy://<owner>/services/*"]`. The host enforces it at the edge before your wasm runs. | The rule is "who may call this service AT ALL". Cheapest, no per-request code. Prefer this. |
| **In-handler** — `self_identity()` + parse the attested caller's owner, branch in code. | The owner-match drives *behavior*, not just admission — e.g. partitioning rows by the calling app, or a defense-in-depth second check behind the ingress allowlist. |

The two compose: the catalog `stripe-base` does both — `internal`
ingress restricts callers to the owner's apps, AND each handler derives
the attested caller's service id to partition orders per-app, so one app
can never read another's rows even if ingress were misconfigured.

## Peer mechanics (quick reference)

```rust boogy-snippet
use boogy_sdk::peer::PeerRequest;

#[derive(Deserialize)]
struct Reserved { ok: bool }

fn reserve(payload: serde_json::Value) -> Result<(), ApiError> {
    let resp = peer_fetch(
        "boogy://acme/services/inventory",
        &PeerRequest::post("/api/reserve").body_json(&payload)?,
    )?;
    if resp.is_success() {
        let r: Reserved = resp.json()?;
    }
    Ok(())
}
```

- Caller manifest needs `[capabilities] peer = true`.
- A failed peer call lifts to **502 upstream** via `?` (`From<PeerError>`);
  match the variant first if you want a different status.
- `PeerError` variants: `TargetNotFound`, `Denied`, `Timeout`,
  `DepthExceeded`, `CapabilityDenied`, `Internal`, `InvalidTarget`.
- **Cross-service writes**: one ambient transaction spans the whole
  `peer::fetch` call tree — callees never call `tx`, only the origin
  commits, a 409 means the client retries the whole request. See
  `boogy:boogy-transactions`.

## Origin billing

A request's usage bills to its **origin** (the entry service of the
request tree), propagated unchanged across every hop. So a shared
internal service carries **no fairness cost of its own** — your
callers' usage bills to *them*. Design internal services accordingly:
factoring out a callee is cheap, but a heavyweight internal service
spends its callers' budget.

## Mesh-first

Before integrating an external provider — or building a capability from
scratch — check whether the mesh already offers it: an existing service
or a publishable module in the registry (`boogy:boogy-registry-and-provisioning`).
A healthy mesh is built from healthy individual services others can
build on; a dedicated internal capability others can reuse beats inline
one-off integrations.

This is the **first question, never a mandate**. External integration
via `outbound_http` is fully sanctioned when nothing in the mesh fits —
the rule is "check first", not "never".

## Red flags

| Thought | Reality |
|---|---|
| "Forward the `Authorization` header so B knows the user." | Stripped on every hop. Use a payload field (non-authoritative) or OBO (authoritative). |
| "Split everything into microservices." | Default to one service; split only at a real seam (scaling / ownership / reuse / blast-radius). |
| "We need payments — integrate Stripe inline." | Check the mesh first; prefer a shared internal capability; external is fine only when nothing fits. |
| "I'll read my own owner from an env var / a config row." | Use `self_identity()` — host-pinned and unspoofable. Env/config can drift or be wrong; the host value is authoritative. |
| "On a peer hop, `self_identity()` tells me who called me." | No — it's the CALLEE's own identity. The caller is in `current_identity()` (principal/actor). |

## Integration

→ `boogy:boogy-obo-delegation` (authoritative cross-service identity),
`boogy:boogy-transactions` (cross-service writes),
`boogy:boogy-registry-and-provisioning` (mesh discovery, provision-vs-consume),
`boogy:boogy-webhooks` (a service that also receives third-party callbacks).
← `boogy:designing-boogy-services` (the split/compose decision at design time).
