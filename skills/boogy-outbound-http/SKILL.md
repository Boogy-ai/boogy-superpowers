---
name: boogy-outbound-http
description: Use when a Boogy service must call an external HTTP API or bring its own database/backend — egress allowlist, request shape, caps, redirects, and credentials
---

# Boogy Outbound HTTP

A service calls external URLs through one host-mediated capability. There
is no `reqwest`, no socket — every call goes through `fetch`, and the
host enforces policy.

**Check the mesh first.** If another service in the mesh already fronts
what you need, call it via `peer` instead — see
`boogy:boogy-registry-and-provisioning`. Outbound is for genuinely
external systems.

## Grant + policy (manifest)

```toml
[capabilities]
outbound_http = true

[outbound]
allowed_hosts = ["api.stripe.com", "*.example.com"]
# optional, with defaults:
# max_timeout_ms     = 30000   # hard ceiling; caller values clamped down
# default_timeout_ms = 10000   # used when the call omits timeout_ms (≤ max)
# max_request_bytes  = 1048576    # 1 MiB
# max_response_bytes = 10485760   # 10 MiB
# allow_plaintext    = false   # http:// denied unless true
```

`allowed_hosts` is mandatory once the capability is granted: **an empty
allowlist fails at deploy** ("capability granted but allowed_hosts is
empty") — a capability with no destinations is a config mistake, not a
valid deployment. The block uses `deny_unknown_fields`, so a typo'd key
is rejected at parse time.

**Allowlist grammar (glob, not regex):** `api.stripe.com` is exact;
`*.example.com` matches one-or-more leading labels (`api.example.com`,
`a.b.example.com`) but NOT the bare `example.com`. Bare `*`, embedded
`*`, trailing `*`, and port suffixes are refused at parse. IP-literal
destinations must be listed explicitly; a hostname-only allowlist denies
all IP literals (SSRF firewall blocks RFC1918/loopback/link-local by
default).

## The call

There is no SDK wrapper — use the generated binding directly:

```rust boogy-snippet
use bindings::boogy::platform::outbound_http;

fn charge(payload_bytes: Vec<u8>) {
    let req = outbound_http::OutboundRequest {
        method: "POST".into(),
        url: "https://api.stripe.com/v1/charges".into(),
        headers: vec![("content-type".into(), "application/json".into())],
        body: Some(payload_bytes),
        timeout_ms: Some(5000),          // None → manifest default_timeout_ms
        secret_headers: vec![("authorization".into(), "stripe_key".into())],
    };
    match outbound_http::fetch(&req) {
        Ok(resp) => { /* resp.status: u16, resp.headers, resp.body */ }
        Err(e)   => { /* transport-level failure — see taxonomy */ }
    }
}
```

**Credentials go in `secret_headers`, never `headers`** — each tuple is
`(header-name, secret-ref)` where the ref is a name declared in
`[secrets]`. The host injects the value at the wire edge; your wasm never
sees it. See `boogy:boogy-secrets`. Reserved headers (`authorization`,
`cookie`, `x-boogy-*`, `host`) supplied in plain `headers` are stripped.

**A 4xx/5xx is `Ok(resp)`, not `Err`.** `Err(FetchError)` is
transport-level only: `host-not-allowed`, `blocked-address`,
`plaintext-denied`, `timeout`, `dns`, `connection-refused`,
`response-too-large`, `request-too-large`, `rate-limited`,
`unknown-secret`, `capability-denied`, `invalid-url`, `internal`. Check
`resp.status` for application-level HTTP results.

Redirects are followed with per-hop re-validation; cross-origin hops
strip Authorization and injected secret headers, so a credential bound
for one origin can't leak to another.

## Limits

- **Per-request outbound-call ceiling** — a single request may make only
  so many outbound calls before further ones are denied
  (`CapabilityDenied`). Don't fan out unboundedly.
- **Denied inside a transaction.** An outbound call can't roll back and
  would exceed the store transaction envelope, so the host denies it
  in-tx. To make an external effect atomic with a write, enqueue a
  *staged* background job inside the tx (commit-gated) — see
  `boogy:boogy-transactions`.

## Bring your own backend

The built-in store handles typical CRUD plus most write-heavy workloads.
For genuinely extreme write rates (large payloads, write-amplifying
indexes), reach an external DB over `outbound_http`: allowlist its host,
credential via `[secrets]`. Keep platform-identity and control-plane
concerns — auth, ownership keys, cross-service data — in the built-in
store. (For large files: metadata rows in-store, bytes via presigned-URL
to external object storage — see `boogy:boogy-capability-limits`.)

## Red flags

| Thought | Reality |
|---------|---------|
| "I'll add `reqwest` / open a socket." | No network primitive — only `outbound_http::fetch`. |
| "Grant the capability, set hosts later." | Empty `allowed_hosts` fails at deploy. List real hosts. |
| "`allowed_hosts = ["*"]`." | Bare `*` is refused. Enumerate hosts or `*.domain`. |
| "Put the API key in `headers`." | Use `secret_headers` (host-injected); plain auth headers are stripped. |
| "A 404 came back as an error." | 4xx/5xx are `Ok(resp)` with `resp.status`. `Err` is transport-only. |
| "Call the payment API inside the tx so it's atomic." | Outbound is denied in-tx. Stage a commit-gated job instead. |
