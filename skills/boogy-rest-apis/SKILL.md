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

The typed DTO is **necessary but not sufficient for request bodies**:
whether the body's schema actually reaches the document depends on the
handler shape you pick. Read *Documented request body vs. validated
request body* below before writing your first `POST`.

This is **enforced, not advised** — a CI gate FAILS untyped handler I/O.
And a type-level bound can't catch it for you: `schemars` implements
`JsonSchema` for `serde_json::Value`, so a `T: JsonSchema` bound on
`Json<T>` would still accept `Json<json::Value>` and emit a useless
"any" schema. That is exactly why the discipline AND the gate matter.

```rust
use boogy_sdk::model::{Id, Timestamp};
use boogy_sdk::Model;

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

// The stored row is its own type — a #[derive(Model)] struct, never the
// wire DTO. See `boogy:boogy-data-modeling`.
#[derive(Model)]
#[model(table = "messages")]
struct Message {
    #[pk] id: Id<Message>,
    to_addr: String,
    from_addr: String,
    subject: String,
    body: String,
    created_at: Timestamp,
}

// The Json<T> extractor arg decodes the typed body AND publishes its
// schema; the Json<SendResult> return type publishes the response
// schema. Note: the extractor does NOT run garde — see below.
fn send(Json(req): Json<SendReq>) -> Result<Json<SendResult>, ApiError> {
    let id = db_insert(&Message {
        id: Id::new(0),                     // placeholder PK; the store assigns _id
        to_addr: req.to,
        from_addr: req.from,
        subject: req.subject,
        body: req.body,
        created_at: Timestamp::new(now_millis() as i64),
    })?;
    Ok(Json(SendResult { message_id: id, status: "queued".into() }))
}

// Lists are a typed wrapper around a Vec<T> — never a bare Vec or Value.
#[derive(Serialize, schemars::JsonSchema)]
struct MessageOut { id: u64, subject: String }

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

fn send(Json(req): Json<json::Value>) -> Json<json::Value> {
    Json(json::json!({ "ok": true }))       // untyped in, untyped out
}
```

## Routing — annotate every route, set the doc identity

`Router::info(title, version, Some(description))` sets the document
identity; chain `.summary(…)` (one line) + `.description(…)` (prose)
before each route — both apply to the NEXT route registered, then
self-clear:

```rust
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
- [ ] You fetched `<routes>/openapi.json` and saw your request bodies in
      it. The derive alone does not put them there (next-but-one section).

## Handler bodies use the model layer

A create handler inserts a typed model and returns it — no
`store::insert`, no bare column strings:

```rust
use boogy_sdk::model::{Id, Timestamp};

// `Widget` is a #[derive(Model)] struct (see boogy:boogy-data-modeling);
// `CreateWidget` / `WidgetOut` are the DTOs declared in the next section.
// This is the `&mut Req` shape: garde runs, but the request body does
// NOT reach openapi.json. See the tradeoff section below.
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

`now_millis()` is **not an import** — `wit_glue!` emits it into your crate root, so
call it bare (`now_millis()`) or as `crate::now_millis()` from a submodule. It
returns the wall-clock time as `u64` epoch **milliseconds** (a thin wrapper over the
`clock` capability's `runtime::now_millis`). There is no `boogy_sdk::clock::…` path
to import; the macro provides it. (It needs the `clock` capability in your manifest.)

Reads go through `db_get` / `db_find_by` / `Query` (see
`boogy:boogy-access-patterns`). Raw `store::insert`/`find` is the escape
hatch only.

## Guards (auth, ownership, scope)

Guards are NOT attached with a `.guard()` method — that does not exist.
Use `.group(guards, |g| …)`:

```rust
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

```rust
#[derive(serde::Serialize, schemars::JsonSchema)]
struct WidgetOut { id: u64, name: String }

#[derive(Deserialize, garde::Validate)]
struct CreateWidget {
    #[garde(length(min = 1, max = 80))] name: String,
    #[garde(email)] email: String,
}

fn create_widget(req: &mut Req<'_>) -> Result<Created<WidgetOut>, ApiError> {
    let input: CreateWidget = validate_body(req.body())?;
    // ... insert, return Created(...) ...
    Ok(Created(WidgetOut { id: 1, name: input.name }))
}
```

**The `garde` version must match the SDK workspace pin (currently
`0.22`).** Add `garde = { workspace = true }` (or `garde = "0.22"`) —
NOT `0.20`. The derive macro emits `::garde::*` paths, so it's a direct
dependency. Some rules are feature-gated: `#[garde(email)]` needs
`features = ["email"]`, `#[garde(pattern(...))]` needs `["pattern"]` —
enable them alongside `derive`.

**Optional fields (`Option<T>`) — for PATCH/partial updates.** garde validates
`Option<T>` by **skipping `None` and applying the rule to the inner value when
`Some`** — exactly what you want for an optional PATCH field: omitted = unchanged,
present = validated. Just put the rule on the field directly:

```rust
#[derive(Deserialize, garde::Validate)]
struct PatchWidget {
    #[garde(length(min = 1, max = 80))] name: Option<String>,  // checked only if present
}
```

Do **not** reach for `inner(...)` here — `#[garde(inner(...))]` is for the elements
of a **collection** (`Vec<String>`), not for `Option`. (Confirmed against garde
0.22: every rule has an `impl … for Option<T>` that no-ops on `None`.)

**`schemars = "0.8"` is required for spec generation.** Add it as a
direct dep and derive `schemars::JsonSchema` on every DTO that appears
in a typed extractor or response. Omitting it is not a runtime error —
the type simply has no schema to publish. The derive is a
**precondition**, not the mechanism; the mechanism is the next section.

## Documented request body vs. validated request body

Spec capture happens **at route registration**, from the handler's
*types* — nothing inspects the handler body. So which shapes reach
`openapi.json` depends on the handler signature, and the two signatures
are not interchangeable:

| Handler shape | Request body in the spec | `garde` runs |
|---|---|---|
| `fn h(Json(b): Json<Body>) -> R` | **yes** — the extractor records `Body`'s schema at registration | **no** — it only deserializes |
| `fn h(req: &mut Req<'_>) -> R` + `validate_body::<Body>(req.body())?` | **no** — registration sees only the return type | **yes** |

The **response** side is identical in both — the return type's schema is
captured either way. Only the request body differs. Deriving
`JsonSchema` on a DTO you only ever hand to `validate_body`/`parse_body`
is **inert**: nothing reads it.

The query string splits the same way: `Query<T>` documents and does not
validate; `req.parse_query::<T>()` validates and does not document.

**To get both**, take the typed extractor and validate explicitly:

```rust
use garde::Validate;

// The extractor bound is `DeserializeOwned + JsonSchema` — that second
// derive is what puts the request body in openapi.json, and the
// `validate_body` shape above does NOT need it. Derive all three here.
#[derive(Deserialize, garde::Validate, schemars::JsonSchema)]
struct CreateWidget {
    #[garde(length(min = 1, max = 80))] name: String,
}

#[derive(Serialize, schemars::JsonSchema)]
struct WidgetOut { id: u64, name: String }

// The extractor publishes CreateWidget's schema; the explicit
// .validate() gives the same 422 + per-field map validate_body does.
fn create_widget(Json(input): Json<CreateWidget>)
    -> Result<Created<WidgetOut>, ApiError>
{
    input.validate().map_err(ApiError::validation)?;
    // ... insert, return Created(...) ...
    Ok(Created(WidgetOut { id: 1, name: input.name }))
}
```

**When you can't:** the extractor shape hands you no `Req`, so no
`req.ctx` (guard-stashed resources), no raw headers, no params beyond a
`Path<T>`. A route whose guard loads a row into `Ctx` must stay on
`&mut Req`, and its request body will be absent from the spec. Take the
extractor shape wherever the handler doesn't need `Req`; accept the gap
where it does, knowingly.

**Passing CI is not evidence.** The typed-DTO gate keys on the DTO at
the *use site* (`Json<Name>`, `parse_body::<Name>`), never on what
reached the document — a service can be fully green with zero request
bodies documented. Fetch `<routes>/openapi.json` and look.

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
| `HttpResponse` | whatever you built — and **undescribed**: the route loses its response schema. Escape hatch. |

**Idempotent routes: one status + a boolean in the body.** Nothing in
that table expresses a runtime-chosen status — "201 if I created it, 200
if it already existed" — the natural REST reflex for every enrol,
subscribe, ensure-exists, or upsert. Don't reach for `HttpResponse` to
build it. The convention is a single status with a **discriminator field
in the response DTO** (`already_member: bool`, `created: bool`):

```rust
#[derive(Serialize, schemars::JsonSchema)]
struct MemberOut { room_id: u64, principal: String, already_member: bool }
```

The route asserts a post-condition — *this principal is a member* —
equally true on the first call and the tenth, so it has one meaning and
should have one status. Splitting it turns the status line into a side
channel every client must branch on, and doubles the documented
responses for that one meaning. Reserve `201` for routes that only ever
create.

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
`conflict` 409 (version mismatch, "already in this state"),
`constraint_violation` 409 (duplicate value on a unique index, a **not-null
column written as null or omitted from a row-creating write**, or an FK /
check violation), `unprocessable` 422 (freeform domain rule),
`validation(report)` **422** (per-field), `service_unavailable` 503
(transient — the store was too contended or the platform is at a
concurrency cap), `internal` 500. `ApiError`
converts to both `HttpResponse` and `RpcError`, so the same value flows
through REST or JSON-RPC.

**409 is never "retry me".** A store commit conflict is retried inside `tx`
and does not reach the client; every 409 that does is deterministic and
needs the caller to change something. Transient contention is a **503**
whose retry hint rides in the problem+json `detail` (there is no
`Retry-After` header on it — `ApiError` carries no headers). See
`boogy:boogy-transactions`.

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

## `boogy check` counts write call-sites, not runtime paths

`boogy check` (the multi-write-without-transaction gate) counts write
**call sites** statically, not which branch actually executes. An
update-or-insert written as `match existing { Some(_) => db_update(...),
None => db_insert(...) }` has **two** write call-sites in the source even
though only one runs at runtime — the gate FAILS it as an unguarded
multi-write. Wrap the whole `match` in `tx::<_, _, ApiError>(|| ...)?` to
pass:

```rust
// FAILS `boogy check` — two write call-sites, no tx around them.
match &existing {
    Some(c) => db_update(c.id.get(), &updated)?,
    None    => { db_insert(&updated)?; }
}

// PASSES — the whole match (both call-sites) is inside one tx.
// Match on `&existing`, not `existing`: `tx` takes an `Fn` closure, so
// moving a captured value out of it does not compile.
tx::<_, _, ApiError>(|| {
    match &existing {
        Some(c) => db_update(c.id.get(), &updated)?,
        None    => { db_insert(&updated)?; }
    }
    Ok(())
})?;
```

See `boogy:boogy-transactions` for the full decision rule on when a
handler needs `tx`.

## Red flags

| Thought | Reality |
|---------|---------|
| "I'll just `parse_body` and check fields myself." | If the body has rules, use `validate_body` — you get 422 + a per-field map for free. |
| "garde 0.20 should be fine." | Match the workspace pin (currently 0.22). A mismatched garde version fails to build or drifts the derive. |
| "I'll return a 201 with a custom JSON error envelope." | Return `Created<T>` / `ApiError`; the wire shape is RFC 7807 `application/problem+json`, not a bespoke `{error:...}`. |
| "Attach the guard with `.guard(...)`." | No such method. Use `.group([...], |g| …)`; heterogeneous types → `guards![...]`. |
| "No framework for JSON-RPC, I'll parse the envelope." | `Router::rpc(path, || Dispatcher::new()…)` does registration + spec capture + envelope + routing + typed params + standard codes. |
| "I'll `store::insert` / `store::find` in the handler." | Use `db_insert` / `db_get` / `db_find_by` / `Query` on a `#[derive(Model)]` struct. Raw `store::*` for ordinary CRUD is a regression (see `boogy:boogy-data-modeling`). |
| "The handler inserts a row and bumps a counter — that's fine as two calls." | Any write whose state must roll back if later work in the handler fails belongs in one `tx` — multi-write handlers (≥ 2 dependent writes, read-modify-write upsert, debit + credit) are the common case, but a single write with fallible work after it counts too — see `boogy:boogy-transactions`. |
| "Only one branch of my `match` ever writes, so it's a single write." | `boogy check` counts write call-sites statically, not runtime branches — an update-or-insert `match` has two call-sites and FAILS the gate unless the whole `match` is inside one `tx`. |
| "I'll wire the routes and skip the docs." | MANDATORY: `Router::info(...)` + `.summary()` + `.description()` on every route. They flow into the auto-served `openapi.json`/`openrpc.json` (the API console + clients surface them). An un-annotated route or identity-less spec is a defect, not a smell. |
| "I'll just take/return `Json<json::Value>` / `Created<json::Value>` — it's flexible." | Your endpoint is undocumented: no request or response schema in `openapi.json`. The CI gate FAILS it. Define a typed `#[derive(…, schemars::JsonSchema)]` DTO. |
| "My request struct only needs `Deserialize`." | Without `JsonSchema` the body can never be described — `schemars` emits a schema only when the derive is present. Derive both. |
| "My DTOs all derive `JsonSchema`, so my request bodies are documented." | Only under the `Json<T>` extractor signature. With `&mut Req` + `validate_body` the derive is inert and the body is absent from `openapi.json` — and the extractor form doesn't run `garde`, so you can't have both without an explicit `.validate()`. CI proves neither; fetch the document. |
| "201 when I create it, 200 when it already existed." | No response type expresses a runtime-chosen status. Return **one** status and put a boolean discriminator in the body (`already_member: bool`). |

→ `boogy:boogy-api-specs` — the full picture of the auto-served
`openapi.json`/`openrpc.json`, two-tier visibility, and overrides.
