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
binds it with the CLI — `boogy secret set <service> stripe_key <value>`
(or `--value-stdin`), which **seals the value client-side** before it
leaves the machine; the host stores it encrypted and never sees the
plaintext. A raw plaintext PUT to the binding endpoint is rejected — the
value must be sealed (the dashboard does the same sealing in-browser).
Binding/removal is audited, but the value never appears in audit records
or logs.

**3. Use** by referencing the NAME on the outbound request — pass
`(header-name, secret-name)` in `secret_headers`. The host resolves and
injects the value as that header at the wire edge:

```rust
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
        connection_auth: None,
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
manifest validation. Three usages exist today:

| Usage | What the host does | The value is… |
|---|---|---|
| `outbound-header` | Injects the value as a header on an `outbound_http::fetch` call (above). | …never returned; injected at the wire edge. |
| `hmac-verify` | Computes `HMAC(secret, message)` host-side and constant-time-compares it to a tag you supply — for verifying inbound signatures (webhooks). | …never returned; only a `bool` comes back. |
| `oauth-client` | Uses the value as the OAuth2 client id / client secret of a declared `[connections.<name>]`, on the platform's own token and revoke calls. | …never returned, and never reachable from a guest request. |

A name can carry both `outbound-header` and `hmac-verify` if it's used
for both — but the common case is one each. **`oauth-client` is
exclusive of `outbound-header`**, and the manifest is refused if one
name carries both: an OAuth *client secret* a guest could name in
`secret_headers` is a client secret the guest can exfiltrate to any
allowlisted host. See `boogy:boogy-oauth-connections`.

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

**2. Bind** the provider's signing secret out-of-band the same way as any
secret — `boogy secret set <service> stripe_webhook_secret <value>` (the
CLI seals it client-side; a raw plaintext PUT is rejected).

**3. Verify** in the handler. Reconstruct the exact bytes the provider
signed (usually `"{timestamp}.{raw_body}"`) and the expected hex tag from
the signature header, then call the `wit_glue!`-emitted helper:

```rust
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
into the canonical inbound-webhook receiver. → `boogy:boogy-signing` is the
counterpart for *producing* a signature with a host-held private key your
code never touches. → `boogy:boogy-oauth-connections` is the counterpart
for a credential that is **per end user** and produced at runtime — a
service acting on a user's account at a third-party API, with an OAuth2
token the platform holds, refreshes and injects.

## Red Flags

| Thought | Reality |
|---|---|
| "I'll put the API key in the manifest for now" | The manifest is not secret storage. Bind secrets through the platform's secret surface so the value is encrypted at rest and never travels with your code. |
| "I'll read the key and pass it to the HTTP call" | Prefer the paths where the host injects the credential at the wire edge — the guest never holds plaintext, so a guest-side bug cannot leak what it never had. |
| "I'll log the request so I can debug the signature" | Secret values never appear in audit rows by design; do not reintroduce them through your own logs. Log the key NAME and the outcome, never the material. |
| "Rotating means redeploying" | Rotation is a bind against the running service. If your design requires a redeploy to rotate, it will not be rotated. |
| "The secret is only in memory, that's fine" | It is fine *until* it is in an error message, a panic payload, or a trace. Treat every value you can format as a value you will eventually print. |
