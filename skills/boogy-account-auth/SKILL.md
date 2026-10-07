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
pairwise pseudonym. **This is NOT generic OAuth** — read the contract below; do
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
| **Another website** (`https://app.example.com`) that calls your service | the page itself, with an **app token** | `requestAppToken` / `appTokenSession` ("A page on another website", below); any service may allow it, with or without a frontend |

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
  navigated through.
- **Why a navigation to your own address is fine:** your page can register a
  service worker on its own address, and that worker could answer the
  navigation back to `/boogy/callback`. That gains your app nothing it could not
  already do as a website — it owns its tab — and the person enters
  credentials only on the platform's sign-in origin, never on yours.
- Your page then calls its own API same-origin, and `__Host-boogy_app` rides
  along. The `@boogy/web` README ("Signing in from a pane") has the pane API.

### A page on another website: app tokens

Any service — with or without a frontend — can let pages on **other websites**
sign people in and call it: a page on an origin the service's
`[ingress.cors] allowed_origins` names gets a short-lived **app token** and
calls the service with `Authorization: Bearer <token>`. The owner opts in per
website, with that list and `[ingress.app_tokens] redirect_uris`. A service
with a frontend then accepts two credentials: the cookie session of its own
pages, and app tokens from the websites it lists. It is authorization code with
PKCE for a public client:

1. The page, on origin `P`, keeps a PKCE verifier `V` and a `state` in its own
   `sessionStorage` and navigates to
   `<auth>/authorize?mode=token&aud=boogy://<owner>/services/<service>&client_origin=P&redirect=<a registered return URL on P>&code_challenge=<S256(V)>&state=<nonce>`.
2. `/authorize` admits it only when the service is live, `P` is listed **by
   name** in its `allowed_origins` (`"*"` admits no page), and `redirect` is
   **exactly** one of the URLs the service registers in
   `[ingress.app_tokens] redirect_uris` — byte for byte, so no extra query,
   other path or other spelling — on `P`.
   Consent names the service and `P`, offers no profile-sharing choice, and is
   recorded **per page**: allowing the service from one page does not let
   another page on its allowlist act as the person — that page is asked again
   — and never changes what the service sees of the person. It is skipped only
   when the person owns the service **and** `P` is one of that owner's own
   origins — the address of any service they hold, or a custom domain of
   theirs (another owner's service is a third-party page).
   Revoking the app forgets every page, and asks again — its owner included. It then
   `302`s to `redirect#state=…&code=…` — the code rides the fragment, so no
   server log or `Referer` sees it, and only the registered page receives it.
   A denial comes back as `#state=…&error=consent_denied`. The code is
   single-use and lives 60 seconds.
3. The page drops the fragment, checks `state`, and POSTs JSON
   `{"grant_type": "authorization_code", "code": …, "verifier": V}` to
   `<auth>/sso/token` with no credentials — exactly those fields: a body that
   names no `grant_type`, or carries a field its grant does not take, is a
   `401`. Only an `Origin` equal to `P` redeems it: another origin is a `403`
   that consumes nothing; an unknown, used or expired code, a wrong verifier, a
   service that no longer allows `P` at that return URL, a suspended account,
   or consent revoked meanwhile is a `401` with no detail. A sign-in the
   platform cannot complete after taking the code is a `503` saying to start
   sign-in again. The answer is `{"access_token", "token_type": "Bearer",
   "expires_in", "refresh_token", "refresh_expires_in"}` — never a cookie. The
   access token is **encrypted**: an opaque string that tells the page nothing
   about the person. The refresh token keeps the person signed in ("Staying
   signed in", below).
4. The page calls the service with `Authorization: Bearer <access_token>`, at
   the service's own address. Your service sees the same pairwise principal a cookie
   session gives — `auth::current_principal()` is unchanged. The token works
   at that one service only: anywhere else on the platform it authenticates
   nothing.

`@boogy/web` wraps it:
`requestAppToken({ service: '<owner>/<service>', redirect: '<a registered return URL>' })`
starts the trip, `completeAppToken()` on the page it returns to finishes it and
keeps the session (signing out, in the background, a sign-in to the same
service that this website already held), and `appTokenSession('<owner>/<service>')` hands the page a
live token from then on ("Staying signed in", below). Do not store a token
yourself.

**What the service's manifest must allow** — a browser preflights a request
carrying `Authorization`. The platform answers that preflight itself, from
`[ingress.cors]` (no need to route `OPTIONS`), and admits only the request
headers you list — an empty `allowed_headers` admits none:

```toml
[ingress]
mode = "authenticated"

[ingress.cors]
allowed_origins = ["https://app.example.com"]
allowed_headers = ["authorization", "content-type"]

[ingress.app_tokens]
redirect_uris = ["https://app.example.com/signed-in"]
```

`redirect_uris` holds 1 to 20 absolute URLs, each `https://` (`http://` only
for `localhost`), with no `#fragment` and no userinfo, written in canonical form
(`https://app.example.com/`, never `https://app.example.com`), on an origin
`allowed_origins` names — the deploy refuses anything else. Without the block,
no page can obtain a token for the service. The manifest key is `redirect_uris`;
the `/authorize` query parameter stays `redirect`.

#### Staying signed in: the refresh token

The access token lasts `BOOGY_APP_TOKEN_TTL_SECS` (15 minutes by default). The
refresh token renews it with no redirect, for as long as the person keeps
using the page: it lapses after `BOOGY_APP_REFRESH_TTL_SECS` (30 days by
default) **without a renewal**, and each renewal restarts that count — but
never past `BOOGY_APP_REFRESH_MAX_LIFETIME_SECS` (90 days by default) after the
sign-in, however often it is renewed. Each answer's `refresh_expires_in` is
what is left of whichever ends first. Use the SDK rather than handling it
yourself:

```ts
import { BoogyError, appTokenSession, requestAppToken } from '@boogy/web';

const SERVICE = 'alice/notes';
// `fetch` sends your access token to the URL you give it. WITHOUT `apiOrigin`
// that is any URL at all; with it, `fetch` refuses (`url_not_allowed`) any URL
// not on the service's origin and sends nothing. Pass only your service's URLs,
// or set `apiOrigin`.
const notes = appTokenSession(SERVICE, { apiOrigin: 'https://notes-k3v9.boogy.app' });

async function loadNotes() {
  if (!notes.signedIn()) return signIn(); // signIn() calls requestAppToken(...)
  try {
    // Bearer token attached; renewed first when it has 60 s or less left.
    const res = await notes.fetch('https://notes-k3v9.boogy.app/entries');
    return await res.json();
  } catch (e) {
    if (!(e instanceof BoogyError)) throw e;
    if (e.code === 'sign_in_required') return signIn(); // the sign-in is over
    throw e; // `network`: still signed in — the platform could not be reached
  }
}

// Sign out: revokes the sign-in at the platform and forgets it, in every tab.
const signOut = () => notes.signOut();
```

`apiOrigin` guards `fetch` only. `notes.accessToken()` hands the access token
itself to your code, and whatever you do with it — attach it to a request,
log it — is unguarded: send it only to the service it names.

**Every renewal ROTATES the refresh token.** The platform answers with a new
one, and the one presented is now retired. **Presenting a retired token — any
of them, not only the latest, within that token's own lifetime — ends the
whole sign-in**: the platform cannot tell the person's page from a thief
holding a copy, so neither keeps it, and it writes one critical entry to its
audit log. That holds at a renewal and at a sign-out alike, and it is why the
SDK never presents a token another renewal has already rotated, and sends the
current one once however many callers ask: callers in a tab share one renewal,
and every tab renews and signs out under one cross-tab lock, re-reading the
stored session first. (It does send the SAME token again after a `429`, a
`503` or a timeout — on purpose: see the table.)

**One exception: a lost answer.** If a renewal's answer never arrived, the page
still holds the token that renewal retired. For
`BOOGY_APP_REFRESH_GRACE_SECS` (60 s by default) after the rotation, while its
replacement has not been used, presenting the retired token again — to renew
or to sign out — is read as that lost answer: a renewal gets the SAME
replacement back, a sign-out is a sign-out, and no alarm is raised. Past the
minute, or once the replacement has been used, it is reuse as above. The SDK
gives up on a token request after 10 s so that several retries fit inside the
minute. The cost: inside it the platform cannot tell a lost answer from a
thief racing the person on one token (see the cost paragraph below).

**What the outcomes mean** (and how the SDK reacts, so your page does not have
to):

| Answer to a renewal | Means | SDK |
|---|---|---|
| `200` with a new pair | renewed; the old refresh token is retired | stores the pair |
| `401` | the platform decided: the sign-in is over (revoked, lapsed, refused, or a retired token) | forgets it; `sign_in_required` |
| `200` without a pair | the platform may already have rotated | forgets it; `sign_in_required` |
| `403` | the token was presented from another origin than the one it belongs to; nothing changed. It carries no CORS, so a browser page cannot read it | backs off, as for a `503` (a readable `400` or `403` would end the session; the refresh grant sends neither to a browser) |
| `429`, any `5xx` | nothing changed: a `429` is refused before the token is read, and the platform decides everything before it rotates. The one exception is a `503` for a rotation whose commit outcome was unknown: it may have landed, and then the retry within the grace is handed the same replacement | keeps the session, backs off 1 s doubling to 60 s (`Retry-After` honoured), then tries the SAME token again; `network` meanwhile |
| no readable answer — offline, no answer within 10 s, or a failure the browser hides from the page (the sign-in rate limiter's `429` carries no CORS) | unknown — the platform may have rotated. A retry that reaches it within the grace (a minute) gets the same replacement; a later one ends the sign-in | the same as a `503` |

**When the person must sign in again** — `sign_in_required`, and only then:
the refresh lifetime (30 days by default) passing without a renewal; the
absolute lifetime (90 days by default after the sign-in) passing, however
often it was renewed; a revoke (they signed out, disconnected the service
from their Boogy account, the service no longer allows this page, or their
account was suspended); more than **20** sign-ins to one service from one
website (one per browser, roughly — a 21st ends the one used least recently);
more than about 10,000 renewals in one refresh lifetime (far beyond a page
renewing once per default 15-minute access token); or theft detection. **A renewal whose answer was
lost** (the connection dropped after the platform rotated) ends it only if the
retry reaches the platform more than a minute after the rotation, or after the
replacement was used: the SDK retries only when the page next asks for a
token, so a page that stops asking can retry too late. Calling
`requestAppToken` again is silent while the person still allows this page.

**Driving it by hand** (a non-browser client, or a page without the SDK):
`POST <auth>/sso/token` with JSON `{"grant_type": "refresh_token",
"refresh_token": "brt_…"}`, the page's own `Origin`, and no other credential.
From another origin it is a `403` that changes nothing. Keep exactly ONE holder
per refresh token — two processes or two tabs sharing one will end it the
first time both renew — and never present a token after a renewal has
returned its replacement. Retry a `429`, a `5xx` or a request that got no
answer with the same token, and send the person to sign in on a `401`. Give
each request a short timeout and retry promptly: a renewal whose answer was
lost is handed the same replacement only for a minute after the rotation (the
SDK's 10 s timeout fits about four retries inside it). Sign out with
`POST <auth>/sso/token/revoke` and `{"refresh_token"}` from the same origin:
`200 {}` whether or not the token was live (it says nothing about which tokens
exist), `400 {"error": "invalid_request"}` for a body or token that is not
well-formed, `503` when the platform cannot record it (retry), and `403` from
another origin, changing nothing. A retired token presented there ends the
sign-in too.

**Where the session lives, and the cost.** The SDK keeps both tokens in the
page's `localStorage` (`boogy.app-token.session.v1:<owner>/<service>`), which
is what keeps a reload or a new tab signed in; a cookie the page cannot read is
not available, because the service and the platform are on other sites. Where
storage is refused, or the browser has no `navigator.locks`, the session lives
in the tab's memory instead and is not shared. **Any script running on the page
can read `localStorage`**, so a cross-site scripting bug or a compromised
third-party script can copy the refresh token. What limits it: rotation with
theft detection (whichever of the thief and the person presents a retired token
second ends it for both), origin binding (the platform accepts the token only
from this page's origin — which stops other web pages, not a program that
forges the header), the idle lapse (30 days by default), the absolute lifetime
(90 days by default), and revocation by the person at any time. A live access
token keeps working until it expires (15 minutes by default) even after a
revoke. Two limits to know:

- **A thief racing inside the grace shares the sign-in.** Anyone who presents
  the just-retired token inside the minute gets the same replacement, whether
  the requests overlap or come one after the other, and keeps getting each new
  one for as long as every retired token is presented within a minute of its
  rotation and before its replacement is used. The first presentation that
  comes later ends it with the alarm; the absolute lifetime ends it at the
  latest. It is not "until the next renewal".
- **A script that copies the token and deletes the page's copy is never
  detected.** No retired token is ever presented, so theft detection never
  fires; the person signs in again and the copy lives on beside the new
  sign-in. Only the absolute lifetime bounds it, unless the person
  disconnects the service from their Boogy account, which ends every sign-in
  to it.

Keep scripts you do not control off pages that hold a
session, and set a Content Security Policy. A browser app that wants an
httpOnly cookie instead puts its API under its own frontend's `api_prefix`.

### The classic flow — your service's own address, a custom domain or the boards origin (drive it by hand)

Your app is served on its own address (`notes-7k3q.boogy.app`), or on a
verified custom domain bound to it (`notes.example.com`) — either way an
origin that serves exactly one service, here `alice`'s `notes`.
`GET /boogy/signin` (below) does all of this for you; to sign a user in by
hand:

> ⚠️ **This is NOT generic OAuth.** There is **no** `client_id`, `response_type`,
> `redirect_uri`, `scope`, or `code_challenge_method` — those are ignored, and
> using them *instead of* the real params below gets you a `400 invalid
> authorization request`. The real param set is exactly: `aud`, `app_origin`,
> `redirect`, `state`, `code_challenge`, `mode`.

**1. Generate PKCE (client-side, S256) and stash the verifier in a cookie.**
The verifier stays on the app origin; the platform's callback reads it to
complete the exchange.

```js
// verifier: 32 random bytes, base64url; challenge = base64url(SHA-256(verifier))
const verifier  = base64url(crypto.getRandomValues(new Uint8Array(32)));
const challenge = base64url(new Uint8Array(
  await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier))));
const state = base64url(crypto.getRandomValues(new Uint8Array(16))); // CSRF nonce
// Short-lived, on THIS (app) origin. The `__Host-` name is REQUIRED — the
// callback reads no other — and the browser only keeps a `__Host-` cookie with
// Secure and Path=/ exactly, so no other host can plant a verifier here:
document.cookie =
  `__Host-boogy_pkce=${verifier}; Secure; SameSite=Lax; Path=/; Max-Age=300`;
```

**2. Redirect (or open a popup) to `/authorize` on the auth origin** with these
exact params:

```
https://auth.<base>/authorize
  ?aud=boogy://<owner>/services/<service>      # ONE service: the one this origin serves. owner is its HANDLE, not an agent id
  &app_origin=https://<this origin>            # this origin itself: the service's own address, its custom domain, or the boards origin
  &redirect=<relative-path-on-the-app-origin>  # e.g. /  — a path, NOT redirect_uri, NOT absolute
  &state=<csrf-nonce>
  &code_challenge=<base64url(SHA-256(verifier))>
  &mode=redirect                               # or "popup"
```

Concrete example (`notes.example.com` serving `alice`/`notes`):
`https://auth.boogy.app/authorize?aud=boogy%3A%2F%2Falice%2Fservices%2Fnotes&app_origin=https%3A%2F%2Fnotes.example.com&redirect=%2F&state=abc123&code_challenge=E9Melh…&mode=redirect`

**Exactly one `aud`**, and it must be the one service this origin serves — a
second `aud`, or another service of the same owner, is a `400`.

**3. The auth origin** logs the user in (Google / GitHub / passkey / password —
new users pick a handle) if no `__Host-boogy_session` exists, shows consent **if
it is needed**, mints a one-time code, and 302s to
`<app-origin>/boogy/callback?code=…&state=…`.

**Consent is only asked for an app someone ELSE owns.** Signing in to your own
app is auto-granted: you do not consent to share your identity with yourself.
So when you are testing your own app as its owner you will see no consent
screen, and that is correct rather than a missing step; sign in as a different
account to exercise the consent path.

The same implied consent has a consequence for revoking: a person who revokes
an app someone else owns stays signed out of it, since neither an older sign-in
code nor a renewal brings the grant back. If you revoke your OWN app, your next
sign-in to it makes the grant live again, because there is nothing to ask; a
renewal alone does not.

**Boards makes that sign-in for you.** Right after you sign in to Boards, it
signs in the apps on all of your boards, not only the open one, and any later
trip it makes for a pane is the same kind of sign-in. For an app you own, each of
those is your implied consent, so signing in to Boards makes a grant you
revoked live again for any of your own apps that sits on a board. To stay
signed out of your own app, take it off your boards before you sign in to
Boards again.

**4. The platform handles `<app-origin>/boogy/callback`** (this route is LIVE and
reserved — you do NOT implement it): it reads the code + `state` + your
`__Host-boogy_pkce` cookie, verifies PKCE, mints the app token, sets the **httpOnly,
Secure, host-only `__Host-boogy_app` cookie** (~15 min TTL) and its renewal
cookie, replacing any session the origin held, clears `__Host-boogy_pkce`, and
302s to your `redirect` path (or `postMessage`s `{boogy:'sso_done'}` to the
opener in `popup` mode).

**5. Subsequent same-origin `fetch()` sends `__Host-boogy_app` automatically.**
The service reads the pairwise pseudonym via `auth::current_principal()`. Don't
set `credentials`/`Authorization` — the cookie is httpOnly and same-origin.

### Profile-share consent: handle, name & photo

The consent screen in step 3 offers one pre-checked toggle bundling three
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
  `null` when it does not apply (see "Sign out / session" below).

> **Caution:** only the token handle (`current_handle()`) is trusted for
> identity. Never treat a `/boogy/me` value, or a handle a client hands you
> directly, as a unique or authoritative id — both are client-readable/-editable
> and can be spoofed (impersonation risk). Key ownership on
> `current_principal()`; use `current_handle()` for verified identity display
> or routing, never a `/boogy/me` field or client-supplied value.

### Verify before you ship

**`curl` your built `/authorize` URL and confirm it returns `200` (the sign-in
page), not `400`.** A `400 invalid authorization request` means a missing/malformed
param — the most common mistakes:

| Symptom | Cause |
|---|---|
| `400 invalid authorization request` at `/authorize` | Missing/empty `app_origin`, `redirect`, `state`, or `code_challenge`; or you sent `redirect_uri`/`response_type` (ignored) instead of `redirect`; or `mode` isn't `redirect`/`popup` |
| `400` even with all params present | `app_origin` is no app origin (an owner's handle is not one); more than one `aud`; `aud` is not the ONE service the origin serves; the origin's service is not deployed or not routed; `aud` owner ≠ the service's **handle**; or `redirect` is an absolute URL / doesn't start with `/` |
| Signed in, but your page's API calls answer `401` (gated routes) or run anonymously (public routes) | The origin's session does not name the service the request reached. A session covers exactly one service, and a cookie for any other reads as no session at all — never as a `403`. Call the API on the origin the person signed in on, and check `GET /boogy/me` there. (A **Bearer** app token is different: sent to a service it does not name, it is refused `403 token audience does not match target` — a header is the caller's own assertion, not ambient browser state.) |
| `400 invalid authorization request` at `/authorize?mode=token` | `client_origin` is not listed by name in the service's `[ingress.cors] allowed_origins` (a `"*"` entry does not count), or is not a bare origin (`https://host[:port]`, lowercase, no path); or `redirect` is not exactly one of the service's `[ingress.app_tokens] redirect_uris` on that origin (the service registers none, or the URL differs by a query, a path, a slash or a letter's case); or more than one `aud`, or a missing `state`/`code_challenge` |
| The page's Bearer call fails in the browser before reaching the service | The preflight was refused: the page's origin is not in `[ingress.cors] allowed_origins`, or `"authorization"` is not in `allowed_headers` (an empty list admits no request header) |
| Sign-in never completes / app cookie missing | The `__Host-boogy_pkce` cookie wasn't set before the redirect — or was set as plain `boogy_pkce` (no longer read), or with a `Path` other than `/` (the browser silently drops a `__Host-` cookie then) |
| A "this address has moved" page from `/boogy/me`, `/boogy/logout` or `/boogy/signin` | You called it on your handle's address, which is not an app's address. Call it on the origin your page is served on — the service's own address |

### Owner form: always the handle

The `aud` owner segment, routing, and the dispatch-time audience check all use
the service's **handle** (e.g. `alice`) — the same value everywhere. Do not use
an internal id form for `aud`: an `aud` whose owner is not the origin's owner,
or whose service is not the one the origin serves, is refused at `/authorize`
with a `400` before any code is minted, so no session is ever set.

### Sign out / session

These are served on the origin that holds the session — your service's own
address, a custom domain or the boards origin. Call them same-origin, from your
own page.

- `GET /boogy/me` → the current end-user session —
  `{ pairwiseId, connectedAt?, displayName, handle, avatarUrl }` — or `null` if
  not signed in. The session is your app's alone, so `pairwiseId` is your
  service's pairwise. (A query string is not read: the answer follows the cookie
  rule for the request, so a request the rule refuses, such as a cross-site one,
  reads `null`, exactly as it would to any other route.) `handle` is set when your app is
  entitled to it (always for the person's own app, otherwise with their
  consent), `displayName` is their shared profile name or else that handle, and
  `avatarUrl` needs the shared profile — each `null` otherwise (see above);
  `connectedAt` is omitted if unavailable. Live route.
- `POST /boogy/logout` → clears the origin's `__Host-boogy_app` cookie and its
  renewal cookie, and answers **`204`**. It signs the person out of this app —
  the one app the session covers — and nothing else. Live route.
- `POST /boogy/renew` → swaps the origin's **renewal cookie** for a fresh app
  session, with no page change: `200 {"service": "<id>"}` and a new
  `__Host-boogy_app`, or `401` (and the renewal cookie cleared) when there is
  nothing to renew. **Same-origin only** — `fetch('/boogy/renew', {method:'POST'})`
  from your own page. It renews only while the person still has a grant for the
  app: revoking it ends its renewal. Live route.
- The `__Host-boogy_app` token has a **~15 min TTL**, by design. On a `401` to a
  previously-authenticated call, **try `POST /boogy/renew` first** (the SDK's
  `fetch` does). If that fails: shown on its own, sign in again (`boogy.signIn()`, or the
  `/authorize` redirect); in a board pane, ask the board
  (`pane.requestSignIn()`). Never from inside a frame — a framed page cannot show the sign-in
  page, and a popup that flashes open and shut is not a sign-in.
- `GET /boogy/signin?aud=boogy://<owner>/services/<service>&redirect=<url>` —
  on the service's own address, a custom domain or the boards origin, with
  exactly one `aud` →
  starts the classic sign-in from that origin, with the PKCE verifier made **on
  the server**. It navigates to `/authorize` and back to `redirect`; it grants
  nothing `/authorize` would not. `400` for a bad link. Live route.

**Pairwise pseudonym:** the subject your service sees is `pw_…` — the same human
gets a **different** id at each service. The service can never recover the global
id. It's a path-independent fingerprint of `(user, service)`: the same user always
lands on the same pairwise whether they arrived directly or via a delegation chain.
Read it with `auth::current_principal()`. Because that returns an opaque string,
handler code is unchanged — `find_owned`/`owns_resource` scope rows by the `pw_…`
value (`find_owned` returns one bounded page plus a cursor, as it does for any
principal — see `boogy:boogy-auth`).

**Cookies — four names, never confused:**

| Cookie | Origin | Set by | Contents |
|---|---|---|---|
| `__Host-boogy_session` | `auth.<base>` (host-only, httpOnly) | auth origin | Bootstrap PASETO; proves platform login; **cannot call any app** |
| `__Host-boogy_app` | the app's origin — its own address, a custom domain, or boards (host-only, httpOnly) | the callback, or a board's exchange | App PASETO for **one** service, whose subject is that service's `pw_…` (~15 min). A new sign-in on the origin replaces it |
| `__Host-boogy_renew` | the same app origin (host-only, httpOnly, `SameSite=Strict`, Path=`/`) | the callback, or a board's exchange | Renewal token: swapped at `POST /boogy/renew` for a fresh `__Host-boogy_app`. Lives one platform-session length (24 h) from the sign-in that set it and **never slides**; covers no app itself, so it authorizes nothing but a renewal on this one origin |
| `__Host-boogy_pkce` | the app origin, classic flow only (host-only, `Path=/`) | **you (the client)**, or `/boogy/signin` | The classic flow's PKCE verifier; short-lived; consumed + cleared by the callback. `__Host-` so no other host can plant one |

> **`@boogy/web` browser SDK** starts the sign-in for you
> (`boogy.connectApp('<owner>/<service>')`, `boogy.fetch('<owner>/<service>', path)`,
> `pane.requestSignIn()`), but it runs none of the steps above itself: on the
> app's own address it navigates to `/boogy/signin`, and in a frame it asks the
> page framing it. It writes no PKCE cookie and opens no `/authorize` window. If
> it's available to you, prefer it; otherwise drive `/authorize` →
> `/boogy/callback` by hand exactly as above.

Social login (Google/GitHub) is brokered at the bootstrap level — an app gets
it for free without registering its own OAuth app.

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
origin during the "Sign in with Boogy" flow (step 2 above). Your app gets it
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
| "My API has no frontend, so I'll set `allowed_origins = ["*"]` and let any page get tokens." | `"*"` lets any page *call* a public API; it lets no page obtain a person's token. Name each page's origin. |
| "App tokens expire every 15 minutes, so I'll send people back through sign-in on a timer." | No: the code grant also returns a refresh token, and `appTokenSession` renews with it. A person is sent to sign in only on `sign_in_required`. |
| "I'll keep the refresh token myself and renew from several tabs, workers or processes." | Each renewal retires the token it sends, and a retired token presented again ends the sign-in for everyone. One holder per refresh token: use `appTokenSession` in a browser; in a headless client, one session per process. |
| "A renewal failed, so I'll sign the person out." | Only a readable `400`/`401`/`403` (or a `200` without a token pair) ends a sign-in. After a `429`, a `503` or a network failure, retry the same token — promptly: if the platform had rotated before the answer was lost, it hands the retry the same replacement for a minute, and a later retry ends the sign-in. |
| "I'll put two services under my custom domain and sign into both." | A custom domain binds ONE service id, and a session covers exactly one service. Give each service its own domain, or reach the second from your backend over the mesh. |
| "The session cookie's token `sub` is my app's pairwise id, so I'll read it in my page." | You can't — the cookie is httpOnly — and you don't need to: ask `auth::current_principal()` in the service, or `GET /boogy/me` in the page for display. |
| "The `pw_…` pairwise id needs special handling in my code." | It is an opaque string to your service — exactly like any other principal. `find_owned`/`owns_resource` work unchanged (and `find_owned` is paginated for a pairwise principal exactly as for any other). Never parse or assume the `pw_` prefix. |
| "If a user reaches my service via a chain, they get a different owner than a direct visit." | No — the pairwise is a fingerprint of `(user, your-service)`. Direct visit and chain arrival produce the same `pw_…`. |
| "I'll use a `/boogy/me` field (or a handle the client sends me) as a unique user id." | Only the token handle — `auth::current_handle()`, read server-side — is verified. `/boogy/me` fields and client-supplied handles are browser-readable/-editable and can be spoofed; treat neither as authoritative. |

## Integration

← `boogy:designing-boogy-services` picks the ingress mode that admits
these tokens. → `boogy:boogy-auth` is what you do with the principal
(ownership, scopes, the control-plane/app-plane boundary). → `boogy:boogy-obo-delegation` for one service
acting on a user's behalf in another. ↔ `boogy:boogy-serving-frontends`
for wiring this into a FullStack SPA — the page calls its same-origin API
and the `__Host-boogy_app` cookie rides along automatically.
