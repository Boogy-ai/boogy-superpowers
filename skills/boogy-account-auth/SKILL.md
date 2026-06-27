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
session (`boogy_app` cookie), an `sk_*` API key on a `public`-ingress route, or
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
  - **A handle IS the subdomain** — it must be a DNS label: lowercase
    `[a-z0-9-]`, **3–30 characters** (no `_`, `.`, or spaces). Services are
    reached at `https://<handle>.<base>/<service>/<path>`. Registration coerces
    fixable input to a valid label (`my_app` → `my-app`) and returns the final
    handle; reserved or already-taken handles are rejected so the user picks
    another. A handle that isn't a valid label would be unroutable — enforced
    at registration, not discovered at deploy.
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

## Sign in with Boogy — end-user app-plane SSO (new)

For end-users of a **deployed app** (app-plane), the flow is
**"Sign in with Boogy"** — an authorization-code flow where the platform
acts as the identity provider:

1. The app (via the `@boogy/web` browser SDK — **forthcoming; not yet built**,
   or driven manually) opens `https://auth.<base>/authorize?aud=<service-workload-uri>&…` in a
   popup (full-redirect fallback when popups are blocked).
2. The auth origin handles login (passkey / password / social) if no
   bootstrap session (`__Host-boogy_session`) exists, then shows consent.
3. The auth origin mints a one-time authorization code and redirects to the
   app origin's `/boogy/callback`.
4. The **host intercepts `/boogy/callback`**, exchanges the code in-process
   (PKCE; no network hop), and sets an httpOnly, host-only **`boogy_app` cookie**
   on the app origin — then 302s back to the original path.
5. Subsequent same-origin requests carry the cookie automatically.
   `auth_middleware` reads it; the wasm sees the **pairwise pseudonym** via
   `auth::current_principal()`.

**Pairwise pseudonym:** the `sub` in every `boogy_app` token is `pw_…` — the
same human gets a **different** id at each service. The service can never recover
the global id. The mask is a path-independent fingerprint of `(user, service)`:
the same user always lands on the same pairwise at a given service whether they
visited directly or arrived via a delegation chain. Because `current_principal()`
returns an opaque string, handler code is unchanged — `find_owned`/`owns_resource`
scope rows by the `pw_…` value with no SDK changes.

**Two cookies, two origins, never shared:**

| Cookie | Origin | Contents |
|---|---|---|
| `__Host-boogy_session` | `auth.<base>` (host-only, httpOnly) | Bootstrap PASETO; proves platform login; **cannot call any app** |
| `boogy_app` | `<handle>.<base>` (host-only, httpOnly) | App PASETO (`aud` = one service, `sub` = `pw_…`; ~15 min TTL); grants exactly one service |

> **`@boogy/web` SDK is forthcoming (not yet built).** Until it ships, a
> consuming app drives `/authorize` → `/boogy/callback` by hand. Treat any
> reference to `@boogy/web` as pending.

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
| "I'll mint `sk_*` keys as user sessions." | API keys aren't logins. Scoping every user to one service principal **breaks per-user isolation**. Send users through the SSO flow. |
| "I'll register an agent per Google user and issue their token." | Your service **cannot sign platform tokens** and must not duplicate identity inside one tenant. Use the platform SSO / OAuth flow. |
| "I'll store the user's password for re-auth." | Never. The platform owns credentials; your service only sees the resolved principal. Re-auth = send them through login again. |
| "There's no social login, only password/agentkey." | Wrong — social OAuth (Google/GitHub) is brokered at the platform bootstrap layer; end-users get it via the "Sign in with Boogy" SSO flow. |
| "After OAuth I'll read the token in JS and attach a Bearer header." | You can't — both `__Host-boogy_session` and `boogy_app` are **httpOnly** by design. You don't need to: a same-origin request sends the cookie automatically. Don't try to extract it. |
| "My global deploy token works fine for calling my deployed service." | A bare global Agent token is **rejected (403)** at a non-public app route — the control-plane/app-plane boundary. Use an SSO `boogy_app` cookie, an `sk_*` key on a public route, or add the service to the first-party allowlist. |
| "The `pw_…` pairwise id needs special handling in my code." | It is an opaque string to your service — exactly like any other principal. `find_owned`/`owns_resource` work unchanged. Never parse or assume the `pw_` prefix. |
| "If a user reaches my service via a chain, they get a different owner than a direct visit." | No — the pairwise is a fingerprint of `(user, your-service)`. Direct visit and chain arrival produce the same `pw_…`. |

## Integration

← `boogy:designing-boogy-services` picks the ingress mode that admits
these tokens. → `boogy:boogy-auth` is what you do with the principal
(ownership, scopes, the control-plane/app-plane boundary). → `boogy:boogy-obo-delegation` for one service
acting on a user's behalf in another. ↔ `boogy:boogy-serving-frontends`
for wiring this into a FullStack SPA — the page calls its same-origin API
and the `boogy_app` cookie rides along automatically.
