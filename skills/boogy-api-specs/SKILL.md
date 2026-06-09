---
name: boogy-api-specs
description: Use when asking about the auto-served spec documents (openapi.json, openrpc.json, MCP discovery), Router::info, two-tier visibility, Router::undocumented, the JsonSchema derive requirement, or override escape hatches
---

# Boogy API Specs

Every deployed service auto-serves spec documents off its route tree —
no handler code needed. This skill covers what's served, how visibility
works, and how to control or override the generated output.

## What's served and where

| URL (relative to service subtree) | Format | When |
|---|---|---|
| `GET …/openapi.json` | OpenAPI 3.0.3 | Always |
| `GET …/openrpc.json` | OpenRPC 1.3.2 | One or more `Router::rpc(…)` mounts exist |
| `POST <rpc path>` with body `{"method":"rpc.discover"}` | OpenRPC 1.3.2 (in-protocol) | Same document, served by the JSON-RPC dispatcher itself |

MCP endpoints have **no spec URL** — discovery is in-protocol per the
MCP spec (`initialize`, `tools/list`, `resources/list`, `prompts/list`),
and `tools/list` now carries `outputSchema` alongside `inputSchema`. The
generated `openapi.json` lists each `Router::mcp` mount as a POST
operation pointing clients at that flow.

"Relative to service subtree" means the path is suffix-matched inside
the service's own routing prefix. For a service deployed at
`/alice/notes-api`, `GET /alice/notes-api/api/openapi.json` returns the
doc.

The host forwards spec-doc GETs to the service even when the manifest
`[routing] methods` list excludes GET — no manifest change required.

## Setting the doc identity

`Router::info(title, version, description)` sets the `info` block of
the generated documents. Call it once on the router before mounting
routes:

```rust
Router::new()
    .info("Notes API", env!("CARGO_PKG_VERSION"), Some("CRUD and MCP for notes"))
    .get("/api/notes", list_notes)
    .post("/api/notes", create_note)
```

Omitting `info` produces a generic title and version `0.0.0`.

## Two-tier visibility

The spec documents respect authentication state:

- **Anonymous** callers (no bearer) see only public routes: not inside
  a `.group([...], |g| …)` guard block AND not taking a `Principal`
  typed extractor (an `Option<Principal>` extractor does NOT hide a
  route — it works anonymously).
- **Authenticated** callers (any valid bearer) see all routes.

This means you can ship a public-facing API that shows its public
surface to unauthenticated tooling (e.g. code generators, SDKs) and
shows the full surface to authenticated agents.

## Excluding routes from specs (`Router::undocumented`)

Wrap routes in `Router::undocumented` to keep them out of all generated
spec documents. The routes still dispatch normally; guards inside the
block still apply. Useful for internal health endpoints, debug probes,
or admin routes you don't want advertised:

```rust
Router::new()
    .get("/api/notes", list_notes)
    .undocumented(|g| g
        .get("/internal/health", health_check)
        .post("/internal/flush-cache", flush_cache))
```

`undocumented` composes with `group`: guards inside are independent of
spec visibility.

## Canonical mount methods

Use the dedicated mount methods — they register the route AND record it
in the generated spec in one call:

```rust
// JSON-RPC: closure runs once at mount (spec capture) + once per request (dispatch)
Router::new()
    .rpc("/api/rpc", || rpc::Dispatcher::new()
        .method("search", search_notes)
        .method("share", share_note))

// MCP: handler closure runs per request; endpoint appears in openapi.json
Router::new()
    .mcp("/mcp", |req| {
        McpServer::new("notes-mcp", env!("CARGO_PKG_VERSION"))
            .tool_typed(tool("create_note").description("…"), create_note_tool)
            .handle(req.request)
    })
```

`.post(path, handler)` works for both but does NOT record the endpoint
in the spec. Prefer `.mcp` and `.rpc`.

## Annotating endpoints (`summary` / `description`)

REST routes and RPC methods both take chainable `.summary("one line")`
and `.description("longer prose")` — they apply to the NEXT thing
registered, then self-clear. `Router::summary/description` annotate the
next route; `Dispatcher::summary/description` annotate the next
`.method(…)`:

```rust
Router::new()
    .summary("List widgets")
    .description("Return every widget the caller owns.")
    .get("/widgets", list_widgets)
    .rpc("/api/rpc", || rpc::Dispatcher::new()
        .summary("Search notes")
        .description("Full-text search over the caller's notes.")
        .method("search", search_notes))
```

These populate `summary` / `description` on the generated OpenAPI
operations and OpenRPC methods (omitted when unset). Write them — they
are how REST clients and agents discover what each endpoint does.

## The `JsonSchema` derive requirement

Typed extractors (`Json<T>`, `Query<T>`, `Path<T>`) and typed responses
(`Json<T>`, `Created<T>`) need `schemars::JsonSchema` on the payload
type to contribute schema information to `openapi.json`.

Add `schemars` as a **direct dependency** — `#[derive(JsonSchema)]`
emits `::schemars::*` absolute paths:

```toml
# Cargo.toml (external consumer)
schemars = "0.8"

# In-repo (workspace = true, already pinned)
schemars = { workspace = true }
```

Derive it alongside `Serialize`/`Deserialize` on every DTO:

```rust
#[derive(Deserialize, Serialize, schemars::JsonSchema)]
struct CreateNote {
    title: String,
    body: String,
}
```

For MCP `tool_typed::<P, R>`, **both** `P` (args) and `R` (result) must
derive `JsonSchema` — `inputSchema` and `outputSchema` are both
auto-derived.

Omitting `JsonSchema` is not a runtime error — the generated spec will
simply have an empty schema for that type. No panics, no 500s.

## Reserved filenames

`openapi.json` and `openrpc.json` are reserved at the leaf of any path
in your service's tree. Priority rules:

1. **Explicit literal GET route** at that exact path overrides the
   generated doc — mount `GET /api/openapi.json` and your handler's
   response is returned instead.
2. **`{param}`-style wildcard routes** do NOT capture doc filenames —
   `GET /api/{file}` will NOT intercept `GET /api/openapi.json`. The
   spec document wins.

This means you can't accidentally shadow the spec doc with a catch-all,
but you CAN deliberately replace it with a hand-crafted document.

## Override escape hatches

When auto-derived schema is wrong for a specific tool or endpoint, use
the explicit override methods before calling `tool_typed`:

```rust
// MCP: hand-roll input or output schema for one tool
McpServer::new("my-svc", "1.0")
    .tool_typed(
        tool("do_thing")
            .description("…")
            .input_schema(serde_json::json!({
                "type": "object",
                "properties": { "id": { "type": "string" } },
                "required": ["id"],
            }))
            .output_schema(serde_json::json!({ "type": "object" })),
        do_thing_handler,
    )
```

For REST types, implement `schemars::JsonSchema` manually on the type
to control the emitted schema.

## Platform API vs service API

There are two distinct levels of spec document:

| Level | URL | Format | Covers | Auth |
|---|---|---|---|---|
| **Service spec** | `GET /<owner>/<service-id>/…/openapi.json` | OpenAPI 3.0.3 | One deployed service's own routes | Two-tier (see above) |
| **Platform spec** | `GET <host>/openapi.json` | OpenAPI 3.1.0 | Full deploy lifecycle: `/_agents/*`, `/_admin/*`, `/v1/*` | Anonymous — no token needed |

Use the **platform spec** when you need to understand the host's own API
(register/login, deploy, provision, secrets, jobs, admin ops). It is
served at the host root (`/openapi.json`), not inside any service subtree,
and is always anonymous — no bearer token required.

Use the **service spec** when you need to introspect a deployed service's
own routes and schemas.

## Red flags

| Thought | Reality |
|---------|---------|
| "I need to write a handler for openapi.json." | The router serves it automatically. Only override if you need a custom document. |
| "My catch-all `{file}` route will intercept openapi.json." | Reserved filenames are not captured by `{param}` routes. Spec doc wins. |
| "Omitting JsonSchema breaks the build." | Not a build error — but that type's schema will be empty in the generated doc. Add `JsonSchema` to get full schema output. |
| "I use `.post(\"/mcp\", mcp_dispatch)` to mount MCP." | Use `Router::mcp` so the endpoint is recorded in `openapi.json`. |
| "I use `.post(\"/rpc\", rpc_dispatch)` to mount JSON-RPC." | Use `Router::rpc(path, || Dispatcher::new()…)` so methods appear in `openrpc.json`. |
| "Anonymous clients should see all routes in the spec." | Routes inside `.group([...], |g| …)` are hidden from anonymous callers. Move them out of the group or use `Router::undocumented` if that's the intent. |
