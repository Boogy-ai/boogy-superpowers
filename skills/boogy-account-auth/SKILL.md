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

## How a user gets a token

The platform exposes a self-serve account surface (mounted at
`/_agents` on the host):

- **Register** — `POST /_agents/register` with a handle + password (or
  for headless agents, register a keypair). Creates the account.
- **Log in** — get back a bearer **token** + the account record.
- **Use it** — the client sends that token as `Authorization: Bearer …`
  on every request to your service.

The token is a signed, opaque bearer credential (a `v4.public.…` PASETO).
**Only the platform can mint it** — your service cannot sign one and
must not try.

## Login methods — all converge

Every method below runs through the **same single token-minting path**,
so they all produce the same token shape and the same opaque principal:

| Method | What it is |
|---|---|
| Password | handle + password |
| Passkey | WebAuthn (`/_agents/passkey/*`) |
| Agentkey | Ed25519 challenge for headless agents (`/_agents/agentkey/*`) |
| Social OAuth | "Sign in with X" (`/_agents/oauth/*`) |

**Providers live today: Google.** Other social providers are scaffolded
but not enabled — don't promise them.

## How your service consumes it

Grant the `auth` capability in your manifest, then read
`auth::current_principal() -> Option<String>`. That value is the SAME
whether the user logged in by password, passkey, agentkey, or Google —
the platform resolves the verified token into one principal before your
code runs. Programmatic `sk_*` API keys unify into the same value too.

The principal is **opaque**: never parse it, prefix-strip it, or assume
it's a UUID. Use it only as your owner-column value and as input to the
`auth::*` helpers (see `boogy:boogy-auth`).

Your service **never** sees the password, the passkey, or the OAuth
provider token. It only ever sees the resolved principal.

## Sign-in-with-Google: the real answer

The **platform owns OAuth**. You do NOT implement it in your service.

1. Your front-end asks the platform what's available
   (`GET /_agents/oauth/providers`) and offers a "Sign in with Google"
   button.
2. The button sends the user into the platform flow
   (`/_agents/oauth/google/start`). The platform handles the redirect,
   the callback, and find-or-create of the account.
3. On success the user holds a platform token — the **same** token any
   other login yields.
4. Your service consumes the resulting principal via
   `current_principal()`, exactly like every other login.

Your service implements no OAuth, mints no tokens, and never touches the
Google credential.

## Red flags

| Thought | Reality |
|---|---|
| "I'll mint `sk_*` keys as user sessions." | API keys aren't logins. Scoping every user to one service principal **breaks per-user isolation**. Send users through the platform login. |
| "I'll register an agent per Google user and issue their token." | Your service **cannot sign platform tokens** and must not duplicate identity inside one tenant. Use the platform OAuth flow. |
| "I'll store the user's password for re-auth." | Never. The platform owns credentials; your service only sees the resolved principal. Re-auth = send them through login again. |
| "There's no social login, only password/agentkey." | Wrong — social OAuth (Google) is a real platform feature. |

## Integration

← `boogy:designing-boogy-services` picks the ingress mode that admits
these tokens. → `boogy:boogy-auth` is what you do with the principal
(ownership, scopes). → `boogy:boogy-obo-delegation` for one service
acting on a user's behalf in another.
