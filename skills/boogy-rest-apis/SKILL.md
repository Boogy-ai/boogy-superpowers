---
name: boogy-rest-apis
description: Use when building HTTP/REST or JSON-RPC endpoints on a Boogy service — routing, guards, request parsing/validation, response types, or the error wire format
---

# Boogy REST APIs

Handlers take `&mut Req<'_>` and return anything `IntoResponse`. Build
from this surface — never hand-roll status codes or error bodies.
Handler bodies read and write through the typed model layer (`db_*` +
`Query`, see `boogy:boogy-access-patterns`), **not** raw `store::*`.

## Iron Law: every request body and every response is a typed DTO

**Every HTTP request body and every response is a typed
`#[derive(Serialize/Deserialize, schemars::JsonSchema)]` DTO, returned
as `Json<T>` / `Created<T>` (lists as `Json<Wrapper { items: Vec<T> }>`).
`Json<json::Value>` is an escape hatch, not a default.**

Every deployed service auto-serves `GET <routes>/openapi.json`. The
typed DTOs are *what populates the request and response schemas in that
document* — they are the entire reason a REST client, an SDK generator,
or another agent can use your API without reading your source. A handler
that takes or returns `json::Value` produces an endpoint with **no
schema**: an undocumented hole in the spec.

This is **enforced, not advised** — a CI gate FAILS untyped handler I/O.
And a type-level bound can't catch it for you: `schemars` implements
`JsonSchema` for `serde_json::Value`, so a `T: JsonSchema` bound on
`Json<T>` would still accept `Json<json::Value>` and emit a useless
"any" schema. That is exactly why the discipline AND the gate matter.

```rust
// GOOD — typed DTO in, typed DTO out. Both derive JsonSchema, so both
// the request and the response shape land in openapi.json.
#[derive(Deserialize, schemars::JsonSchema)]
struct SendReq {
    to: String,
    from: String,
    subject: String,
    body: String,
}

#[derive(Serialize, schemars::JsonSchema)]
struct SendResult {
    message_id: u64,
    status: String,
}

// The Json<T> extractor arg decodes + validates the typed body; the
// Json<SendResult> return type publishes the response schema.
fn send(Json(req): Json<SendReq>) -> Result<Json<SendResult>, ApiError> {
    let id = db_insert(&Message { /* … */ })?;
    Ok(Json(SendResult { message_id: id, status: "queued".into() }))
}

// Lists are a typed wrapper around a Vec<T> — never a bare Vec or Value.
#[derive(Serialize, schemars::JsonSchema)]
struct MessageList { items: Vec<MessageOut>, count: usize }
```

```rust
// BAD — both directions are invisible in openapi.json.
//   * Json<json::Value> in/out → no request and no response schema.
//   * a Deserialize-only request struct → the body has no schema either,
//     because schemars only emits a schema when JsonSchema is derived.
#[derive(Deserialize)]                       // ← missing schemars::JsonSchema
struct SendReq { to: String, body: String }

fn send(Json(req): Json<json::Value>) -> Json<json::Value> { /* … */ }
```

## Routing — annotate every route, set the doc identity

`Router::info(title, version, Some(description))` sets the document
identity; chain `.summary(…)` (one line) + `.description(…)` (prose)
before each route — both apply to the NEXT route registered, then
self-clear:

```rust boogy-snippet
fn routes() -> Router {
    Router::new()
        .info("Widgets", "0.1.0", Some("CRUD over the widget catalog."))
        .summary("List widgets")
        .description("Return every widget the caller owns, newest first.")
        .get("/widgets", list_widgets)
        .summary("Create a widget")
        .description("Insert a widget and return it with its new id.")
        .post("/widgets", create_widget)
        .summary("Get a widget")
        .description("Fetch one widget by id; 404 if it doesn't exist.")
        .get("/widgets/{id}", get_widget)
        .summary("Update a widget")
        .description("Replace a widget's fields by id.")
        .patch("/widgets/{id}", update_widget)
        .summary("Delete a widget")
        .description("Delete a widget by id; 404 if it doesn't exist.")
        .delete("/widgets/{id}", delete_widget)
        .nest("/admin", admin_routes())     // mount a sub-router under a prefix
}

// Handler / sub-router shapes (bodies elided):
fn list_widgets(_req: &mut Req<'_>) -> NoContent { NoContent }
fn create_widget(_req: &mut Req<'_>) -> NoContent { NoContent }
fn get_widget(_req: &mut Req<'_>) -> NoContent { NoContent }
fn update_widget(_req: &mut Req<'_>) -> NoContent { NoContent }
fn delete_widget(_req: &mut Req<'_>) -> NoContent { NoContent }
fn admin_routes() -> Router { Router::new() }
```

`get`/`post`/`put`/`patch`/`delete` register one route each;
`route_many(&["GET","POST"], path, h)` shares a handler. The router
answers 404, 405 + `Allow:`, and auto-OPTIONS (204 + `Allow:`); HEAD
falls back to GET with the body stripped.

**Route annotation is MANDATORY, not decoration.** `Router::info(...)`
plus `.summary()` + `.description()` on **every** route flow straight
into the auto-served `openapi.json` (and `openrpc.json` for JSON-RPC
mounts) — the surface the API console, REST clients, and other agents
read to understand your service without your source. An un-annotated
route or an empty/identity-less spec is a **defect**, the same as a
missing test. Checklist before you call a router done:

- [ ] `Router::info(title, version, Some(desc))` is set.
- [ ] Every route has both `.summary()` and `.description()`.
- [ ] Every DTO in an extractor or response derives `schemars::JsonSchema`.

## Handler bodies use the model layer

A create handler inserts a typed model and returns it — no
`store::insert`, no bare column strings:

```rust
// `Widget` is a #[derive(Model)] struct (see boogy:boogy-data-modeling).
fn create_widget(req: &mut Req<'_>) -> Result<Created<WidgetOut>, ApiError> {
    let input: CreateWidget = validate_body(req.body())?;
    let id = db_insert(&Widget {
        id: Id::new(0),                       // placeholder PK; store assigns _id
        name: input.name.clone(),
        created_at: Timestamp::new(now_millis() as i64),
    })?;
    Ok(Created(WidgetOut { id, name: input.name }))
}
```

Reads go through `db_get` / `db_find_by` / `Query` (see
`boogy:boogy-access-patterns`). Raw `store::insert`/`find` is the escape
hatch only.

## Guards (auth, ownership, scope)

Guards are NOT attached with a `.guard()` method — that does not exist.
Use `.group(guards, |g| …)`:

```rust boogy-snippet
fn routes() -> Router {
    Router::new()
        .group([auth::owns_resource("widgets", "owner_principal", "id")], |g| g
            .get("/widgets/{id}", get_widget)
            .delete("/widgets/{id}", delete_widget))
        .get("/health", health)            // ungrouped → no guards
}

fn get_widget(_req: &mut Req<'_>) -> NoContent { NoContent }
fn delete_widget(_req: &mut Req<'_>) -> NoContent { NoContent }
fn health(_req: &mut Req<'_>) -> NoContent { NoContent }
```

Guard ordering: **outer guards (parent `.group`/`.nest`) run before
inner; within an array, left-to-right; the first `Err` short-circuits.**
For two guards of different Rust types the array won't type-check — use
`.group(boogy_sdk::guards![api_key_guard, auth::owns_resource(...)], |g| …)`.
A group's guard set is always the array right above the routes.

## Extractors

| Need | Call |
|------|------|
| typed path param | `req.params.parse::<i64>("id")?` (missing/bad → 400) |
| JSON body **with validation** | `validate_body::<T>(req.body())?` |
| JSON body, no validation rules | `parse_body::<T>(req.body())?` |
| query string, validated | `req.parse_query::<T>()?` |
| query string, no rules | `req.parse_query_raw::<T>()?` |

Use `validate_body` whenever the input has any constraint: it parses
JSON **and** runs `garde` (missing body → 400, bad JSON → 400, failed
validation → 422 with a per-field map). Use `parse_body` only when the
type has no validation rules (avoids the `garde::Validate` bound).

```rust boogy-snippet
#[derive(serde::Serialize)]
struct WidgetOut { id: u64 }

#[derive(Deserialize, garde::Validate)]
struct CreateWidget {
    #[garde(length(min = 1, max = 80))] name: String,
    #[garde(email)] email: String,
}

fn create_widget(req: &mut Req<'_>) -> Result<Created<WidgetOut>, ApiError> {
    let input: CreateWidget = validate_body(req.body())?;
    // ... insert, return Created(...) ...
    Ok(Created(WidgetOut { id: 1 }))
}
```

**The `garde` version must match the SDK workspace pin (currently
`0.22`).** Add `garde = { workspace = true }` (or `garde = "0.22"`) —
NOT `0.20`. The derive macro emits `::garde::*` paths, so it's a direct
dependency. Some rules are feature-gated: `#[garde(email)]` needs
`features = ["email"]`, `#[garde(pattern(...))]` needs `["pattern"]` —
enable them alongside `derive`.

**`schemars = "0.8"` is required for spec generation.** Add it as a
direct dep and derive `schemars::JsonSchema` on every DTO that appears
in a typed extractor or response — this is what makes request/response
shapes show up in the auto-served `…/openapi.json` document. Omitting
it is not an error at runtime, but the generated schema will be empty
for that type.

## Responses

Return typed wrappers and let the framework set the status:

| Return | Status |
|--------|--------|
| `Json<T>` | 200 |
| `Created<T>` | 201 |
| `NoContent` / `()` | 204 |
| `Redirect::to(url)` | 302 |
| `Option<T>` (`None`) | 404 |
| `Result<T, ApiError>` (`Err`) | the error's status, as 7807 |

## Error wire format (RFC 7807)

Every SDK error is `application/problem+json`:

```json
{ "type": "/errors/validation_failed", "title": "Validation failed",
  "status": 422, "detail": "1 field failed validation",
  "errors": { "email": ["not a valid email"] } }
```

`errors` (per-field map) appears only on validation. Construct via
`ApiError`: `bad_request` 400, `unauthenticated` 401, `forbidden` 403,
`not_found` 404 (also "exists but not yours" — existence-mask),
`conflict` 409, `unprocessable` 422 (freeform domain rule),
`validation(report)` **422** (per-field), `internal` 500. `ApiError`
converts to both `HttpResponse` and `RpcError`, so the same value flows
through REST or JSON-RPC.

## JSON-RPC (it has a real layer)

JSON-RPC 2.0 is NOT "a POST route you parse yourself" — use
`Router::rpc`, which registers the route AND captures method shapes for
`…/openrpc.json`:

```rust
// mount: the closure runs once at registration (spec capture) and once
// per request (dispatch).
Router::new().rpc("/rpc", || rpc::Dispatcher::new()
    .method("search", search)      // Fn(P) -> Result<R, RpcError>
    .method("share", share))
```

It does envelope parse, method routing, typed `params` decode, and
standard error codes. `RpcError`: `parse_error`, `invalid_request`,
`method_not_found`, `invalid_params`, `internal`, plus
`RpcError::application(code, msg)`. (MCP tools use the same substrate —
see `boogy:boogy-mcp-services`.)

## Red flags

| Thought | Reality |
|---------|---------|
| "I'll just `parse_body` and check fields myself." | If the body has rules, use `validate_body` — you get 422 + a per-field map for free. |
| "garde 0.20 should be fine." | Match the workspace pin (currently 0.22). A mismatched garde version fails to build or drifts the derive. |
| "I'll return a 201 with a custom JSON error envelope." | Return `Created<T>` / `ApiError`; the wire shape is RFC 7807 `application/problem+json`, not a bespoke `{error:...}`. |
| "Attach the guard with `.guard(...)`." | No such method. Use `.group([...], |g| …)`; heterogeneous types → `guards![...]`. |
| "No framework for JSON-RPC, I'll parse the envelope." | `Router::rpc(path, || Dispatcher::new()…)` does registration + spec capture + envelope + routing + typed params + standard codes. |
| "I'll `store::insert` / `store::find` in the handler." | Use `db_insert` / `db_get` / `db_find_by` / `Query` on a `#[derive(Model)]` struct. Raw `store::*` for ordinary CRUD is a regression (see `boogy:boogy-data-modeling`). |
| "The handler inserts a row and bumps a counter — that's fine as two calls." | Multi-write handlers (≥ 2 dependent writes, read-modify-write upsert, debit + credit) must wrap the writes in one `tx` — see `boogy:boogy-transactions`. |
| "I'll wire the routes and skip the docs." | MANDATORY: `Router::info(...)` + `.summary()` + `.description()` on every route. They flow into the auto-served `openapi.json`/`openrpc.json` (the API console + clients surface them). An un-annotated route or identity-less spec is a defect, not a smell. |
| "I'll just take/return `Json<json::Value>` / `Created<json::Value>` — it's flexible." | Your endpoint is undocumented: no request or response schema in `openapi.json`. The CI gate FAILS it. Define a typed `#[derive(…, schemars::JsonSchema)]` DTO. |
| "My request struct only needs `Deserialize`." | A request struct that derives `Deserialize` without `JsonSchema` makes the request body invisible in the spec — `schemars` emits a schema only when `JsonSchema` is derived. Derive both. |

→ `boogy:boogy-api-specs` — the full picture of the auto-served
`openapi.json`/`openrpc.json`, two-tier visibility, and overrides.
