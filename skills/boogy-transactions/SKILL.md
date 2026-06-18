---
name: boogy-transactions
description: Use when a state change must roll back if later work in the handler fails, when two or more writes must agree, writing rows atomically, combining writes with cross-service calls, handling 409s, or placing side effects near writes
---

# Transactions on Boogy

Multi-row atomic writes go through a **no-arg closure**: `tx(|| { ... })`.
There is no transaction handle — inside the closure you call the *same*
`store::*` / `db_*` / `find_row_by` functions as outside; they join the
ambient transaction. `Ok` commits, `Err` rolls back, a panic discards it.

**The request is your unit of work.** If anything in a handler fails, the caller
must see *no* partial state change — the same transaction discipline you'd apply
to any SQL-backed service. You reach that bar two ways, chosen deliberately:
**wrap the writes in a `tx`** so an error rolls them back, **or** **sequence a
single write last** so nothing fallible runs after it. That *intent* — integrity
on error — decides the design, not a write count.

**But do NOT reflexively wrap a handler in `tx`.** A `tx` guards **store writes
only**. An *irreversible* side effect — an `outbound_http` call, a payment, an
email — can **never** go inside a `tx`: the host **denies** it, because a sent
HTTP request cannot be rolled back when the tx aborts. Those use a different
pattern (a **staged job enqueued inside the tx**, or the call **after** the tx
commits) — see *The side-effect decision* and *Sequencing discipline* below.
Read this skill before you reach for `tx`; the right shape is often not "wrap
everything."

## ⚖️ THE DECISION RULE — wrap writes in `tx` when an error must undo them

Wrap store writes in `tx::<_, _, ApiError>(|| { … })` **whenever an error
later in the handler should logically roll back the state change.** The
criterion is rollback-on-error *intent*, not a write count: even a
**single** write belongs in a `tx` if fallible work runs after it (or
alongside it) and a partial state would be invalid. Multiple writes that
must agree are the most common case of this, not the defining one.

The canonical cases:

- **A write followed by fallible work** — a single `db_insert` (or
  `store::update`/`delete`) where validation, a derived computation, or
  any `?`-returning step *after* the write would otherwise leave the row
  stranded. Move the write inside the `tx` so that `Err` discards it.
- An insert **plus a dependent counter / summary / denormalized row** —
  e.g. insert a message and bump its conversation's last-message summary;
  insert an investment and increment a cached backer count.
- A **multi-row invariant** — a ledger debit + credit; a "move" that
  deletes here and inserts there.
- An **upsert that reads-then-writes** — find-then-update-or-insert: the
  read and the write must see one consistent snapshot (read-your-writes).
- Any **"all-or-nothing"** mutation you'd describe as "atomically".

A **single** write with **no fallible work after it** does **not** need an
explicit `tx` — it is already atomic on its own. **Reads alone never** need
one.

### Single write + fallible work: two correct shapes (prefer write-last)

When a handler has **one** write and fallible work around it, you have two
correct shapes. Prefer the first when you can reorder:

1. **Sequence the write LAST.** Do every fallible step first — parse, validate,
   authorize, derive values, any `?`-returning call — and make the `db_*` write
   the **final statement**, reached only once everything that could fail has
   succeeded. Nothing runs after it, so no error can strand it and you need no
   `tx`. Prefer this for a single write: design the handler so the irreversible
   step happens last.
2. **Wrap it in `tx`.** When the write *must* precede later fallible work — you
   need its generated id to do more fallible work, or the steps genuinely can't
   be reordered — put it in `tx::<_, _, ApiError>(|| …)` so `Err` rolls it back.

```rust
// WRITE-LAST: all fallible work proves out BEFORE the single write.
fn rename(req: &mut Req<'_>) -> Result<Json<NoteDto>, ApiError> {
    let id: u64 = req.params.get("id").parse().map_err(|_| ApiError::bad_request("id"))?;
    let body: RenameBody = req.json()?;                 // can fail
    let note = auth::load_owned::<Note>(id)?;           // can fail (404 if not yours)
    let title = validate_title(&body.title)?;           // can fail (422)
    // …every fallible step is above this line. The write is last — nothing
    // after it can fail and orphan it, so no tx is needed.
    let updated = db_update(id, &Note { title, ..note })?;
    Ok(Json(updated.into()))
}
```

Reach for `tx` (not reordering) whenever there are **≥2 writes**, a
read-modify-write upsert, or writes you genuinely can't move after the fallible
work.

| What the handler does | Wrap in `tx`? |
|-----------------------|:-------------:|
| One write, nothing fallible after it | **No** — already atomic |
| One write **then** fallible work that should undo it on `Err` | **`tx`** — or **reorder the write last** so nothing fallible follows it |
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
| "It's only one write, so no `tx` needed" | Not the test. If fallible work runs after the write, a partial state is invalid — wrap it in `tx`, **or move the write after all fallible work** so nothing can strand it. |
| "I'll write the row, then validate / call out / derive the rest" | Backwards. Do the fallible work FIRST; the irreversible write goes LAST (or in a `tx`). A write before a step that can `?` is a partial-state bug. |
| "Snapshot the balance before the tx" | Read it INSIDE — read-your-writes closes the TOCTOU window. |
| "The callee should open its own tx" | It must NOT — it auto-enrolls; a callee `tx` fails at commit. |
| "Call outbound inside the tx so it's atomic" | Denied + irreversible. Enqueue a staged job instead. |
| "Auto-retry the 409 server-side" | No — the client retries the whole request. |

## Integration

← `boogy:boogy-data-modeling` (tables to write). Evolving schema:
`boogy:boogy-migrations` (separate `MigrationCtx::tx` surface; ships this
release). Handler-side job details: `boogy:boogy-background-jobs` (next
release).
