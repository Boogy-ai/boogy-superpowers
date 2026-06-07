---
name: boogy-transactions
description: Use when writing multiple rows atomically, combining writes with cross-service calls, handling 409s, or placing side effects near writes
---

# Transactions on Boogy

Multi-row atomic writes go through a **no-arg closure**: `tx(|| { ... })`.
There is no transaction handle — inside the closure you call the *same*
`store::*` / `db_*` / `find_row_by` functions as outside; they join the
ambient transaction. `Ok` commits, `Err` rolls back, a panic discards it.

```rust boogy-snippet
use store::{Value, Column};

fn transfer(me: String, amount: f64, from_id: u64, to_id: u64) -> Result<f64, ApiError> {
    let debit = |bal: f64| vec![Column { name: "balance".into(), val: Value::Text(bal.to_string()) }];
    let credit = |amt: f64| vec![Column { name: "balance".into(), val: Value::Text(amt.to_string()) }];

    let new_balance: f64 = tx::<_, _, ApiError>(|| {
        let bal = find_row_by("balances", "principal", Value::Text(me.clone()))?
            .map(|r| r.text("balance").parse::<f64>().unwrap_or(0.0))
            .unwrap_or(0.0);
        if bal < amount {                       // check INSIDE — read-your-writes
            return Err(ApiError::unprocessable("insufficient balance"));
        }
        store::update("balances", from_id, &debit(bal - amount))?;
        store::update("balances", to_id, &credit(amount))?;
        Ok(bal - amount)
    })?;
    Ok(new_balance)
}
```

## Sequencing discipline

1. **Validate / parse** inputs.
2. **Reads + writes + job ENQUEUES** inside ONE `tx` closure. Sufficiency
   and uniqueness checks go INSIDE — the closure reads its own writes
   (no pre-snapshot, no TOCTOU window).
3. **External calls (`outbound_http`) AFTER** `tx? ` returns `Ok` — or
   better, enqueue an in-tx job to make them both atomic and durable.

## The side-effect decision

| Side effect | Where it goes |
|-------------|---------------|
| Must not be lost (email, webhook, charge) | **Enqueue a job INSIDE the tx** — the enqueue is *staged* and submitted only if the tx commits; the job does the outbound call after commit. Atomic with the data AND survives a crash between commit and send. |
| Fire-and-forget / latency-critical | Do it AFTER `tx?` returns `Ok`, directly. |
| Inside the tx | **NEVER** call `outbound_http` here — the host denies it (an HTTP call is irreversible and can't roll back). |

## Semantics quick reference

- **Read-your-writes:** reads inside the closure see the tx's own pending
  writes. No snapshot-before-tx pattern is ever needed.
- **Cross-service enrollment:** a `peer::fetch` inside an open tx enrolls
  the callee's whole subtree into the SAME transaction. The callee's
  `store::*` auto-joins and the callee does **NOT** call `tx` (a callee
  that opens its own `tx` fails at commit). Only the **originating owner**
  commits. Any participant failure **poisons** the transaction → commit
  refuses, rollback only.
- **One envelope:** the whole call tree shares a single ~5s / 10MB
  transaction budget. Split work that won't fit.
- **`insert_many(table, &[&[Column]])`** — batch insert, in or out of a
  tx, returns the new ids in input order.
- **Denied inside a tx:** `outbound_http`; `background_jobs` *cancel* and
  *status* (a staged job isn't queryable until after commit — use the id
  `enqueue` returned). `background_jobs` *enqueue* is allowed (staged).

## 409 client contract

| Outcome | Status | Client does |
|---------|--------|-------------|
| Commit conflict (serialization abort) | **409** | Retry the **whole request** (no server-side auto-retry) |
| Domain error you raised in-closure | 409 / 422 / 404 | Fix input; do not retry blindly |
| Success | 2xx | Done |

## Cross-service sketch (verified shapes)

```rust boogy-snippet
use boogy_sdk::peer::PeerRequest;
use store::{Value, Column};

fn place_order(order_cols: Vec<Column>, reserve: serde_json::Value) -> Result<(), ApiError> {
    tx::<_, _, ApiError>(|| {
        store::insert("orders", &order_cols)?;
        let resp = peer_fetch(                          // enrolls B in this tx
            "boogy://owner/services/inventory",
            &PeerRequest::post("/reserve")
                .body_json(&reserve)
                .map_err(|e| ApiError::internal(e.to_string()))?,
        )
        .map_err(|e| ApiError::internal(format!("reserve failed: {e}")))?;
        if !resp.is_success() {                          // poisons → both roll back
            return Err(ApiError::conflict("out of stock"));
        }
        Ok(())
    })?;
    Ok(())
}
```

## Red flags

| Rationalization | Reality |
|-----------------|---------|
| "Snapshot the balance before the tx" | Read it INSIDE — read-your-writes closes the TOCTOU window. |
| "The callee should open its own tx" | It must NOT — it auto-enrolls; a callee `tx` fails at commit. |
| "Call outbound inside the tx so it's atomic" | Denied + irreversible. Enqueue a staged job instead. |
| "Auto-retry the 409 server-side" | No — the client retries the whole request. |

## Integration

← `boogy:boogy-data-modeling` (tables to write). Evolving schema:
`boogy:boogy-migrations` (separate `MigrationCtx::tx` surface; ships this
release). Handler-side job details: `boogy:boogy-background-jobs` (next
release).
