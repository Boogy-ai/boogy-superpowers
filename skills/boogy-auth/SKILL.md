---
name: boogy-auth
description: Use when adding authorization to a Boogy service — per-user data, ownership checks, "only my X" endpoints, API keys for programmatic callers, or scope gating
---

# Boogy auth (in-service authorization)

Authorization on Boogy is three layers. Don't hand-roll any of them —
the SDK emits verified helpers that keep the security invariants intact.

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
    let id = current_identity();
    let actor_owner = id.and_then(|i| i.actor).and_then(workload_owner);
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
| `auth::owns_resource(table, owner_col, id_param) -> Guard` | Item routes (`GET/DELETE /things/{id}`). Loads the row, **404 if missing OR not-yours**, stashes it in `req.ctx`. `.slot("name")` for multiple loads. |
| `auth::find_owned(table, owner_col) -> Result<Vec<Row>, _>` | Principal-scoped list for index endpoints. 401 when anonymous. |
| `auth::load_owned(table, owner_col, id) -> Result<Option<Row>, _>` | Single load + ownership check for MCP/JSON-RPC (id in body, not path). `None` = missing OR not-yours. |
| `auth::require_scope(scope) -> Guard` | Coarse capability gate: 401 if anonymous, **403 if logged in but lacks the scope**. |

Owner column is always `DEFAULT_OWNER_COL` (`"owner_principal"`) — never
invent `owner_id`/`created_by`. Wire item routes as
`.group([auth::owns_resource("things", DEFAULT_OWNER_COL, "id")], |g| …)`.
Handlers behind that guard read the **ctx-stashed row** — don't re-fetch.

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

## API keys for programmatic callers (verified recipe)

Invoke `api_keys_glue!(bindings)` next to `wit_glue!`, then:
1. `api_key_routes::install_table()` in `init_tables`.
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

## Red flags

| Thought | Reality |
|---|---|
| "403 'not yours' tells users why." | It's an id-enumeration oracle. Return 404 for both; explain client-side. |
| "I'll check ownership in the handler after loading the row." | `owns_resource` does load + check + ctx-stash in one guard. Read the stashed row; don't re-implement the check. |
| "I'll add a custom api_keys table." | `api_keys_glue!` ships a hashed, isolated, scope-aware table. Use it. |
| "Read the owner id from the request body." | Stamp it from `current_principal()`. The body is attacker-controlled. |
| "A public `[[ingress.routes]]` route still needs an in-wasm auth check." | Public means anyone reaches it — authenticate it another way (HMAC signature for webhooks). The override doesn't self-gate. |

## Integration

← `boogy:designing-boogy-services` picks the ingress mode feeding layer
1. `boogy:boogy-account-auth` is where principals come from (login →
the token you read). For acting on a user's behalf across services, see
`boogy:boogy-obo-delegation`. A public per-route carve-out for a signed
callback is the front half of `boogy:boogy-webhooks`.
