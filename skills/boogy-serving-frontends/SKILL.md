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

A **FullStack** manifest (`[service]` + a wasm + `[frontend]` with `api_prefix`):

```toml
[service]
id = "notes"
name = "Notes"
version = "0.1.0"
wasm = "target/wasm32-wasip2/release/notes.wasm"   # FullStack: your API wasm
# owner: omit it — the platform sets it to your handle at deploy.

[routing]             # `path` is the mount (see the mount rule below)
path = "/notes"
methods = ["GET", "POST"]

[capabilities]        # optional — declare only what the wasm uses
store = true

[frontend]
root = "web"          # your source dir: index.html + .ts/.js/.css/assets
api_prefix = "/api"   # FullStack: requests under <mount>/api go to the wasm. omit it for a Frontend site.
index = "index.html"  # the SPA entry document (served for unmatched routes). default: index.html
build = "ts"          # "ts" = the platform transpiles your TypeScript. "none" = you uploaded plain JS.
private = false       # false (default) = assets are public. true = assets require the service ingress.
allow_cdn = false     # false = bare imports must be vendored. true = a bare import may resolve to a pinned CDN.
```

A **Frontend-only** site runs no wasm, so it's smaller — `wasm`,
`[capabilities]`, and `[limits]` are all optional, and it **omits** `api_prefix`:

```toml
[service]
id = "mysite"
name = "My Site"
version = "0.1.0"

[routing]
path = "/mysite"
methods = ["GET"]

[frontend]
root = "web"
build = "ts"
```

Only `[service]` (id/name/version), `[routing]`, and `[frontend]` are needed for a
Frontend; a **FullStack** app adds a `wasm` and an `api_prefix`.

## Write TypeScript or JavaScript — there is no build step

Write your frontend in **TypeScript** (or plain JavaScript). You do **not** install
Node, run `vite`/`esbuild`, or produce a bundle. With `build = "ts"`, the platform
strips the types and emits browser-ready ES modules **at deploy time**; what gets
served is the JavaScript. Your authoring loop is: write `.ts`/`.js`, deploy. (If you
already have built JS and don't want the transpile, set `build = "none"`.)

**Imports use native ES modules + an import map.** A bare specifier like
`@arrow-js/core` resolves either to a copy you include under `web/vendor/` (the
default — fully self-hosted), or, with `allow_cdn = true`, to a CDN URL. The
platform generates the `<script type="importmap">` and injects it into your
`index.html`. Relative `./foo.ts` imports are rewritten to `./foo.js` for you.

> **Pin your CDN imports.** With `allow_cdn = true`, always write
> `<pkg>@<version>` (e.g. `react@18.2.0`) rather than a bare `react`. A bare
> specifier floats to the CDN's current latest — a supply-chain risk. The
> platform logs a deploy-time warning for each unpinned CDN import. Scoped
> packages follow the same rule: `@scope/pkg@1.0.0`, not `@scope/pkg`.

### ⚠️ In HTML, reference the transpiled `.js` — never `.ts`

The `.ts`→`.js` rewrite applies to **imports inside a module**, NOT to the HTML
`<script>` tag. If your entry lives in a separate file `web/app.ts` and you load
it with `<script type="module" src="./app.ts">`, it **404s** — the platform
serves the transpiled `./app.js` and does **not** serve raw `.ts` — so the module
never loads and you get a **blank page** (just whatever static HTML you wrote).

You author `app.ts`, but reference the **output** in your HTML:

```html
<script type="module" src="./app.js"></script>   <!-- ✓ the transpiled output -->
<script type="module" src="./app.ts"></script>   <!-- ✗ 404 → blank page -->
```

(An **inline** `<script type="module">…</script>` sidesteps it — its imports are
rewritten normally.)

**The deploy enforces this now.** A frontend bundle with a **dangling reference**
(a `<script src>`/`<link href>`/`<img src>` or relative import that points at a
file not in the bundle) **fails the deploy** with the list — a blank-page app
can't ship. A `.ts` reference in your HTML is **auto-rewritten to `.js`** (with a
warning, so you learn to reference the output). `boogy check` reports both
**before** you deploy. Still **load the page** to confirm *runtime* behavior —
the gate catches missing assets, not logic bugs.

### `boogy deploy --smoke` — automate the "load it in a browser" step

The deploy gate and `boogy check` catch *static* problems; the bugs that survive
them (blank `#app`, an import map that 404s a vendor file, a framework that
mounts nothing, a stale-cache breakage) only show up when a **real browser runs
the served page**. `--smoke` does that for you, against the **actually-deployed
URL**:

```bash
boogy deploy app.boogy.toml --smoke
# or, after a manual publish:
boogy publish app.boogy.toml --provision --smoke
```

After the deploy succeeds it loads `<host>/<owner>/<id>/` in a detected headless
Chrome/Chromium and asserts: the page renders non-empty content in `#app`
(override with `--smoke-selector`), the console has no errors / uncaught
exceptions, and no same-origin sub-resource returned ≥ 400. A failure prints a
report (which assertion, the console errors, the failed request URLs) and exits
non-zero — fix and re-ship with `boogy deploy --replace`.

- **Opt-in and best-effort.** Without `--smoke` nothing changes. With it but **no
  browser installed**, it prints a one-line note and exits cleanly (never blocks
  a deploy) — point it at a binary with `BOOGY_SMOKE_BROWSER=/path/to/chrome`.
- **Frontend deployments only** — a wasm-only service has nothing to render.
- `--smoke-timeout <ms>` (default 10000) bounds the render wait.

This is the concrete way to satisfy the "load the page in a real browser" rule
below — run it as the last step of every frontend deploy.

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

### Vendor a KNOWN-GOOD build — not every CDN artifact works

arrow-js is pre-1.0 and not all published artifacts are usable standalone. Vendor a
self-contained ES-module build and **pin the version**. Known-good for
`@arrow-js/core@1.0.0-alpha.9`:

- ✅ `https://cdn.jsdelivr.net/npm/@arrow-js/core@1.0.0-alpha.9/+esm` (self-contained, no external imports — recommended to vendor)
- ✅ `https://unpkg.com/@arrow-js/core@1.0.0-alpha.9?module`
- ✅ the esm.sh **default** entry (`https://esm.sh/@arrow-js/core@1.0.0-alpha.9`)
- ❌ **`https://esm.sh/@arrow-js/core@1.0.0-alpha.9/es2022/core.bundle.mjs`** — loads,
  exports the right names, throws nothing, and then **silently renders nothing**.
  This is the easy-to-reach path and the worst to debug. Avoid it.
- ⚠️ Fetching `esm.sh/...?bundle` **server-side** (curl/agent) returns a ~160-byte
  re-export *shim*, not the module — so "download it with curl" mis-vendors. Use a
  `/+esm` or `?module` build that is the actual code.

After vendoring, **load the page in a real browser** and confirm `#app` actually
renders — a blank page with no console error is the signature of a bad arrow-js
build (and of mount/caching bugs); curl and `boogy check` won't catch it.
`boogy deploy --smoke` (above) automates exactly this check.

### Boolean attributes: prefer `checked="${…}"` over `.checked="${…}"`

In this arrow-js version, the **`.`-prefixed property binding** (`.checked`) can
throw under multiple bindings on one element (`Cannot use 'in' operator … '$on'`),
silently breaking the render. Use the **bare boolean-attribute binding**
(`checked="${() => done}"`) — it reflects state correctly and avoids the bug. Same
caution for other `.`-prefixed property bindings until the framework stabilizes.

**Mount-correct by construction.** Your service is served under a mount
(`/{owner}/{service}/…`), not the host root. You do **not** hand-write mount-aware
URLs: the platform serves your index with a `<base href>` set to your mount and
generates a **mount-relative** import map (`./vendor/…`), so a vendored bare
import resolves correctly wherever the service is mounted and at any client-side
route depth. Relative imports (`import "./vendor/core.js"`) and relative asset
paths work the same way. Don't write host-root-absolute paths (`/vendor/…`,
`/app.js`) — those ignore the mount and 404.

## Responsive by default — it must work on phone, desktop, AND wide screen

A Boogy frontend is served to real users on real devices. Build it
**mobile-first and fluid** so it works from a ~360px phone to a 4K monitor — not
just at whatever width you happened to test. This is not optional polish.

- **Viewport meta is mandatory:** `<meta name="viewport" content="width=device-width, initial-scale=1" />` in `<head>`. Without it, mobile browsers render at a fake ~980px and zoom out — everything tiny.
- **Fluid, not fixed.** Size with `%`, `rem`, `fr`, `min()/max()/clamp()`, flexbox, and grid — never a hardcoded `width: 1200px`. Constrain the reading column with `max-width` + `margin-inline: auto` and let it shrink: `width: min(100% - 2rem, 60rem)`.
- **Mobile-first CSS:** write the single-column phone layout as the base, then *add* complexity at wider widths with `@media (min-width: …)`. Two breakpoints is usually enough (e.g. `48rem` tablet, `80rem` desktop). On a wide screen, cap the content width or use a grid so lines don't stretch unreadably across 2560px.
- **Touch + readability:** interactive targets ≥ ~44px tall; base font ≥ 16px (smaller triggers iOS auto-zoom on inputs); wrap long content; make tables/wide content scroll or reflow.
- **No horizontal scroll** at any width. `box-sizing: border-box` globally; test that nothing overflows at 360px.
- **Verify at the extremes, not the middle.** Open it (or use a headless browser / dev-tools device mode) at ~**360px**, ~**768px**, and a **wide** ≥1920px width and confirm the layout holds, the page renders, and every control is reachable. "Looks fine on my screen" is not the test.

A tiny responsive baseline:

```css
*, *::before, *::after { box-sizing: border-box; }
body { margin: 0; font: 16px/1.5 system-ui, sans-serif; }
.container { width: min(100% - 2rem, 60rem); margin-inline: auto; }
.grid { display: grid; gap: 1rem; grid-template-columns: 1fr; }
@media (min-width: 48rem) { .grid { grid-template-columns: repeat(2, 1fr); } }
button, input { min-height: 44px; font-size: 1rem; }
```

## Discoverable by default — GEO/SEO is not optional

A frontend served on Boogy is a real public page; build it so search engines and
LLM/AI crawlers can find, read, and represent it. This is a **strong default**,
not a footnote — ship it unless the user explicitly wants a private/internal tool.

- **Document head, every page:** a unique, descriptive `<title>` and
  `<meta name="description">`; `<meta name="viewport">` (already mandated above);
  `<link rel="canonical">` to the page's own URL; `<html lang="…">`.
- **Social/AI cards:** OpenGraph (`og:title`/`og:description`/`og:image`/`og:url`/
  `og:type`) and Twitter card tags — this is what link unfurls and many AI
  summaries read.
- **Structured data:** a `<script type="application/ld+json">` JSON-LD block
  describing the page (e.g. `WebSite`, `Organization`, `Product`, `Article`) so
  engines and AI agents get typed facts, not guesses.
- **Crawlability:** serve a `robots.txt` and a `sitemap.xml` (just files in your
  `root`); use semantic HTML (`<header>/<main>/<nav>/<article>`, one `<h1>`,
  meaningful headings) and `alt` text. Don't hide primary content behind a
  click/interaction a crawler won't perform.
- **SPA caveat — render meaningful HTML, not an empty shell.** A pure
  client-rendered `<div id="app"></div>` gives crawlers nothing. At minimum put
  the page's title/description/OG tags + core copy in the served `index` HTML so
  the document is meaningful before JS runs; hydrate from there.
- **Fast first paint** helps ranking and AI fetches: small critical assets,
  no blocking work before content. (Assets revalidate via ETag — see caching.)

## Routing: api_prefix → wasm, everything else → assets + SPA fallback

For a **FullStack** app: a request under `api_prefix` (`/api/...`) runs your wasm
(the API — build it with `boogy:boogy-rest-apis`). Every other path is matched
against your asset files by exact path; a miss with no file extension serves
`index` so your client-side router takes over (SPA fallback); a miss **with** an
extension is a 404. Hashed assets are cached immutably; `index.html` is revalidated
each load so a redeploy takes effect immediately. The page and the API are
**same-origin** (`/{owner}/{service}/…`), so the page calls its API with relative
URLs and there's no CORS.

### ⚠️ The mount rule (FullStack) — get this right or every API call 404s

Your `[routing] path` (the **mount**) MUST equal the path prefix your guest
Router serves its routes under. The host forwards an API request to the guest
with the mount **included** — it does not strip it. `api_prefix` is the API
subtree **relative to the mount**, not an absolute path.

So if your wasm Router registers `.get("/notes/api/items", …)`:
- mount → `[routing] path = "/notes"`
- `api_prefix = "/api"` (the subtree under the mount that goes to the wasm)
- frontend assets serve at the mount root (`/{owner}/notes/…`, the paths **not**
  under `api_prefix`).

The trap: mounting at `/notes` but writing your guest routes as `/api/items`
(without the mount). Then `/{owner}/notes/api/items` reaches the guest as
`/notes/api/items`, your Router has no such route, and **every API call 404s with
no other error**. Simplest convention: pick one mount, put ALL your guest routes
under it (`<mount>/…`), and set `api_prefix` to the API sub-path.

## Visibility

Assets are **public by default** — anyone can load the page (including a client-side
login screen) — while the wasm `api_prefix` routes enforce the service's normal
ingress. Set `private = true` to put asset serving behind the service ingress too
(for an internal tool whose shell itself shouldn't be exposed).

## Calling your API as a logged-in user

For a same-origin FullStack app the auth token rides along **automatically** —
the bare `fetch("./api/…")` shown above is usually all you write:

- After a browser login (OAuth), the platform sets an HttpOnly `boogy_session`
  cookie on your app's origin. A **same-origin** `fetch` sends it by default
  (the Fetch API's default is `credentials: "same-origin"`), so you do **not**
  set `credentials` and you do **not** build an `Authorization` header. The host
  resolves the cookie to the principal exactly like a Bearer token, and your
  `api_prefix` routes enforce the service's normal ingress.
- Set `credentials: "include"` **only** for a *cross-origin* API (a different
  origin) — which also requires `[ingress.cors]` with `allow_credentials = true`
  (see *Cross-origin* below).
- If you instead hold a token in JS (e.g. a password login that returned one in
  its response body), attach it explicitly:

```js
fetch("./api/notes", { headers: { Authorization: `Bearer ${token}` } });
```

See `boogy:boogy-account-auth` for how a user gets that session and which login
method delivers which transport.

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

`csp` is a pass-through string — you own the policy; an empty `csp`, or one that
isn't a legal HTTP header value (e.g. contains control characters), is rejected at
manifest parse (fail-closed at deploy). This baseline is the right hardening for a **Frontend-only** (no-wasm)
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

The transpiled `.ts` → `.js` output is **minified by default** (compacted at deploy);
set `[frontend] minify = false` to ship readable JS while debugging. Minification is
compaction only — your vendored `.js` is served verbatim.

## Red flags

| Reach / claim | Reality |
|---|---|
| Serve the page from a wasm handler (`include_str!` + return HTML bytes) | Don't. Declare `[frontend]`; the host serves your assets decoupled from the wasm. |
| "I'll run `vite`/`esbuild`/a Node build first" | No build step. Write `.ts`/`.js`; the platform transpiles at deploy. |
| "TypeScript can't run in the browser, so I'll write plain JS" | Write TS — `build = "ts"` transpiles it server-side. (Plain JS works too.) |
| Embed assets in the wasm binary | Assets live in object storage, served by the host — not in your wasm (no artifact-size hit). |
| `import "@arrow-js/core"` will just work from anywhere | Bare imports resolve via the import map — vendor the file under `web/vendor/` or set `allow_cdn = true`. |
| Put a big video in `root` and serve it from a handler | Large assets auto-offload to object storage via redirect; just drop the file in `root`. |
| Ship a bare `<div id="app">` SPA with no head metadata | Crawlers and AI agents get nothing. Put title/description/OG + core copy in the served `index` HTML; add JSON-LD, `robots.txt`, `sitemap.xml`. GEO/SEO is a default, not a follow-up. |
| Fold a reusable backend into this frontend service | If the API logic is generically useful, build it as its **own** (publicly provisionable) module — see `boogy:growing-boogy-meshes` — and keep this service the app-specific shell. |

## Integration

← Reach this from `boogy:designing-boogy-services` (the "does this need a UI?"
branch). → `boogy:boogy-rest-apis` builds the wasm API a FullStack frontend calls
(under `api_prefix`). → `boogy:boogy-auth` / `boogy:boogy-account-auth` for gating
that API and wiring a login the public shell renders. ↔ `boogy:boogy-capability-limits`
for the asset size limits + what's served where.
