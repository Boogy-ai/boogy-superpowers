---
name: boogy-mcp-services
description: Use when exposing MCP (Model Context Protocol) tools, resources, or prompts to LLM clients from a Boogy service, or adding MCP alongside an existing REST service
---

# Boogy MCP Services

MCP tools/resources/prompts ride on the same service as your REST
routes — one deployed service, two surfaces, same data. Build from the
`McpServer` surface; never hand-roll the JSON-RPC envelope.

## Mounting (hybrid with REST)

Add ONE POST route alongside your existing routes — no second service:

```rust
fn build_router() -> Router {
    Router::new()
        .get("/tasks", list_tasks)            // existing REST
        .post("/tasks", create_task)
        .post("/mcp", mcp_dispatch)           // MCP surface
}

fn mcp_dispatch(req: &mut Req<'_>) -> response::HttpResponse {
    McpServer::new("tasks", env!("CARGO_PKG_VERSION"))
        .tool_typed(tool("create_task").description("Create a task."), create_task_tool)
        .tool_typed(tool("list_tasks").description("List the caller's tasks."), list_tasks_tool)
        .handle(req.request)
}
```

`McpServer::new(name, version)` is cheap — build it per request.
`.handle(req.request)` does the handshake, `tools/list`, `tools/call`,
resources, prompts, and all envelope/error mapping.

## Registering tools

Prefer **`tool_typed::<P, R>`**: a typed arg struct deriving
`Deserialize + JsonSchema`, a typed result deriving `Serialize`, handler
returns `Result<R, ApiError>`. The advertised `inputSchema` is
auto-derived from `P`, so the deserializer and the protocol surface
can't drift.

```rust
use schemars::JsonSchema;

#[derive(Deserialize, JsonSchema)]
struct CreateTaskArgs { title: String }

#[derive(Serialize)]
struct TaskOut { id: String, title: String }

fn create_task_tool(args: CreateTaskArgs) -> Result<TaskOut, ApiError> {
    let principal = auth::current_principal().ok_or_else(ApiError::unauthenticated)?;
    // ... insert scoped to `principal`, return TaskOut ...
}
```

`schemars` is a **direct dependency** — add `schemars = "0.8"` (the SDK
workspace pin) to your `Cargo.toml`, because `#[derive(JsonSchema)]`
emits `::schemars::*` paths.

Reach for the raw **`tool(descriptor, |Value| -> Result<ToolResult,
RpcError>)`** form only when you need full `ToolResult` control —
multi-content-block responses or a marked error.

## Resources and prompts (they exist)

- `resource(uri, name)` + `.resource(desc, |&str| -> Result<Vec<ResourceContent>, RpcError>)` — a single concrete URI.
- `resource_template(uri_template, name)` + `.resource_template(desc, handler)` — `{var}` placeholder URIs; recover a variable with `extract_template_var(template, uri, "var")`.
- `prompt(name)` + `.prompt(...)` — reusable prompt templates.

`initialize` advertises a capability block only when you register
something of that kind.

## Auth inside tools

Tool auth is **identical to REST** — there is no separate MCP auth
system. The host's auth middleware verifies the bearer (PASETO session
or `sk_*` API key) before the request ever reaches your wasm; inside a
tool you just call `auth::current_principal()`:

- `Some(principal)` → scope every read/write by it (owner column),
  deny-by-existence-mask, exactly like a REST handler.
- `None` → anonymous; return `ApiError::unauthenticated()`.

Per-principal isolation is the same invariant on both surfaces: one
caller never sees another's rows.

## Error channels (don't confuse them)

| You return | Client sees |
|------------|-------------|
| `Err(ApiError)` / `Err(RpcError)` | a JSON-RPC `error` (protocol failure) — status survives via `RpcError::application(code, msg)` |
| `Ok(ToolResult::error("…"))` | an **Ok** response with `isError: true` — the model sees the failure and can react |

Use `ToolResult::error` when you want the LLM in the loop on a
domain failure; use `Err(ApiError)` for hard rejections (auth, missing
resource). `tool_typed` handlers return `ApiError` and its status code
round-trips into the JSON-RPC application-error band automatically.

## Validate against a real client

Unit-calling a tool handler is not enough. Deploy the service, then
connect a **real MCP client** and exercise `initialize` → `tools/list`
→ `tools/call`. The handshake, schema advertisement, and auth path only
fully exercise through a live client. See `boogy:testing-boogy-services`.

## Red flags

| Thought | Reality |
|---------|---------|
| "MCP needs its own service separate from the REST one." | One service serves both — add a `.post("/mcp", mcp_dispatch)` route alongside REST. |
| "I'll parse the JSON-RPC envelope and dispatch by hand." | `McpServer::handle` does the handshake, routing, schema, and error mapping. |
| "MCP tools run unauthenticated / have separate auth." | Same bearer path as REST; call `auth::current_principal()` and scope by it. |
| "There's no resource/template support, only tools." | `resource`, `resource_template`, `extract_template_var`, and `prompt` all exist. |
| "Return `Err` so the model sees the failure." | `Err` is a protocol error. For a model-visible failure return `Ok(ToolResult::error(...))` (`isError: true`). |
| "I'll write the inputSchema by hand." | `tool_typed` derives it from the arg struct's `JsonSchema` — they can't drift. |
