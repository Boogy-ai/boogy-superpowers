---
name: boogy-webhooks
description: Use when building a service that RECEIVES and verifies inbound webhooks from a third party (Stripe, GitHub, Twilio, or any HMAC-signed callback) — the public route, signature verification, dedupe, and durable processing
---

# Receiving webhooks on Boogy

A webhook is a third party POSTing an event to a URL you expose — a
Stripe payment completing, a GitHub push, a Twilio SMS status. The
sender holds **no Boogy identity**, so you can't authenticate it the way
you authenticate your own users. Instead the provider **signs** the body
with a shared secret and sends the signature in a header; you verify it.

Getting this wrong is a security incident: an unverified webhook endpoint
lets anyone forge a "payment succeeded" event. This skill is the
canonical, end-to-end receiver pattern.

## Iron Law

**Verify the signature host-side BEFORE you trust, record, or act on
anything — and the signing secret never enters your wasm.** A webhook
body is attacker-controlled until the HMAC check passes.

## The five-step pattern

```
[1] public /webhook route  →  [2] read raw body + sig header  →
[3] HOST-VERIFY the HMAC    →  [4] dedupe on event id          →
[5] enqueue durable work, return 200 fast
```

### 1. Expose `/webhook` as a public route — and nothing else

The provider can't authenticate, so the route must be `public`. But the
*rest* of your service should stay restricted. Use a **per-route ingress
override** (see `boogy:boogy-auth`): keep a restricted service-wide mode
and carve out only `/webhook`.

```toml
[ingress]
mode = "authenticated"          # the rest of your service stays protected

[[ingress.routes]]
path = "/webhook"               # service-relative; ALL methods
mode = "public"                 # the provider reaches this, nothing else
```

`public` here means "ingress admits anyone" — the route is authenticated
by the **signature** in step 3, not by identity. Never put a webhook on
an `authenticated` route: the provider has no token and every delivery
would 401.

### 2. Read the RAW body and the signature header

Signatures are computed over the **exact bytes** the provider sent.
Re-serializing parsed JSON changes whitespace/key order and breaks the
HMAC. Read the body as raw bytes; pull the provider's signature header.

```rust boogy-snippet
fn read_raw_body_and_sig(req: &mut Req<'_>) -> Result<(Vec<u8>, String), ApiError> {
    let body = req.body().unwrap_or(&[]).to_vec();          // RAW bytes
    let sig_header = req
        .header("Stripe-Signature")                         // provider-specific
        .ok_or_else(|| ApiError::bad_request("missing signature"))?
        .to_string();
    Ok((body, sig_header))
}
```

**Parse the header into `(signed_message, expected_hex)` in pure logic.**
The shape is provider-specific — Stripe sends `t=<ts>,v1=<hex>` and signs
`"{t}.{raw_body}"` with a replay-tolerance window; GitHub sends
`sha256=<hex>` over the raw body. This parsing — including the
timestamp/replay-tolerance check — is **pure, host-testable logic**: put
it in a sibling `*-core` crate with unit tests, not in the wasm handler.
Reject (400) malformed/stale/missing-field headers *without* echoing
which check failed.

### 3. Verify the HMAC HOST-SIDE — the secret never enters your wasm

Declare the provider's signing secret with `hmac-verify` usage (see
`boogy:boogy-secrets`) and let the host do the HMAC + constant-time
compare. Your code hands over the message and the expected tag; it gets
back only a `bool`.

```toml
[secrets]
webhook_secret = { usage = ["hmac-verify"] }
```

```rust boogy-snippet
// secrets_verify_hmac_sha256(secret_ref, message, expected_hex)
//   -> Result<bool, boogy_sdk::secrets::VerifyError>   (emitted by wit_glue!)
fn verify_signature(signed_message: &[u8], expected_hex: &str) -> Result<(), ApiError> {
    match crate::secrets_verify_hmac_sha256(
        "webhook_secret",          // the declared NAME — never the value
        signed_message,            // raw bytes you reconstructed in step 2
        expected_hex,              // the hex tag from the signature header
    ) {
        Ok(true) => Ok(()), // verified — proceed
        // Fail closed identically: forged sig, undeclared/unbound secret,
        // and host error are ALL a flat 400. Don't leak which fired.
        Ok(false) | Err(_) => Err(ApiError::bad_request("bad signature")),
    }
}
```

A forged or stale signature is rejected here, **before** any record or
side effect. (Why host-side: a `hmac-verify` secret is KMS-wrapped at
rest and the plaintext is never returned to wasm — a compromised or buggy
component can't leak a signing key it never holds. See
`boogy:boogy-secrets`.)

### 4. Dedupe on the provider's event id

Providers **retry** deliveries (timeouts, your 5xx, at-least-once
delivery), so the same event arrives more than once. Key idempotency on
the provider's event id, not on your own row id:

```rust boogy-snippet
use boogy_sdk::model::{Id, Timestamp};
use boogy_sdk::store::Val;
use boogy_sdk::Model;

/// The dedupe row: `#[lookup_by]` on the provider's event id emits a unique
/// point-lookup access pattern (`WebhookEvent::PROVIDER_EVENT_ID`).
#[derive(Model)]
#[model(table = "webhook_events")]
pub struct WebhookEvent {
    #[pk]
    pub id: Id<WebhookEvent>,
    #[lookup_by]
    pub provider_event_id: String,
    pub status: String,
    pub received_at: Timestamp,
}

// Parse the event id from the now-verified body, then pre-check.
fn dedupe(event_id: String) -> Result<Option<Json<json::Value>>, ApiError> {
    let existing = db_find_by::<WebhookEvent>(
        WebhookEvent::PROVIDER_EVENT_ID, Val::Text(event_id.clone()),
    )?;
    if !existing.is_empty() {
        // Already seen → 200, no re-record, no re-process. Idempotent.
        return Ok(Some(Json(json::json!({ "status": "duplicate" }))));
    }
    Ok(None)
}
```

A duplicate must return **200** (so the provider stops retrying) while
doing nothing — never double-process.

### 5. Enqueue durable work, return 200 fast

Do the minimum on the request path: record the event and **enqueue** the
real work as a background job (see `boogy:boogy-background-jobs`), then
return 200. Providers treat a slow or non-2xx response as a failure and
retry — so don't run the heavy processing inline.

```rust boogy-snippet
use boogy_sdk::jobs::JobSpec;
use boogy_sdk::model::{Id, Timestamp};
use boogy_sdk::Model;

#[derive(Model)]
#[model(table = "webhook_events")]
pub struct WebhookEvent {
    #[pk]
    pub id: Id<WebhookEvent>,
    #[lookup_by]
    pub provider_event_id: String,
    pub status: String,
    pub received_at: Timestamp,
}

fn record_and_enqueue(event_id: String) -> Result<Json<json::Value>, ApiError> {
    db_insert(&WebhookEvent {
        id: Id::new(0),
        provider_event_id: event_id.clone(),
        status: "received".to_string(),
        received_at: Timestamp::new(0),
    })?;
    jobs_enqueue(JobSpec {
        handler: "apply_webhook".to_string(),
        payload: json::to_vec(&json::json!({ "event_id": event_id }))?,
        // Second line of dedupe defense against an insert/enqueue race.
        idempotency_key: Some(format!("apply_webhook:{event_id}")),
        ..Default::default()
    })
    .map_err(|e| ApiError::internal(format!("enqueue apply: {e}")))?;
    Ok(Json(json::json!({ "status": "received" }))) // 200, fast
}
```

> **Why two writes, not a transaction?** Enqueuing a job is denied inside
> an open store transaction, so the event-record insert and the enqueue
> are independent writes. The recorded `received` row is the durable
> hand-off; the job's `idempotency_key` collapses a rare insert/enqueue
> race. See `boogy:boogy-background-jobs` and `boogy:boogy-transactions`.

## Reference implementation

The catalog `stripe-base` service is the canonical end-to-end example:
a `mixed`-default service with a single `[[ingress.routes]] path =
"/webhook" mode = "public"` carve-out, `Stripe-Signature` parsing +
replay tolerance in a `*-core` crate, host-side `hmac-verify` of the
signing secret, event-id dedupe, and a durable `apply_webhook` job that
performs the order state transition. Study its handler as the worked
pattern.

## Red flags

| Thought | Reality |
|---|---|
| "I'll read the signing secret and compute the HMAC in my handler." | The secret must stay host-side. Use a `hmac-verify` secret + `secrets_verify_hmac_sha256` — your wasm never holds the key. |
| "I'll verify against the parsed/re-serialized JSON." | The signature is over the **raw bytes**. Re-serializing breaks it. Read and sign the raw body. |
| "Put `/webhook` on an `authenticated` route." | The provider has no Boogy token — every delivery 401s. It must be `public`, authenticated by the signature. |
| "...so make the whole service public." | No — carve out **only** `/webhook` with a per-route override; the rest stays restricted. |
| "Record the event, then check the signature." | Verify FIRST. An unverified body is attacker-controlled; never record or act on it before the HMAC passes. |
| "Process each delivery as it arrives." | Providers redeliver. Dedupe on the provider's event id (duplicate → 200, no-op), or you double-process. |
| "Do the work inline and return when done." | A slow/non-2xx response triggers provider retries. Enqueue durable work and return 200 fast. |
| "Tell the caller *why* verification failed." | Don't leak which check failed (stale vs forged vs unbound secret) — flat 400 for all. |

## Integration

This skill composes three building blocks:
`boogy:boogy-auth` (the public per-route ingress carve-out),
`boogy:boogy-secrets` (`hmac-verify`, secret stays host-side), and
`boogy:boogy-background-jobs` (durable, idempotent processing).
← `boogy:designing-boogy-services` (decide the ingress posture up front).
→ `boogy:boogy-transactions` (why record + enqueue are independent writes).
For a service that also *sends* requests to a third party, see
`boogy:boogy-outbound-http`.
