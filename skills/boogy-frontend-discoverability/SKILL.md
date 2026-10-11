---
name: boogy-frontend-discoverability
description: Use when a Boogy page must be found by search engines or AI crawlers, or previewed when its link is shared: titles, descriptions, OpenGraph and Twitter cards, canonical URLs, JSON-LD, robots.txt, sitemap.xml, or per-route metadata for a single-page app
---

# Discoverable frontends

Part of `boogy:boogy-serving-frontends`: read its core first.

## Discoverable by default — GEO/SEO is not optional

A frontend served on Boogy is a real public page; build it so search engines and
LLM/AI crawlers can find, read, and represent it. This is a **strong default**,
not a footnote — ship it unless the user explicitly wants a private/internal tool.

- **Document head, every page:** a unique, descriptive `<title>` and
  `<meta name="description">`; `<meta name="viewport">` (mandated by `boogy:boogy-serving-frontends`);
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

## Red flags

| Reach / claim | Reality |
|---|---|
| Ship a bare `<div id="app">` SPA with no head metadata | Crawlers and AI agents get nothing. Put title/description/OG + core copy in the served `index` HTML; add JSON-LD, `robots.txt`, `sitemap.xml`. GEO/SEO is a default, not a follow-up. |
| Hardcode `canonical`/`og:url`/`sitemap` to a guessed domain (e.g. `boogy.ai`, or whatever the user typed) before deploying | The app plane is `boogy.app`; the real URL is printed by `boogy deploy`. Fill absolute URLs from that output, not from a guess. A relative `href="./"` canonical also fails the dangling-reference gate. |

## Integration

↑ `boogy:boogy-serving-frontends`. → `boogy:boogy-frontend-builds` for a framework's static, prerendering build.
