---
name: boogy-serving-frontends
description: Use when a Boogy service needs to serve a web frontend — a reactive UI, a single-page app, an admin dashboard, static HTML/JS/CSS, or a full-stack app where the same deployment serves both the page and its API
---

# Serving frontends on Boogy

A Boogy deployment can serve a **web frontend** — the page and its assets are
served by the platform, **decoupled from your wasm**. You do **not** serve assets
out of your wasm handlers, and you do **not** run a JavaScript build. You declare a
`[frontend]` section, point it at a source directory, and deploy; the platform
transpiles, stores, and serves.

## The model: declare it, the platform serves it

You ship a directory of frontend source (`index.html` + `.ts`/`.js`/`.css`/assets).
At deploy the platform **transpiles TypeScript to JavaScript** (server-side — no
Node, no bundler, nothing on your machine), content-addresses every file, and
serves them directly. Your wasm — if you have one — only handles the dynamic API
routes. **Don't reach for `include_str!` + a handler that returns HTML bytes** —
that's the old way; the host serves your assets for you.

**Why decoupled:** asset requests never run your wasm (no per-request cost, no
artifact-size pressure), the platform caches them, and large media offloads to
object storage automatically.

## Three deployment shapes

| Shape | What it is | Has a wasm? |
|---|---|---|
| **Frontend** | a frontend only (a static site / SPA, no backend of its own) | no |
| **FullStack** | a frontend **and** a wasm API under one deployment | yes |
| **Service** | a wasm API only (no frontend — the classic Boogy service) | yes |

The shape is derived from your manifest: a `[frontend]` with no wasm → `Frontend`;
`[frontend]` + a wasm → `FullStack`; no `[frontend]` → `Service`.

## The `[frontend]` manifest section

```toml
[service]
id = "notes"
owner = "daniel"

[frontend]
root = "web"          # your source dir: index.html + .ts/.js/.css/assets
api_prefix = "/api"   # FullStack: requests under here go to the wasm. omit it for a Frontend site.
index = "index.html"  # the SPA entry document (served for unmatched routes). default: index.html
build = "ts"          # "ts" = the platform transpiles your TypeScript. "none" = you uploaded plain JS.
private = false       # false (default) = assets are public. true = assets require the service ingress.
allow_cdn = false     # false = bare imports must be vendored. true = a bare import may resolve to a pinned CDN.
```

A **Frontend** site needs only `[service]` + `[frontend]` (no `service.wasm`). A
**FullStack** app adds a wasm and an `api_prefix`. (A Frontend deployment must **not**
set `api_prefix` — there's no wasm to route to.)

## Write TypeScript or JavaScript — there is no build step

Write your frontend in **TypeScript** (or plain JavaScript). You do **not** install
Node, run `vite`/`esbuild`, or produce a bundle. With `build = "ts"`, the platform
strips the types and emits browser-ready ES modules **at deploy time**; what gets
served is the JavaScript. Your authoring loop is: write `.ts`/`.js`, deploy. (If you
already have built JS and don't want the transpile, set `build = "none"`.)

**Imports use native ES modules + an import map.** A bare specifier like
`@arrow-js/core` resolves either to a copy you include under `web/vendor/` (the
default — fully self-hosted), or, with `allow_cdn = true`, to a pinned CDN URL. The
platform generates the `<script type="importmap">` and injects it into your
`index.html`. Relative `./foo.ts` imports are rewritten to `./foo.js` for you.

## arrow-js: the reference framework

[arrow-js](https://github.com/standardagents/arrow-js) is the recommended frontend
framework here precisely because it is **buildless and ES-module-native** — a tiny
reactive runtime you `import` directly, no compiler required. A minimal `web/index.html`:

```html
<!doctype html>
<html>
<head><meta charset="utf-8" /><title>Notes</title></head>
<body>
  <div id="app"></div>
  <script type="module">
    import { reactive, html } from "@arrow-js/core";   // resolved by the import map
    const state = reactive({ notes: [] });
    async function load() {
      const r = await fetch("./api/notes");            // same-origin → the wasm /api
      state.notes = (await r.json()).items ?? [];
    }
    html`<ul>${() => state.notes.map(n => html`<li>${n.title}</li>`)}</ul>`(
      document.getElementById("app"));
    load();
  </script>
</body>
</html>
```

(You can write the same logic in `web/app.ts` with full types and `import` it — the
platform transpiles it.) Include arrow-js at `web/vendor/@arrow-js/core.js`, or set
`allow_cdn = true`.

## Routing: api_prefix → wasm, everything else → assets + SPA fallback

For a **FullStack** app: a request under `api_prefix` (`/api/...`) runs your wasm
(the API — build it with `boogy:boogy-rest-apis`). Every other path is matched
against your asset files by exact path; a miss with no file extension serves
`index` so your client-side router takes over (SPA fallback); a miss **with** an
extension is a 404. Hashed assets are cached immutably; `index.html` is revalidated
each load so a redeploy takes effect immediately. The page and the API are
**same-origin** (`/{owner}/{service}/…`), so the page calls its API with relative
URLs and there's no CORS.

## Visibility

Assets are **public by default** — anyone can load the page (including a client-side
login screen) — while the wasm `api_prefix` routes enforce the service's normal
ingress. Set `private = true` to put asset serving behind the service ingress too
(for an internal tool whose shell itself shouldn't be exposed).

## Security headers (always-on baseline + opt-in CSP)

Every **host-served frontend response** carries a safe baseline automatically — you
do nothing to get it:

- `X-Content-Type-Options: nosniff`
- `Referrer-Policy: strict-origin-when-cross-origin`
- `X-Frame-Options: SAMEORIGIN` (clickjacking default)

Two `[frontend]` knobs tune it:

```toml
[frontend]
root = "web"
csp = "default-src 'self'"   # opt-in Content-Security-Policy, emitted verbatim. unset = no CSP header.
frame_options = "same_origin" # same_origin (default → SAMEORIGIN) | deny (→ DENY) | none (omit the header, for apps meant to be embedded)
```

`csp` is a pass-through string — you own the policy; an empty `csp` is rejected at
manifest parse. This baseline is the right hardening for a **Frontend-only** (no-wasm)
static site, which has no API surface to apply CORS to.

## Cross-origin (CORS) — opt-in, host-enforced, default-deny

A same-origin FullStack page (its own `api_prefix`) needs **no CORS** — the page and
its API share an origin. CORS matters only when a **different** origin calls your
service's API. It is **off by default** (browsers block cross-origin reads); opt in
with `[ingress.cors]`:

```toml
[ingress.cors]
allowed_origins   = ["https://app.example.com"]  # exact; "*" only when allow_credentials = false
allowed_methods   = ["GET", "POST"]
allowed_headers   = ["content-type", "authorization"]
allow_credentials = false                          # true ⇒ "*" origin is rejected at parse (CORS spec)
max_age = 600                                       # preflight cache seconds
```

The host enforces this **at the ingress edge**: it answers `OPTIONS` preflights
directly (204 + the negotiated headers, no wasm invocation) and reflects the matched
origin (`Access-Control-Allow-Origin` + `Vary: Origin`) on allowed actual responses.
A non-matching origin gets no CORS headers. CORS governs the **API surface** — it
decorates wasm-backed (FullStack/Service) responses; a **Frontend-only deployment
emits no CORS headers** (it has no API), so use the security-header baseline / CSP
above to harden a static site.

**CORS is not authorization.** It controls which origins the *browser* lets read a
response; it does **not** bypass your service ingress. An allowed origin still passes
through the normal PASETO/API-key check — an unauthenticated request to an
`authenticated`-mode service still gets a 401. Never treat `[ingress.cors]` as an
access grant.

## Large assets

Small assets (HTML/JS/CSS, usually KB) are served by the platform directly. Assets
over an operator-configured size limit are stored in object storage and served via a
redirect — so a large image or video doesn't run through your service at all. This is
automatic; you just put the file in your `root`.

## Deploy — no JavaScript toolchain

Deploy the same way you deploy any service. The CLI tarballs your `[frontend].root`
and uploads it with the manifest; the platform does the transpile + storage:
```
boogy deploy boogy.toml
```
An agent deploying through the MCP admin tool passes the frontend source files (paths
+ contents) alongside the manifest — again, **no Node, no bundler, no build**. You
ship `.ts`/`.js` source; the platform produces the served JavaScript.

## Red flags

| Reach / claim | Reality |
|---|---|
| Serve the page from a wasm handler (`include_str!` + return HTML bytes) | Don't. Declare `[frontend]`; the host serves your assets decoupled from the wasm. |
| "I'll run `vite`/`esbuild`/a Node build first" | No build step. Write `.ts`/`.js`; the platform transpiles at deploy. |
| "TypeScript can't run in the browser, so I'll write plain JS" | Write TS — `build = "ts"` transpiles it server-side. (Plain JS works too.) |
| Embed assets in the wasm binary | Assets live in object storage, served by the host — not in your wasm (no artifact-size hit). |
| `import "@arrow-js/core"` will just work from anywhere | Bare imports resolve via the import map — vendor the file under `web/vendor/` or set `allow_cdn = true`. |
| Put a big video in `root` and serve it from a handler | Large assets auto-offload to object storage via redirect; just drop the file in `root`. |

## Integration

← Reach this from `boogy:designing-boogy-services` (the "does this need a UI?"
branch). → `boogy:boogy-rest-apis` builds the wasm API a FullStack frontend calls
(under `api_prefix`). → `boogy:boogy-auth` / `boogy:boogy-account-auth` for gating
that API and wiring a login the public shell renders. ↔ `boogy:boogy-capability-limits`
for the asset size limits + what's served where.
