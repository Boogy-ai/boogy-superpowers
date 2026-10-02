---
name: boogy-peer-to-peer-apps
description: Use when every user runs their own copy of the same service and those copies talk to each other — per-user instances each holding their own data, reading or writing another owner's instance, authorizing a call from an owner you have never met, or publishing a module meant to interconnect
---

# Boogy peer-to-peer apps (one module, many owners)

The three topologies in `boogy:boogy-mesh-architecture` — shared internal
service, pipeline, hub — are all **one owner composing their own
services**. This skill is the other shape: **one module, many owners**.
Each person provisions their own instance under their own handle, that
instance holds only their data, and instances call each other as equals.
Chat, contacts, a shared calendar, a federated feed: anything where "my
copy" and "your copy" are the same code and neither is the hub.

It gets its own skill because the platform's cross-service allowlists are
written **per owner**, and in this shape you do not know the owners: the
next person to provision your module has not signed up yet. That one fact
drives everything below.

## The rule this shape forces: a wide grant, a narrow gate

| In a hub (one owner) | In a peer-to-peer app (many owners) |
|---|---|
| You name the exact caller workloads in `allowed_origins` / `allow_actor` | You cannot — the callers do not exist yet |
| Ingress is the whole authorization story | Ingress admits broadly; **the handler is the gate** |
| A route with `auth::required()` is "signed-in users only" | A route with only `auth::required()` is reachable by **any delegated hop** |

Build it in that order: ingress admits the mesh, and **every route decides
for itself** who it is really for.

## The grant you need is `[ingress.delegation]`, not `allowed_origins`

Get this the wrong way round and you will spend a while on an allowlist
that was never consulted. A peer call in this shape is **delegated**: a
user entered instance A, A called instance B, so the identity B sees has
`principal` = the user and `actor` = A's workload
(`boogy:boogy-obo-delegation`). Two things follow.

- The mode that admits it is **`authenticated`** — it admits an agent
  principal, which is what a delegated hop carries. `internal` and
  `mixed` are for *plain* workload callers, and they will not admit a
  signed-in end user either, so they are the wrong mode for a service
  whose users log in.
- `allowed_origins` is therefore **not** on the path at all. The gate the
  peer call actually passes through is `[ingress.delegation]`.

Reach for `internal`/`mixed` + `allowed_origins` only if instances also
call each other with **no user in the request tree** (a background sync).
That is a different, non-delegated hop, and it is the only reason to
declare origins here.

## There is no "any owner's copy of this module" matcher

`allow_actor` and `allowed_origins` take the same matcher, and it has
exactly three forms (verified):

| Spelling | Means |
|---|---|
| `*`, `boogy://*`, `boogy://*/*`, `boogy://*/services/*` | any workload on the mesh |
| `boogy://<owner>/*`, `boogy://<owner>/services/*` | any service owned by `<owner>` |
| `boogy://<owner>/services/<name>` | that one exact workload |

There is **no fourth form** for "the service named `chat`, whoever owns
it" — and the spelling you would reach for, `boogy://*/services/chat`,
is the trap. It is not rejected at deploy. It parses as an **exact
workload whose owner is the literal string `*`**, and no workload has
that owner, so it matches nothing and silently denies every peer call.
The owner segment is the only place the wildcard is not honoured, which
is exactly the segment a peer-to-peer app needs it in.

So the grant that spans owners is the mesh-wide wildcard, and you take it
knowing it is wide:

```toml
[ingress]
mode = "authenticated"               # admits the owner's SSO session AND delegated peer hops

[ingress.delegation]
allow_actor = ["*"]                  # any instance — you cannot name owners who have not signed up
max_delegated_scopes = ["chat:*"]    # mandatory cap; see boogy:boogy-obo-delegation
```

## The grant is per SERVICE, not per route

This is the half that surprises people. `[ingress.delegation]` is
evaluated once, against the **service-wide** block, *before* any
per-route `[[ingress.routes]]` resolution happens. A per-route override
carries its own mode and allowlists — it does **not** carry its own
delegation policy, and it cannot narrow one.

So `allow_actor = ["*"]` opens **every route on the service**, including
the ones you gated with `auth::required()`. That guard asks one question
— "is anybody signed in?" — and a delegated hop *is* signed in: as the
user, because the platform re-derives the identity from whoever entered
the request tree.

The consequence, concretely. Your chat instance grants a wildcard actor
so other people's chat instances can deliver messages. Its owner signs in
to some unrelated service on the mesh that holds `[capabilities] peer =
true`. That service can now `peer::fetch` your chat instance, the host
hands it an identity whose principal is the owner, the wildcard admits
it, and every route behind `auth::required()` — the conversation list,
the send endpoint — serves it as the owner. `max_delegated_scopes` is a
real bound but not the one that saves you here: it caps the *scopes*
forwarded, not which service may act, and a cap wide enough for your own
routes is wide enough for theirs.

## The compensating primitive: `caller_is_service_owner()`

`caller_is_service_owner()` (emitted by `wit_glue!`, no capability grant
needed) is the gate the wide ingress leaves you needing. The host attests
it, and two properties are what make it the right primitive here:

- **It is false for any call carrying an `actor`** — refused before the
  caller is even resolved. A delegated hop therefore cannot borrow the
  owner's identity, no matter which workload made it.
- **It is still true for the owner signed in through SSO**, and for the
  owner's own workloads. The host resolves the real account behind the
  `pw_…` pairwise, which your wasm cannot do.

```rust
// Owner-only surface on a service whose ingress must admit the whole mesh.
fn require_owner() -> Result<(), ApiError> {
    if caller_is_service_owner() {
        Ok(())
    } else {
        Err(ApiError::forbidden("owner only"))
    }
}
```

**Cover every route the grant opens, not just the ones that feel
administrative.** The wide grant is service-wide, so the audit is
service-wide: walk the router and put each route in exactly one bucket.

| Bucket | Gate |
|---|---|
| The owner's own data and actions | `require_owner()` above |
| The peer inbox — what another owner's instance may call | a recorded-relationship check (next section) |
| Genuinely public (a health check, a profile card) | nothing, deliberately, and say so in a comment |

A route left with only `auth::required()` is in none of those buckets and
is the hole. Re-run this walk on every new route: the grant does not
change, so a route added later inherits the whole mesh by default.

## Authorize on a recorded relationship, never on a service name

A peer inbox has to admit callers you have never met, which is not the
same as admitting anyone. The shortcut that looks like a check and is not:

```rust ignore-snippet: the rejected shape, shown to be argued against — it parses a principal that under delegation is the user, not the caller
// WRONG, twice over.
let principal = auth::current_principal().ok_or_else(ApiError::unauthenticated)?;
match parse_workload(&principal) {
    Some(w) if w.service_id == "chat" => accept(w.owner),
    _ => return Err(ApiError::forbidden("only chat services may deliver")),
}
```

Wrong the first way: **service ids are chosen by whoever provisions.**
Anyone on the mesh who names their instance `chat` passes this check.
That is not an allowlist, it is an open inbox with a naming convention in
front of it.

Wrong the second way: **under delegation `current_principal()` is not the
caller's workload** — see the next section.

Record the relationship instead, at the moment it is established (a
contact request accepted, a follow confirmed, an invite redeemed), and
store the **full workload URI** of the other instance. Then the inbox
checks a row, not a string shape — and revoking a peer is a delete rather
than a redeploy.

## A peer call from behind a login guard is DELEGATED

`boogy:boogy-obo-delegation` states the rule; here is the consequence
that costs debugging time. When a user's request enters instance A and A
calls instance B, the host synthesizes the identity B sees:

| B reads | Gets |
|---|---|
| `auth::current_principal()` | **the user's pairwise for B** — not A's workload URI |
| `current_identity().actor` | **A's workload URI** — the calling instance |
| `auth::current_handle()` | the user's verified handle, if they consented to share it |

Only a hop with no user anywhere in the request tree (a background job,
a cron sweep) is plain workload-to-workload, and only then does
`current_principal()` hold a workload URI. So the same peer route
behaves differently depending on how the call was started — which is why
a handler that wants to know **which instance is calling** must read
`actor`, every time, and never `current_principal()`.

```rust
// A peer inbox: authorize the CALLING INSTANCE against a recorded peer row.
fn deliver(req: &mut Req<'_>) -> Result<NoContent, ApiError> {
    // The attested caller. Identity-bearing headers are stripped on every
    // hop, so nothing here can be forged by the sender.
    let identity = bindings::boogy::platform::auth::current_identity();
    let caller = identity
        .as_ref()
        .and_then(|i| i.actor.clone())          // the calling WORKLOAD, under delegation
        .ok_or_else(|| ApiError::forbidden("peer route: direct calls are not accepted"))?;

    // Recorded at the moment the relationship was established — the full
    // workload URI, not a service name. Unknown sender → the same 404 an
    // unknown row gets (boogy:boogy-auth, deny-by-existence-mask).
    let _known = db_find_by::<Conversation>(Conversation::PEER, Val::Text(caller))?
        .into_iter()
        .next()
        .ok_or_else(ApiError::not_found)?;

    let _body: RenameBody = validate_body(req.body())?;
    Ok(NoContent)
}
```

## Degrade when a peer is gone — do not 502 the page

In a hub, a callee that does not answer is an incident. Here it is
Tuesday: the other person has not provisioned their instance yet, or
removed it, or their ingress refuses you. `?` on a peer call lifts a
`PeerError` to **502 upstream**, so one absent contact fails the whole
list.

Reach for `peer_fetch_raw` or match the error, and render the row as
unavailable instead:

```rust ignore-snippet: a fan-out fragment — the peer list, the row type and the surrounding handler are not in scope in this block
match peer_fetch(&target, &PeerRequest::get("/chat/presence")) {
    Ok(resp) => rows.push(Row::Live(resp.json()?)),
    // Not provisioned, or refusing us: a state of the world, not a failure.
    Err(PeerError::TargetNotFound) | Err(PeerError::Denied) => rows.push(Row::Unavailable),
    Err(e) => return Err(e.into()),   // a real fault still surfaces
}
```

Decide this per call site. A peer read that decorates a list degrades; a
peer write the user explicitly asked for should still fail loudly.

## `mode = "public"` is not "this data is public" — but anyone can sign in

A peer-to-peer instance often wants a public shell: a page anyone can
load that then authenticates its own users. `public` ingress gives you
that, and it means exactly what it says — **anyone reaches the service,
and anyone may sign in to it.** A stranger completing the SSO flow
against your instance arrives with a valid principal and, on any route
gated only by `auth::required()`, starts creating rows in an instance
that was meant to belong to one person.

A login gate is not an owner gate. If the instance belongs to its
provisioner, say so with `caller_is_service_owner()` on the routes that
write; use `auth::required()` alone only where many end users genuinely
share one instance.

## Identifying a peer in a URL

A peer is named by its workload URI, and a URI in a path segment does not
survive the trip: path params arrive **exactly as they appear in the
URL**, so a percent-encoded `boogy%3A%2F%2F…` reaches your handler still
encoded and matches zero stored rows — a 200 with an empty list, which no
gate catches. Put the peer in the **body or the query string**, or decode
it yourself. See `boogy:boogy-rest-apis`, "Extractors".

## Publishing the module

A peer-to-peer module is only useful if others can run it, so leave
`[provisioning]` at its `public` default, and declare `[discovery]` so
instances can find each other (`boogy:boogy-registry-and-provisioning`,
"Finding another account's instance"):

```toml
[discovery]
[[discovery.routes]]
name = "peer-messages"
path = "/chats/api/peer/messages"   # the module's own path
version = 1
```

- **A peer is found by handle, never by assumption.** A provisioner
  chooses the service id, so `boogy://<handle>/services/<your-id>` is a
  guess. `discovery::lookup(handle, &Module::Same)` returns their listed
  instances of your module, with addresses. Look up once, when the
  relationship starts, and store the address.
- **The peer path is the module's own path, whatever the mount.** A
  provisioner may mount their instance at another path. A `peer::fetch` is
  resolved by the target's address and handed the path unchanged, so the
  module's own paths work on every instance. Only a browser's URL follows
  the mount.
- **Tell "gone" from "down".** When a stored peer's `peer::fetch` fails with
  `PeerError::TargetNotFound`, they no longer run the module. Say so, and
  keep "couldn't be reached" for the other failures.

## Checklist

- [ ] The cross-owner grant is the **wildcard**; you confirmed no
      `boogy://*/services/<name>` spelling is anywhere in the manifest.
- [ ] Every route is in one of three buckets: owner-gated, peer-gated by
      a recorded relationship, or deliberately public.
- [ ] No route is gated by `auth::required()` alone.
- [ ] The peer inbox reads `actor`, not `current_principal()`.
- [ ] Peer identity is stored as a full workload URI, written when the
      relationship was established.
- [ ] Peer reads that decorate a view degrade; peer writes the user asked
      for still fail loudly.

## Red flags

| Thought | Reality |
|---|---|
| "`boogy://*/services/chat` grants every owner's chat instance." | It parses as an exact workload owned by the literal `*` and matches **nothing** — deploy succeeds, every peer call is denied. The owner segment takes no wildcard in that form. |
| "I'll put the wildcard grant on just the peer routes." | Delegation is a **service-wide** gate evaluated before per-route resolution. A wildcard actor opens every route on the service. |
| "`auth::required()` keeps the peer surface off my owner routes." | It asks whether *anyone* is signed in. A delegated hop is signed in — as the owner. Use `caller_is_service_owner()`, which is false for any call carrying an actor. |
| "The caller is a chat service, so `current_principal()` tells me which one." | Under delegation the principal is the **user's pairwise**. The calling workload is in `actor`. |
| "Checking `service_id == "chat"` restricts it to chat instances." | Service ids are chosen by whoever provisions. That admits every owner who picked the name. Check a recorded workload URI. |
| "A missing peer is a 502." | In this shape a peer routinely does not exist. `?` fails the whole page for one absent contact — match `TargetNotFound`/`Denied` and degrade. |
| "`public` ingress just makes the page loadable." | It also means any stranger may sign in and, on a route gated only by `auth::required()`, write rows in an instance meant for one person. |

## Integration

← `boogy:boogy-mesh-architecture` (the single-owner topologies, peer
mechanics, `self_identity()`), `boogy:boogy-obo-delegation` (the actor /
principal model and the `max_delegated_scopes` cap), `boogy:boogy-auth`
(`caller_is_service_owner()`, deny-by-existence-mask, owner columns).
→ `boogy:boogy-registry-and-provisioning` (publishing the module others
provision), `boogy:boogy-rest-apis` (extractors, and why a URI-shaped
path param does not arrive decoded).
