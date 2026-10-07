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

### Vendor a KNOWN-GOOD build — verify the artifact, don't pattern-match a URL shape

Not every published CDN artifact is usable standalone, and the failure mode is
the worst kind: it loads, exports the right names, throws nothing, and then
**silently renders nothing**. Vendor a self-contained ES-module build and
**pin the version**. Known-good for `@arrow-js/core@1.0.0-alpha.9`:

- ✅ `https://cdn.jsdelivr.net/npm/@arrow-js/core@1.0.0-alpha.9/+esm` (self-contained, no external imports — recommended to vendor)
- ✅ `https://unpkg.com/@arrow-js/core@1.0.0-alpha.9?module`
- ✅ the esm.sh **default** entry for this package (`https://esm.sh/@arrow-js/core@1.0.0-alpha.9`)
- ❌ **`https://esm.sh/@arrow-js/core@1.0.0-alpha.9/es2022/core.bundle.mjs`** — loads,
  exports the right names, throws nothing, and then **silently renders nothing**.
  This is the easy-to-reach path and the worst to debug. Avoid it.
- ⚠️ Fetching `esm.sh/...?bundle` **server-side** (curl/agent) returns a ~160-byte
  re-export *shim*, not the module — so "download it with curl" mis-vendors. Use a
  `/+esm` or `?module` build that is the actual code.

**Don't read that list as "avoid the `/es2022/*.bundle.mjs` shape, and any
plain default entry is fine."** Verified separately, for a different package:
plain `https://esm.sh/preact@10.24.3`, with **no query parameter or extra path
segment at all**, also serves a stub that renders nothing. Both of these are
specific, dated observations about specific URLs — not a general claim that
esm.sh, or CDNs at large, ship broken builds. What they rule out is inferring
"this entry point works" from what its URL looks like: a shape you haven't
personally hit failing is not evidence it can't.

**A vendored file's own imports can be off-origin without looking bare.** A
jsdelivr `+esm` build of `preact/jsx-runtime` imports via a
**jsdelivr-root-absolute path**, e.g. `from"/npm/preact@10.24.3/+esm"` inside
the file you vendored. That specifier isn't bare — it doesn't lack a leading
`.`/`/` — so a check that only looks for bare imports won't flag it. And
because it *starts* with `/`, a check that treats a leading slash as
"relative, therefore already safe" reads it exactly backwards: at page load
that path resolves against the **tenant's own origin**, not jsdelivr's, and
404s. Read every vendored file's own imports, not just the entry URL you
fetched it from.

**"Does this artifact contain bare imports" is the wrong test.** A legitimate
vendored file can, and often should, contain a bare import. Say your app's
entry module does `import { render } from "preact"` (a bare specifier, so the
platform records an import-map entry for it, `"preact" → "./vendor/preact.js"`),
and you also vendor `web/vendor/preact/jsx-runtime.js`, whose first line is
`import{options as r,Fragment as e}from"preact";`. That bare import is
**correct**, not a mis-vendor: the browser resolves it through the exact same
import-map entry your own entry module's import produced. The test that
actually matters is not "relative vs. bare" in isolation — it's: **is every
specifier this artifact imports either relative, or itself covered by the
generated import map?**

That coverage is latent, not structural, and worth stating plainly: it holds
only because your entry graph happens to import the same specifier the
vendored file needs. The import map is built from what the entry graph
actually imports, not from scanning every vendored file for specifiers it
would like resolved. So a vendored dependency can go from resolvable to
unresolvable with no change to the vendored file itself — purely because
unrelated application code stopped importing that same bare specifier.

After vendoring, **load the page in a real browser** and confirm the app
actually renders — a blank page with no console error is the signature of a
bad vendored build (and of mount/caching bugs); curl and `boogy check` won't
catch it. `boogy deploy --smoke` (above) automates exactly this check.

### Boolean attributes: prefer `checked="${…}"` over `.checked="${…}"`

In this arrow-js version, the **`.`-prefixed property binding** (`.checked`) can
throw under multiple bindings on one element (`Cannot use 'in' operator … '$on'`),
silently breaking the render. Use the **bare boolean-attribute binding**
(`checked="${() => done}"`) — it reflects state correctly and avoids the bug. Same
caution for other `.`-prefixed property bindings until the framework stabilizes.

### Asset paths at nested routes — the host injects `<base href>` for you

Your service is served at the root of its own address
(`https://notes-7k3q.boogy.app/`). **The host injects a `<base href>` as the
first element inside `<head>` of every HTML document it serves** — so every
relative `<script src>`, `<link href>`, `<img src>`, relative import, and
relative `fetch` resolves correctly **at any SPA-route depth**.

The injected value is `/` joined with **that document's own directory in your
bundle** — which is exactly where the deploy gate resolved the document's
relative references from, so the two always agree:

| Document served | Injected base |
|---|---|
| `index.html` (the usual SPA shell) | `/` |
| `about.html` (flat prerendered form) | `/` |
| `about/index.html` (nested prerendered form) | `/about/` |
| a nested `[frontend].index`, e.g. `app/index.html` | `/app/` |

(With `build = "dist"` the base also points into a per-deployment `_a/<hash>/`
segment — see "Routing" below. You never write it.) The same holds on a custom
domain: every origin serves its one service at the root.

That's what makes the SPA fallback safe: a hard refresh or shared deep link at
`/p/42` gets the `index` document back, and its `./app.js` still resolves to
`/app.js` rather than `/p/app.js`.

**So write ordinary relative references and stop thinking about it:**

```html
<script type="module" src="./app.js"></script>
<link rel="stylesheet" href="./style.css" />
```

| You write | What happens |
|---|---|
| `./app.js` / `app.js` (relative) | ✅ Resolves against the injected base — correct at the root, at `/p/42`, and on a custom domain. Use this. |
| `/app.js` (host-root-absolute) | ⚠️ **Works today, and is still the wrong habit.** Your service is at the root, so it resolves — but it skips the injected base, so a `build = "dist"` bundle's per-deployment `_a/<hash>/` prefix is lost for that file (it is no longer cached as immutable),. Write `./app.js`. |
| `/<service-id>/app.js` | ❌ **Rejected at deploy** — bundle keys are root-relative, so the gate resolves it to a key that is not a built asset. No URL carries the service's id or base as a path. |
| `<base href="…">` (author-supplied) | ❌ **Rejected at deploy** if it names a path that is not a bundle asset. You also don't want one: an author-supplied `<base>` *suppresses* the host's injection, so writing it can only lose you the correct value. |
| a path string inside an HTML **comment** that is not a bundle asset (e.g. documenting `href="/<service-id>/"`) | ❌ **Also rejected** — the gate is a string scanner, not an HTML parser; it can't tell a comment from a live attribute. Keep such path strings out of comments entirely. |
| `https://notes-7k3q.boogy.app/app.js` (fully-qualified absolute URL) | Works, but **unnecessary** — and it hardcodes the deployed origin, so a local preview server has to rewrite it. Prefer relative. |

**Verify with a headless browser at a NESTED route — a curl won't catch a
runtime break.** A `curl` against the root only proves the shell HTML came back;
it can't see that the app's own assets 404 once the browser is one level deeper.
Load `https://notes-7k3q.boogy.app/<some-nested-path>` in a headless browser and
confirm the app actually boots (non-empty `#app`, no console errors, no failed
sub-resource) — not just the root. `boogy deploy --smoke` (above) checks the
root by default; if your app serves nested paths, also open one of those paths
yourself before calling the deploy done.

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
- **Absolute URLs (`canonical`, `og:url`, `sitemap.xml` `<loc>`) must be the real
  deployed origin — the service's own address, `https://<name>-<suffix>.boogy.app/`
  (or its custom domain).** Don't guess it before you have it — the suffix is
  random: it's `boogy.app` (the app plane), not `boogy.ai` (the
  control/marketing plane), and the **`boogy deploy` output prints the exact URL**.
  Either fill these in *after* the first deploy from that printed URL, or leave a
  clear placeholder and reconcile before shipping. Note the gate trap: a *relative*
  `<link rel="canonical" href="./">` (or any `href`/`src` pointing at a directory)
  counts as a **dangling reference** and fails the deploy — canonical/OG want the
  absolute deployed URL anyway, so use it.
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
  no blocking work before content. (Content-addressed assets cache immutably;
  others revalidate via ETag — see caching.)

### Per-route metadata: prerender the routes

Yes — for routes you can enumerate at build time. The host serves a
**prerendered document** when your bundle holds one: on an extensionless
request it looks for `<path>/index.html`, then `<path>.html`, and only falls
back to the SPA `index` when neither exists. So a build that emits
`blog/my-post/index.html` gets that document — with its own `<title>`,
`og:image`, `og:description` and body copy — served at `/blog/my-post`,
and crawlers and link-unfurlers read the real thing.

One constraint on the route path: a request whose **last segment contains a
dot** is read as a file request and 404s without ever being probed as a route.
So `blog/node.js-tips/index.html` is stored but not reachable at
`/blog/node.js-tips`. Keep dots out of prerendered route segments.

Prerendered documents revalidate (`no-cache` + `ETag`) exactly like the shell, so a
redeploy reaches returning browsers immediately, and a `<base href>` is injected
into each one. That base is `/` joined with the **document's own directory in
the bundle** — `/about/index.html` served at `/about` gets
`<base href="/about/">` — so a relative reference resolves to the same file the
deploy gate resolved it to.

What this does **not** cover is a route whose content is not known until request
time — a per-user dashboard, a search-results URL. There is no server-side
render, so those still get the generic shell. If the unfurl matters for
user-generated content, prerender the enumerable set and accept the shell for
the rest.

One collision to know about: a prerendered route whose path falls under
`api_prefix` loses — the API check runs before any asset resolution, so
`/api/things` reaches the wasm even if `api/things/index.html` is in
the bundle. Keep prerendered routes out of your `api_prefix` subtree.

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
`build = "dist"`.** The default assumes source.

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

### Framework-built frontends (Vite, Astro, SvelteKit, Nuxt) → build with a RELATIVE base

A pre-built framework bundle is a perfectly good `[frontend].root`: point it at
the build output (`dist/`, `out/`, `build/`) and set `build = "dist"` so the
platform serves the files verbatim instead of transpiling them. Combined with a
Rust API under `api_prefix`, a FullStack deployment gives you the whole
page-plus-API shape in one deploy — same origin, no CORS, the app cookie riding
along automatically.

The one thing to get right is the framework's **base** option, which decides
what asset paths the build writes into your HTML.

**Set it to relative.** In Vite that is `base: './'`; other build tools have the
equivalent. The build then emits `./assets/index-abc123.js`, which resolves
against the `<base href>` the host injects — correct at the root, at a deep SPA
route, from a nested prerendered document, and on a custom domain.

| The build emits | What happens |
|---|---|
| `./assets/index-abc123.js` (relative base) | ✅ Deploys and serves correctly. Resolved against the injected `<base href>`, which is `/` for a root-level document and the document's own directory for a prerendered one — so a nested document's `./`-relative assets resolve alongside it, as the build emitted them. |
| `/assets/index-abc123.js` (default absolute base) | ⚠️ **Resolves today, and loses what the base gives you.** The service is at the root, so the file is found — but `<base>` does not apply to root-absolute URLs, so the per-deployment `_a/<hash>/` prefix of a `build = "dist"` bundle is skipped and those files are no longer cached as immutable. |
| `/<service>/assets/index-abc123.js` (base set to the service name) | ❌ **Rejected at deploy** — bundle keys are root-relative, so `/<service>/…` is not one, and no URL carries the service's name as a path. |

That last rejection is **correct, and worth understanding rather than working
around**: the service's name is in its hostname, never in its paths, and a
bundle is built once at publish and served wherever it is provisioned — its own
address, a custom domain, a board pane. A prefix baked into the built HTML
would point at a path that does not exist on any of them. A relative base
cannot, because the host supplies the base at serve time.

Two things this does **not** get you:

- **The framework's server never runs.** There is no JavaScript runtime — the
  guest is Rust/wasm. SSR, React Server Components, server actions, middleware,
  and `app/api/*/route.ts` handlers do not come across. Build in the framework's
  fully-static mode (`output: 'export'`, `adapter-static`, `nuxi generate`) and
  port the route handlers to your wasm Router under `api_prefix`. A build that
  needs a Node server at request time cannot deploy here — see
  `boogy:boogy-capability-limits`.
- **`--smoke` still needs the right selector on a framework build.** Its
  default (`#app,#root,#__next`) covers arrow-js, Vite/React and Next roots,
  and a selector that matches nothing now **fails** the check rather than
  falling back to `<body>` — but a build that mounts somewhere else entirely
  needs its own `--smoke-selector`, or the smoke fails even on a correctly
  rendered page.

#### Where the app is served from

Always at the root of its own address, `https://<name>-<suffix>.boogy.app/` —
every service has one, so an owner runs as many apps as they like side by side
and none of them shares an origin with another. Two more places show the same
app:

- **A board pane.** Boards frame the app from that same address, so a tab and a
  pane share one origin, one storage and one session.
- **A custom domain.** One domain, one service, served at the domain root. A
  person's page visit to the app's own address then moves to the domain, while
  board panes and API calls keep using the address (`boogy:boogy-custom-domains`).

With a relative base none of this needs anything from you.

## Visibility

Assets are **public by default** — anyone can load the page (including a client-side
login screen) — while the wasm `api_prefix` routes enforce the service's normal
ingress. Set `private = true` to put asset serving behind the service ingress too
(for an internal tool whose shell itself shouldn't be exposed).

## Your page runs on an origin of its own

Every service is served at the root of an address of its own — not shared with
any other app, yours or anyone else's — so the browser itself keeps apps apart.
Shown on its own, your page is an ordinary top-level website at that address;
`fetch("./api/…")` for your own app, as shown throughout this skill, just works.

What this means for you as an author:

- **Shown on its own, your page is not framed.** It owns its tab: full-page
  navigation, `target="_top"`, OAuth and checkout redirects, install-to-home-screen
  and password managers all behave as on any website.
- **In a board, your page is framed — and can never navigate the page around
  it.** The board's frame is sandboxed with no top-level navigation of any
  kind: a `target="_top"` link does nothing there. Open anything that leaves
  your app — OAuth consent, a payment page, "open elsewhere" — in a new window
  (`target="_blank"` or `window.open`), which works in both cases.
- **Who may frame you:** the platform's own framers — boards and the console —
  and nobody else. `[frontend] frame_options = "deny"` refuses them too (and the
  registry then reports your app as not embeddable); no setting lets any other
  site frame your address (see **Security headers** below).
- **Signing in:** shown on its own, a "Sign in" button calling `boogy.signIn()`
  sends the person through the platform's sign-in and back to the page they
  were on. In a board, the same call asks the board, which signs the pane in.
  Nothing signs your app in on its own, so a sign-out stays signed out.
  Details: `boogy:boogy-account-auth`.
- **Browser storage is per instance.** `localStorage`, `IndexedDB` and
  cookies on your address belong to THIS deployment alone. Redeploying keeps
  them (it's the same instance, at the same address); deleting the instance
  and provisioning a fresh one gives it a new address that starts empty, on
  purpose — an address is never reused, so nobody inherits data a deleted
  instance left behind.
- **Your page calls only its own backend.** A request to a DIFFERENT app's
  API — even one under your own account — is not authenticated: the session
  cookie that makes a same-origin `fetch` "just work" is deliberately
  withheld from a cross-origin call, including to another app on the same
  base domain. A public route still answers such a call; a gated one answers
  `401`. If your app genuinely needs another of your services' data, call it
  from YOUR backend over the mesh (`boogy:boogy-mesh-architecture`) — never
  directly from the browser.
- **Camera, microphone and geolocation in a board need an explicit grant.** A
  board frames you with `fullscreen` and `clipboard-write`; the other three are
  opt-in, because they're the ones a person expects to be asked about:

  ```toml
  [frontend]
  root = "web"
  allow = ["camera", "microphone", "geolocation"]   # closed list
  ```

  Without the matching entry, a framed page is refused the permission exactly
  as in any other frame, however your own code prompts for it. Shown on its own,
  the browser asks the person as it would for any website.
- **Use relative paths, never a hard-coded prefix.** The asset-path rule above
  (write `./app.js`, never `/<service-id>/app.js`) applies to anything that
  addresses your own page: build links and API calls from a relative path or
  from the platform's own config. Your address carries no service prefix at
  all.
- **A page your BACKEND renders is served like any other response.** If your
  wasm returns an HTML page from a handler — rather than through `[frontend]` —
  it is served on your address under the same framing rules, but it gets none
  of `[frontend]`'s serving (the injected base, the pane script, asset caching,
  the deploy-time checks). An interactive page belongs in `[frontend]`; reserve
  a backend-rendered HTML response for something small (an error page, a
  redirect-with-explanation).

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

**One exception, and it changes which header you will see.** Where the platform is
configured to let the Boogy console embed a running service (so your app can be shown
inside a console pane), a `same_origin` response omits `X-Frame-Options` entirely and
carries CSP `frame-ancestors 'self' <console origin>` instead — `X-Frame-Options` has
no allow-list value modern browsers honour, and sending a permissive `frame-ancestors`
beside `SAMEORIGIN` is exactly the combination browsers disagree about. `deny` is
never overridden: it is a sentence you wrote, where `same_origin` is a default you
inherited. Your own `csp` is sent as a SEPARATE header beside the grant, and two
policies intersect — so `frame-ancestors 'none'` in your `csp` still blocks
everything, and you can narrow the grant but never widen it.

**On your service's own address the framing grant is fixed: the platform's
framers — boards and the console — and nobody else.** `frame_options = "deny"`
refuses them too (your sentence, never overridden), and the registry then
reports the app as not embeddable; `same_origin` and `none` both leave the
platform grant as it is, so `none` cannot make your address frameable by
anybody else. Your `csp` still intersects as described above. The baseline and
the exception above describe a custom domain.

Two `[frontend]` knobs tune it:

```toml
[frontend]
root = "web"
csp = "default-src 'self'"   # opt-in Content-Security-Policy, emitted verbatim. unset = no CSP header.
frame_options = "same_origin" # same_origin (default → SAMEORIGIN, or a frame-ancestors grant where the console may embed you — see above) | deny (→ DENY, never overridden) | none (omit the header, for apps meant to be embedded)
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
| `import "@arrow-js/core"` will just work from anywhere | Bare imports resolve via the import map — vendor the file under `web/vendor/` or set `allow_cdn = true`. |
| Use a root-absolute asset path (`src="/app.js"`) because "the base tag handles it" | `<base>` only affects **relative** URLs. A root-absolute path skips the injected base, so a `build = "dist"` bundle loses its per-deployment prefix for that file. Write `./app.js`. |
| `[routing] path = "/notes"` so the URL says notes | The name is already in the hostname, and the declared base never appears in a URL — it only makes every route repeat it. Declare `path = "/"`. |
| Put a big video in `root` and serve it from a handler | Large assets auto-offload to object storage via redirect; just drop the file in `root`. |
| Ship a bare `<div id="app">` SPA with no head metadata | Crawlers and AI agents get nothing. Put title/description/OG + core copy in the served `index` HTML; add JSON-LD, `robots.txt`, `sitemap.xml`. GEO/SEO is a default, not a follow-up. |
| Hardcode `canonical`/`og:url`/`sitemap` to a guessed domain (e.g. `boogy.ai`, or whatever the user typed) before deploying | The app plane is `boogy.app`; the real URL is printed by `boogy deploy`. Fill absolute URLs from that output, not from a guess. A relative `href="./"` canonical also fails the dangling-reference gate. |
| "I'll deploy my Next.js/SvelteKit app" without checking which mode it builds in | Only the **fully-static** build deploys (`output: 'export'`, `adapter-static`, `nuxi generate`). There is no JS runtime, so SSR/RSC/server actions/middleware/`route.ts` handlers never run — port those to the wasm under `api_prefix`. |
| Point the framework's base option at the service name (`vite build --base=/todos/`) | Rejected at deploy, and correctly so — no URL carries the service's name as a path, so a baked-in prefix points nowhere. Use a **relative** base (`base: './'`); the host supplies the base via the injected `<base href>`. |
| "Deploy succeeded, so the page works" / treating a skipped `--smoke` as verification | A clean deploy only published + routed. `Smoke: skipped` verified nothing. Run `--smoke` with a real browser, or load the printed URL yourself, before claiming it renders. |
| Fold a reusable backend into this frontend service | If the API logic is generically useful, build it as its **own** (publicly provisionable) module — see `boogy:growing-boogy-meshes` — and keep this service the app-specific shell. |

## Integration

← Reach this from `boogy:designing-boogy-services` (the "does this need a UI?"
branch). → `boogy:boogy-rest-apis` builds the wasm API a FullStack frontend calls
(under `api_prefix`). → `boogy:boogy-auth` / `boogy:boogy-account-auth` for gating
that API and wiring a login the public shell renders. ↔ `boogy:boogy-capability-limits`
for the asset size limits + what's served where. → `boogy:boogy-custom-domains` when a framework
build needs root-serve (its root-absolute asset paths only resolve at the origin
root).
