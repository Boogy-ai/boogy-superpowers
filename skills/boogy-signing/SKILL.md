---
name: boogy-signing
description: Use when a Boogy service needs to sign data with a private key it must never hold — issuing signatures, per-user signing keys, blockchain/wallet transactions, signed receipts or attestations
---

# Boogy signing

When a service must produce a **cryptographic signature** — a signed receipt,
an attestation, a blockchain transaction — it needs a private key. On Boogy
the private key never enters your code. You ask the host to sign; you get back
a signature and a public key. **There is no operation that returns a private
key — by design.**

## The model: the host holds the key, your code asks for signatures

Your component generates a key (by a name you choose) and signs with it through
the host. The private key is created host-side, stored encrypted at rest, and
used only host-side. `create-key` returns **only the public key**; signing
returns **only the signature**. A read/export operation does not exist.

**Why:** what a component never holds, a compromised or buggy component can't
leak. A memory dump, a logging mistake, a malicious dependency — none can reach
a key your code never touched. A compromised component can request *signatures*
(bounded by what it's allowed to sign); it can never steal the key itself.
That blast-radius shrink is the entire point.

You also never implement the crypto. Deterministic nonces (RFC 6979), low-S
normalization, and the recovery id are produced host-side — you call one
function and get a correct, non-malleable signature.

## Declare the capability

Signing is gated by a manifest capability (deny-by-default):

```toml
[capabilities]
signing = true
```

A call without the grant fails closed. (Contrast `secrets`, which has no
capability flag — `signing` does.)

## Algorithms and the two sign calls

| `SigAlg` | Call | Input you pass | Signature |
|---|---|---|---|
| `EcdsaSecp256k1` | `sign-digest` | a **32-byte digest** (you hash first) | 64-byte `r‖s` + `recovery_id` (Ethereum's `v`) |
| `EcdsaP256` | `sign-digest` | a **32-byte digest** | 64-byte `r‖s` |
| `Ed25519` | `sign-message` | the **full message** | 64-byte |

**ECDSA signs a digest; Ed25519 signs the message.** This split is enforced:
`sign-digest` with a non-32-byte input, or `sign-message` for an ECDSA key (or
vice-versa), returns `BadInput`. ECDSA needs a 32-byte digest because *you*
choose the hash (keccak256 for Ethereum, SHA-256 otherwise) — there is **no
platform hashing call**, so add a hashing crate (`sha2`, `tiny-keccak`) to your
own `Cargo.toml` and hash in-wasm before signing.

## Lifecycle: generate → sign → (list / remove)

The SDK glue (`wit_glue!`-emitted) gives you typed free functions; the result
types live in `boogy_sdk::signing`.

```rust
use boogy_sdk::signing::{SigAlg, SignError};

const ALG: SigAlg = SigAlg::EcdsaSecp256k1;

// Generate ON FIRST USE; return the 33-byte compressed public key.
// list-keys → find by label → create-key if absent. Keys are addressed by a
// `label` you choose (see "Per-subject keys" below).
fn ensure_key(label: &str) -> Result<Vec<u8>, SignError> {
    if let Some(info) = crate::signing_list_keys().into_iter().find(|k| k.label == label) {
        return Ok(info.public_key);
    }
    crate::signing_create_key(label, ALG) // -> Result<Vec<u8> /*pubkey*/, SignError>
}

// Sign a 32-byte digest you computed in-wasm.
fn sign(label: &str, digest: &[u8; 32]) -> Result<(Vec<u8>, u8), ApiError> {
    let sig = crate::signing_sign_digest(label, digest, ALG).map_err(map_sign_err)?;
    // secp256k1 always carries a recovery id; its absence is a host bug.
    let rid = sig.recovery_id.ok_or_else(|| ApiError::internal("no recovery id"))?;
    Ok((sig.bytes, rid + 27)) // Ethereum `v` = recovery_id + 27
}

// Fail closed; the inner strings never carry key material.
fn map_sign_err(e: SignError) -> ApiError {
    match e {
        SignError::CapabilityDenied(m) => ApiError::internal(m), // your bug, not the caller's
        SignError::UnknownKey(_)       => ApiError::not_found(),
        SignError::BadInput(m)         => ApiError::bad_request(m),
        SignError::Internal(_)         => ApiError::internal("signing unavailable"),
    }
}
```

`signing_list_keys() -> Vec<KeyInfo{label, alg, public_key}>` and
`signing_remove_key(label) -> Result<(), SignError>` round out the lifecycle.
None of them ever return private material.

## Per-subject keys: use the `label`, and derive it from the attested principal

A key is scoped host-side to `(owner, service)`; the only axis your code
controls is the **`label`**. To give each user (or account, or wallet) its own
key, use a stable id as the label — `ensure_key(&user_id)`.

**The label is an authorization decision. Derive it from the host-attested
principal, never from a URL path segment or request body** — those are
caller-controlled, so keying on them lets any caller sign as anyone:

```rust
// RIGHT: the host set this from the verified token; it can't be forged.
let label = auth::current_principal().ok_or_else(ApiError::unauthenticated)?;

// WRONG: `{user}` from the path is attacker-controlled → sign-as-anyone.
// let label = req.params.get("user");
```

This is a **custodial** model: the service can sign with any label it names, so
the service (and its operator) is the custodian for every subject's key. That
fits "the service signs on the user's behalf." It cannot express "the user holds
their own key and we can never sign without them" — that's non-custodial and
outside this capability.

**Know you are custodial, and verify it from the code — not from prose.** A
comment, a PR description, or a design doc that calls the service
"external-signer" or claims "signing is delegated, so the threat surface is
small" is a claim to check, not a fact. `signing = true` in `boogy.toml` plus
the `sign-digest`/`sign-message` calls mean the service holds the keys and the
threat surface is maximal. Don't let the framing shrink the review.

## One gate for every signing path; verify what you signed

Two disciplines apply to *any* signer (a signed receipt or attestation, not
only a blockchain tx):

**One choke point.** If your service exposes more than one path that produces a
signature, route them ALL through **one shared authorization gate** (the
block/policy/accounting checks that guard the sensitive action) before the sign
call. A second "lighter" path that skips the gate the main path enforces is a
bypass — the signature is the irreversible act, so gate at the signature, not at
whatever happens after. Make the gate one function the handlers can't sidestep;
copy-pasted per-handler checks drift, and one drifted copy is the hole.

**Verify what you signed.** When you assemble a payload around the host
signature, verify the signature against the **exact message it should sign**
(recover/verify under the expected public key) before you return or broadcast
it — "sign what you see." Fail closed on any mismatch; never return a partial or
fabricated signature. (For on-chain transactions, the per-chain form of this —
sighash/recovery-id/chain-id verification, fee bounds, denom-aware caps — lives
in `boogy:boogy-blockchain-transactions`.)

## Never inside a transaction — sign first, then record

**Every signing write is denied while a store transaction is open**:
`signing_create_key`, `signing_sign_digest`, `signing_sign_message`, and
`signing_remove_key` all return `SignError::CapabilityDenied("signing is not
allowed inside a transaction…")` when called from inside a `tx(|| …)` closure.
`signing_list_keys` is a read and is allowed.

Match the **variant**, not the message. `CapabilityDenied` is also what an
ungranted `[capabilities] signing` produces — the string tells you which of the
two applies, and it is free to be reworded.

The reason is the transaction closure itself: a commit conflict makes the
platform **re-run** it, so a sign call inside would mint a fresh signature —
and a fresh durable audit row — on every attempt, and a signature cannot be
un-issued. Unlike an email, it also can't be deferred to after the commit,
because the closure *consumes the returned value*.

So the shape is always the same:

```rust
use boogy_sdk::model::{Id, Timestamp};
use boogy_sdk::signing::SigAlg;
use boogy_sdk::Model;

// The row the signature is recorded in.
#[derive(Model)]
#[model(table = "receipts")]
pub struct Receipt {
    #[pk] pub id: Id<Receipt>,
    pub subject: String,
    pub sig_hex: String,
    pub created_at: Timestamp,
}

// 1. Everything fallible + the signature, BEFORE the tx.
//    `SignError` does NOT convert into `ApiError` on its own — map it
//    (see `map_sign_err` above); a bare `?` here does not compile.
// `fx_digest_of` / `fx_hex` stand in for your own hashing and hex encoding —
// the platform signs a digest you compute, it does not compute one for you.
let digest = fx_digest_of(&payload);
let sig = signing_sign_digest(&label, &digest, SigAlg::EcdsaSecp256k1)
    .map_err(map_sign_err)?;

// 2. The tx records the result. Store writes only — re-runnable, no side effects.
tx::<_, _, ApiError>(|| {
    db_insert(&Receipt {
        id: Id::new(0),
        subject: p.clone(),
        sig_hex: fx_hex(&sig.bytes),
        created_at: Timestamp::new(now_millis() as i64),
    })?;
    Ok(())
})?;
```

If you need a value *from* the transaction (a reserved nonce, an allocated id)
in order to sign, split it: one transaction reserves and commits, then you
sign, then a second transaction records. That is exactly the nonce-reservation
shape in `boogy:boogy-blockchain-transactions`.

A denial does **not** poison the transaction — it is an ordinary error your
code handles, and the tx can still commit. See `boogy:boogy-transactions`.

## Importing an existing key (operator, out-of-band)

Generate-in-place is the default and the strongest path (the key is born inside
the boundary, non-exportable). An operator can also **import** an existing
private key out-of-band — `PUT /v1/services/{service}/signing-keys/{label}`
with a **sealed** body (the first-party clients seal it client-side; a raw
plaintext body is rejected). Your wasm never does this — it only ever
*generates*. Imported keys are a documented weaker-provenance path (the key
existed outside the boundary once).

## Error model: deny-by-existence-mask, fail closed

`SignError` (in `boogy_sdk::signing`) has four variants; the inner strings are
for humans, never carry key material, and are **not** the thing to match on:

- `CapabilityDenied(String)` — the platform refused on capability grounds:
  either `[capabilities] signing` isn't granted, or the call was made **inside
  a transaction** (see above). Both are your bug, not the caller's, and the
  string says which. Never transient — retrying cannot help.
- `UnknownKey(String)` — no key by that label in this service's scope. A
  caller can't tell "never created" from "removed" from "another tenant's".
- `BadInput(String)` — wrong digest length, an alg/key mismatch, an
  unsupported algorithm.
- `Internal(String)` — the signing subsystem is unavailable or the platform
  faulted. Operational, and the only possibly-transient variant.

**Fail closed on any error** — never return a partial result or fabricate a
signature. Cross-tenant isolation is host-enforced: a label belonging to
another service is simply `UnknownKey`.

## Red flags

| Reach / claim | Reality |
|---|---|
| Load the private key and sign in my handler | No API returns a private key. You call `sign-digest`/`sign-message`; the host signs. |
| Implement secp256k1 / RFC 6979 / low-S myself | The key isn't in your reach anyway, and the host produces a correct, non-malleable, deterministic signature. Don't hand-roll it. |
| `label` = the `{user}` path param | Caller-controlled → sign-as-anyone. Key the label on `auth::current_principal()`. |
| One signing path is gated, so I'm covered | Enumerate EVERY path that calls sign — they must ALL pass the same gate. A skipped one is a bypass. |
| Return the assembled signature without re-checking it | Verify it against the message it should sign first; broadcasting a wrong signature is irreversible. |
| The doc says it's an external signer | Verify from `boogy.toml` (`signing = true`) + the sign calls; custodial vs external-signer is the whole threat surface. |
| `sign-digest` with the raw message bytes | ECDSA needs a 32-byte digest — hash first (keccak256 / SHA-256). A non-32-byte input is `BadInput`. |
| `sign-message` for a secp256k1 key | `BadInput`. secp256k1/P-256 use `sign-digest`; only Ed25519 uses `sign-message`. |
| Store the key in a table / env to "cache" it | There is nothing to store — your code never holds it. |
| Sign inside `tx(\|\| …)` so the signature and the row commit together | Denied by the host. The closure re-runs on a conflict, which would mint one signature per attempt. Sign first, then open the tx to record it. |

## Integration

← Reach this from `boogy:designing-boogy-services` (capability planning).
↔ `boogy:boogy-secrets` is the sibling host-mediated-crypto mechanism
(verify an inbound signature / inject an outbound credential without holding the
value) — `signing` is the *produce-a-signature* counterpart. → `boogy:boogy-account-auth`
covers principals, which is what you key per-subject signing labels on.
→ `boogy:boogy-blockchain-transactions` — if you sign or broadcast on-chain
transactions, the on-chain rules (one gate per send/sign path, total-outflow +
fee bounds, denom-aware caps, per-chain signature self-verify, adversarial RPC
values, nonce serialization) build on this skill.
