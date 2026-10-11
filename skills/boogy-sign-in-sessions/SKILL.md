---
name: boogy-sign-in-sessions
description: Use when signing a person out, renewing or reading their app session (/boogy/me, /boogy/logout, /boogy/renew, /boogy/signin), driving the "Sign in with Boogy" redirect flow by hand (/authorize, PKCE, /boogy/callback), debugging a 400 at /authorize or a signed-in page whose API answers 401, or telling the platform's cookies apart
---

# Sign-in sessions: the calls, the cookies and the flow by hand

Part of `boogy:boogy-account-auth`, which holds the identity model and how a page signs in through the SDK: read it first.

## The classic flow — your service's own address, a custom domain or the boards origin (drive it by hand)

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

## Verify before you ship

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

## Owner form: always the handle

The `aud` owner segment, routing, and the dispatch-time audience check all use
the service's **handle** (e.g. `alice`) — the same value everywhere. Do not use
an internal id form for `aud`: an `aud` whose owner is not the origin's owner,
or whose service is not the one the origin serves, is refused at `/authorize`
with a `400` before any code is minted, so no session is ever set.

## Sign out / session

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
  `avatarUrl` needs the shared profile — each `null` otherwise (profile-share consent, `boogy:boogy-account-auth`);
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

## Integration

↑ `boogy:boogy-account-auth`. → `boogy:boogy-app-tokens` for a page on another website. → `boogy:running-in-a-board` for signing in a board's pane.
