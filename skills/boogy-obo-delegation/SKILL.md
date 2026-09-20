---
name: boogy-obo-delegation
description: Use when one Boogy service must act on a user's behalf when calling another service
---

# Boogy on-behalf-of (OBO) delegation

One service calling another **as a specific user** (not as itself) is
on-behalf-of delegation. Get it wrong and per-user isolation breaks
across the whole mesh — so the model is strict and default-deny.

## The model: actor performs, principal owns

A delegated call carries two identities:

- **principal** — the user the call is *for* (a human/agent). Stays
  the same on every hop.
- **actor** — the service *making* the call right now (its workload).

Under delegation the callee sees `principal = the user`,
`actor = the calling service`.

## The trigger: it's automatic — you write no token code

When your service makes a peer call, the platform derives the identity
the callee sees from **your service's own inbound identity**. You do
nothing — no header, no token, no minting.

- If your service was entered **by a user** (principal is an agent),
  the peer call becomes **OBO**: callee sees `principal = that user`,
  `actor = your workload`, the user's scopes carried through.
- If your service was entered **by another service** (or by nothing),
  the peer call is plain **workload-to-workload**: callee sees
  `principal = your workload`, no actor. NOT delegation.

So a call is OBO exactly when a user originated the request tree. Each
hop rewrites only the *immediate* actor; the user principal is
preserved end-to-end.

## Receiver opt-in is default-deny

A delegated (actor-bearing) call is **rejected** unless the callee
opts in with `[ingress.delegation]`. Opt-out delegation would be a
footgun, so absence = denial.

```toml
[ingress.delegation]
allow_actor = ["boogy://owner/services/assistant"]  # exact workloads that may delegate
max_delegated_scopes = ["notes:*"]                  # REQUIRED cap; every token scope must match
require_principal_in_allowed_agents = false         # also gate the USER against allowed_agents
```

- `allow_actor` — who may deliver delegated calls. **Empty = delegation
  disabled** even with the block present.
- `max_delegated_scopes` — **mandatory whenever `allow_actor` is
  non-empty.** A delegated call forwards the principal's *full* inbound
  scope set (there is no per-call narrowing), so the receiver's cap is
  the only ceiling — omitting it would silently accept the principal's
  entire scope set. A delegation block with `allow_actor` but no
  `max_delegated_scopes` is **rejected at deploy** (manifest validation)
  and, defensively, denied at runtime. *Every* scope on the call must
  match at least one matcher (`*`, `resource:action`, `resource:*`,
  `*:action`). A delegated call carrying **zero** scopes trivially
  satisfies the cap (nothing to match) and is **allowed** — it's denied
  only by the other gates (no `[ingress.delegation]` block, an empty cap,
  or an actor not on the allowlist), never by scopelessness itself.

## Spending a user's balance needs their grant

Delegation lets you *act* for a user. It does not let you *spend* for them. If
the route you reach on their behalf is priced and charges the `principal`, the
charge falls on that user — and a user who is not the one sending the request has
to have agreed to it in advance, with a **spending grant** they created
themselves. Without one the call is refused `402 spending_grant_required`, before
any work happens.

This is the customer- versus merchant-initiated split card networks use, and it
applies to exactly the cases delegation exists for: a service acting on a user's
behalf, a background job running as that user, an app calling a service other
than its own. A user spending their own balance on their own request needs no
grant.

Two consequences when you design a delegated flow:

- **You cannot create the grant for them.** Grants are made only by the account
  holder acting directly, so the flow needs a step where the user grants it —
  design that in rather than discovering the 402 in production.
- **A grant carries its own per-charge ceiling**, so a route priced above what
  your users typically grant is refused by the grant rather than by the balance.
  That is a pricing problem wearing an authorization error; see
  `boogy:boogy-route-pricing`.

## Iron Law: authorize on the principal, never the actor

In the callee's handlers, scope rows by `current_principal()` — that's
the **user** under OBO. The normal per-user helpers (`find_owned`,
`owns_resource`, see `boogy:boogy-auth`) just work, unchanged. The
actor is *not* an authorization input.

The same bounds apply under delegation as anywhere else: `find_owned`
returns one page and a cursor, never a whole set. A delegated caller is
usually another service in a fan-out, which makes the unbounded shape
*more* dangerous, not less — a listing that materializes a user's entire
history runs inside the calling request's budget and counts against the
originating tenant's fair share. Page it, and pass the cursor back up.

## Failure modes (verified)

| Situation | Result |
|---|---|
| Callee has no `[ingress.delegation]` | Denied — "must opt in with an `[ingress.delegation]` block" |
| `[ingress.delegation]` sets `allow_actor` but no `max_delegated_scopes` | **Rejected at deploy** — the cap is mandatory (would otherwise forward the principal's full scope set) |
| Actor not in `allow_actor` | Denied — "actor not permitted to delegate" |
| Token scope exceeds `max_delegated_scopes` | Denied — "scope not permitted in delegation" |
| Delegated token on an `/_admin/*` route | 403 `audience_bound_token` — admin is never delegable |

## Delegation vs internal call

| Need | Use |
|---|---|
| Callee must enforce **which user** (acting for a person) | OBO delegation; key on principal |
| Callee just needs **which service** is calling (service acts as itself) | `mode = "internal"` + `allowed_origins`; no delegation |

## Red flags

| Thought | Reality |
|---|---|
| "Check `identity.actor` is our service and allow everything." | Breaks isolation — the actor is identical for every user. Authorize on the **principal**. |
| "Pass the user's token through in a header." | Identity-bearing headers are **stripped** on every hop. The platform propagates identity for you. |
| "Set `allow_actor = ["*"]` to be safe." | Inverted — that's maximally **unsafe** (any workload may impersonate users). Name exact workloads. |
| "Leave `max_delegated_scopes` off — it's optional." | No longer accepted: a block with `allow_actor` and no cap is **rejected at deploy**. The cap is the only ceiling on forwarded scopes — always set it. |

## Integration

← `boogy:boogy-auth` (in-handler ownership), `boogy:boogy-account-auth`
(where the user principal comes from). → `boogy:boogy-mesh-architecture`
for the broader cross-service picture.
