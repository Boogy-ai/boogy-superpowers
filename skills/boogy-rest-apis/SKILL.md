---
name: boogy-rest-apis
description: Use when building HTTP/REST or JSON-RPC endpoints on a Boogy service — routing, guards, request parsing/validation, response types, or the error wire format
---

# Boogy REST APIs

Handlers take `&mut Req<'_>` and return anything `IntoResponse`. Build
from this surface — never hand-roll status codes or error bodies.

## Routing

```rust boogy-snippet
fn routes() -> Router {
    Router::new()
        .get("/widgets", list_widgets)
        .post("/widgets", create_widget)
        .get("/widgets/{id}", get_widget)
        .patch("/widgets/{id}", update_widget)
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
