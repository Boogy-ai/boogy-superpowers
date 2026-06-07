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
| `src/cols.rs` | Table/column/index name constants (no bare string literals) |
| `src/lib.rs` | `mod bindings { wit_bindgen::generate!{...} }`, `wit_glue!`, `impl Api` |

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
| Asserting a derived index name from memory | Don't guess it — declare access patterns and let the SDK report the name; verify in `AGENTS.md` |
| Inventing job/store API signatures | Verify in the SDK repo's `AGENTS.md` before writing |

## Integration

- ← `boogy:designing-boogy-services` (HARD GATE: a design artifact must
  exist before scaffolding).
- → `boogy:testing-boogy-services`, `boogy:deploying-boogy-services`.
