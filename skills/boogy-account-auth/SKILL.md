---
name: boogy-account-auth
description: Use when wiring login or signup for a service's users, or asking where principals and tokens come from
---

# Boogy account auth (platform identity)

Identity on Boogy is **two layers**. Keep them separate or you'll
re-implement — badly — what the platform already owns.

1. **Platform accounts** (who the user is) — the platform owns
   registration, login, and token minting. Users get accounts and
   tokens from the platform's account surface, **not from your service**.
2. **In-service authorization** (what they may touch) — your service
   reads the resolved principal and scopes rows to it. That's
   `boogy:boogy-auth`. This skill is about layer 1.

## Two tiers of identity — control plane vs app plane

Boogy has **two planes**, and credentials for one are not accepted on the other.

- **Control plane** — deploying services, the console, admin, account management
  (`/v1`, `/_admin`, `/_agents`). A **global `Agent`** credential lives here:
  `agent_<uuid>`, stable everywhere, minted at `/_agents/login`. This is *you,
  to Boogy*.
- **App plane** — a deployed service: its API and its pages, at the root of the
  service's own address (`https://notes-7k3q.boogy.app/`).
  An **app-scoped Agent** credential lives here: internally the same real agent,
  but masked at each tenant-service boundary to a `pw_…` pairwise pseudonym —
  different at each service for the same human, one-way (the service can never
  recover the global id). This is *you, masked per service, to someone else's app*.

**A bare global Agent token is rejected (403) at a non-public tenant route.**
The separation is enforced at tenant dispatch, not at token minting — login
tokens stay the same. Accepted at non-public app routes: an app-scoped SSO
session (`__Host-boogy_app` cookie), an `sk_*` API key on a `public`-ingress route, or
an OBO workload credential.

The third principal, **`Workload`** (`boogy://owner/services/name`), covers
service-to-service calls in the mesh (unchanged — see `boogy:boogy-obo-delegation`).

## How a user gets a token (control-plane / developer identity)

The platform exposes a self-serve account surface (mounted at
`/_agents` on the host):

- **Create an account / pick a handle** — A first-time user normally goes
  through the **OAuth device-flow sign-in** (`boogy login` CLI / the `login`
  MCP tool), which handles both authentication and handle selection in one
  step. `POST /_agents/register` (handle + password) and the passkey/agentkey
  endpoints remain available as alternative registration paths (useful for
  headless agents or non-OAuth setups), but they are not the primary path.
  - **The person picks the handle — an agent never picks it for them.** It is
    their account's username, not the name of the app being built; it is chosen
    once, is hard to change, and every service they ever deploy belongs to it.
    The device flow presents the handle-choosing step, which is a second reason
    to prefer it; on the `register` path, ask them explicitly and wait. Full
    rule, with what to tell them while they choose: `boogy:using-boogy`,
    "Choosing a handle".
  - **A handle keeps a DNS label's shape, but it is not a hostname.** Each
    service is reached at an address of its own, `https://<name>-<suffix>.<base>/`
    (`boogy:using-boogy`); the handle names the account in every service's
    identity, `boogy://<handle>/services/<id>`. The platform applies ONE rule
    on every path that creates a handle (the sign-in flow, `register`,
    agentkey):

    | Rule | Detail |
    |---|---|
    | **Length** | **4 to 30 characters**, counted AFTER the fixes below. |
    | **Characters** | lowercase `a-z`, digits `0-9`, and `-`. No `-` at either end. |
    | **Fixed for them** | uppercase → lowercase; `_`, `.`, spaces and any other character → `-`; runs of `-` → one `-`; a leading `@` is dropped. `My_App` → `my-app`. |
    | **Refused** | under 4 or over 30 after fixing (never padded, never cut short); reserved platform names (`api`, `www`, `admin`, `auth`, `mail`, …). |
    | **Taken** | a handle someone already holds: `409 handle_taken`, so they pick another. |

    Because the length is counted after fixing, what counts is the handle the
    person will actually get: `a_b_` is four characters typed but `a-b`
    stored, so it is refused. A rule refusal is `400 invalid_handle` with
    the reason in `detail` (`handle is too short (minimum 4 characters)`,
    `handle is too long (maximum 30 characters)`, `handle is reserved`) —
    relay that text; don't guess at it. On success the response carries the
    FINAL handle: show it to the person, because it may differ from what
    they typed. All of this is enforced at registration, so a handle that
    registers is always usable — nothing is discovered later, at deploy.
- **Log in** — get back a bearer **token** + the account record.
- **Use it** — the client presents that token on every request. *How* it's
  presented depends on the login method (see the transport column below): a
  readable `Authorization: Bearer …` header for password/passkey/agentkey, or
  an HttpOnly `__Host-boogy_session` cookie for the browser OAuth flow. Either way the
  platform resolves it to the same principal.

The token is a signed, opaque bearer credential (a `v4.public.…` PASETO).
**Only the platform can mint it** — your service cannot sign one and
must not try.

> **Scope:** this token is valid on the **control plane** (deploy, console,
> admin). It is NOT accepted at a deployed app's non-public routes — see
> "Sign in with Boogy" below for the app-plane flow.

## Login methods — all converge

Every method below runs through the **same single token-minting path**,
so they all produce the same token shape and the same opaque principal:

| Method | What it is | Token transport |
|---|---|---|
| Password | handle + password | token in response body → client sets `Authorization: Bearer` |
| Passkey | WebAuthn (`/_agents/passkey/*`) | token in response body → `Authorization: Bearer` |
| Agentkey | Ed25519 challenge for headless agents (`/_agents/agentkey/*`) | token in response body → `Authorization: Bearer` |
| Social OAuth | "Sign in with X" (`/_agents/oauth/*`) | **HttpOnly `__Host-boogy_session` cookie** set on the callback redirect — JS never sees the token |

**Providers live today: Google and GitHub** (plus a generic OIDC provider for
self-hosted / enterprise issuers), each enabled by setting its client-id +
secret env vars on the host. TikTok, X, and LinkedIn are scaffolded but not
wired — don't promise those.

### Transport: header vs. cookie — same principal either way

The login method differs in *how the token reaches your service*, but the
platform resolves **both** transports to the same opaque principal before your
code runs, so your service treats them identically:

- **`Authorization: Bearer <token>`** — the primary path, and it always wins
  when present. Password/passkey/agentkey logins return the token in the
  response body and the client sets this header.
- **`__Host-boogy_session` cookie** — the fallback, used by the browser OAuth flow
  (which can't hand a token to JS). The host reads it only when no
  `Authorization` header is present. **Service ingress resolves the
  `__Host-boogy_session` cookie to the principal exactly like a Bearer token** — your
  `authenticated`/owner-scoped routes work unchanged whether the caller sent a
  header or rode the cookie.

## Sign in with Boogy — end-user app-plane SSO

For end-users of a **deployed app** (app-plane), the flow is **"Sign in with
Boogy"**: the platform is the identity provider, the person's session lands as
an httpOnly cookie on the app's origin, and your service sees a per-service
pairwise pseudonym. **This is NOT generic OAuth** — read the contract below (and
`boogy:boogy-sign-in-sessions` for the flow by hand); do
not extrapolate from OAuth defaults.

### Which origin holds the session — and who signs it in

**An app session lives only on an origin that serves exactly ONE service, and
covers exactly that one service** — and every origin that serves a service
serves exactly one. Every service has its own address,
`https://<name>-<suffix>.<base>` (read it from the `boogy deploy` output);
where your page runs decides who signs it in:

| Your page is served on | Who signs it in | What your code does |
|---|---|---|
| **Its own address**, open in a tab | the classic flow, on that address: `/boogy/signin` → `/authorize` → `/boogy/callback` | a "Sign in" button calling `boogy.signIn()` (or `boogy.connectApp('<owner>/<service>')`), which navigates to the address's own `/boogy/signin` |
| **Its own address, as a pane in a board** (`boards.<base>` frames it) | the board, through a background exchange that never navigates into the pane | report "signed out" (`pane.reportAuthState(false)`), and give the person a button that calls `pane.requestSignIn()` or `boogy.signIn()`, which ask the board |
| **A verified custom domain** bound to the service, or the platform's **boards** origin | the classic flow, on that origin | the same calls as on its own address |
| **Another website** (`https://app.example.com`) that calls your service | the page itself, with an **app token** | `requestAppToken` / `appTokenSession` (`boogy:boogy-app-tokens`); any service may allow it, with or without a frontend |

**A tab and a board pane of the same address share one session**, because
they are one origin: signing in in either signs the other in on its next
request, and signing out in either signs both out.

**An owner's handle is not an address.** Nothing is served at
`<your handle>.boogy.app` — it answers every request, `/boogy/*` included, with a
page saying apps have their own addresses — so no sign-in can happen there.

**A custom domain binds one service id**, so it signs people in for exactly
that service. To serve a second service on a domain of your own, give it a
second domain.

### On your service's own address (the usual case)

- **Shown on its own** (in a tab): `boogy.signIn()` checks the address's own
  `GET /boogy/me` first, so a signed-in app asks nothing, and otherwise
  navigates to the address's own `/boogy/signin`, which runs the classic flow
  and comes back to the page the person was on. It always navigates (a
  redirect, never a popup). **Nothing signs an app in on its own**, so a sign-out stays
  signed out: show a "Sign in" button.
- **In a board pane:** a framed page never navigates. `pane.requestSignIn()`
  (or `boogy.signIn()`, which asks the same way in a frame) resolves
  `'leaving'` (the board is signing in now), `'already_signed_in'`,
  `{ busy: ms }` (a trip for this app went in the last 15 seconds — say so and
  let them retry), or `'unavailable'` (nothing framing the app can sign it in —
  link the person to the app's own address, in a new window). A board signs in
  every pane it shows through one trip from `boards.<base>`, so no pane is ever
  navigated through. Connect with `connectPane({ service, signsIn: true })` in
  an app that signs people in: the board then keeps the pane covered until the
  app reports signed in, so the app's signed-out view (and its "Sign in"
  button) is shown in a board only when the board cannot sign it in.
- **Why a navigation to your own address is fine:** your page can register a
  service worker on its own address, and that worker could answer the
  navigation back to `/boogy/callback`. That gains your app nothing it could not
  already do as a website — it owns its tab — and the person enters
  credentials only on the platform's sign-in origin, never on yours.
- Your page then calls its own API same-origin, and `__Host-boogy_app` rides
  along. The `@boogy/web` README ("Signing in from a pane") has the pane API.

### The session on your origin

Your page needs only four calls on its own origin, all same-origin:
`GET /boogy/me` (who is signed in, or `null`), `POST /boogy/logout` (signs out
of this app, `204`), `POST /boogy/renew` (a fresh app session from the renewal
cookie; the SDK's `fetch` calls it on a `401`) and `GET /boogy/signin` (starts
sign-in). The app session lasts about 15 minutes and renews for a day. Each
call in full, the cookies, the hand-driven flow and what a `400` at
`/authorize` means: `boogy:boogy-sign-in-sessions`.


### Profile-share consent: handle, name & photo

The consent screen at sign-in offers one pre-checked toggle bundling three
things: the user's **handle**, display name, and photo. If it stays checked
(default) — or the user re-enables it later from their connected-apps
settings — your app gets two different channels for it:

- **The handle — trusted, server-side.** Read it in your wasm via
  `auth::current_handle() -> Option<String>` (see `boogy:boogy-auth`). It
  rides the signed app token as a claim, so it's safe to treat as the user's
  real, verified identity. `None` if they declined to share.
- **Name + photo — browser-readable, via `/boogy/me`.** Fetch
  `GET <app-origin>/boogy/me` for `displayName`, `handle` and `avatarUrl`.
  `handle` is the same handle the token carries, so it is there exactly when
  your app is entitled to it: always for the person's OWN app, otherwise only
  with their consent to share their identity. `displayName` is the profile name
  they shared, falling back to that handle — so "who is signed in" has a name to
  show without anyone setting one. `avatarUrl` needs the shared profile. Each is
  `null` when it does not apply (`GET /boogy/me` in `boogy:boogy-sign-in-sessions`).

> **Caution:** only the token handle (`current_handle()`) is trusted for
> identity. Never treat a `/boogy/me` value, or a handle a client hands you
> directly, as a unique or authoritative id — both are client-readable/-editable
> and can be spoofed (impersonation risk). Key ownership on
> `current_principal()`; use `current_handle()` for verified identity display
> or routing, never a `/boogy/me` field or client-supplied value.

## How your service consumes end-user identity

Grant the `auth` capability in your manifest, then read
`auth::current_principal() -> Option<String>`. That value is the SAME
whether the end-user arrived via SSO (`pw_…` pairwise id), a password/passkey
login (platform operator), or a programmatic `sk_*` API key — the platform
resolves the verified credential into one opaque string before your code runs.

The principal is **opaque**: never parse it, prefix-strip it, or assume
it's a UUID. Use it only as your owner-column value and as input to the
`auth::*` helpers (see `boogy:boogy-auth`). A `pw_…` pairwise id works
identically to any other principal as an owner-column value.

Your service **never** sees the password, the passkey, or the OAuth
provider token. It only ever sees the resolved principal.

## Sign-in-with-Google: the real answer

**For control-plane logins (developer / operator identity)** — Google OAuth
is handled at the bootstrap layer. You do NOT implement it in your service.

Social login (Google/GitHub) for **end-users of a deployed app** is also
handled by the platform: it is brokered at the bootstrap layer on the auth
origin during the "Sign in with Boogy" flow. Your app gets it
for free and never registers its own Google OAuth app.

Specifically for bootstrap (control-plane) OAuth:

1. Your front-end asks the platform what's available
   (`GET /_agents/oauth/providers`) and offers a "Sign in with Google"
   button.
2. The button sends the user into the platform flow
   (`/_agents/oauth/google/start?return_to=<url>`). The platform handles the
   redirect, the callback, and find-or-create of the account.
3. On success the platform's callback sets an **HttpOnly `__Host-boogy_session`
   cookie** on the auth origin — the same platform token any other login
   yields. For control-plane use (developer console), that cookie is the
   credential.

For app-plane (end-user) use the "Sign in with Boogy" SSO flow above is the
correct path — the `__Host-boogy_session` bootstrap cookie lands on the auth origin
and cannot directly call a deployed app.

## Red flags

| Thought | Reality |
|---|---|
| "They're signing up mid-build — I'll pick a sensible handle from the project name and move on." | The handle is theirs, not the app's: an account username, chosen once, hard to change, and the account every later service belongs to. `register` will happily take whatever you send. Send them through the device flow's handle step, or ask and wait — `boogy:using-boogy`, "Choosing a handle". |
| "I'll mint `sk_*` keys as user sessions." | API keys aren't logins. Scoping every user to one service principal **breaks per-user isolation**. Send users through the SSO flow. |
| "I'll register an agent per Google user and issue their token." | Your service **cannot sign platform tokens** and must not duplicate identity inside one tenant. Use the platform SSO / OAuth flow. |
| "I'll store the user's password for re-auth." | Never. The platform owns credentials; your service only sees the resolved principal. Re-auth = send them through login again. |
| "There's no social login, only password/agentkey." | Wrong — social OAuth (Google/GitHub) is brokered at the platform bootstrap layer; end-users get it via the "Sign in with Boogy" SSO flow. |
| "After OAuth I'll read the token in JS and attach a Bearer header." | You can't — both `__Host-boogy_session` and `__Host-boogy_app` are **httpOnly** by design. You don't need to: a same-origin request sends the cookie automatically. Don't try to extract it. The one JS-held token is the **app token** a page on another website obtains through `/authorize?mode=token` — never extracted from a cookie. |
| "My global deploy token works fine for calling my deployed service." | A bare global Agent token is **rejected (403)** at a non-public app route — the control-plane/app-plane boundary. Use an SSO `__Host-boogy_app` cookie, an `sk_*` key on a public route, or add the service to the first-party allowlist. |
| "I'll redirect to `/authorize` from inside a board pane." | A framed page cannot show the sign-in page, and its frame grants no top-level navigation. Report signed-out and call `pane.requestSignIn()` (or `boogy.signIn()`) from a button: the board signs the pane in. Shown on its own address, `boogy.signIn()` navigates to the classic flow itself. |
| "I'll sign browser users in at my handle's address, with the service name as a path." | A handle is not an address: that host answers every request with a "this address has moved" page. Browser sign-in happens on the origin the page is served on — the service's own address or its custom domain — or, for a page on another website, through an app token. |
| "I'll put two services under my custom domain and sign into both." | A custom domain binds ONE service id, and a session covers exactly one service. Give each service its own domain, or reach the second from your backend over the mesh. |
| "The session cookie's token `sub` is my app's pairwise id, so I'll read it in my page." | You can't — the cookie is httpOnly — and you don't need to: ask `auth::current_principal()` in the service, or `GET /boogy/me` in the page for display. |
| "The `pw_…` pairwise id needs special handling in my code." | It is an opaque string to your service — exactly like any other principal. `find_owned`/`owns_resource` work unchanged (and `find_owned` is paginated for a pairwise principal exactly as for any other). Never parse or assume the `pw_` prefix. |
| "If a user reaches my service via a chain, they get a different owner than a direct visit." | No — the pairwise is a fingerprint of `(user, your-service)`. Direct visit and chain arrival produce the same `pw_…`. |
| "I'll use a `/boogy/me` field (or a handle the client sends me) as a unique user id." | Only the token handle — `auth::current_handle()`, read server-side — is verified. `/boogy/me` fields and client-supplied handles are browser-readable/-editable and can be spoofed; treat neither as authoritative. |
| "A page on another website must sign people in, so I'll proxy the cookie." | A cookie never crosses origins. The page gets an app token: `boogy:boogy-app-tokens`. |

## Integration

← `boogy:designing-boogy-services` picks the ingress mode that admits
these tokens. → `boogy:boogy-auth` is what you do with the principal
(ownership, scopes, the control-plane/app-plane boundary). → `boogy:boogy-obo-delegation` for one service
acting on a user's behalf in another. ↓ Its parts: `boogy:boogy-app-tokens`
(a page on another website) and `boogy:boogy-sign-in-sessions` (the session
calls, the cookies, the hand-driven flow). ↔ `boogy:boogy-serving-frontends`
for wiring this into a FullStack SPA — the page calls its same-origin API
and the `__Host-boogy_app` cookie rides along automatically.
