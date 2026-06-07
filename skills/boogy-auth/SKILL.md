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

## Integration

← `boogy:designing-boogy-services` picks the ingress mode feeding layer
1. `boogy:boogy-account-auth` is where principals come from (login →
the token you read). For acting on a user's behalf across services, see
`boogy:boogy-obo-delegation`.
