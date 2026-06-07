---
name: boogy-secrets
description: Use when a Boogy service needs an API key or credential for an external call, or when asking how secrets work
---

# Boogy secrets

When a service calls an external API (Stripe, OpenAI, anything) it needs
a credential. On Boogy the credential value never enters your code.

## The wire-edge model

Your component declares and references secret **names**. The **values**
are bound out-of-band by an operator, stored encrypted at rest, and
injected by the host at the **wire edge** of the outbound request —
after your code hands the request off, just before it goes on the wire.

**The wasm never holds the value.** Why: what a component never holds, a
compromised or buggy component can't leak. A bug that dumps your whole
environment, a dependency that exfiltrates memory, a logging mistake —
none of them can reach a value your code never touched. That blast-radius
shrink is the entire point; it's a feature, not an inconvenience.

## Lifecycle: declare → bind → use

**1. Declare** the name in the manifest (`usage` is the source of truth
for where the secret may be used):

```toml
[secrets]
stripe_key = { usage = ["outbound-header"] }
```

**2. Bind** the value out-of-band, never in code/env/store. An operator
PUTs the raw value to the binding endpoint
`PUT /_admin/secrets/{owner}/{service}/stripe_key` (≤ 64 KiB). The value
is stored encrypted; binding/removal is audited but the value never
appears in audit records or logs.

**3. Use** by referencing the NAME on the outbound request — pass
`(header-name, secret-name)` in `secret_headers`. The host resolves and
injects the value as that header at the wire edge:

```rust
let req = outbound_http::OutboundRequest {
    method: "POST".into(),
    url: "https://api.stripe.com/v1/charges".into(),
    headers: vec![],
    body: Some(form_bytes),
    timeout_ms: Some(5000),
    // (header name, declared secret name) — NOT the value
    secret_headers: vec![("Authorization".into(), "stripe_key".into())],
};
let resp = outbound_http::fetch(&req)?;
```

Injected secret headers are highest precedence (they overwrite any
same-named header you set) and are stripped on cross-origin redirects.

## Usage-scoping

`outbound-header` is the only usage today: inject as a header on an
outbound HTTP call. The declared `usage` list is **enforced** — a
reference is honored only if the name is declared AND permitted for that
context. A name with no usage entry is rejected at manifest validation.

## Liveness and errors

Resolution is **live** wherever the host's secret backend is configured;
otherwise it fails closed. A reference that is undeclared, not permitted
for the context, or has no value bound returns the same error class —
`unknown-secret(<name>)` — deliberately not distinguishing "unknown" from
"unbound" to your code.

## Rotation

No redeploy. Re-PUT the new value to the same binding endpoint; the
declared name is unchanged. The value is resolved **per request**, so the
next request uses the new value; in-flight requests past resolution use
the value they already resolved. DELETE removes the binding → later
references fail closed.

## Red flags

| Reach / claim | Reality |
|---|---|
| `store::get_secret("key")` to read the value | No such API, by design. Your code never holds the value. |
| `"Bearer {{secret}}"` templated into a header string | Not a thing. Reference the name in `secret_headers`; the host injects. |
| Put the key in an env var at deploy | The wasm env is not a secret channel — the value would live in the component's reach. |
| Store the value in a table | Same exposure; secrets are bound out-of-band, never in the store. |

## Integration

← Reach this from `boogy:designing-boogy-services` (capability/credential
planning). → `boogy:boogy-outbound-http` (ships next release) covers the
full egress story — allowlists, size/time caps, the SSRF firewall.
