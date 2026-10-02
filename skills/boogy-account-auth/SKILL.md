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
- **App plane** — a deployed service running at `<handle>.<base>/<service>`.
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
    once, is hard to change, and every service they ever deploy sits under it.
    The device flow presents the handle-choosing step, which is a second reason
    to prefer it; on the `register` path, ask them explicitly and wait. Full
    rule, with what to tell them while they choose: `boogy:using-boogy`,
    "Choosing a handle".
  - **A handle IS the subdomain**, so it must be a DNS label. Services are
    reached at `https://<handle>.<base>/<mount>/<path>`. The platform applies
    ONE rule on every path that creates a handle (the sign-in flow,
    `register`, agentkey):

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
    registers always routes — nothing is discovered later, at deploy.
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
Boogy"** — a PKCE authorization-code flow where the platform is the identity
provider. **This is NOT generic OAuth** — read the exact contract below and copy
it; do not extrapolate from OAuth defaults.

> ⚠️ **This is NOT generic OAuth.** There is **no** `client_id`, `response_type`,
> `redirect_uri`, `scope`, or `code_challenge_method` — those are ignored, and
> using them *instead of* the real params below gets you a `400 invalid
> authorization request`. The real param set is exactly: `aud`, `app_origin`,
> `redirect`, `state`, `code_challenge`, `mode`.

### The exact flow (drive it by hand)

Your app has a service at `<owner>.<base>/<service>` (e.g.
`alice.boogy.app/notes`). To sign a user in:

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
  ?aud=boogy://<owner>/services/<service>      # owner is the app's HANDLE (its subdomain label), NOT an agent id
  &app_origin=https://<owner>.<base>           # the app's own origin
  &redirect=<relative-path-on-the-app-origin>  # e.g. /notes/  — a path, NOT redirect_uri, NOT absolute
  &state=<csrf-nonce>
  &code_challenge=<base64url(SHA-256(verifier))>
  &mode=redirect                               # or "popup"
```

Concrete example (`alice`/`notes`, redirecting back to `/notes/`):
`https://auth.boogy.app/authorize?aud=boogy%3A%2F%2Falice%2Fservices%2Fnotes&app_origin=https%3A%2F%2Falice.boogy.app&redirect=%2Fnotes%2F&state=abc123&code_challenge=E9Melh…&mode=redirect`

**`aud` may name SEVERAL of the owner's services in one flow** — repeat the
parameter, or whitespace-separate the values inside one. That is how a page
framing several of an owner's apps signs into all of them with a single redirect
and a single consent decision, and the result is still **one** cookie (see the
cookie table below). Up to 32 per request; duplicates collapse. Every audience
must belong to the app origin's own owner — **one foreign `aud` refuses the whole
request**, never just that entry, so you cannot sign into two owners' apps at
once.

**3. The auth origin** logs the user in (Google / GitHub / passkey / password —
new users pick a handle) if no `__Host-boogy_session` exists, shows consent **if
it is needed**, mints a one-time code, and 302s to
`<app-origin>/boogy/callback?code=…&state=…`.

**Consent is only asked for an app someone ELSE owns.** Signing in to your own
app — every `aud` under your own handle — is auto-granted: you do not consent to
share your identity with yourself, and a twelve-pane board of your own would
otherwise ask you twelve times in one list. So when you are testing your own app
as its owner you will see no consent screen, and that is correct rather than a
missing step; sign in as a different account to exercise the consent path.

**4. The platform handles `<app-origin>/boogy/callback`** (this route is LIVE and
reserved — you do NOT implement it): it reads the code + `state` + your
`__Host-boogy_pkce` cookie, verifies PKCE, mints the app token, sets the **httpOnly,
Secure, host-only `__Host-boogy_app` cookie** (~15 min TTL), clears `__Host-boogy_pkce`,
and 302s to your `redirect` path (or `postMessage`s `{boogy:'sso_done'}` to the
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
| `400` even with all params present | `aud` owner ≠ the app_origin's **handle**; or `redirect` is an absolute URL / doesn't start with `/` |
| `403 token audience does not match target` after callback lands back on the app | The `aud` owner isn't the service's handle owner — it MUST be `boogy://<handle>/services/<service>` (the handle everywhere: `aud`, routing, and the audience check all agree on the handle form) |
| Sign-in never completes / app cookie missing | The `__Host-boogy_pkce` cookie wasn't set before the redirect — or was set as plain `boogy_pkce` (no longer read), or with a `Path` other than `/` (the browser silently drops a `__Host-` cookie then) |

### Owner form: always the handle

The `aud` owner segment, the `app_origin` subdomain, routing, and the dispatch-time
audience check all use the service's **handle** (e.g. `alice`) — the same value
everywhere. Do not use an internal id form for `aud`; a token whose `aud` owner
doesn't match the service's registered handle owner is rejected with 403 on every
request.

### Sign out / session

- `GET <app-origin>/boogy/me?service=<service>` → the current end-user session —
  `{ pairwiseId, services, connectedAt?, displayName, handle, avatarUrl }` — or `null` if
  not signed in to that service. `services` lists every one of this owner's
  services the session covers, so a page can tell which of its apps the person is
  signed in to without a probe each. `pairwiseId` is **per service**, so `?service=`
  is what makes it about YOUR app; it is `null` when the session covers several
  services and none was named, because handing a page another app's id would be a
  wrong answer rather than a partial one (`null` there still means signed in — the
  bare `null` body is what means "not signed in"). `handle` is set when your app
  is entitled to it (always for the person's own app, otherwise with their consent),
  `displayName` is their shared profile name or else that handle, and `avatarUrl`
  needs the shared profile — each `null` otherwise (see above); `connectedAt` is
  omitted if unavailable. Live route.
- `POST <app-origin>/boogy/logout` → clears the `__Host-boogy_app` cookie and
  returns `200 {"signedOut":"origin"}`. **Sign-out is all-or-nothing:** one cookie
  covers every app the person signed in to on that origin, so clearing it signs them
  out of all of them. A `?service=` is accepted but selects nothing — the response
  body names the scope that was actually applied. Live route.
  It also clears the renewal cookie (below), so a sign-out stays signed out.
- `POST <app-origin>/boogy/renew` → swaps the origin's **renewal cookie** for a fresh
  app session, with no page change: `200 {"services": [...]}` and a new
  `__Host-boogy_app`, or `401` (and the renewal cookie cleared) when there is nothing
  to renew. **Same-origin only** — call it from a page on the app's own origin
  (`fetch('/boogy/renew', {method:'POST'})`). It renews only the apps the person
  still has a grant for: revoking an app ends its renewal. Live route.
- The `__Host-boogy_app` token has a **~15 min TTL**, by design. On a `401` to a
  previously-authenticated call, **try `POST /boogy/renew` first**; re-run the
  `/authorize` redirect only if that fails — and **never from inside a frame** (a
  framed page cannot show the sign-in page, and a popup that flashes open and shut
  is not a sign-in). A framed app reports "signed out" to whatever frames it and
  lets that page sign it in.
- `GET <app-origin>/boogy/signin?aud=boogy://<owner>/services/<service>&redirect=<url>`
  (repeat `aud` for several apps) → starts the sign-in above from the app's own
  origin, with the PKCE verifier made **on the server** — for a page on ANOTHER
  origin that needs this one signed in, such as a board framing the owner's apps.
  It navigates to `/authorize` and back to `redirect`; it grants nothing
  `/authorize` would not. `400` for a bad link (no audience, one owned by someone
  else, more than 32, or a `redirect` the platform would refuse). Live route.

**Pairwise pseudonym:** the subject your service sees is `pw_…` — the same human
gets a **different** id at each service. The service can never recover the global
id. It's a path-independent fingerprint of `(user, service)`: the same user always
lands on the same pairwise whether they arrived directly or via a delegation chain.
Read it with `auth::current_principal()`. Because that returns an opaque string,
handler code is unchanged — `find_owned`/`owns_resource` scope rows by the `pw_…`
value (`find_owned` returns one bounded page plus a cursor, as it does for any
principal — see `boogy:boogy-auth`).

> ⚠️ **Do not read the session token's top-level `sub` and expect your pairwise.**
> One cookie covers several apps, so the token carries one subject **per app** and
> its top-level `sub` is not any app's — it is a fixed placeholder chosen so that
> reading it yields nothing usable rather than something plausible. The platform
> resolves the right subject for the app a request routed to, before your code runs.
> `current_principal()` is the only correct way to ask, and it always was; this is
> the assumption that stopped being safe.

**Your user's handle may be withheld because of a SIBLING app.** `current_handle()`
rides one claim on the one cookie and every app on the origin reads the same claim,
so the platform shares it only when the person has consented for **every** app the
session covers — otherwise sharing it with one would disclose it to the others. So
an app that had the handle can stop receiving it when the person signs in to a
sibling app under the same owner without consenting there. Treat `None` as normal
and never as an error: it already meant "not shared", and this is one more reason
for it. `current_principal()` is unaffected, so ownership and storage never change.

**Cookies — four names, never confused:**

| Cookie | Origin | Set by | Contents |
|---|---|---|---|
| `__Host-boogy_session` | `auth.<base>` (host-only, httpOnly) | auth origin | Bootstrap PASETO; proves platform login; **cannot call any app** |
| `__Host-boogy_app` | `<handle>.<base>` (host-only, httpOnly) | the callback | App PASETO covering a **set** of this owner's services, each with its own `pw_…` subject (~15 min). **One cookie for the origin, not one per app** — signing in to a second app adds it to the set rather than replacing it, so the request header stays the same size however many apps the person uses |
| `__Host-boogy_pkce` | `<handle>.<base>` (host-only, `Path=/`) | **you (the client)**, or `/boogy/signin` | The PKCE verifier; short-lived; consumed + cleared by the callback. `__Host-` so no other host can plant one |
| `__Host-boogy_renew` | `<handle>.<base>` (host-only, httpOnly, `SameSite=Strict`, Path=`/`) | the callback | Renewal token: swapped at `POST /boogy/renew` for a fresh `__Host-boogy_app`. Lives one platform-session length (24 h) from the sign-in that set it and **never slides**; covers no app itself, so it authorizes nothing but a renewal on this one origin |

> **`@boogy/web` browser SDK** wraps all of the above (`boogy.connectApp('<owner>/<service>')`,
> `boogy.fetch('<owner>/<service>', path)`). If it's available to you, prefer it;
> otherwise drive `/authorize` → `/boogy/callback` by hand exactly as above.

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
| "They're signing up mid-build — I'll pick a sensible handle from the project name and move on." | The handle is theirs, not the app's: an account username, chosen once, hard to change, and the subdomain every later service sits under. `register` will happily take whatever you send. Send them through the device flow's handle step, or ask and wait — `boogy:using-boogy`, "Choosing a handle". |
| "I'll mint `sk_*` keys as user sessions." | API keys aren't logins. Scoping every user to one service principal **breaks per-user isolation**. Send users through the SSO flow. |
| "I'll register an agent per Google user and issue their token." | Your service **cannot sign platform tokens** and must not duplicate identity inside one tenant. Use the platform SSO / OAuth flow. |
| "I'll store the user's password for re-auth." | Never. The platform owns credentials; your service only sees the resolved principal. Re-auth = send them through login again. |
| "There's no social login, only password/agentkey." | Wrong — social OAuth (Google/GitHub) is brokered at the platform bootstrap layer; end-users get it via the "Sign in with Boogy" SSO flow. |
| "After OAuth I'll read the token in JS and attach a Bearer header." | You can't — both `__Host-boogy_session` and `__Host-boogy_app` are **httpOnly** by design. You don't need to: a same-origin request sends the cookie automatically. Don't try to extract it. |
| "My global deploy token works fine for calling my deployed service." | A bare global Agent token is **rejected (403)** at a non-public app route — the control-plane/app-plane boundary. Use an SSO `__Host-boogy_app` cookie, an `sk_*` key on a public route, or add the service to the first-party allowlist. |
| "The session cookie's token `sub` is my app's pairwise id, so I can read it directly." | One cookie covers several of the owner's apps, so the token carries a subject **per app** and its top-level `sub` is none of them — it is a placeholder that resolves to nothing usable on purpose. Ask `auth::current_principal()`, which the platform has already resolved for the app the request reached. |
| "One cookie for several apps means signing in to the second signs me out of the first." | No — each sign-in UNIONS into the set. What it does mean is that **signing OUT signs you out of all of them**, and that a stolen cookie reaches every app in the set rather than one. |
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
