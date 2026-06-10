---
name: scaffolding-a-service
description: Use when beginning implementation of a designed Boogy service — creating the project, manifest, and build loop
---

# Scaffolding a Boogy service

A design artifact must exist first (run `boogy:designing-boogy-services`).
This skill turns that design into a buildable project. Start from the SDK
repo's `smoke/` template and the SDK repo's `docs/quickstart.md` — follow
the quickstart for exact, current copy; this skill only adds what agents
get wrong.

## The five files

| File | Role |
|------|------|
| `Cargo.toml` | `[lib] crate-type = ["cdylib"]`; deps below |
| `build.rs` | Syncs WIT files from the pinned SDK into local `wit/` |
| `boogy.toml` | Manifest: `[service]`, `[routing]`, `[capabilities]`, `[ingress]` |
| `src/models.rs` | `#[derive(Model)]` structs — one per table; the derive emits the column consts (NO hand-written `cols` module) |
| `src/lib.rs` | `mod bindings { wit_bindgen::generate!{...} }`, `wit_glue!`, `impl Api` (`init_tables` = `create_model::<M>()` per model; `build_router` = annotated routes) |

## Start from the model layer

The first code you write is the data layer, and it is
`#[derive(Model)]` — not a `cols` module, not `Table::new(...)`. Each
table is a struct; register it in `init_tables` and read/write through
`db_*` + `Query`. The canonical shape:

```rust
// src/models.rs
use boogy_sdk::model::{Id, Timestamp};
use boogy_sdk::Model;

#[derive(Model)]
#[model(table = "messages", list_by(filter = "peer", newest = "created_at"))]
pub struct Message {
    #[pk] pub id: Id<Message>,
    pub peer: String,
    pub body: String,
    pub created_at: Timestamp,
}
```

```rust
// src/lib.rs — inside impl Api
fn init_tables() {
    create_model::<Message>();           // schema + indexes from the struct
}
fn build_router() -> Router {
    Router::new()
        .info("Chat", "0.1.0", Some("Peer-to-peer chat."))
        .summary("Conversation messages")
        .description("The last N messages with a peer, newest first.")
        .get("/chat/messages", list_messages)
}
```

A hand-written `cols` module, `Table::new(...).text(...)`, or
`create_table_from(...)` for a fixed-shape table is a **regression** —
see `boogy:boogy-data-modeling`. Routes MUST carry `Router::info(...)` +
`.summary()` + `.description()` (see `boogy:boogy-rest-apis`).

## Dep-form rule (the #1 scaffolding bug)

The `smoke/` template uses `path` / `workspace` deps — those resolve
**only inside the SDK repository**. ANY standalone project MUST use git
deps pinned to a rev:

```toml
[dependencies]
boogy-sdk   = { git = "https://github.com/Boogy-ai/boogy-sdk", rev = "<pin-rev>" }
wit-bindgen = "0.46"
serde       = { version = "1", features = ["derive"] }
serde_json  = "1"   # REQUIRED: wit_glue! emits ::serde_json absolute paths

[build-dependencies]
boogy-wit   = { git = "https://github.com/Boogy-ai/boogy-sdk", rev = "<pin-rev>" }
```

Copying the template's `{ path = ... }` / `{ workspace = true }` deps into
a real project is a hard error — those paths/workspace don't exist there.

## wit/ is generated — never edit it

`build.rs` regenerates `wit/` from the pinned SDK rev on every build, so
hand edits vanish and can break the build. Gitignore it:

```gitignore
/wit/
/target/
```

The platform interface comes from your pinned SDK rev; to change it, bump
the rev — never edit `wit/`.

## The two worlds

- `world: "service"` — REST / JSON-RPC / MCP. The default.
- `world: "service-with-jobs"` — adds the job export. **Compile footgun:**
  this world makes a `job_handler::Guest` impl with `handle_job(ctx,
  payload)` mandatory; without it the crate won't compile. A Terminal-error
  stub is enough to start. Only choose this world if the design calls for
  background jobs.

Job-router specifics (the `#[job(...)]` attribute, `JobRouter`, dispatch,
and how a handler's error becomes a terminal failure) are a real API but
exact-shape-sensitive — **verify them in the SDK repo's `AGENTS.md` before
writing; do not reconstruct the signatures from memory.**

## Build loop

```bash
cargo build --target wasm32-wasip2 --release
# artifact: target/wasm32-wasip2/release/<crate>.wasm  (Cargo turns - into _)
# `boogy build <dir>` runs exactly this.
```

## Common Mistakes

| Mistake | Do instead |
|---------|------------|
| Copying template `path`/`workspace` deps into a real project | Git deps pinned to a rev (above) |
| Omitting `serde_json` | Add it — `wit_glue!` needs it as a direct dep |
| No `.gitignore` → generated `wit/` gets committed | Gitignore `/wit/` and `/target/` |
| Editing `wit/` | It's regenerated every build; bump the pinned rev instead |
| `service-with-jobs` without `handle_job` | Impl `job_handler::Guest` (stub is fine) or it won't compile |
| Hand-writing a `cols` module / `Table::new(...)` / `create_table_from` | `#[derive(Model)]` + `create_model::<M>()` — the derive emits the column consts and schema |
| Un-annotated routes / no `Router::info` | Set `Router::info(...)` and `.summary()`+`.description()` on every route (feeds `openapi.json`) |
| Asserting a derived index name from memory | Don't guess it — declare access patterns and let the SDK report the name; verify in `AGENTS.md` |
| Inventing job/store API signatures | Verify in the SDK repo's `AGENTS.md` before writing |

## Integration

- ← `boogy:designing-boogy-services` (HARD GATE: a design artifact must
  exist before scaffolding).
- → `boogy:testing-boogy-services`, `boogy:deploying-boogy-services`.
