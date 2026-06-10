---
name: boogy-transactions
description: Use when a handler does two or more writes that must agree, writing multiple rows atomically, combining writes with cross-service calls, handling 409s, or placing side effects near writes
---

# Transactions on Boogy

Multi-row atomic writes go through a **no-arg closure**: `tx(|| { ... })`.
There is no transaction handle — inside the closure you call the *same*
`store::*` / `db_*` / `find_row_by` functions as outside; they join the
ambient transaction. `Ok` commits, `Err` rolls back, a panic discards it.

## ⚖️ THE DECISION RULE — wrap writes in `tx` when they must agree

Wrap store writes in `tx::<_, _, ApiError>(|| { … })` **whenever a handler
performs two or more writes that must agree.** The canonical cases:

- An insert **plus a dependent counter / summary / denormalized row** —
  e.g. insert a message and bump its conversation's last-message summary;
  insert an investment and increment a cached backer count.
- A **multi-row invariant** — a ledger debit + credit; a "move" that
  deletes here and inserts there.
- An **upsert that reads-then-writes** — find-then-update-or-insert: the
  read and the write must see one consistent snapshot (read-your-writes).
- Any **"all-or-nothing"** mutation you'd describe as "atomically".

A **single** write does **not** need an explicit `tx` — it is already
atomic on its own. **Reads alone never** need one.

| What the handler does | Wrap in `tx`? |
|-----------------------|:-------------:|
| One `db_insert` / `store::update` / `store::delete` | **No** — already atomic |
| Reads only (list, point-lookup, query) | **No** |
| ≥ 2 writes that must all land or none (insert + dependent update, debit + credit) | **YES** |
| Read-modify-write upsert (find → update-or-insert) | **YES** |
| Mutation that must stay consistent across a `peer::fetch` | **YES**, at the entry handler |

### The shape (verbatim from real handlers)

The closure is **no-arg**. Every `db_*` / `store::*` op inside auto-joins
the ambient tx. Return `Ok(result)` to commit; return / propagate
`Err(ApiError)` (via `?` on any store error, or a raised domain error) to
roll the whole thing back.

```rust
let id = tx::<_, _, ApiError>(|| {
    let id = db_insert(&message)?;     // write 1
    db_update(conv_id, &conversation)?; // write 2 — depends on write 1 agreeing
    Ok(id)                              // Ok ⇒ commit; any Err ⇒ both roll back
})?;
```

### Worked example — insert + dependent upsert (the chat bug class)

Two dependent writes: insert a message **and** keep the conversation's
last-message summary in sync. A partial failure must not leave a message
without its conversation bump (or a bump without its message), so both go
in one `tx`. This is exactly the handler that shipped without atomicity —
a comment said "atomically" but there was no `tx(||)` around the writes.

```rust boogy-snippet
use boogy_sdk::model::{Id, Timestamp};
use boogy_sdk::store::Val;
use boogy_sdk::Model;

#[derive(Model)]
#[model(table = "conversations")]
pub struct Conversation {
    #[pk]
    pub id: Id<Conversation>,
    #[lookup_by]
    pub peer: String,
    pub last_body: String,
    pub last_at: Timestamp,
}

#[derive(Model)]
#[model(table = "messages")]
pub struct Message {
    #[pk]
    pub id: Id<Message>,
    pub peer: String,
    pub body: String,
    pub created_at: Timestamp,
}

/// Insert the message AND upsert its conversation summary in ONE tx, so a
/// partial failure can't leave them disagreeing. Returns the message id.
fn record_message(peer: &str, body: &str, now: i64) -> Result<u64, ApiError> {
    tx::<_, _, ApiError>(|| {
        // Write 1: the message (auto-PK — Id::new(0) is the placeholder).
        let id = db_insert(&Message {
            id: Id::new(0),
            peer: peer.to_string(),
            body: body.to_string(),
            created_at: Timestamp::new(now),
        })?;

        // Write 2: read-modify-write the conversation summary. The read
        // inside the tx sees a consistent snapshot — no TOCTOU window.
        let existing: Option<Conversation> =
            db_find_by::<Conversation>(Conversation::PEER, Val::Text(peer.to_string()))?
                .into_iter()
                .next();
        match existing {
            Some(c) => db_update(c.id.get(), &Conversation {
                id: c.id,
                peer: peer.to_string(),
                last_body: body.to_string(),
                last_at: Timestamp::new(now),
            })?,
            None => { db_insert(&Conversation {
                id: Id::new(0),
                peer: peer.to_string(),
                last_body: body.to_string(),
                last_at: Timestamp::new(now),
            })?; }
        }
        Ok(id) // Ok ⇒ both commit; any `?` Err ⇒ both roll back
    })
}
```

A debit + credit ledger move is the same shape — both `store::update`s
inside one `tx`, with the sufficiency check read **inside** so it sees the
tx's own pending writes:

```rust
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

## Cross-service consistency — open the tx at the entry handler

When a mutation must stay consistent **across a `peer::fetch`**, open the
`tx` once, at the **entry handler** (the root of the call tree). It spans
the **entire `peer::fetch` call tree as one store transaction**:

- Each callee's `store::*` ops **auto-join** the same tx — callees do
  **NOT** call `tx` (a callee that opens its own `tx` fails at commit).
- Only the **originating owner** commits.
- **Any participant failure poisons** the tx → commit refuses, rollback
  only. A non-success peer response you turn into `Err(…)` rolls back the
  whole tree.
- A commit conflict surfaces as **409**; the client retries the **whole
  request** (no server-side auto-retry).
- `outbound_http` and `background_jobs` (cancel/status) are **denied while
  a tx is open**.
- The whole tree shares **one ~5s / 10MB store-transaction envelope** —
  split work that won't fit.

## Cross-service sketch (verified shapes)

```rust boogy-snippet
use boogy_sdk::peer::PeerRequest;
use store::{Value, Column};

fn place_order(order_cols: Vec<Column>, reserve: serde_json::Value) -> Result<(), ApiError> {
    tx::<_, _, ApiError>(|| {
        store::insert("orders", &order_cols)?;
        let resp = peer_fetch(                          // enrolls B in this tx
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

## 🚩 Smells — a missing `tx` hides here

Scan a handler for these. Each is a partial-write waiting to corrupt data:

| Smell in the code | Fix |
|-------------------|-----|
| Insert a row, **then** update a count / summary / denormalized row — no `tx` around them | Wrap both writes in one `tx::<_, _, ApiError>(\|\| …)`. |
| A **read-modify-write upsert** (find → update-or-insert) outside a tx | Move the find + write inside one `tx` — read-your-writes, no TOCTOU. |
| A comment that says **"atomically" / "in one tx"** but there is **no `tx(\|\|)`** in the body | The exact bug class this skill exists for — add the `tx`. |
| Two `store::update`s that must agree (debit + credit) sitting bare | One `tx`; check sufficiency **inside**. |
| A multi-write mutation that fans out via `peer::fetch` with no tx at the entry | Open the `tx` at the entry handler — the call tree enrolls. |

## Red flags

| Rationalization | Reality |
|-----------------|---------|
| "It's just two writes, they'll both succeed" | Until one doesn't — partial write, corrupt state. ≥ 2 dependent writes ⇒ `tx`. |
| "Snapshot the balance before the tx" | Read it INSIDE — read-your-writes closes the TOCTOU window. |
| "The callee should open its own tx" | It must NOT — it auto-enrolls; a callee `tx` fails at commit. |
| "Call outbound inside the tx so it's atomic" | Denied + irreversible. Enqueue a staged job instead. |
| "Auto-retry the 409 server-side" | No — the client retries the whole request. |

## Integration

← `boogy:boogy-data-modeling` (tables to write). Evolving schema:
`boogy:boogy-migrations` (separate `MigrationCtx::tx` surface; ships this
release). Handler-side job details: `boogy:boogy-background-jobs` (next
release).
