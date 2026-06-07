---
name: deploying-boogy-services
description: Use when deploying, updating, or removing a deployed Boogy service
---

# Deploying a Boogy service

This is the authoritative command reference. Use it instead of reading
the CLI source.

## Install the CLI

```bash
cargo install --locked --git https://github.com/Boogy-ai/boogy-sdk boogy-cli
```

## Configure host + token

| What | Flag | Env | Default |
|------|------|-----|---------|
| Host URL | `--host` | `BOOGY_HOST_URL` | `http://localhost:3000` |
| Bearer token | `--token` | `BOOGY_TOKEN` | none (required) |

Get a token from the Boogy web app or `POST /_agents/login`. Most
commands need a valid token; `list`/`remove` need **admin scope**.

## Command quick reference

| Command | What it does |
|---------|--------------|
| `boogy build <crate-dir>` | `cargo build --target wasm32-wasip2 --release` in that dir |
| `boogy deploy <manifest>` | **publish + provision in one shot** — the normal path |
| `boogy publish <manifest> [--provision]` | upload an immutable, versioned module artifact; `--provision` also runs your own service from it |
| `boogy provision <module-ref> <service-id> [--overrides <toml>]` | run a service instance from a published module |
| `boogy upgrade <service-id> --to <version>` | move a provisioned service to another module version |
| `boogy list` | list deployed services (admin scope) |
| `boogy remove <owner> <service-id>` | delete a deployment (admin scope) |

Module ref shape: `boogy://<owner>/modules/<id>@<version>`.

## Deploy flow facts

1. Build the wasm (`boogy build .` or `cargo build --target
   wasm32-wasip2 --release`).
2. `boogy deploy boogy.toml`. The manifest needs `[service]` (with
   `[service.owner]`); `service.wasm` is **relative to the manifest
   file**, typically `target/wasm32-wasip2/release/<crate_name>.wasm`
   (Cargo turns `-` into `_`).
3. Verify: `boogy list`, then `curl <host>/<user_id>/<path>`.

## Updating a deployed service

`boogy deploy` is keyed by **`owner.user_id` + `service.id`** — not by
version. Re-deploying the same pair **replaces** the running service.
To ship a new version: edit code, **bump `[service] version`** (stored
per deployment for readable history — the replace happens on owner+id
regardless), rebuild, and `boogy deploy boogy.toml` again.

**Your data survives a redeploy** — a deploy swaps routing and records a
new deployment row; it does not touch the service's stored data.

Don't guess at module-registry republish behavior (e.g. re-publishing an
identical `@version`) — that isn't part of the documented CLI contract.
For the everyday path, the rule above holds.

## Partial-failure recovery

`boogy deploy` (and `publish --provision`) can publish OK but fail at
provision; the CLI reports the published module and exits non-zero.
**Do not rebuild or re-upload** — re-run only provision:

```bash
boogy provision <module-ref> <service-id>
```

## Common deploy errors

| Error | Fix |
|-------|-----|
| **Capability used but not granted** (e.g. uses `background_jobs`/`store`/`auth`/`outbound_http` but it's `false`) — fails at the linker stage before your code runs | Grant it in `[capabilities]` and redeploy — do NOT rescaffold. Granting one you don't use is harmless; using one you didn't grant fails. |
| **`outbound_http` with empty `allowed_hosts`** | Add an `[outbound]` block with non-empty `allowed_hosts`. |
| **`allowlist`/`internal`/`mixed` ingress with empty lists** | Populate `allowed_agents` / `allowed_origins` for that mode. |
| **Path-traversal / bad id** | `service.id` and `owner.user_id`: ASCII alphanumeric + `-`/`_`, ≤64 chars, no leading `-`, no `/ \ . :`; reserved names rejected. |
| **`cpu_deadline_ms` out of range** | Keep it in `1..=600000`. |
| **Missing token** ("set --token or BOOGY_TOKEN") | Export `BOOGY_TOKEN` or pass `--token`. |
| **wasm not found** | `service.wasm` resolves relative to the manifest; build first and point at the real output path. |

## Integration

- ← `boogy:testing-boogy-services` — deploy is how you exercise Layer 3
  (real requests against the running service).
- **Iron Law cross-ref:** a green build is not "done"; only a deployed,
  exercised service is.
