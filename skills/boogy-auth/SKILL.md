---
name: boogy-auth
description: Use when adding authorization to a Boogy service — per-user data, ownership checks, "only my X" endpoints, API keys for programmatic callers, or scope gating
---

# Boogy auth (in-service authorization)

Authorization on Boogy is three layers. Don't hand-roll any of them —
the SDK emits verified helpers that keep the security invariants intact.

## The control-plane / app-plane boundary

Boogy enforces a hard split between two planes. **Non-public tenant (app)
routes require an app-plane credential.** A bare global **Agent** token (your
deploy / console credential) is **rejected with 403** at a non-public app route
— unless the service is explicitly first-party-allowlisted.

**Accepted at non-public app routes:**

| Credential | Arrives as |
|---|---|
| `boogy_app` cookie (end-user SSO) | `pw_…` pairwise (projected at this service boundary) |
| `sk_*` API key on a `public`-ingress route | anonymous at host; wasm self-auths |
| OBO delegation (peer call from another service) | `pw_…` pairwise for the delegated user (if delegation gate passes), or the calling workload URI |
| Global agent token for first-party-allowlisted services only | `agent_<uuid>` |

Control-plane routes (`/v1`, `/_admin`, `/_agents`, `/healthz`) match
**before** tenant dispatch, so your global Agent token works there exactly as
before. The builder's own `/mcp` (guidance/login tools) matches before tenant
dispatch the same way on the control host — but if your OWN service mounts a
route at `/mcp`, that path is scoped to your service's own host and dispatches
to your service like any other route. Deploy/provision/login via CLI or MCP
are **unaffected**.

> **Deploy/test caveat:** if you try to `curl` or smoke-test your OWN deployed
> service's `authenticated` route with your global operator token, it will
> **403**. Use an `sk_*` key on a `public`-ingress route, hit a public endpoint,
> or (for your own first-party service) add it to `BOOGY_FIRSTPARTY_WORKLOADS`.
> Login, deploy, and provision via CLI/MCP are unaffected.

## The three-layer model

1. **Ingress admits** — the platform's ingress mode decides whether a
   request reaches your service. By the time your code runs the caller
   is already a known *principal* or anonymous.
2. **Guards gate routes** — per-route checks run before the handler:
   require a login, or require ownership of the addressed resource.
3. **Helpers scope rows** — handlers list/load only the caller's rows.

Resolve the caller with `auth::current_principal() -> Option<String>`.
The principal is **opaque** — never parse, prefix-strip, or assume a
UUID; use it only as your owner-column value and as input to `auth::*`.
An end-user SSO session surfaces as a `pw_…` pairwise id; treat it exactly
like any other principal (ownership scoping is unchanged).

For a human-readable identity, use `auth::current_handle() -> Option<String>`
alongside `current_principal()`. It returns the signed-in end-user's
**verified** platform handle — sourced from a signed platform-token claim,
never browser-asserted, so it's safe to key on or display. It's `None`
whenever the user hasn't consented to share their identity (also `None` for
anonymous and API-key callers). The two accessors do different jobs:
`current_principal()` stays your storage/ownership key — the opaque,
per-service pairwise every row's owner column holds; `current_handle()` is a
human-readable, cross-service-stable **display/routing** identity — the same
person's handle looks the same at every service, so use it for showing a name
or routing to a per-user page, not for scoping storage.

### End-user ingress semantics

An end-user who signs in via "Sign in with Boogy" arrives with a `pw_…` pairwise
pseudonym — a per-service mask of their real identity. The mask is stable: the
same user always lands on the same pairwise at a given service, whether they
visited directly or arrived via a delegated call chain. Different services see
different, mutually-unlinkable masks.

| Ingress mode | App-scoped end-user (`pw_…`) admitted? |
|---|---|
| `public` | yes |
| `authenticated` | yes (any non-anonymous identity) |
| `allowlist` | **conditionally** — `pw_…` is opaque and cannot match directly, but the host resolves the user's real account for the admission check, so an app-signed-in user IS admitted if their real account id or handle is in `allowed_agents` (wasm still sees only the mask) |
| `internal` | **no** — workload-only |
| `mixed` | **no** — tries internal then allowlist; neither admits a pairwise |

An owner's own `allowlist`-gated or `private` surface will reject the owner's
SSO session — after SSO they arrive as a pairwise, which cannot match an
`allowlist` entry. Use `BOOGY_FIRSTPARTY_WORKLOADS` (global identity) or an
`sk_*` key on a `public` route if you need owner-level access to such a surface.

**End-user identity in delegation chains:** when another service calls yours on
a user's behalf (OBO), the user's identity propagates through the chain — gated
by your `[ingress.delegation]` opt-in. Your service receives a delegated
identity where `principal` = the user's pairwise for YOUR service and `actor` =
the calling workload. The same user always lands on the same per-service pairwise
regardless of path, so "both notes are mine" holds even when one note was filed
directly and the other arrived via a chain.

## Per-route ingress: a public route inside a restricted service

Layer 1 (ingress) is normally one service-wide `mode`. But sometimes one
route must be reachable by callers the rest of the service rejects — the
canonical case is a **public `/webhook`** receiver inside an otherwise
`authenticated` (or `internal`/`mixed`) service. Carve it out with a
per-route override; the rest of the service stays restricted:

```toml
[ingress]
mode = "authenticated"          # service-wide default — everything else

[[ingress.routes]]
path = "/webhook"               # service-relative path; ALL methods
mode = "public"                 # anyone may reach /webhook
```

**The security contract (read it — it's fail-closed):**

| Rule | Why it matters |
|---|---|
| **Service-relative literal paths.** Exact (`/webhook`) or prefix (`/stripe/*`, segment-boundary). No `{param}` capture. | The `path` is the path your Router sees, the same frame as your handlers. |
| **Most-specific match wins; exactly one mode applies.** Exact beats prefix; longer prefix beats shorter. | A public sub-route can never *widen* a sibling: `/webhook` public does not loosen `/data`. |
| **Default = the service-wide mode.** An unmatched path (or a `..` traversal attempt) falls through to the restricted default, **never** to the most-permissive route. | Forgetting to list a route leaves it protected, not exposed. |
| **Each override carries its OWN mode + allowlists.** An override does NOT inherit `allowed_agents`/`allowed_origins`. | List them on the route block; the same non-empty validation applies so a typo can't silently deny-all. |
| **Per-PATH, not per-method (today).** `path = "/webhook"` applies to GET, POST, etc. alike. | A public `/webhook` is reachable by any verb — so still validate the request in-handler (a stray GET should do nothing). |
| **Host-enforced at the edge.** Ingress runs *before* your wasm instantiates. | You do NOT self-gate a public route in code; but a public route means **anyone** reaches it — authenticate it some *other* way (e.g. an HMAC signature; see `boogy:boogy-webhooks`). |
| **Delegation gate + rate limit stay SERVICE-WIDE.** | A public carve-out can't bypass the `[ingress.delegation]` gate, and shares the rate-limit bucket. |

**FullStack / non-root-mounted services: the `path` is MOUNT-INCLUSIVE.** "The
path your Router sees" includes the service mount — the host forwards the request
to the guest *with* the mount, it does not strip it (the same frame as the mount
rule in `boogy:boogy-serving-frontends`). So for a FullStack app mounted at
`/todos` whose API lives under `api_prefix = "/api"`, a public carve-out for the
SPA's auth-check endpoint must be the **mount-inclusive** path:

```toml
[ingress]
mode = "authenticated"

[[ingress.routes]]
path = "/todos/api/me"          # NOT "/api/me" — include the mount
mode = "public"
```

Writing the un-mounted `/api/me` is the trap: it never matches, the carve-out
silently doesn't apply, and the route stays gated by the service default. (The
`/webhook` example above works only because that service is mounted at root.)

A manifest with no `[[ingress.routes]]` behaves exactly as before — this
is purely additive.

### The reverse: a RESTRICTED subtree inside an open service (owner-only `/admin`)

The other direction — a service whose default is open (`authenticated`) but whose
`/admin/*` subtree is reachable only by the **service owner** (the provisioner).
The trap: a **provisionable** module is deployed by *anyone*, so you must NOT
hardcode an identity (`@alice`, `boogy://alice/services/*`) in the manifest — that
literal owner is wrong for every other provisioner, and ingress allowlist strings
are **not** substituted at deploy time. Ingress has no "same owner as me" matcher.

Use the ungated **`caller_is_service_owner()`** capability — the host attests
whether the caller is THIS service's owner (their agent token, resolved host-side
against the agents registry, OR one of their own workloads). No per-route ingress,
no hardcoded identity:

```toml
[ingress]
mode = "authenticated"          # all routes; the handler gates /admin itself
```

```rust
// require_operator(): host-attested, nothing hardcoded.
fn require_operator() -> Result<(), ApiError> {
    if caller_is_service_owner() { return Ok(()); }   // the owner: their agent OR own workload
    // OBO: the owner's backend acting for a user — the ATTESTED actor is the workload.
    // `current_identity()` is NOT an SDK free function — it's the full binding path.
    // `actor` is `Option<String>`, set only on delegated calls.
    let identity = bindings::boogy::platform::auth::current_identity();
    let actor_owner = identity
        .as_ref()
        .and_then(|i| i.actor.as_deref())
        .and_then(workload_owner);                    // workload_owner: a small helper YOU write —
                                                      // parse <owner> out of "boogy://<owner>/services/<id>"
    if actor_owner == Some(self_identity().owner) { return Ok(()); }
    Err(ApiError::forbidden("operator only"))
}
```

Why this is the right primitive: the **human owner can curl `/admin` directly**
with their own token (the wasm can't resolve an agent's handle, but the host can —
that's what the capability does), AND the owner's backend works as a workload.
Fail-closed: anonymous, a different owner, or an unresolvable caller → `false`.
(See the `resend-base` catalog module.) The earlier "`internal` + same-owner
workload" pattern also works but EXCLUDES direct human curl — prefer
`caller_is_service_owner` for owner-only surfaces.

## Guard & helper quick-reference (verified)

| Item | Use |
|---|---|
| `auth::required() -> Guard` | 401 if anonymous. Put on collection routes (`list`, `create`). |
| `auth::owns_resource(table, owner_col, id_param) -> Guard` | Item routes (`GET/DELETE /things/{id}`). Loads the row, **404 if missing OR not-yours**, stashes it in `req.ctx`. `.slot("name")` for multiple loads. **Numeric `_id` path param ONLY** — it parses the param as `u64`; a slug/`public_id` route 404s on every request (see below). |
| `auth::find_owned::<M>(owner_col) -> Result<Vec<Row>, _>` | Principal-scoped list. Takes the model `M` as a type parameter, **not** a table string — that is what lets it read `M`'s declared access patterns. If `M` declares an order over `owner_col` (a `list_by`, or an index leading with it) the call keyset-paginates the principal's whole set in that order. If it does not, the call reads **one page and errors** rather than silently returning a partial or duplicated list. Either way it loads the entire set into memory, so it is still for **bounded per-principal sets** — for a set that grows without limit, expose a cursor. 401 when anonymous. |
| `auth::load_owned(table, owner_col, id) -> Result<Option<Row>, _>` | Single load + ownership check for MCP/JSON-RPC (id in body, not path). `None` = missing OR not-yours. |
| `auth::require_scope(scope) -> Guard` | Coarse capability gate: 401 if anonymous, **403 if logged in but lacks the scope**. |

**Owner column** — the `owner_col` argument above. Every per-user table has one
column that records the **owning principal** of each row (the value from
`auth::current_principal()`). Use the SDK constant **`DEFAULT_OWNER_COL`** for it
— exported from `boogy_sdk` (`pub const DEFAULT_OWNER_COL: &str =
"owner_principal"`) — both as the column name in your table *and* as the
`owner_col` argument to the helpers. Don't invent `owner_id`/`created_by`:
keeping the name uniform across services is what lets the ownership helpers,
audit, and migration tooling work. Wire item routes as
`.group([auth::owns_resource("things", DEFAULT_OWNER_COL, "id")], |g| …)`.

The same `.group([...], |g| …)` form gates collection routes with
**`auth::required()`** — the most common guard, "must be logged in to
write":

```rust
Router::new()
    .group([auth::required()], |g| g
        .post("/things", create)
        .get("/things/mine", list_mine))
```

**Reading the ctx-stashed row** — the guard already loaded + ownership-checked the
row and put it in `req.ctx`; the handler reads it back, never re-fetches. The
stashed value is a `boogy_sdk::store::Row`; pull it with `req.ctx.get::<Row>()`
(default slot) or `req.ctx.get_at::<Row>("name")` when the guard used
`.slot("name")`, then read columns off it:

```rust
fn get_thing(req: &mut Req<'_>) -> Result<Json<ThingOut>, ApiError> {
    // owns_resource already loaded it + verified ownership + 404'd otherwise.
    let row = req.ctx.get::<Row>().expect("owns_resource guard stashed the row");
    Ok(Json(ThingOut { id: row.id(), name: row.text("name") }))
}
```

**`Row` column accessors** — every accessor takes the plain column name
(`&str`) and returns a plain value (never `Option`; a missing/null column
comes back as that type's zero value):

| Accessor | Returns |
|---|---|
| `.id()` | `u64` — the row's id (shortcut for the id column) |
| `.text(col)` | `String` |
| `.int(col)` | `i64` |
| `.real(col)` | `f64` |
| `.bool(col)` | `bool` |
| `.to_json(fields)` | `serde_json::Value` — only the listed columns |
| `.to_json_all()` | `serde_json::Value` — every column |

See `boogy:boogy-data-modeling` for table/column conventions. `get`/`get_at`
on `req.ctx` return `Option<&T>`: present because
the guard ran, so a missing value is a wiring bug, not a client error.

**Owner-from-token rule:** on create, stamp the owner column from
`auth::current_principal()`. NEVER read the owner from the request body
— a client could claim another user's id.

## Iron Law: deny-by-existence-mask

**Missing and exists-but-not-yours both return 404 — NEVER 403.** A
platform security invariant, not a style choice. A 403-vs-404 split is
an enumeration oracle: an authenticated user probes ids and learns
which exist (403) versus which don't (404). The SDK guards enforce this.

*"But the UI wants to tell the user why."* Do it **client-side**: treat
404 uniformly as "not available to you" and render that message; the
wire status stays 404. Do **not** fork or patch the SDK guard to split
the mask. (`require_scope`'s 403 is a *different axis* — coarse
capability, not resource ownership — and is correct.)

The three sections below are cases where the SDK guard **cannot** enforce
the mask for you. The 404 rule does not bend; you become the one who
upholds it.

## Items addressed by a natural or opaque key

`owns_resource` parses its path param as the row's numeric `_id` (`u64`).
Hand it a slug or a `public_id` and the parse fails **before any lookup**:
the route returns **404 on every request** — a total, silent outage that
reads like a data problem, not a guard problem.

`boogy:boogy-data-modeling` tells you to expose an opaque `#[lookup_by]`
`public_id` precisely because `Id<T>` is enumerable. That advice wins.
Keep the guard off the route and hand-roll the three steps, in one place:

```rust
use boogy_sdk::store::Val;   // not re-exported by wit_glue! — import it

// Seek the unique #[lookup_by] index, then check the owner. Both misses → 404.
fn load_owned_thing(public_id: &str, principal: &str) -> Result<Thing, ApiError> {
    let thing = db_find_by::<Thing>(Thing::PUBLIC_ID, Val::Text(public_id.to_string()))?
        .into_iter().next()
        .ok_or_else(ApiError::not_found)?;   // missing        → 404
    if thing.owner_principal != principal {
        return Err(ApiError::not_found());   // exists, not yours → the SAME 404
    }
    Ok(thing)
}
```

Once the mask is yours:

- **One helper per resource**, called by every route touching it. The
  mask must never be re-typed per handler — that's how one route drifts.
- **Resolve the principal first, fail closed**:
  `auth::current_principal().ok_or_else(ApiError::unauthenticated)?`.
  Never compare an owner column against a possibly-empty string.
- The key column must be `#[lookup_by]` — otherwise the lookup is a scan,
  not a seek. (Not `#[unique]`: it is rejected by the derive, and before it
  was it built no index at all.)
- Soft-deleted counts as missing: tombstone check → 404 as well.

## Composite and parent-keyed rules

Some rules are not "this row is mine". Moderation is the canonical one:
*delete a post if you are its author **OR** the room's creator*. There is
no single ownership fact to guard on — and stacking a second
`owns_resource` on the parent is worse than nothing: it 404s exactly when
the caller **is** the author but doesn't own the room, so the rule you
wrote the guard for is the case it breaks.

Load both facts, then decide in one pure predicate:

```rust
// Pure, unit-testable, fails closed on a blank viewer.
pub fn can_delete_post(viewer: &str, author: &str, room_creator: &str) -> bool {
    !viewer.trim().is_empty() && (viewer == author || viewer == room_creator)
}

let post = load_live_post(&public_id)?;                        // 404 if missing
let room = db_get::<Room>(post.room_id as u64)?.ok_or_else(ApiError::not_found)?;
if !can_delete_post(&principal, &post.owner_principal, &room.owner_principal) {
    return Err(ApiError::not_found());   // Iron Law unchanged: 404, NEVER 403
}
```

- **The existence mask still applies.** A caller who fails the composite
  rule must not learn the row exists. Same status as "no such post".
- Membership/role rules are the same shape: seek the junction row
  (`where_eq(room_id).where_eq(member_principal)` on its unique index)
  and feed the resulting boolean into the predicate.
- Keep predicates in a `perms` module with unit tests, including
  blank-viewer and blank-column cases. Handlers do lookups; predicates
  decide; neither does the other's job.

## Index endpoints: owner-scoped keyset, not `find_owned`

`find_owned` is fine for a set bounded by construction (one settings row,
a handful of keys). On a table that grows it loads every row the
principal has ever created into wasm memory on **every** request —
unbounded memory and latency that climbs with tenure, and it reads as a
platform regression rather than a service bug.

For anything that grows, scope by the owner column and page by keyset:

```rust
use boogy_sdk::store::SortDir;

let principal = auth::current_principal().ok_or_else(ApiError::unauthenticated)?;
let page = Query::on(Receipt::TABLE)
    .where_eq(DEFAULT_OWNER_COL, principal.as_str())  // the whole privacy story
    .keyset_by(Receipt::CREATED_AT, SortDir::Desc)
    .limit(limit)          // clamp the client's requested limit
    .cursor(cursor)        // pagination::decode() from the query string
    .fetch_page(|row| ReceiptOut::from_row(row))?;    // → CursorPage<T>
```

The owner filter is part of the query, not a post-filter over a wider
result — there must be no unscoped variant of this query anywhere in the
service. Back it with a declared access pattern
(`list_by(filter = owner_principal, newest = created_at)`) so it's a seek.
Cursor/limit/ordering mechanics: `boogy:boogy-access-patterns`.

## API keys for programmatic callers (verified recipe)

Invoke `api_keys_glue!(bindings)` next to `wit_glue!`, then:
1. `api_key_routes::install_table()` in `schema`.
2. Mount management routes via the `ApiKeyRoutes` ext trait:
   `Router::new().with_api_key_routes()` (`/_keys`) or
   `.with_api_key_routes_at("/admin/keys")`.
3. Gate your routes: `.group([api_key_routes::guard], |g| ...)`.

| Fact | Detail |
|---|---|
| Dual credential | `guard` accepts a session bearer OR an `sk_*` key; both unify into `current_principal()`, so `owns_resource`/`find_owned` work unchanged. |
| Managing keys | Requires a session identity; an `sk_*` key cannot mint keys. |
| No escalation | A key carries only scopes the minter already holds (403 otherwise). |
| Storage | Keys live hashed in the service's own store; never roll your own table. |
| Format | `sk_<env>_<…>_<crc>`. |
| Requires `clock` + `entropy` | Key generation and expiry checks use the raw wall clock and secure random source, not the gated `runtime::now-millis`/`random-bytes` wrapper — grant both in `[capabilities]` or every issued key comes from the same deterministic (denied) stream and expiry math never advances. |

## Red flags

| Thought | Reality |
|---|---|
| "403 'not yours' tells users why." | It's an id-enumeration oracle. Return 404 for both; explain client-side. |
| "I'll check ownership in the handler after loading the row." | Right for the **numeric-`_id`, single-owner** route: `owns_resource` does load + check + ctx-stash; read the stashed row. Wrong — and unavoidable — for an **opaque/slug key** (the guard parses `u64`) or a **composite/parent-keyed rule**. Hand-roll those: one helper per resource, 404 for both misses. |
| "The parent's owner rule? I'll stack a second `owns_resource` on it." | It 404s the author who doesn't own the parent — it kills the very case you added it for. Load both facts, decide in one predicate. |
| "`find_owned` is the list helper, so index endpoints use it." | It materializes the principal's whole set per request. Bounded sets only; growing tables use the owner-scoped keyset query. |
| "I'll add a custom api_keys table." | `api_keys_glue!` ships a hashed, isolated, scope-aware table. Use it. |
| "Read the owner id from the request body." | Stamp it from `current_principal()`. The body is attacker-controlled. |
| "A public `[[ingress.routes]]` route still needs an in-wasm auth check." | Public means anyone reaches it — authenticate it another way (HMAC signature for webhooks). The override doesn't self-gate. |
| "I'll smoke-test my `authenticated` route with my deploy/operator token." | That token is a global Agent — **rejected 403** at a non-public tenant route (the control-plane/app-plane boundary). Use an `sk_*` key, a public route, or the SSO flow. Deploy/provision/login itself is unaffected. |
| "The `pw_…` prefix means I need special ownership logic for end-users." | `current_principal()` is an opaque string regardless of how it was derived. `find_owned`/`owns_resource` work unchanged for pairwise ids. |
| "If a user calls my service via a chain, they'll get a different owner than a direct visit." | No — the pairwise is a fingerprint of `(user, your-service)`, path-independent. Direct visit and chain arrival produce the same `pw_…` at your boundary. |

## Integration

← `boogy:designing-boogy-services` picks the ingress mode feeding layer
1. `boogy:boogy-account-auth` is where principals come from (login →
the token you read). For acting on a user's behalf across services, see
`boogy:boogy-obo-delegation`. A public per-route carve-out for a signed
callback is the front half of `boogy:boogy-webhooks`.
`boogy:boogy-data-modeling` decides the key an item route is addressed by
(opaque `public_id` vs. numeric `_id`) — which decides whether
`owns_resource` can guard it at all. `boogy:boogy-access-patterns` owns
the keyset query every owner-scoped index endpoint should use.
