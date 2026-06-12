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

```rust boogy-snippet
use bindings::boogy::platform::outbound_http;

fn charge(form_bytes: Vec<u8>) -> Result<(), outbound_http::FetchError> {
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
    Ok(())
}
```

Injected secret headers are highest precedence (they overwrite any
same-named header you set) and are stripped on cross-origin redirects.

## Usage-scoping

A secret's `usage` list says *what the host may do with it* — and is
**enforced**: a reference is honored only if the name is declared AND
permitted for that context. A name with no usage entry is rejected at
manifest validation. Two usages exist today:

| Usage | What the host does | The value is… |
|---|---|---|
| `outbound-header` | Injects the value as a header on an `outbound_http::fetch` call (above). | …never returned; injected at the wire edge. |
| `hmac-verify` | Computes `HMAC(secret, message)` host-side and constant-time-compares it to a tag you supply — for verifying inbound signatures (webhooks). | …never returned; only a `bool` comes back. |

A name can carry both (`usage = ["outbound-header", "hmac-verify"]`) if
it's used for both — but the common case is one each.

## hmac-verify: verify an inbound signature without holding the secret

When a third party (Stripe, GitHub, Twilio) POSTs you a webhook, it
signs the body with a **shared signing secret** and sends the signature
in a header. You must verify it. The naive shape — "read the secret,
compute HMAC in my code, compare" — would put the signing secret in your
wasm's reach. `hmac-verify` keeps it host-side: **you hand the host the
message and the expected tag; the host does the HMAC and the compare and
returns only a `bool`.**

**1. Declare** the signing secret with `hmac-verify` usage:

```toml
[secrets]
stripe_webhook_secret = { usage = ["hmac-verify"] }
```

**2. Bind** the provider's signing secret out-of-band (same endpoint as
any secret — `PUT /_admin/secrets/{owner}/{service}/stripe_webhook_secret`).

**3. Verify** in the handler. Reconstruct the exact bytes the provider
signed (usually `"{timestamp}.{raw_body}"`) and the expected hex tag from
the signature header, then call the `wit_glue!`-emitted helper:

```rust boogy-snippet
// SHA-256 convenience form (the webhook common case):
//   secrets_verify_hmac_sha256(secret_ref, message, expected_hex)
//     -> Result<bool, boogy_sdk::secrets::VerifyError>
fn verify(signed_message: &[u8], expected_hex: &str) -> Result<(), ApiError> {
    match crate::secrets_verify_hmac_sha256(
        "stripe_webhook_secret",   // the declared name — NOT the value
        signed_message,            // &[u8] you reconstructed
        expected_hex,              // the hex tag from the provider's header
    ) {
        Ok(true)  => Ok(()), // verified — proceed
        Ok(false) => Err(ApiError::bad_request("bad signature")),
        Err(_)    => Err(ApiError::bad_request("bad signature")),
    }
}
```

The host KMS-unwraps the secret, computes `HMAC-SHA256(secret,
signed_message)`, **constant-time-compares** it to `expected_hex`, and
returns `Ok(true)`/`Ok(false)`. The wasm never receives the secret, the
message digest, or the computed tag — only the boolean.

`secrets_verify_hmac(secret_ref, algorithm, message, expected_hex)` is
the full form taking a `boogy_sdk::secrets::HmacAlgorithm` (today only
`Sha256`). There is **no** `[capabilities]` flag for this — the gate is
the per-secret `usage = ["hmac-verify"]` declaration.

### The error model is deny-by-existence-mask

`VerifyError` has two variants (in `boogy_sdk::secrets`):

- `VerifyError::UnknownSecret(String)` — the ref is **undeclared**, OR
  declared **without** `hmac-verify`, OR has **no value bound**. The host
  collapses all three into one variant on purpose: a caller can't probe
  which condition holds.
- `VerifyError::Internal(String)` — no secret backend configured /
  KMS/storage failure. Operational, distinct from the above.

**Fail closed on either.** A webhook handler should treat `Ok(false)`,
`Err(UnknownSecret)`, and `Err(Internal)` identically — reject the
request (HTTP 400) without revealing which one fired. See
`boogy:boogy-webhooks` for the full receiver pattern.

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
planning). → `boogy:boogy-outbound-http` covers the full egress story
(allowlists, size/time caps, the SSRF firewall) — where `outbound-header`
secrets are consumed. → `boogy:boogy-webhooks` composes `hmac-verify`
into the canonical inbound-webhook receiver.
