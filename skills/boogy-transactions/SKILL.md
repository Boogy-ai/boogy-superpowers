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
email, **producing a signature**, **writing or deleting a file** — can **never**
go inside a `tx`: the host **denies** it, because a sent HTTP request, a
released signature or a stored object cannot be rolled back when the tx aborts. Those use a different pattern (a **staged job
enqueued inside the tx**, the call **after** the tx commits, or — for signing —
**before** the tx opens) — see *The side-effect decision* and *Sequencing
discipline* below.
**A charge for a priced route is one of those irreversible effects, and it is the
one you do not control.** If your handler calls a priced route and then returns
an error, the store writes roll back and **the charge stands** — you read the
answer, so you paid for it. Rolling it back would make "open a transaction, call
a priced route, read the reply, roll back" a way to get someone else's paid work
for free. Every response tells you what it cost in `X-Boogy-Charged`, so this is
visible rather than silent. Two consequences for a handler that spends money:

- Do the fallible work **before** the priced call, for the same reason you do it
  before an irreversible write. A priced call after a step that can `?` is a
  bill you might not need.
- If the callee's own route opted into `refund_if_request_fails`, a later
  server-side failure of your request does void it — but that is the callee's
  choice, declared in their manifest, not something you can ask for.

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
  e.g. insert a message and bump its conversation's message count and
  last-message summary; insert an investment and increment a cached
  backer count.
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
    let id: u64 = req.params.parse("id")?;              // can fail (400)
    let body: RenameBody = validate_body(req.body())?;  // can fail (400/422)
    // `auth::load_owned(table, owner_col, id)` — not generic, and `None`
    // means "missing OR not yours", which is the same 404.
    let row = auth::load_owned(Note::TABLE, DEFAULT_OWNER_COL, id)?
        .ok_or_else(ApiError::not_found)?;              // can fail (404 if not yours)
    let note = Note::from_row(&row);
    let title = validate_title(&body.title)?;           // can fail (422)
    // …every fallible step is above this line. The write is last — nothing
    // after it can fail and orphan it, so no tx is needed.
    let updated = Note { title, ..note };
    db_update(id, &updated)?;                           // returns `()`
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
| Insert + a counter bump on a parent row | **YES** — insert + `upsert_increment`, parent read inside too |
| Read-modify-write where the read informs a decision (balance check, state transition) | **YES** |
| Mutation that must stay consistent across a `peer::fetch` | **YES**, at the entry handler |
| Expensive local CPU (hashing, key stretching, big parse, image work) | **Keep it OUT** — compute before opening the tx |

### Which dependent-write shape — `upsert_increment` or RMW?

The `tx` is required either way. What differs is *how the dependent row
is written*:

- **Pure counter** (`+1` / `-1`, plus summary columns you simply stamp) →
  **`upsert_increment` inside the `tx`.** One atomic keyed increment;
  concurrent bumps compose. Never read → add → `db_update`: that
  serializes the hot row into a conflict on every concurrent bump (paid
  for in retries, then a 503), and `db_update` writes the **whole** model
  row, so it silently clobbers increments another request committed after
  your read. Fold the summary columns into the *same* call via its `always`
  argument (or `on_insert` if the column is needed only at creation). See
  `boogy:boogy-data-modeling`.
- **Summary / denormalized row whose new value is computed from the old**
  (a rolling average, a state-machine transition, a balance check) →
  **read-modify-write inside the `tx`**, where the read sees a consistent
  snapshot and the tx's own pending writes.

### The shape (verbatim from real handlers)

The closure is **no-arg**. Every `db_*` / `store::*` op inside auto-joins
the ambient tx. Return `Ok(result)` to commit; return / propagate
`Err(ApiError)` (via `?` on any store error, or a raised domain error) to
roll the whole thing back.

```rust
let id = tx::<_, _, ApiError>(|| {
    let id = db_insert(&message)?;         // write 1
    upsert_increment(                      // write 2 — must agree with write 1
        Conversation::TABLE,
        &[store::Column {                  // the key columns, as WIT values
            name: Conversation::PEER.to_string(),
            val: store::Value::Text(peer.to_string()),
        }],
        Conversation::MESSAGE_COUNT,
        store::Value::Integer(1),
        UpsertColumns::none(),
    )?;
    Ok(id)                                 // Ok ⇒ commit; any Err ⇒ both roll back
})?;
```

#### The closure is `Fn` — you may not consume what it captures

A commit conflict re-runs the closure, so it cannot be `FnOnce`, and `FnMut`
would still not allow a captured value to be moved out. The bound is `Fn`.
Two natural-looking shapes therefore **do not compile** — *E0507: cannot move
out of a captured variable in an `Fn` closure*:

```rust ignore-snippet: both arms are code the borrow checker is meant to REJECT (E0507) — compiling it would assert the opposite of what it teaches
// WRONG — the struct-update `..conv` moves the captured `conv`.
tx::<_, _, ApiError>(|| {
    db_update(id, &Conversation { last_body: body, ..conv })?;
    Ok(())
})

// WRONG — matching by value moves the captured `existing`.
tx::<_, _, ApiError>(|| {
    match existing { Some(c) => db_update(c.id.get(), &updated)?, None => () }
    Ok(())
})
```

Build the owned value **before** the closure and borrow it inside, or match on
a reference. Constructing values *inside* the closure is always fine — the
restriction is only on consuming captures.

```rust
// RIGHT — the owned row is built by the caller; the closure only borrows it,
// and the match is on a reference.
fn upsert_conversation(existing: Option<Conversation>, updated: Conversation)
    -> Result<(), ApiError>
{
    tx::<_, _, ApiError>(|| {
        match &existing {                      // `&existing`, not `existing`
            Some(c) => db_update(c.id.get(), &updated)?,
            None    => { db_insert(&updated)?; }
        }
        Ok(())
    })?;
    Ok(())
}
```

### Worked example — insert + dependent counter (the chat bug class)

Two dependent writes: insert a message **and** keep the conversation's
count and last-message summary in sync. A partial failure must not leave
a message without its conversation bump (or a bump without its message),
so both go in one `tx`. This is exactly the handler that shipped without
atomicity — a comment said "atomically" but there was no `tx(||)` around
the writes.

```rust
use boogy_sdk::model::{Id, Model as _, Timestamp};
use boogy_sdk::Model;

#[derive(Model)]
#[model(table = "conversations")]
pub struct Conversation {
    #[pk]
    pub id: Id<Conversation>,
    /// The upsert's conflict target. `#[lookup_by]` derives the UNIQUE
    /// single-column index `upsert_increment` requires over its key
    /// columns — and the auto-PK does not qualify (it is not an indexed
    /// *column*, so keying on it is refused).
    #[lookup_by]
    pub peer: String,
    pub message_count: i64,
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

/// One WIT column, spelled once instead of at every counter call site.
fn text_col(name: &str, v: &str) -> store::Column {
    store::Column { name: name.to_string(), val: store::Value::Text(v.to_string()) }
}

fn int_col(name: &str, v: i64) -> store::Column {
    store::Column { name: name.to_string(), val: store::Value::Integer(v) }
}

/// Insert the message AND bump its conversation in ONE tx, so a partial
/// failure can't leave them disagreeing. Returns the message id.
fn record_message(peer: &str, body: &str, now: i64) -> Result<u64, ApiError> {
    tx::<_, _, ApiError>(|| {
        // Write 1: the message (auto-PK — Id::new(0) is the placeholder).
        let id = db_insert(&Message {
            id: Id::new(0),
            peer: peer.to_string(),
            body: body.to_string(),
            created_at: Timestamp::new(now),
        })?;

        // Write 2: `message_count += 1` as ONE atomic keyed increment —
        // concurrent bumps compose instead of colliding. The summary
        // columns ride along in the SAME call via `always` (written on both
        // the insert and the update path, last-write-wins — they must keep
        // changing on every message, so `on_insert` would not fit). Never a
        // separate `db_update` on this row: it writes every model column
        // and would clobber the counter with a stale, pre-read value.
        upsert_increment(
            Conversation::TABLE,
            &[text_col(Conversation::PEER, peer)],
            Conversation::MESSAGE_COUNT,
            store::Value::Integer(1),
            UpsertColumns::always(&[text_col(Conversation::LAST_BODY, body), int_col(Conversation::LAST_AT, now)]),
        )?;
        Ok(id) // Ok ⇒ both commit; any `?` Err ⇒ both roll back
    })
}
```

**Upserts insert on missing.** Here that is the point: the first message
to a new peer creates the conversation row. But the same behaviour is a
hazard whenever the counter lives on a **parent** the caller had to be
authorized against — if the parent is deleted between the authorization
read and the bump, `upsert_increment` **resurrects** it as a stub row
carrying only the key columns, the `always` and `on_insert` columns, and the
counter. Every other column comes back missing or defaulted, and nothing
errors.

So: **any parent existence / authorization read that feeds a counter bump
belongs INSIDE the same `tx` as the bump.** Load the parent, check the
caller may write under it, insert the child, bump the counter — all in one
closure. Reading the parent outside the tx is exactly the hole.

A debit + credit ledger move is the **genuine read-modify-write** case —
the read informs a decision, so it cannot be an atomic increment. Both
`store::update`s go inside one `tx`, with the sufficiency check read
**inside** so it sees the tx's own pending writes:

```rust
let new_balance: f64 = tx::<_, _, ApiError>(|| {
    // `Value` is the WIT store value enum — reach it as `store::Value`
    // (or `use store::Value;` first); it is not in unqualified scope.
    let bal = find_row_by("balances", "principal", store::Value::Text(me.clone()))?
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

**Rule 0 — open the transaction as late as possible, close it as early as
possible.** A tx is a lock on the rows it touches *and* a consumer of a
single ~5 s / 10 MB envelope (see *Semantics*). Everything the store does
not need to see stays outside it.

1. **Validate / parse** inputs — cheapest rejections first, no tx.
2. **Compute.** All expensive local CPU — hashing, key stretching, big
   parses, image/text work — happens **here, before the tx opens**.
   Wrapping the whole handler holds a store transaction open through a
   second of pure arithmetic: it burns the envelope on work the store
   isn't involved in and widens the conflict window for every other
   writer on those rows. Build the row struct, *then* open the tx.
   **This is now a correctness rule, not just a cost one:** a conflicted
   closure is **re-run** (`boogy:boogy-transaction-conflicts`), so
   anything inside it runs again — and anything with a side effect outside
   the store must not be there at all.
3. **Sign** — still before the tx opens. `signing_sign_digest` /
   `signing_sign_message` return a value the closure would consume, so they
   cannot be moved after the commit; and the host denies them inside a tx
   (a retried closure would mint one signature per attempt, none of them
   recallable). Produce the signature here, then record it in the tx below.
4. **Reads + writes + job ENQUEUES** inside ONE `tx` closure. Sufficiency,
   uniqueness, and parent existence / authorization checks go INSIDE — the
   closure reads its own writes (no pre-snapshot, no TOCTOU window), and a
   parent read left outside can be stale by the time you write.
5. **External calls (`outbound_http`) AFTER** `tx?` returns `Ok` — or
   better, enqueue an in-tx job to make them both atomic and durable.
6. **File writes** (`files_put_bytes`, `files_delete`) AFTER the tx too —
   both return `DeniedInTransaction` inside one. Minting an upload ticket
   (`files_create_upload`) IS allowed in a tx: it writes a row and hands back a
   URL, and moves no bytes.

## The side-effect decision

| Side effect | Where it goes |
|-------------|---------------|
| Must not be lost (email, webhook, charge) | **Enqueue a job INSIDE the tx** — the enqueue is *staged* and submitted only if the tx commits; the job does the outbound call after commit. Atomic with the data AND survives a crash between commit and send. |
| Fire-and-forget / latency-critical | Do it AFTER `tx?` returns `Ok`, directly. |
| **Signing** (`signing_sign_digest` / `signing_sign_message` / `signing_create_key` / `signing_remove_key`) | **BEFORE the tx opens** — you need the signature *inside* the handler, so it can't be deferred to after the commit the way an email can. Produce it first, then open the tx to record it. Signing after the tx commits also works when nothing in the closure depends on the signature. |
| Inside the tx | **NEVER** call `outbound_http` or any `signing` write here — the host denies both (an HTTP call and a released signature are irreversible and can't roll back). |

## Semantics quick reference

- **Read-your-writes:** reads inside the closure see the tx's own pending
  writes. No snapshot-before-tx pattern is ever needed.
- **Cross-service enrollment:** a `peer::fetch` inside an open tx enrolls
  the callee's whole subtree into the SAME transaction. The callee's
  `store::*` auto-joins and the callee does **NOT** call `tx` (a callee
  that opens its own `tx` fails at commit). Only the **originating owner**
  commits. Any participant failure **poisons** the transaction → commit
  refuses, rollback only. Opening one across a call tree, what a retry
  re-issues, and a callee that refuses to run outside its caller's
  transaction (`in_transaction()`): `boogy:boogy-cross-service-transactions`.
- **One envelope:** every transaction — single-service or spanning a
  whole `peer::fetch` tree — lives inside a single ~5 s / 10 MB budget,
  and **your own code inside the closure spends it too**. Compute before
  you open it; split work that won't fit.
- **`upsert_increment(table, key, counter, delta, columns)`** — the atomic
  keyed counter, the correct shape for every `+1` / `-1`. It **inserts on
  missing** (a vanished parent comes back as a stub), needs a unique index over
  its `key`, and a hot row wants a counter column with an empty `always`. Its
  rules in full: `boogy:boogy-counters`.
- **`insert_many(table, &[&[Column]])`** — batch insert, in or out of a
  tx, returns the new ids in input order.
- **Denied inside a tx:** `outbound_http`; every `signing` **write** —
  `signing_create_key`, `signing_sign_digest`, `signing_sign_message`,
  `signing_remove_key` (each returns `SignError::CapabilityDenied("signing is
  not allowed inside a transaction…")` — match the variant, not the message;
  `signing_list_keys` is a read and is
  allowed); `connections_begin` and `connections_revoke` (each returns
  `ConnectionError::CapabilityDenied` — an authorization and a revocation
  are both irreversible external effects; `connections_status` is a read
  and is allowed, see `boogy:boogy-oauth-connections`);
  `background_jobs` *cancel* and *status* (a staged job isn't
  queryable until after commit — use the id `enqueue` returned).
  `background_jobs` *enqueue* is allowed (staged). A denial does **not**
  poison the transaction: handle the error and the tx can still commit.

## 🚩 Smells — a missing `tx` hides here

Scan a handler for these. Each is a partial-write waiting to corrupt data:

| Smell in the code | Fix |
|-------------------|-----|
| Insert a row, **then** update a count / summary / denormalized row — no `tx` around them | Wrap both writes in one `tx::<_, _, ApiError>(\|\| …)`. |
| A counter maintained by **read → `+ 1` → `db_update`** (even inside a tx) | `upsert_increment` instead — `db_update` writes the whole row and clobbers concurrent increments; RMW serializes the hot row. |
| A counter row's other columns written by a **second `db_update`** after the increment | Fold them into the same `upsert_increment` call's `always` argument (or `on_insert` if the column is only needed at creation). |
| A parent loaded / authorization-checked **outside** the tx, its counter bumped inside | Move the parent read inside the same tx — upserts insert-on-missing, so a deleted parent is resurrected as a stub. |
| Expensive computation (hashing, key stretching, big parse) **inside** the `tx` closure | Compute first; open the tx around the store work only. |
| A **read-modify-write upsert** (find → update-or-insert) outside a tx | Move the find + write inside one `tx` — read-your-writes, no TOCTOU. |
| A comment that says **"atomically" / "in one tx"** but there is **no `tx(\|\|)`** in the body | The exact bug class this skill exists for — add the `tx`. |
| Two `store::update`s that must agree (debit + credit) sitting bare | One `tx`; check sufficiency **inside**. |
| A read, a `count` or an `update_where` inside a `tx` with no filter on a column that leads an index | It takes the whole table as its read set: `boogy:boogy-transaction-conflicts`. |
| A multi-write mutation that fans out via `peer::fetch` with no tx at the entry | Open the `tx` at the entry handler — the call tree enrolls. |

## Red flags

These thoughts mean STOP — each one precedes a mistake this platform actually produces.

| Thought | Reality |
|---|---|
| "It's just two writes, they'll both succeed" | Until one doesn't — partial write, corrupt state. ≥ 2 dependent writes ⇒ `tx`. |
| "It's only one write, so no `tx` needed" | Not the test. If fallible work runs after the write, a partial state is invalid — wrap it in `tx`, **or move the write after all fallible work** so nothing can strand it. |
| "I'll write the row, then validate / call out / derive the rest" | Backwards. Do the fallible work FIRST; the irreversible write goes LAST (or in a `tx`). A write before a step that can `?` is a partial-state bug. |
| "Snapshot the balance before the tx" | Read it INSIDE — read-your-writes closes the TOCTOU window. |
| "A counter is just read, add one, write back — the tx makes it safe" | The tx makes it *correct*, not *scalable*: every concurrent bump conflicts, and a whole-row `db_update` loses increments outright. The conflicts are retried, so you see latency and eventually a 503 rather than an error — which is exactly why this stays invisible until load. Use `upsert_increment`; declare it a counter column (`#[model(counter(name = "..."))]`) if the row is hot. |
| "I read the counter inside the tx, so branching on it is safe" | No — a counter read takes **no conflict range**. The value may be stale and a concurrent increment will NOT trigger a retry; it is silently discarded. Express the decision as a `delete_where` / `update_where` predicate, which serializes the rows it matches. Give that predicate a filter on a column that **leads** an index or the sweep takes the whole table as its read set. |
| "Wrap the whole handler in one tx — simpler to reason about" | It holds the ~5 s envelope open through your CPU and locks rows nothing is writing yet. Compute first, open late. |
| "I checked the parent exists before opening the tx" | Stale by bump time — and the upsert won't error, it inserts a stub parent. Read it inside. |
| "Sign inside the tx so the signature and the row land together" | Denied. A retried closure would mint a fresh signature per attempt, and a signature can't be un-issued. Sign **before** the tx, then record the signature inside it. |
| "The closure can keep a bit of state between iterations / bump a local counter / fire a notification" | It may run more than once. Attempt 2 starts from attempt 1's leftovers while the store discarded attempt 1's writes, so your code and the database disagree. `Fn`, not `FnMut`, on purpose. |
| "A 409 means retry" | **No 409 is retryable.** `ConstraintViolation` (duplicate key, a required column left null or absent) is deterministic, `Poisoned` would re-run a failed participant, `CommitUnknown` may double-apply. The one retryable outcome, `Conflict`, is retried *for* you and doesn't reach the client. |
| "I'll pass the transaction handle into the helper" | `tx(\|\| ...)` takes a **no-arg** closure. Store calls inside auto-join the ambient transaction. A handle parameter means you have invented a second mechanism. |
| "The service I'm calling should open its own transaction too" | Callees must NOT call `tx`. One transaction spans the whole call tree; a nested `tx` in a callee is a bug, not defence in depth. |
| "I'll call the payment API inside the transaction so it's atomic" | `outbound_http` is **denied** while a transaction is open. The body is re-runnable on retry, so it may hold no irreversible external effect. Enqueue a job inside the tx and make the call from the job. |
| "One participant failed, I'll catch it and commit the rest" | Any participant failure **poisons** the transaction. Commit will refuse; rollback is the only outcome. Catching the error does not un-poison it. |

## Integration

↓ Its parts: `boogy:boogy-transaction-conflicts` (read sets, retries, 409
and 503) and `boogy:boogy-cross-service-transactions` (one transaction across
a `peer::fetch` tree). ← `boogy:boogy-data-modeling` (tables to write) and `boogy:boogy-counters`
(the counter row: `upsert_increment`, not read-modify-write). Evolving schema:
`boogy:boogy-migrations` (separate `MigrationCtx::tx` surface; ships this
release). Handler-side job details: `boogy:boogy-background-jobs` (next
release).
