---
name: boogy-mcp-services
description: Use when exposing MCP (Model Context Protocol) tools, resources, or prompts to LLM clients from a Boogy service, or adding MCP alongside an existing REST service
---

# Boogy MCP Services

MCP tools/resources/prompts ride on the same service as your REST
routes — one deployed service, two surfaces, same data. Build from the
`McpServer` surface; never hand-roll the JSON-RPC envelope.

(Separately, the platform itself exposes owner-scoped MCP tools for your
own usage, audit, and service logs — `query_my_usage`,
`tail_my_audit_events`, `get_service_logs`. Those are platform tools you
*consume*, not tools you author; see `boogy:boogy-observability`.)

## Mounting (hybrid with REST)

Use `Router::mcp` — it registers the POST route AND records the
endpoint in the auto-served `…/openapi.json`:

```rust
fn build_router() -> Router {
    Router::new()
        .get("/tasks", list_tasks)            // existing REST
        .post("/tasks", create_task)
        .mcp("/mcp", |req| {                  // MCP surface
            McpServer::new("tasks", env!("CARGO_PKG_VERSION"))
                .tool_typed(tool("create_task").description("Create a task."), create_task_tool)
                .tool_typed(tool("list_tasks").description("List the caller's tasks."), list_tasks_tool)
                .handle(req.request)
        })
}
```

`McpServer::new(name, version)` is cheap — build it per request.
`.handle(req.request)` does the handshake, `tools/list`, `tools/call`,
resources, prompts, and all envelope/error mapping.

### Gate it with the same guard as the REST routes

An MCP mount usually exposes the **same data** the REST routes do, so it
belongs behind the same guard. `.mcp(..)` is available inside a `.group(..)`
block for exactly this:

```rust ignore-snippet: a router shape — the guard and tool handlers it composes are defined by the service, not here
Router::new()
    .group([api_key_routes::guard], |g| g
        .get("/tasks", list_tasks)
        .mcp("/mcp", |req| {
            McpServer::new("tasks", env!("CARGO_PKG_VERSION"))
                .tool_typed(tool("create_task").description("Create a task."), create_task_tool)
                .handle(req.request)
        }))
```

**Do not "fix" a compile error here by moving `.mcp(..)` out of the group.**
That is the shape the mistake takes: the line compiles again, the deploy
succeeds, the REST routes stay guarded — and the MCP endpoint, serving the same
data, is now open to any caller the ingress admits. Nothing reports the
downgrade. If the mount must live outside a group for some other reason, each
tool handler has to do its own `auth::current_principal()` check and mean it.

MCP handlers see no `Req` or `Ctx`, so a guard is the only thing that can
reject a caller *before* a tool body runs.

`tool("name").description("…")` annotates a tool the same way REST routes
and RPC methods now take `.summary()` / `.description()` (see
`boogy:boogy-api-specs`) — annotate them all so clients and agents can
discover what each one does.

## Registering tools

Prefer **`tool_typed::<P, R>`**: a typed arg struct deriving
`Deserialize + JsonSchema`, a typed result deriving `Serialize +
JsonSchema`, handler returns `Result<R, ApiError>`. Both `inputSchema`
and `outputSchema` are auto-derived from the struct types, so the
deserializer/serializer and the protocol surface can't drift.

```rust
use schemars::JsonSchema;

#[derive(Deserialize, JsonSchema)]
struct CreateTaskArgs { title: String }

#[derive(Serialize, JsonSchema)]
struct TaskOut { id: String, title: String }

fn create_task_tool(args: CreateTaskArgs) -> Result<TaskOut, ApiError> {
    let principal = auth::current_principal().ok_or_else(ApiError::unauthenticated)?;
    // ... insert scoped to `principal`, return TaskOut ...
    Ok(TaskOut { id: "1".into(), title: args.title })
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

## Charging for tools

An MCP tool can be priced, and pricing is **per tool** — `mcp_tool = "summarize"`
prices that tool and nothing else, so a server can charge for the expensive tool
and leave discovery and the cheap ones free. `initialize`, `ping` and
`tools/list` run no tool and are always free; a client must be able to find out
what you offer without paying.

The part worth designing around: **an LLM client calls tools in a loop.** A price
that reads as trivial per call — a tenth of a cent — becomes visible when an agent
makes forty calls to answer one question, and the agent's operator sees the total,
not your per-call figure. So price the *unit of value the user asked for* where
you can: one tool call that does the whole job at a higher price is easier to
adopt than six cheap ones that each look free. Where the loop is unavoidable, a
`max` is what lets the caller bound it.

The host reads which tool a request selects from the request body itself, so the
tool you are paid for is always the tool that ran. See
`boogy:boogy-route-pricing` for choosing the numbers.

## Red flags

| Thought | Reality |
|---------|---------|
| "MCP needs its own service separate from the REST one." | One service serves both — add a `Router::mcp("/mcp", handler)` route alongside REST. |
| "I'll parse the JSON-RPC envelope and dispatch by hand." | `McpServer::handle` does the handshake, routing, schema, and error mapping. |
| "MCP tools run unauthenticated / have separate auth." | Same bearer path as REST; call `auth::current_principal()` and scope by it. |
| "There's no resource/template support, only tools." | `resource`, `resource_template`, `extract_template_var`, and `prompt` all exist. |
| "Return `Err` so the model sees the failure." | `Err` is a protocol error. For a model-visible failure return `Ok(ToolResult::error(...))` (`isError: true`). |
| "I'll write the inputSchema/outputSchema by hand." | `tool_typed` derives both from the arg/result struct `JsonSchema` impls — they can't drift. |
| "I mount MCP with `.post(\"/mcp\", mcp_dispatch)`." | Use `Router::mcp(\"/mcp\", handler)` — it also records the endpoint in the generated `openapi.json`. |
| "`.mcp()` won't compile inside my `.group()`, so I'll move it out." | Moving it out **removes the guard** — silently, on an endpoint serving the same data as the routes you just gated. `.mcp()` and `.rpc()` exist on the group's `RouteSet` too; keep it inside. |
