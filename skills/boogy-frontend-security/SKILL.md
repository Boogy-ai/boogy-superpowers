---
name: boogy-frontend-security
description: Use when a Boogy page is framed in a board or console, opens OAuth or payment pages, needs camera, microphone or geolocation, sets a Content-Security-Policy or frame options, is called from another website (CORS), keeps data in browser storage, or wants another app's data from the browser
---

# A frontend's origin, framing and headers

Part of `boogy:boogy-serving-frontends`: read its core first.

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
  it.** (Its Back/Forward, reload and the board's size: `boogy:running-in-a-board`.) The board's frame is sandboxed with no top-level navigation of any
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
- **Use relative paths, never a hard-coded prefix.** The asset-path rule
  (write `./app.js`, never `/<service-id>/app.js`; `boogy:boogy-serving-frontends`) applies to anything that
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

Every page that is not standalone-only declares `[boards] background = "board"`, so a board's background shows through it in a pane (`boogy:running-in-a-board`).

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

## Integration

↑ `boogy:boogy-serving-frontends`. → `boogy:running-in-a-board` for a page in a board's pane. → `boogy:boogy-account-auth` for signing in. → `boogy:boogy-mesh-architecture` for another service's data, from your backend.
