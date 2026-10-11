---
name: boogy-app-tokens
description: Use when a page on another website (not the service's own address) must sign people in and call a Boogy service, a service with no frontend serves browser clients, or wiring [ingress.app_tokens] redirect_uris, requestAppToken, appTokenSession, refresh tokens or a 403 token audience mismatch
---

# App tokens: signing in from another website

Part of `boogy:boogy-account-auth`, which holds the identity model and the session on a service's own origin: read it first.

## A page on another website: app tokens

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

### Staying signed in: the refresh token

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

## Red flags

| Thought | Reality |
|---|---|
| "My API has no frontend, so I'll set `allowed_origins = ["*"]` and let any page get tokens." | `"*"` lets any page *call* a public API; it lets no page obtain a person's token. Name each page's origin. |
| "App tokens expire every 15 minutes, so I'll send people back through sign-in on a timer." | No: the code grant also returns a refresh token, and `appTokenSession` renews with it. A person is sent to sign in only on `sign_in_required`. |
| "I'll keep the refresh token myself and renew from several tabs, workers or processes." | Each renewal retires the token it sends, and a retired token presented again ends the sign-in for everyone. One holder per refresh token: use `appTokenSession` in a browser; in a headless client, one session per process. |
| "A renewal failed, so I'll sign the person out." | Only a readable `400`/`401`/`403` (or a `200` without a token pair) ends a sign-in. After a `429`, a `503` or a network failure, retry the same token — promptly: if the platform had rotated before the answer was lost, it hands the retry the same replacement for a minute, and a later retry ends the sign-in. |

## Integration

↑ `boogy:boogy-account-auth`. → `boogy:boogy-frontend-security` for `[ingress.cors]`. → `boogy:boogy-auth` for what the service does with the principal.
