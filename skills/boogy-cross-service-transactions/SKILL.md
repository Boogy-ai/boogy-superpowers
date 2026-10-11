---
name: boogy-cross-service-transactions
description: Use when a write must stay consistent across services called with peer::fetch, a caller's transaction must span the callee, a callee must know whether it runs inside a transaction, or a peer call's failure must roll back the caller's writes
---

# Transactions across services

Part of `boogy:boogy-transactions`, which holds the transaction rules this extends: read it first.

## A callee that REQUIRES a transaction can now check

A read-modify-write — read a value, decide from it, write it back — is
serializable only inside a transaction. Outside one, every store call is its own
auto-commit transaction, so two racing callers both pass the same check and both
commit. For a callee like "reserve stock", that is an oversell.

A callee cannot open a transaction defensively: **a callee that calls `tx` fails
at commit.** So refuse instead:

```rust ignore-snippet: a guard fragment — the handler, its DTO and its error type are not in scope in this block
if !in_transaction() {
    return Err(ApiError::conflict(
        "reserve must be called inside a caller's transaction",
    ));
}
```

`in_transaction()` is emitted by `wit_glue!` — no import. It reads no data and
takes no conflict range, and returns `false` when the store capability is not
granted.

**Use it only where the contract is real.** Most callees are fine either way;
this is for a service whose correctness genuinely depends on the caller's
transaction, where the alternative is a silent wrong answer under contention.

## Cross-service consistency — open the tx at the entry handler

When a mutation must stay consistent **across a `peer::fetch`**, open the
`tx` once, at the **entry handler** (the root of the call tree) — never in
a callee. It then spans the **entire call tree as one store transaction**,
under the enrollment / poisoning / one-envelope semantics in
`boogy:boogy-transactions` (*Semantics quick reference*). A
non-success peer response you turn into `Err(…)` rolls back the whole
tree.

Two things behave differently across a tree, and the difference is the
point: a **commit conflict** is retried, which re-runs the closure *and
therefore re-issues every `peer::fetch` in it* — so a callee must tolerate
being called again (and it burns the callee's rate budget faster than the
commit rate implies). A **poisoned** transaction is **not** retried: the
participant already failed, and re-running would fail once per attempt at
every callee it reached.

## Cross-service sketch (verified shapes)

`peer_fetch` fails (`Err`) on a non-success status **by default**, so the
plain `peer_fetch(...)?` shape already stops the closure — and therefore
the commit — on a callee's rejection; you don't need to check
`resp.is_success()` yourself. Reach for `peer_fetch_raw` (same signature)
only when you want to map the callee's status to your OWN domain-specific
error instead of the generic 502 upstream `?` would produce, as below:

```rust
use boogy_sdk::peer::PeerRequest;
use store::{Value, Column};

fn place_order(order_cols: Vec<Column>, reserve: serde_json::Value) -> Result<(), ApiError> {
    tx::<_, _, ApiError>(|| {
        store::insert("orders", &order_cols)?;
        let resp = peer_fetch_raw(                       // enrolls B in this tx
            "boogy://owner/services/inventory",
            &PeerRequest::post("/reserve").body_json(&reserve)?,
        )?;
        if !resp.is_success() {                          // poisons → both roll back
            return Err(ApiError::conflict("out of stock"));
        }
        Ok(())
    })?;
    Ok(())
}
```

A failed peer call lifts to **502 upstream** via `?` — clients receive
only the failure class; the full error is in your service's
request-correlated logs — (`From<PeerError> for
ApiError`); body construction (`body_json`/`resp.json`) lifts its
`serde_json::Error` to **500** (`From<serde_json::Error>`). Match the variant
first if you want a different status (e.g. treat the callee's 404 as your own).
This also covers `PeerError::Rejected` — the variant `peer_fetch`'s checked
default produces for a non-2xx response — the same way as any other
dependency failure.

**Probing a peer's status from inside a transaction requires the explicit
`peer_fetch_raw` opt-in above.** The platform also enforces this
independently at the host: a non-2xx participant response poisons the open
ambient transaction regardless of which call a closure uses, so bypassing
the checked default doesn't reopen a way to commit past a callee's
rejection — it only changes whether YOUR closure notices before the host does.

## Integration

↑ `boogy:boogy-transactions`. → `boogy:boogy-mesh-architecture` for composing services. → `boogy:boogy-transaction-conflicts` for what a retry re-runs.
