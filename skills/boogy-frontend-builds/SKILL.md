---
name: boogy-frontend-builds
description: Use when a Boogy frontend uses a UI framework, a build tool or a vendored package (arrow-js, Preact, React, Vite, Astro, SvelteKit, Nuxt, a Next.js static export), when setting the build's base path, or when a page renders blank or its assets 404 at a nested route
---

# Frontend builds, frameworks and asset paths

Part of `boogy:boogy-serving-frontends`, which holds the `[frontend]` manifest, the `build = "source"` / `"dist"` modes and routing: read it first.

## arrow-js: the reference framework

[arrow-js](https://github.com/standardagents/arrow-js) is the recommended frontend
framework here precisely because it is **buildless and ES-module-native** — a tiny
reactive runtime you `import` directly, no compiler required. A minimal
`web/index.html` loads the entry module as a file:

```html
<!doctype html>
<html>
<head><meta charset="utf-8" /><title>Notes</title></head>
<body>
  <div id="app"></div>
  <script type="module" src="./app.js"></script>
</body>
</html>
```

and `web/app.ts` holds the code (served transpiled, as `./app.js`):

```ts
import { reactive, html } from "@arrow-js/core";   // resolved by the import map
const state = reactive({ notes: [] as { title: string }[] });
async function load() {
  const r = await fetch("./api/notes");            // same-origin → the wasm /api
  state.notes = (await r.json()).items ?? [];
}
html`<ul>${() => state.notes.map(n => html`<li>${n.title}</li>`)}</ul>`(
  document.getElementById("app")!);
load();
```

Include arrow-js at `web/vendor/@arrow-js/core.js`, or set `allow_cdn = true`.

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
catch it. The deploy smoke (`boogy:boogy-serving-frontends`) automates
exactly this check.

### Boolean attributes: prefer `checked="${…}"` over `.checked="${…}"`

In this arrow-js version, the **`.`-prefixed property binding** (`.checked`) can
throw under multiple bindings on one element (`Cannot use 'in' operator … '$on'`),
silently breaking the render. Use the **bare boolean-attribute binding**
(`checked="${() => done}"`) — it reflects state correctly and avoids the bug. Same
caution for other `.`-prefixed property bindings until the framework stabilizes.

## Asset paths at nested routes — the host injects `<base href>` for you

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
segment — see "Routing" in `boogy:boogy-serving-frontends`. You never write it.) The same holds on a custom
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
sub-resource) — not just the root. The deploy smoke checks the root by
default (`--smoke-path` checks another); if your app serves nested paths, also open one of those paths
yourself before calling the deploy done.

## Framework-built frontends (Vite, Astro, SvelteKit, Nuxt) → build with a RELATIVE base

A pre-built framework bundle is a perfectly good `[frontend].root`: point it at
the build output (`dist/`, `out/`, `build/`) and set `build = "dist"` so the
platform serves the files verbatim instead of transpiling them. Combined with a
Rust API under `api_prefix`, a FullStack deployment gives you the whole
page-plus-API shape in one deploy — same origin, no CORS, the app cookie riding
along automatically.

**Name the authored source.** The root now holds build output, so the manifest
also names the source it was built from, which the platform checks against the
`@boogy/web` conventions: `[frontend] source = ["index.html", "web"]` (paths
relative to `boogy.toml`). `boogy deploy` uploads it for the check only.

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
- **The smoke still needs the right selector on a framework build.** Its
  default (`#app,#root,#__next`) covers arrow-js, Vite/React and Next roots,
  and a selector that matches nothing now **fails** the check rather than
  falling back to `<body>` — but a build that mounts somewhere else entirely
  needs its own `--smoke-selector`, or the smoke fails even on a correctly
  rendered page.

### Keep each chunk under 256 KiB

Every script and stylesheet the build emits should stay under 256 KiB (the
platform's asset threshold; `boogy:boogy-serving-frontends` §"Asset sizes"
says why, and where the hard ceiling is). Make the build warn at the target,
and split where it does:

```ts
// vite.config.ts
export default defineConfig({
  build: { chunkSizeWarningLimit: 256 }, // kB: warn at the target, not at Vite's 500
  plugins: [preact(), ...boogyVite(dev)],
});
```

- **Split by route or feature** with dynamic `import()`: a screen, an editor,
  a chart library, a large data table load when first needed, each its own
  chunk.
- **Big static data** (a catalogue, a word list, a set of presets) goes in its
  own module, imported where it is used, never in the entry.
- **A vendor chunk** (`build.rollupOptions.output.manualChunks`) when the
  libraries together push the entry over the target.

Check the sizes in the build's output before deploying.

### Where the app is served from

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

## Red flags

| Reach / claim | Reality |
|---|---|
| `import "@arrow-js/core"` will just work from anywhere | Bare imports resolve via the import map — vendor the file under `web/vendor/` or set `allow_cdn = true`. `@boogy/web` is the one exception: it always resolves. |
| Use a root-absolute asset path (`src="/app.js"`) because "the base tag handles it" | `<base>` only affects **relative** URLs. A root-absolute path skips the injected base, so a `build = "dist"` bundle loses its per-deployment prefix for that file. Write `./app.js`. |
| "I'll deploy my Next.js/SvelteKit app" without checking which mode it builds in | Only the **fully-static** build deploys (`output: 'export'`, `adapter-static`, `nuxi generate`). There is no JS runtime, so SSR/RSC/server actions/middleware/`route.ts` handlers never run — port those to the wasm under `api_prefix`. |
| "The bundle is 600 KB but it's one request, so it's fine" | Keep every chunk under 256 KiB: split by route or feature with dynamic `import()`, and set `chunkSizeWarningLimit: 256` so the build tells you. |
| Point the framework's base option at the service name (`vite build --base=/todos/`) | Rejected at deploy, and correctly so — no URL carries the service's name as a path, so a baked-in prefix points nowhere. Use a **relative** base (`base: './'`); the host supplies the base via the injected `<base href>`. |

## Integration

↑ `boogy:boogy-serving-frontends`. → `boogy:boogy-capability-limits` for what cannot run (no JavaScript server). → `boogy:boogy-custom-domains` for root-serve on a domain of your own.
