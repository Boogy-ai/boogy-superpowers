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

**This skill is the core: the model, the manifest, build modes, routing and
sign-in.** Load a part when the task touches it:

| The task touches | Skill |
|---|---|
| a UI framework or build tool (arrow-js, Preact, React, Vite, Astro, SvelteKit, Nuxt, a Next.js export), vendoring a package, the build's base path, assets that 404 or a page that goes blank at a nested route | `boogy:boogy-frontend-builds` |
| search engines, AI crawlers and link previews: title, description, OpenGraph, JSON-LD, `robots.txt`, `sitemap.xml`, prerendered routes | `boogy:boogy-frontend-discoverability` |
| framing, browser permissions (camera, microphone, geolocation), a Content-Security-Policy, CORS for another website, browser storage, calling another app from the page | `boogy:boogy-frontend-security` |

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

[routing]             # `path` is the base your wasm's router sees. Always "/" for a
path = "/"            # new service: the name is already in its hostname, and the
methods = ["GET", "POST"]   # base never appears in a URL (see the base rule below).

[ingress]             # REQUIRED — who may call this service. Stated, never
mode = "public"       # inferred: `public` = anyone on the internet, no
                      # credential. `authenticated` = any signed-in principal.

[capabilities]        # optional — declare only what the wasm uses
store = true

[frontend]
root = "web"          # your source dir: index.html + .ts/.js/.css/assets
api_prefix = "/api"   # FullStack: requests under /api go to the wasm. omit it for a Frontend site.
index = "index.html"  # the SPA entry document (served for unmatched routes). default: index.html
build = "source"          # "ts" = the platform transpiles your TypeScript. "none" = you uploaded plain JS.
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
path = "/"
methods = ["GET"]

[ingress]
mode = "public"

[frontend]
root = "web"
build = "source"
```

Only `[service]` (id/name/version), `[routing]`, `[ingress]`, and `[frontend]` are
needed for a Frontend; a **FullStack** app adds a `wasm` and an `api_prefix`.

## Write TypeScript or JavaScript — there is no build step

Write your frontend in **TypeScript** (or plain JavaScript). You do **not** install
Node, run `vite`/`esbuild`, or produce a bundle. With `build = "source"`, the platform
strips the types and emits browser-ready ES modules **at deploy time**; what gets
served is the JavaScript. Your authoring loop is: write `.ts`/`.js`, deploy. (If you
already have built JS and don't want the transpile, set `build = "dist"`.)

**Imports use native ES modules + an import map.** A bare specifier like
`@arrow-js/core` resolves either to a copy you include under `web/vendor/` (the
default — fully self-hosted), or, with `allow_cdn = true`, to a CDN URL. The
platform generates the `<script type="importmap">` and injects it into your
`index.html`. Relative `./foo.ts` imports are rewritten to `./foo.js` for you —
and you can write the modern, extensionless form too: `import './foo'`
resolves the same sibling. An extensionless relative import is probed in a
fixed, documented order — `.ts`, `.tsx`, `.jsx`, `.js` as a direct file, then
the same four as a directory's `index.*` — so when a same-named `.ts` and `.js`
both exist, the `.ts` wins (it's far more likely to be your real source than a
stale build artifact), and a directory's `index.*` is only tried once no direct
file matches. An import that matches nothing still fails the deploy, naming the
specifier and the file that imported it.

**`@boogy/web` needs neither.** The platform's browser SDK is the one reserved
specifier: `import { installFoundation, stack, button } from "@boogy/web"`
resolves to the platform's own copy, served from your app's origin, with
nothing vendored and no `allow_cdn` (which never applies to it). Its layout and
component functions return attributes you set on plain elements, and
`installFoundation()` adds their stylesheet, so a first screen needs no
framework. Every other package follows the rule above. A stage-0 wireframe
built from it is in `boogy:shipping-in-stages`.

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

**The entry must be a file, not an inline script.** With `build = "source"`
the platform bundles from the `<script type="module" src="…">` tags in your
index HTML. An inline `<script type="module">…</script>` is not an entry, and a
page whose only module script is inline is refused at deploy: `no <script
type="module" src="…"> entry found in the index HTML`.

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

After the deploy succeeds it loads the printed URL — the root of the service's own
address, e.g. `https://mysite-k3v9.boogy.app/` — in a detected headless
Chrome/Chromium and asserts: the page renders non-empty content matching one of
`--smoke-selector`'s selectors (`--smoke-selector` takes a comma-separated list and defaults to
`#app,#root,#__next`, covering arrow-js, Vite/React and Next roots; a selector
that matches **nothing** fails the smoke rather than silently checking `<body>`
instead), the console has no errors / uncaught exceptions, and no same-origin
sub-resource returned ≥ 400. Add `--smoke-path /some/nested/route` to check a
deep or prerendered route — the root passing proves the least, since it is the
one URL whose relative assets resolve no matter what. A failure prints a
report (which assertion, the console errors, the failed request URLs) and exits
non-zero — fix and re-ship with `boogy deploy --replace`.

- **Opt-in and best-effort.** Without `--smoke` nothing changes. With it but **no
  browser installed**, it prints a one-line note and exits cleanly (never blocks
  a deploy) — point it at a binary with `BOOGY_SMOKE_BROWSER=/path/to/chrome`.
  **A skipped smoke is NOT a pass — it verified nothing.** If you see
  `Smoke: skipped — no headless browser found`, do not report the page as working:
  install or point at a Chrome/Chromium and re-run `--smoke`, or open the printed
  deploy URL in a real browser yourself and confirm it renders. "Deploy succeeded"
  is not "the page works".
- **Frontend deployments only** — a wasm-only service has nothing to render.
- `--smoke-timeout <ms>` (default 10000) bounds the render wait.

This is the concrete way to load the page in a real browser — run it as the
last step of every frontend deploy.


### Asset paths: write relative references

The host injects a `<base href>` into every HTML document it serves, so a
relative reference (`./app.js`, `./style.css`, `./api/items`) resolves at any
route depth and on a custom domain. Never write `/<service-id>/…` (refused at
deploy) or a `<base>` of your own (it suppresses the host's). The full table,
and how to verify at a nested route: `boogy:boogy-frontend-builds`.

## Responsive and board-ready by default

A Boogy page is opened on a ~360px phone, on a 4K monitor, and in a pane of a
Boogy board at whatever size its person gives it, often all three. Build it on
`@boogy/web` and let the SDK do the sizing; this is not optional polish.

- **Viewport meta is mandatory:** `<meta name="viewport" content="width=device-width, initial-scale=1" />` in `<head>`. Without it, mobile browsers render at a fake ~980px and zoom out: everything tiny.
- **The page scale on:** `installFoundation({ dev: import.meta.env.DEV, scale: true })` (or `installFoundation({ scale: true })` for a `build = "source"` page). The SDK's unit then follows the window, and in a board the pane, so every component and size token grows and shrinks with it.
- **Sizes from SDK tokens only:** `--space-*`, `--control-*`, `--icon-*`, `--fs-*`, `--radius-*`. No `px`/`rem`/`em`/`ch` sizes and no hand-picked `max-width` caps in your CSS: they ignore the scale and the board's Smaller/Larger. A size the SDK lacks is a named token you define once.
- **No width breakpoints:** no `@media (min-width: …)`. Layout that adapts is the SDK's (`FillGrid`, `CardGrid`, `Stack`, `Sheet`) and container units multiplied by `var(--u-zoom)`.
- **Colours from SDK tokens:** `--text-*`, `--accent`, `--edge*`, `--ground*`. A literal colour does not follow the scheme, so it vanishes on a board's background or in the other theme.
- **Board-ready:** `[boards] background = "board"` in the manifest, `connectPane({ service: "<your service id>" })` in the page, and a page background painted with `var(--ground)` or a paint token of your own that gives way in a board. Unless the person has said the page is only ever opened on its own (`boogy:running-in-a-board`).
- **Reuse the SDK's looks, never copy them:** a section label is `Section`, a field label is `TextField`'s. A hand-copied rule drifts the first time the SDK changes.
- **Verify at the extremes, not the middle:** ~**360px**, a **wide** ≥1920px window, and a board pane at Smaller and Larger. The layout holds, nothing scrolls sideways, and every control is reachable. "Looks fine on my screen" is not the test.

A page's own stylesheet holds layout only:

```css
html, body { height: 100%; margin: 0; }
:root { --page-paint: var(--ground-solid); }
:root[data-board-background] { --page-paint: transparent; }   /* in a board pane */
body { background: var(--page-paint); color: var(--text-1); font-family: var(--font-body); }
.screen { height: 100%; display: flex; flex-direction: column; }
.screen-body { flex: 1; min-height: 0; overflow-y: auto; padding: var(--space-4); }
```

A pre-built framework bundle that does not use `@boogy/web` is held to the same
outcomes: fluid from 360px to wide, readable on a board's background, and
`connectPane` for the board's background and size.

## Discoverable by default

A Boogy page is a real public page. Unless the person wants a private tool, the
served `index` HTML carries a unique `<title>`, a `<meta name="description">`,
OpenGraph tags and the page's core copy, beside a `robots.txt` and a
`sitemap.xml`. Absolute URLs (canonical, `og:url`, the sitemap's) come from the
URL `boogy deploy` prints, never a guess. The full baseline and per-route
metadata: `boogy:boogy-frontend-discoverability`.

## Routing: api_prefix → wasm, everything else → assets + SPA fallback

For a **FullStack** app: a request under `api_prefix` (`/api/...`) runs your wasm
(the API — build it with `boogy:boogy-rest-apis`). Every other path is matched
against your asset files by exact path; a miss with no file extension serves a
prerendered document for that path (`<path>/index.html`, then `<path>.html`) if
the bundle holds one, otherwise `index` so your client-side router takes over
(SPA fallback); a miss **with** an extension is a 404.

Caching depends on whether the asset's URL encodes its content:

| Served path | Cache policy | Why |
|---|---|---|
| content-addressed (`site.<hash>.css`) | `immutable`, one year | the URL cannot outlive its bytes, so a returning visitor fetches it **zero** times |
| a stable authored path (`site.css`) | `no-cache` + `ETag` | a redeploy reuses the path, so it must revalidate; the conditional GET returns 304 when nothing changed |
| documents — `index.html` and prerendered routes | `no-cache` + `ETag` | a document URL is a route, so it must always resolve to the current deployment |

`build` answers one question: **who produced what is in `root`?**

- **`build = "source"`** (the default) — `root` holds source, and the platform
  builds it: strips TypeScript, bundles the relative module graph, generates the
  import map, content-addresses the files it emits and rewrites the references
  to them.
- **`build = "dist"`** — `root` holds your build tool's output, served as-is.
  Its filenames are never rewritten.

The distinction that matters is provenance, not language: the platform may
rewrite what IT produced and must not touch what arrived already built, because
a pre-built file can reference others in ways nothing here can see —
`import("./chunk.js")`, `new URL("./w.js", import.meta.url)`, CSS `url()`. Get
this wrong and the failure is a renamed file whose reference still points at the
old name: a 404 at runtime on a lazily-loaded route, not a deploy error.

**So if you ship a framework build — a Vite/Astro/SvelteKit `dist/` — set
`build = "dist"`.** The default assumes source. The framework's own base option
and its static mode: `boogy:boogy-frontend-builds`.

(`ts` and `none` are the historical spellings and still parse. They named a
transpiler step rather than the question above, and `none` was always a misnomer
since the platform does plenty with such a bundle.)

Both modes reach the immutable row, by different routes, and neither is
something you configure:

- **`build = "source"`** — the platform content-addresses your `.css` and `.js`
  (`site.<hash>.css`) and rewrites the references to match.
- **`build = "dist"`** — your build tool's filenames are left exactly as they
  are, because renaming them would mean rewriting references the platform
  cannot see (`import()`, `new URL(…, import.meta.url)`, CSS `url()`), and a
  missed one is a 404 at runtime. Instead the served document's `<base href>`
  points into a per-deployment path, so every relative reference resolves under
  a URL that encodes the deployment. Your asset URLs therefore change on each
  deploy — that is what makes caching them for a year safe.

You will see that second form in the served HTML as a `_a/<hash>/` segment at
the start of the path. It is not something to write, link to, or configure: the
platform injects it and strips it, both spellings of a URL work, and an API
client addressing `<api_prefix>/…` directly never needs to know it exists.

A content-addressed URL keeps serving its bytes for a few deployments after the
bundle that produced it stops being active, so a page loaded just before a
redeploy can still fetch the subresources it was told to. That window is a small
number of deployments, not forever — a client far enough behind gets a 404 and
recovers on reload.

The page and the API are
**same-origin** (`https://notes-7k3q.boogy.app/…`), so the page calls its API with
relative URLs and there's no CORS.

### ⚠️ The base rule (FullStack) — get this right or every API call 404s

Declare `[routing] path = "/"`. Then the URL path, your wasm Router's path and
`api_prefix` line up with nothing to translate: with `api_prefix = "/api"`, the
Router registers `.get("/api/items", …)`, and the page calls `./api/items` —
`https://notes-7k3q.boogy.app/api/items`. Frontend assets are every path **not**
under `api_prefix`.

`[routing] path` is only the base your wasm's own router sees; the platform
relocates each request to it internally, and **it never appears in a URL**. So
a service that declares `path = "/notes"` registers `.get("/notes/api/items", …)`
and is still reached at `https://notes-7k3q.boogy.app/api/items` — `api_prefix`
stays `/api`, relative to the root. The trap is a Router that disagrees with the
declared base: declaring `/notes` but registering `/api/items` makes the guest
see `/notes/api/items`, your Router has no such route, and **every API call 404s
with no other error**. Declaring `/` makes that mistake impossible.

## Visibility

Assets are **public by default** — anyone can load the page (including a client-side
login screen) — while the wasm `api_prefix` routes enforce the service's normal
ingress. Set `private = true` to put asset serving behind the service ingress too
(for an internal tool whose shell itself shouldn't be exposed).

## Your page runs on an origin of its own

Every service is served at the root of an address of its own, so the browser
keeps apps apart. Shown on its own, the page owns its tab; in a board it is
framed and can never navigate the page around it, so open anything that leaves
the app with `target="_blank"`. Browser storage belongs to this instance, and
the page calls only its own backend. Framing, permissions, storage, CSP and
CORS in full: `boogy:boogy-frontend-security`.

## Calling your API as a logged-in user

For a same-origin FullStack app the auth token rides along **automatically** —
the bare `fetch("./api/…")` shown above is usually all you write:

- After a browser sign-in, the platform's `/boogy/callback` **on your app's own
  address** (or a board's background exchange, for a pane) sets an HttpOnly,
  host-only `__Host-boogy_app` cookie there. That is the cookie your page's API
  calls ride on. A **same-origin** `fetch` sends it by default (the
  Fetch API's default is `credentials: "same-origin"`), so you do **not** set
  `credentials` and you do **not** build an `Authorization` header. The host
  resolves it to the principal exactly like a Bearer token, and your `api_prefix`
  routes enforce the service's normal ingress.
- Don't confuse it with `__Host-boogy_session`, the platform-login cookie set on
  the **auth** origin (`auth.<base>`). It is host-only too, so it never travels to
  a tenant origin and cannot authenticate a call to your service. On your
  address `__Host-boogy_app` covers exactly YOUR one service. If your own page
  gets a 401, call `POST /boogy/renew` first (the SDK's `fetch` does); if the
  person is signed out, sign them in again (`boogy.signIn()`) — don't reach for
  a `credentials` option. See `boogy:boogy-account-auth`.
- Set `credentials: "include"` **only** for a *cross-origin* API (a different
  origin) — which also requires `[ingress.cors]` with `allow_credentials = true`
  (`boogy:boogy-frontend-security`).
- If you instead hold a token in JS (e.g. a password login that returned one in
  its response body), attach it explicitly:

```js
fetch("./api/notes", { headers: { Authorization: `Bearer ${token}` } });
```

See `boogy:boogy-account-auth` for how a user gets that session and which login
method delivers which transport.

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

## Frontend assets vs user files

Both are served by the platform, and they are not interchangeable:

| | `[frontend]` | `[[files.collections]]` |
|---|---|---|
| What | your app's own build output | content your USERS upload or you generate |
| When it changes | at deploy | at runtime |
| Versioned with the deployment | yes — a rollback restores it | no — deletion is permanent |

A user avatar is not a frontend asset: shipping it through the frontend
bundle would mean redeploying to add one. See `boogy:boogy-file-storage`.

## Red flags

| Reach / claim | Reality |
|---|---|
| Serve the page from a wasm handler (`include_str!` + return HTML bytes) | Don't. Declare `[frontend]`; the host serves your assets decoupled from the wasm. |
| "I'll run `vite`/`esbuild`/a Node build first" | Not for a hand-authored frontend — write `.ts`/`.js` and the platform transpiles + bundles at deploy. (Shipping a **pre-built framework bundle** is a separate, supported case: `build = "dist"` and serve the output verbatim.) |
| "TypeScript can't run in the browser, so I'll write plain JS" | Write TS — `build = "source"` transpiles it server-side. (Plain JS works too.) |
| Embed assets in the wasm binary | Assets live in object storage, served by the host — not in your wasm (no artifact-size hit). |
| "An inline `<script type="module">` is simplest" | Refused at deploy when it is the page's only module script. Put the code in `web/app.ts` and load `./app.js`. |
| `[routing] path = "/notes"` so the URL says notes | The name is already in the hostname, and the declared base never appears in a URL — it only makes every route repeat it. Declare `path = "/"`. |
| Put a big video in `root` and serve it from a handler | Large assets auto-offload to object storage via redirect; just drop the file in `root`. |
| Size the layout with `rem` widths, `max-width` caps and `@media (min-width)` breakpoints | They ignore the SDK's page scale and the board's Smaller/Larger. Turn the scale on and size from SDK tokens; adapt with the SDK's layouts. |
| "This app is standalone; boards are someone else's concern" | Every page is board-ready unless the person said it is only ever opened on its own: `[boards] background`, `connectPane`, the page scale, token colours and sizes. |
| "Deploy succeeded, so the page works" / treating a skipped `--smoke` as verification | A clean deploy only published + routed. `Smoke: skipped` verified nothing. Run `--smoke` with a real browser, or load the printed URL yourself, before claiming it renders. |
| Fold a reusable backend into this frontend service | If the API logic is generically useful, build it as its **own** (publicly provisionable) module — see `boogy:growing-boogy-meshes` — and keep this service the app-specific shell. |
| "I'll deploy my Next.js/SvelteKit/Astro build as it is" | Only a fully static build deploys, with a relative base. Read `boogy:boogy-frontend-builds` first. |
| "SEO can wait; ship the bare SPA" | Discoverable is the default: head metadata and core copy in the served HTML. `boogy:boogy-frontend-discoverability`. |

## Integration

← Reach this from `boogy:designing-boogy-services` (the "does this need a UI?"
branch). ↓ Its parts: `boogy:boogy-frontend-builds`,
`boogy:boogy-frontend-discoverability`, `boogy:boogy-frontend-security`.
→ `boogy:boogy-rest-apis` builds the wasm API a FullStack frontend calls (under
`api_prefix`). → `boogy:boogy-auth` / `boogy:boogy-account-auth` for gating that
API and wiring a login the public shell renders. → `boogy:running-in-a-board`
for a page in a board's pane. ↔ `boogy:boogy-capability-limits` for the asset
size limits + what's served where. → `boogy:boogy-custom-domains` when a
framework build needs root-serve.
