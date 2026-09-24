---
name: boogy-oauth-connections
description: Use when a service must act on a user's account at a third-party API — Google/YouTube, Slack, GitHub, Notion, Spotify — with OAuth2 authorization-code consent, refresh tokens, "connect your account" buttons, or per-user provider credentials
---

# Boogy OAuth connections

A **connection** lets your service call a third-party API *as one of your
users*, without your code ever holding their access token.

You declare the provider once in the manifest. Your user completes the
consent flow in their browser. Afterwards, any outbound call your service
makes carries a fresh access token — injected by the platform at the wire
edge, only to the hosts you declared, refreshed when it expires.

This is the OAuth counterpart of `boogy:boogy-secrets`. A secret is one
value an operator binds; a connection is **one grant per end user**,
produced at runtime by a code exchange and expiring on its own. Same rule
either way: **you reference a name, never a value.**

## When to use this

| Situation | Use |
|---|---|
| "Let users connect their YouTube/Slack/GitHub account" | this skill |
| One API key for the whole service (Stripe, OpenAI) | `boogy:boogy-secrets` |
| Verifying an inbound signed webhook | `boogy:boogy-secrets` (`hmac-verify`) |
| Calling an external API with no credential | `boogy:boogy-outbound-http` |
| One of your services acting for a user at *another of your services* | `boogy:boogy-obo-delegation` |

## The shape

```
declare  [connections.<name>] in the manifest
register the callback URL with the provider (their console)
bind     the OAuth client id + secret out-of-band (never in code)
link     connections_begin(name, subject, return_to) → send the browser there
call     outbound_http::fetch with connection_auth: Some(ConnectionRef { .. })
```

Only the last two are code. The first three are configuration a
provisioner does once.

## 1. Declare

```toml
[capabilities]
outbound_http = true

[outbound]
allowed_hosts = ["www.googleapis.com", "oauth2.googleapis.com", "accounts.google.com"]

[secrets]
google_client_id     = { usage = ["oauth-client"] }
google_client_secret = { usage = ["oauth-client"] }

[connections.google]
authorize_url    = "https://accounts.google.com/o/oauth2/v2/auth"
token_url        = "https://oauth2.googleapis.com/token"
revoke_url       = "https://oauth2.googleapis.com/revoke"
scopes           = ["https://www.googleapis.com/auth/youtube.readonly"]
authorize_params = { access_type = "offline", prompt = "consent" }
client_id        = "google_client_id"
client_secret    = "google_client_secret"
client_auth      = "basic"
inject_hosts     = ["www.googleapis.com"]
```

There is **no new `[capabilities]` flag** — declaring the block is the
gate, as with `[secrets]`. A connection does require
`outbound_http = true`; without it the manifest is refused.

What the manifest validator enforces, at deploy:

| Rule | Why |
|---|---|
| `token_url`, `revoke_url` and every `inject_hosts` entry ∈ `[outbound] allowed_hosts` | the platform's own egress goes through the same allowlist your calls do |
| every URL is `https` — **except** a loopback host (`127.0.0.1`, `::1`, `localhost`) when `[outbound] allow_plaintext = true` | a bearer token is never put on a plaintext connection. The one exception exists so an integration test can point `token_url` at a mock server on your own machine; it widens nothing in production, because reaching a loopback destination additionally needs an operator-level opt-in the manifest cannot grant itself |
| `inject_hosts` is non-empty | a token with no destination is a config mistake |
| `client_id` / `client_secret` name `[secrets]` entries with `usage = ["oauth-client"]` | ties the client credentials to this one use |
| an `oauth-client` secret must **not** also carry `outbound-header` | otherwise a guest could attach the OAuth *client secret* to its own request via `secret_headers` — the exact leak the separate usage exists to prevent |

`authorize_url` is a browser redirect target the platform never fetches,
so it is checked for scheme and host only, not against the egress
allowlist.

### `inject_hosts` is the token's pinning set — keep it narrow

`inject_hosts` is stricter than `allowed_hosts` on purpose: the access
token is injected **only** on requests to these hosts, so a handler
cannot point a request at some other allowed host and receive the token
there.

**Declare only the provider's API host.** Any host that echoes request
headers back in its response body — a debug endpoint, a webhook-inspection
service, an internal tool you also allowlisted — hands your own guest the
bearer token it was never supposed to see, and the platform cannot tell
that response apart from any other.

**The match is on the HOST, not the origin.** Ports are not part of it
(the same rule `allowed_hosts` follows, which refuses port suffixes at
parse), so `https://api.example.com:8443/…` is injected by an
`inject_hosts` entry of `api.example.com`. Matching is case-insensitive.
If a non-default port on that host is somewhere you would not want the
token to go, it needs a different hostname.

### `revoke_url` is optional, and leaving it out has a cost at delete time

Declare `revoke_url` unless the provider genuinely has no revocation
endpoint. It is what the platform calls to hand a user's grant back when
a connection is revoked or the service is deleted — and if a connection
has no `revoke_url`, there is nothing to call. Those rows are still
removed at teardown, because no amount of waiting would make an endpoint
that was never declared reachable; what ends is your ability to revoke
them. **The user's grant stays live at the provider, and the last handle
on it is gone** — they can only withdraw it from the provider's own
account page, if they think to. The same happens to rows of a connection
you stop declaring while links for it still exist, so remove a
`[connections.<name>]` block only once its users are unlinked.

## 2. Register the callback URL

The provisioner registers exactly this redirect URI in their own OAuth
client, in the provider's console:

```
https://<handle>.<base>/boogy/connections/callback
```

`<handle>` is the owner's handle, `<base>` the platform's base domain.
`boogy` is a reserved path segment on every tenant subdomain, so no
service can shadow this route; it is served by the platform and **no guest
code runs for it**.

**The callback is always on the platform subdomain, even for a service
served on a custom domain.** The two origins answer different questions:
the callback URI is where the *provider* sends the browser back (the
platform subdomain, which is what was registered); `return_to` is where
*your page* is (your custom domain, if you have one). A service on a
custom domain still registers, and completes through, the platform
subdomain — and can still return the user to a page on its own domain.

## 3. Bind the client credentials

Exactly like any other secret, out-of-band, sealed client-side:

```
boogy secret set <service> google_client_id     <value>
boogy secret set <service> google_client_secret <value>
```

Never in code, never in an env var, never in a table.

## 4. Link a user — and get `subject` right

`subject` names **whose** connection this is. The platform takes it at
face value on every call: `status`, `revoke` and the token injected for a
`connection_auth` request all key on exactly the string you pass.

> **Derive `subject` from the authenticated principal. Never from a path
> segment, a query parameter, a header or a request body.**

A handler that forwards request input into `subject` lets any caller
link, inspect, revoke — **and use** — another user's account at the
provider, with your service's credentials. Nothing on the platform can
tell that call apart from the legitimate one, because at that point it
*is* the legitimate call.

```rust
use boogy_sdk::connections::ConnectionError;

/// The one place `subject` comes from. There is no second one.
fn subject_of(_req: &mut Req<'_>) -> Result<String, ApiError> {
    auth::current_principal().ok_or_else(ApiError::unauthenticated)
}

fn connection_error(e: ConnectionError) -> ApiError {
    match e {
        // Nothing usable here — the remedy is always to run `begin` again.
        ConnectionError::UnknownConnection(_) => ApiError::bad_request("connect your account first"),
        ConnectionError::CapabilityDenied(m) => ApiError::unprocessable(m),
        ConnectionError::BadReturnTo(m) => ApiError::bad_request(m),
        ConnectionError::Internal(_) => ApiError::internal("connections unavailable"),
    }
}

/// POST /connect — hand the browser the provider's consent page.
fn start_link(req: &mut Req<'_>) -> Result<Json<String>, ApiError> {
    let subject = subject_of(req)?;
    let authorize_url = connections_begin(
        "google",                                   // the [connections.<name>] key
        &subject,                                   // derived, never supplied
        "https://acme.example.com/settings/linked", // https, your own origin
    )
    .map_err(connection_error)?;
    Ok(Json(authorize_url))
}
```

`return_to` must point at **this service's own origin**, carry no
userinfo, and be at most 2048 bytes; anything else is `BadReturnTo`. The
check is a real **origin** comparison — scheme, host and port — never a
string prefix, so `https://al.example.com.evil.com` cannot pass by
sharing one. The origin it is compared against is one the **platform
derives** from the request's resolved host, using the SAME scheme and
port the browser actually arrived on: `https` in production, and `http`
(with whatever port you're running on) for a local development host like
`http://<handle>.localhost:3000`. So `return_to` should match the page
you're actually serving — pass an `http://` URL locally and an `https://`
one in production; the `BadReturnTo` message names the origin it expected
if you're unsure. After consent the platform finishes the token exchange
and 302s the browser there — so `return_to` is the page that shows
"connected".

One execution context may start at most **four** authorizations; past that
each `begin` is `CapabilityDenied` and writes nothing. A context is one
inbound request *or* one `peer` hop, each with its own budget — so a
fan-out across services is not squeezed into one allowance. A browser can
only be sent to one consent page per response, so this bites only a loop.

## 5. Check and unlink

```rust
use boogy_sdk::connections::ConnectionState;

/// GET /connected — is this caller linked, and with which scopes?
fn linked(_req: &mut Req<'_>) -> Result<Json<bool>, ApiError> {
    let subject = auth::current_principal().ok_or_else(ApiError::unauthenticated)?;
    let status = connections_status("google", &subject)
        .map_err(|e| ApiError::bad_request(e.to_string()))?;
    // `scopes` is what the provider ACTUALLY granted — check it before
    // relying on a scope you asked for.
    let _granted: &[String] = &status.scopes;
    Ok(Json(matches!(status.state, ConnectionState::Connected)))
}

/// DELETE /connected — forget the tokens, and revoke them upstream.
fn unlink(_req: &mut Req<'_>) -> Result<(), ApiError> {
    let subject = auth::current_principal().ok_or_else(ApiError::unauthenticated)?;
    connections_revoke("google", &subject).map_err(|e| ApiError::bad_request(e.to_string()))
}
```

`status` never returns token material — only `state`, the granted
`scopes`, `connected_at_ms`, `refreshed_at_ms`, and a short failure
**class** (`last_error`, e.g. `invalid_grant`), never a provider body.

Three states, and only one of them means "call the API":

| `state` | Meaning | What to do |
|---|---|---|
| `Connected` | usable now; the platform refreshes as needed | call the API |
| `NeedsReconnect` | the stored grant stopped working (revoked upstream, expired refresh token) | send the user through `begin` again |
| `Absent` | never linked | send the user through `begin` |

## 6. Call the API

Using a connection is a **field on the outbound request**, not a call:

```rust
use bindings::boogy::platform::outbound_http::{self, ConnectionRef, OutboundRequest};

fn my_channel(subject: &str) -> Result<Option<Vec<u8>>, ApiError> {
    let resp = outbound_http::fetch(&OutboundRequest {
        method: "GET".into(),
        url: "https://www.googleapis.com/youtube/v3/channels?mine=true".into(),
        headers: vec![],
        body: None,
        timeout_ms: Some(5000),
        secret_headers: vec![],
        // The platform injects `Authorization: Bearer <access token>` at the
        // wire edge. This wasm never sees it.
        connection_auth: Some(ConnectionRef {
            connection: "google".into(),
            subject: subject.to_string(),
        }),
    })
    .map_err(|_| ApiError::internal("upstream call failed"))?;
    Ok(resp.body)
}
```

The platform, at the wire edge: checks the URL's host is in
`inject_hosts`; refreshes the access token if it expires within 60
seconds; injects the bearer. The injected header is stripped on
cross-origin redirects like any injected credential.

**Refresh is lazy and single-flight.** A due refresh takes a per-`(connection,
subject)` lock, so a burst of concurrent calls at expiry produces **one**
call to the provider's token endpoint, not one per request. A non-expired
token is served without taking the lock at all. If the provider answers
`invalid_grant`, the connection moves to `NeedsReconnect`, the call fails
with `connection-unavailable`, and the refresh is **not** retried in a
loop — the user has to consent again.

## Errors

From `connections_begin` / `status` / `revoke`
(`boogy_sdk::connections::ConnectionError` — match the **variant**, not
the message):

| Variant | Means | Remedy |
|---|---|---|
| `UnknownConnection(name)` | no `[connections.<name>]` declared, the service lacks `outbound_http`, or this subject has never connected / must connect again | run `begin` |
| `CapabilityDenied(msg)` | `begin`/`revoke` inside a transaction, `begin` from a background job, a `subject` outside the accepted length, or past a per-context call cap (`begin` and `status` each have one; `status`'s is far higher) | the message says which, and names the bound; fix the call site |
| `BadReturnTo(msg)` | `return_to` did not match this service's own origin (scheme, host and port — `https` in production, `http` for a local dev host) | pass your own page's URL, on the scheme+port you're actually serving |
| `Internal(msg)` | platform-side failure | retry; nothing the caller can change |

From `outbound_http::fetch` when `connection_auth` is set (these are
`FetchError` variants, on top of the usual egress taxonomy):

| Variant | Means |
|---|---|
| `connection-unavailable` | the connection is not declared, the subject never connected, the grant needs reconnecting, or the `subject` you passed is empty or over the accepted length — read `connections_status` and send the user through `begin` |
| `connection-host-not-allowed` | the request URL's host is not in that connection's `inject_hosts` (or the URL is not https) — a manifest/call mismatch, not a user problem |

A 4xx or 5xx from the provider is still `Ok(resp)` with `resp.status`;
`Err` is transport-level only. A `401` from the provider on a connection
that reads `Connected` means the user revoked access at the provider —
call `revoke` and re-link.

## Not inside a transaction; `begin` needs a browser

`connections_begin` and `connections_revoke` are **refused while a store
transaction is open** — the same rule as outbound HTTP and signing
writes. A transaction body is re-runnable, and neither an authorization
nor a revocation can be rolled back. They surface as `CapabilityDenied`,
and the refusal does **not** poison the transaction. `connections_status`
is a read and is allowed.

`connections_begin` is also refused **from a background job**: the URL it
returns is only useful to a browser, and a job has no browser request to
return to. `status` and `revoke` work fine in a job, and a job's outbound
calls may use `connection_auth` normally.

## Lifecycle

- **Rotation** of the OAuth client credentials is a re-bind of the same
  secret names — no redeploy.
- **Deleting the service is not instant, and that is deliberate.** The
  `DELETE` returns **202** with `{"state": "deleting"}` and destroys
  nothing: the service stops serving immediately, but its deployment, its
  data and its connection rows all survive the call. The platform then
  revokes each connection at its provider in the background and deletes
  that row **only once its grant is actually settled** — so a provider
  outage means a retry later, not a stranded grant. When none remain, the
  service is really deleted.

  Three consequences worth knowing before you script against it:

  - **`GET /v1/services/{id}/connections` keeps answering** until the
    teardown finishes, so an owner can still see which grants are left.
    Re-creating a service with the same id is refused (409, "being
    deleted") for the same window.
  - **A provider that refuses forever does not make the service
    undeletable.** Past a bounded number of failed attempts, or a bounded
    age, the platform deletes it anyway and records
    `service.deleted_with_unrevoked_grants` in your audit tail, carrying
    the number of grants left live. When you see that row, the remedy is
    the provider's own account page — nothing on Boogy can reach those
    grants any more.
  - **Unbind your OAuth client secret AFTER the service is gone, not
    before.** Without it the platform cannot authenticate the revoke call,
    which counts as a failure that will never resolve itself, so the
    teardown waits out the full give-up bound and then strands every grant.
    Delete the service, let it finish, then remove the secret.
- **The owner can see, but not read.** `GET /v1/services/{id}/connections`
  lists one row per `(connection, subject)` — state, granted scopes,
  linked/refreshed timestamps, last error class — cursor-paginated. There
  is no field for a token on that surface, because there is no token
  outside the credentials boundary to put in one.

## Provider notes — Google

Two Google limits bite in practice; neither is a Boogy behaviour. Both are
documented at
[developers.google.com/identity/protocols/oauth2](https://developers.google.com/identity/protocols/oauth2):

- **Testing-mode refresh tokens expire in 7 days.** "A Google Cloud
  Platform project with an OAuth consent screen configured for an external
  user type and a publishing status of 'Testing' is issued a refresh token
  expiring in 7 days" (unless the only scopes requested are a subset of
  name, email address and user profile). Your connections will read
  `NeedsReconnect` a week after you link them and there is nothing to fix
  in your service — publish the consent screen.
- **100 refresh tokens per Google Account per client ID.** "If the limit
  is reached, creating a new refresh token automatically invalidates the
  oldest refresh token without warning." A `begin` loop in testing will
  silently kill the grant you were using.

Ask for `access_type = "offline"` in `authorize_params`, or Google issues
no refresh token at all and the connection dies at the first expiry.

## Red flags

| Thought | Reality |
|---|---|
| "I'll store the access token in a table so I can reuse it." | There is nothing to store — no API returns a token. Name the connection on the request; the platform injects it. |
| "I'll pass the token in `headers` / `secret_headers`." | Neither carries a connection token. `connection_auth` is the only way, and it takes a name, not a value. |
| "`subject` comes from the path — `/users/{id}/sync`." | Any caller then acts as any user at the provider. Derive `subject` from `auth::current_principal()`. |
| "I'll add my debug/echo host to `inject_hosts` while I develop." | A host that echoes headers hands your own guest the bearer token. Only the provider's API host belongs there. |
| "I'll refresh the token myself when it's close to expiry." | The platform refreshes lazily and single-flight. A guest-side refresh has no token to refresh with. |
| "I'll `begin` inside the transaction that writes the user's row." | Refused. Authorizations can't roll back. Write the row, commit, then `begin`. |
| "The nightly sync job can `begin` when a grant expires." | Refused — a job has no browser. Detect `NeedsReconnect` in the job, and prompt the user on their next request. |
| "I'll put the OAuth client secret in `[secrets]` with `outbound-header` too, so I can call the token endpoint myself." | Refused at deploy. That combination lets a guest attach the client secret to its own request. |
| "`allowed_hosts` covers it, so `inject_hosts` is redundant." | `allowed_hosts` says where you may call. `inject_hosts` says where the *token* may go. They are deliberately different sets. |
| "`revoke_url` is optional — I'll leave it out and add it later." | Then nothing can hand your users' grants back. Their links are still removed when the service is deleted, with the grants left live at the provider and no way left to reach them. Declare it unless the provider has no revocation endpoint at all. |
| "A user reported a 401 — the platform's refresh must be broken." | Check `connections_status` first. A user revoking access at the provider is the common case, and it reads `NeedsReconnect`. |

## Integration

← Reach this from `boogy:designing-boogy-services` when a requirement says
"on the user's behalf at <third party>". → `boogy:boogy-secrets` is the
single-value counterpart and explains the wire-edge model this inherits.
→ `boogy:boogy-outbound-http` covers the egress policy every connection
call still passes through (allowlist, caps, SSRF firewall, redirects).
→ `boogy:boogy-transactions` for why `begin`/`revoke` are denied in a tx
and what to do instead. → `boogy:boogy-observability` for the owner-facing
`/v1` surfaces, including the connections list.
