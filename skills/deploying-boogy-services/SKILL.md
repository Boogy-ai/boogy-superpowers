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

Get a token by signing in — MCP-first: call the `login` tool then
`login_status` (see `boogy:using-boogy` for the full flow), or run
`boogy login` from the CLI (saves to `~/.config/boogy/credentials.toml`).
Most commands need a valid token; `list`/`remove` need **admin scope**.

## Before you deploy — `boogy check`

```bash
boogy check          # non-zero exit on any finding
```

Lints the service source for the convention defects that only show up once
it is live: raw schema instead of `#[derive(Model)]`, untyped responses,
multi-write handlers with no transaction, unannotated routes, and a counter
read at snapshot then written in the same transaction (which the store
refuses at runtime). Cheap, offline, and it needs no host or token — run it
before every deploy. Full detail in `boogy:testing-boogy-services`.

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
2. `boogy deploy boogy.toml`. The manifest needs `[service]` (the owner
   is set from your authenticated deploy — omit it; if you do set one it's
   a bare `owner = "<handle>"` key under `[service]`, never a
   `[service.owner]` table); `service.wasm` is **relative to the manifest
   file**, typically `target/wasm32-wasip2/release/<crate_name>.wasm`
   (Cargo turns `-` into `_`).
3. Verify (see **Verify it actually works** below) — do not stop at "deploy
   succeeded".

To serve your service on your own domain (`app.theircompany.com`) instead
of the default URL, see `boogy:boogy-custom-domains`.

## Your live URL — read it from the deploy output

`boogy deploy` prints the authoritative live URL on success:

```
Published: boogy://<handle>/modules/<id>@<version>
  URL: https://<handle>.boogy.app/<service>
```

That printed `URL:` is the source of truth. The app plane is **`boogy.app`**, not
`boogy.ai` — `boogy.ai` is the control/marketing plane (`api.boogy.ai` for login +
`/v1`, the docs, the landing page) and **never serves your app**. Do **not**
reconstruct the URL from the generic `<handle>.<base>` placeholder, from the host
you logged in against, or from a domain the user happened to mention. Copy it from
the deploy output. Any absolute origin you wrote *before* this point (e.g. a
`<link rel="canonical">`, `og:url`, or `sitemap.xml` in a frontend bundle — see
`boogy:boogy-serving-frontends`) is a guess: reconcile it with the printed URL and
redeploy if it differs.

## Verify it actually works (deploy success ≠ working)

A non-error deploy means the artifact published and routing was swapped — **not**
that the page renders or the endpoint behaves. Before you claim it works:

1. **Frontend / full-stack:** run `boogy deploy boogy.toml --smoke` (loads the real
   deployed URL in a headless browser and asserts it renders). **A skipped smoke is
   NOT a pass.** If the output says `Smoke: skipped — no headless browser found`,
   you have verified nothing — install or point at a browser
   (`BOOGY_SMOKE_BROWSER=/path/to/chrome`, or any Chrome/Chromium on `PATH`) and
   re-run, or load the printed URL in a real browser yourself and confirm the
   content renders. Only then is it verified. (See `boogy:boogy-serving-frontends`.)
2. **Public API route:** `curl` the printed URL and check the status + body.
3. `boogy list` confirms the deployment row, but a row is not a working page.

Report what you actually observed (the rendered content / the response), not "the
deploy succeeded".

### When the URL does not answer, read the response before touching your code

A deploy prints a URL; it does not prove one is being served. `boogy deploy`
now probes what it printed and warns when the platform did not answer — but
when you are diagnosing by hand, **what answered matters more than the status
code**, and the status code alone will send you the wrong way.

Every platform response carries `x-boogy-deployment-id`. Use its presence, not
the status, to decide whether the request reached your service at all:

```bash
curl -sS -D- -o /dev/null https://<handle>.boogy.app/<service>/health
```

| What you see | What it means | Where the fix is |
|---|---|---|
| Any status **with** `x-boogy-deployment-id` — including 401/403 | The request reached your service. An `authenticated` route refusing your control-plane token is a **success** for this question | Your service / your credential |
| 404 (or anything) **without** that header | Something other than the platform answered — the edge has no route for this hostname | **Operator-side. Not your code.** |
| `SSL: no alternative certificate subject name matches target hostname`, or a certificate issued to something other than your domain | No certificate for this host yet | **Operator-side. Not your code.** |
| Connection refused / DNS failure | The host does not resolve or route | **Operator-side. Not your code.** |

**Why this table exists.** A 404 from the edge's default backend is
byte-identical to the 404 a mis-mounted router produces — and a mis-mounted
router is the failure these skills warn about most loudly, so the evidence
actively steers you into re-reading routing code that is already correct. Two
independent checks settle it in seconds:

```bash
boogy list                                  # is the service provisioned and un-suspended?
curl -H "Authorization: Bearer $BOOGY_TOKEN" \
  https://api.boogy.ai/v1/services/<service-id>/logs
```

**Zero log lines, ever, is the decisive signal**: the guest has never executed,
so nothing inside it — not the router, not a handler, not a capability — can be
responsible. Stop debugging the service and report the URL as unreachable.

A newly registered handle is the common case: tenant routing is subdomain-only,
and a brand-new subdomain may not have an edge route or a certificate yet. That
is a platform-side step, and no amount of redeploying will change it.

### A clean retry can mean the platform reverted you, not that it's live

If a version fails to start (it traps or errors on its very first real request), Boogy
auto-reverts the service back to its last-known-good version — automatically, and slightly
asynchronously. The failure mode this produces: your first request after `boogy deploy`/
`boogy upgrade` gets a `500`, and a retry a moment later gets a clean `200`. **That `200` can
be the OLD version still answering, not your new one** — don't treat "it recovered on retry"
as "my new version works."

To tell the difference, check which deployment actually answered:

1. **Compare `X-Boogy-Deployment-Id`.** Every response carries this header. Capture the
   `deployment_id` your `deploy`/`upgrade`/`provision` call returned, and compare it against
   the header on the response you're verifying — a mismatch means a different deployment
   served it than the one you just shipped.
2. **`boogy list` (or `GET /v1/services`)** shows the service's current active
   `module_version` — confirm it matches what you just deployed, not what you replaced.
3. **`GET /v1/audit`** (works with your own token, no admin scope needed) records a
   `deploy.rolled_back_on_migration_failure` entry when this happens.

A mismatch means your new version never actually started. Retrying again will not fix it —
find out why the first real request failed (a panicking migration, a missing granted
capability, etc.), fix it, and redeploy.

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
| **`413 Payload Too Large`, as raw HTML with no Boogy in it** | Not the artifact cap — that is 8 MiB free / 32 MiB paid and the platform states it in its own error format. An HTML 413 comes from a proxy in front of the platform, so the number it enforces is not one the docs describe. Report it rather than shrinking your binary to fit a limit that does not exist. |

## Calling your own deployed service (control-plane/app-plane boundary)

**Deploy, provision, and login via CLI or MCP are unaffected** — your global
operator token works for all of those.

However, if you try to `curl` or script-test your OWN deployed service's
`authenticated` (non-public) route with the same token, you will receive a
**403 `app_plane_requires_app_credential`**. Non-public app routes require an
app-plane credential:

| What you want | How |
|---|---|
| Smoke-test a `public`-ingress route | `curl` with no auth — anyone can reach it |
| Smoke-test an `authenticated` route | Use an `sk_*` API key (requires `api_keys_glue!` in the service) |
| Full SSO flow | Use the "Sign in with Boogy" flow (see `boogy:boogy-account-auth`) |
| Your own first-party service | Add it to `BOOGY_FIRSTPARTY_WORKLOADS` (host config, never a manifest field) |

## Integration

- ← `boogy:testing-boogy-services` — deploy is how you exercise Layer 3
  (real requests against the running service).
- **Iron Law cross-ref:** a green build is not "done"; only a deployed,
  exercised service is.

## Red Flags

| Thought | Reality |
|---|---|
| "I re-ran provision, so it's running my new code" | Provisioning is **idempotent**: re-running against an existing service returns 409 and the host keeps serving the module it was FIRST provisioned with. The log reads like a successful no-op while every request executes old code. |
| "I published a new version, so the service moved to it" | Publishing does not move a service onto a new module. Publish and provision are separate steps, and only the second changes what runs. |
| "The URL printed, so the URL works" | Printing is not checking. A brand-new tenant subdomain can have no edge route and no certificate while the control plane reports the service perfectly healthy. Read the response headers, not just the status. |
| "The deploy log said OK" | Check that it says *upgraded*, not *existing*. That one word is the difference between measuring your change and measuring the previous build — it has invalidated a real performance conclusion. |
| "The container restarted, so it has my binary" | Recreating a container reuses the existing image. Without a rebuild you are running the old binary with new configuration — which looks like your change had no effect. |
| "My schema change will apply on the next request" | A service's declared schema is resolved **once, at provision**. A type change, a nullability change, or promoting a plain column to an accumulator is a **conflict** that refuses the deployment outright. |
| "I'll test against prod config later" | A default that differs between your stack and production is a measurement you cannot transfer. Pin the values the result depends on and state them. |
