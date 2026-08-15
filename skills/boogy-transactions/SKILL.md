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
email, **producing a signature** — can **never** go inside a `tx`: the host
**denies** it, because a sent HTTP request or a released signature cannot be
rolled back when the tx aborts. Those use a different pattern (a **staged job
enqueued inside the tx**, the call **after** the tx commits, or — for signing —
**before** the tx opens) — see *The side-effect decision* and *Sequencing
discipline* below.
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
   closure is **re-run** (see *Conflicts are retried for you* below), so
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
  refuses, rollback only.
- **One envelope:** every transaction — single-service or spanning a
  whole `peer::fetch` tree — lives inside a single ~5 s / 10 MB budget,
  and **your own code inside the closure spends it too**. Compute before
  you open it; split work that won't fit.
- **`upsert_increment(table, key, counter, delta, columns)`** — atomic keyed
  counter, the correct shape for every `+1` / `-1`. Requires a **unique
  index over the `key` columns** (`#[lookup_by]` on a single column
  derives one; the auto-PK does not qualify) — without one the call is
  **refused**, not silently scanned. `columns` is an `UpsertColumns {
  always, on_insert }`: `always` columns are written on **both** the insert
  and the update path; `on_insert` columns only by the call that creates the
  row, never touched again. **Inserts on missing** — it never errors on a
  vanished row, it recreates it as a stub. Because the first call for a key
  is an insert, **`key ∪ always ∪ on_insert` must cover every non-nullable
  column that has no default**, or that call is refused with
  `ConstraintViolation` naming the column. Give the column a `#[default = …]`
  for a static value, or put it in `on_insert` for a value computed at call
  time, rather than padding `always` — an `always` column is rewritten on the
  *update* arm too, which silently resets an accumulator on every later
  bump. On a **plain** column the increment still rewrites the row, so
  concurrent bumps take a conflict range; those conflicts are retried, but a
  genuinely hot row will burn the attempt budget and 503. Then declare the
  column `#[counter]` and pass an **empty `always`** — the value lives in its
  own cell and the add takes no conflict range at all. `on_insert` does not
  buy that conflict-freedom on the read-modify-write arm of a plain (non-
  `#[counter]`) target column: there, the counter itself still goes through
  the ordinary row update regardless of `on_insert`. Cost: a `#[counter]`
  column cannot back an index. See
  `boogy:boogy-data-modeling`.
- **`insert_many(table, &[&[Column]])`** — batch insert, in or out of a
  tx, returns the new ids in input order.
- **Denied inside a tx:** `outbound_http`; every `signing` **write** —
  `signing_create_key`, `signing_sign_digest`, `signing_sign_message`,
  `signing_remove_key` (each returns `SignError::CapabilityDenied("signing is
  not allowed inside a transaction…")` — match the variant, not the message;
  `signing_list_keys` is a read and is
  allowed); `background_jobs` *cancel* and *status* (a staged job isn't
  queryable until after commit — use the id `enqueue` returned).
  `background_jobs` *enqueue* is allowed (staged). A denial does **not**
  poison the transaction: handle the error and the tx can still commit.

## Reads inside the tx — the whole table is your read set unless the planner can narrow it

A transaction conflicts on what it **read**, not only on what it wrote.
Reads inside the closure go through the same planner as reads outside
it. *Which* read you wrote decides how much of the table you conflict
with:

- **The planner can serve the query from an index** → the transaction
  conflicts only on the index sub-range(s) it seeked plus the rows it
  actually fetched. A concurrent write outside those bounds is invisible
  to you.
- **No usable index** → the read scans, and **every row of that table
  joins your read set**. Any concurrent write anywhere in that table
  aborts your commit — including rows your filter never matched. Past a
  row threshold (half the one that guards a scan outside a transaction,
  because this scan costs more) the read is **refused** in dev/CI with an
  error naming the table, the conflict range the read took, and the fix
  it can honestly name — the index that would serve the query, or, when
  an index already leads a column you constrained, what would have
  *bounded* the walk instead, or, when the query constrains no column at
  all, that there is nothing to index. So you meet this while writing the
  handler rather than as intermittent 409s later. It is a WARNING, not a
  refusal: the read is served and the transaction is not poisoned. Act on
  it anyway — index the read, bound it, or hoist it out of the closure —
  because the conflict range it describes is what turns into intermittent
  409s under concurrency.

So on a table anyone else writes, **narrowing the reads a transaction
performs is a contention fix, not a speed optimization**. It is also
why `#[counter]` alone may not quiet a hot path: the counter removes the
*write* conflict, and an unindexed search in the same closure puts a
whole-table one straight back.

**The rule: give the read a filter on a column that LEADS an index.**
Equality, `where_in`, `where_null` and a range (`>` / `>=` / `<` / `<=`)
all seek — each becomes one bounded index sub-range, or a fan-out of
them, and the fan-out is the read set. It is enough that **one** of the
AND-filters does this; if none does, an `.or()` still seeks when *every*
arm carries an equality on a leading index column. A filter on a column
that appears only *later* in a composite index does not seek — it is
applied per row afterwards, so it narrows the result but not the
conflict range. This is the same rule that decides whether a read is
index-served outside a `tx`; what changes inside one is the price of
missing it.

**One thing is stricter inside a `tx`.** A read whose *only* narrowing
is its SORT — ordered, with no filter on any leading index column —
takes the whole table unless it also skips the total. `.fetch_page(…)`,
`.fetch_one()` and a `.limit()`ed `.fetch_all()` ask for no total; that,
plus the page bound, is what lets such a read stop at the page and ride
the sort index. `.fetch_all_with_total()` and a *filtered* `.count()`
want an exact number, so they drain. Inside a tx, don't ask for a total
you won't use.

**Predicate writes follow the same rule.** `update_where` /
`delete_where` inside a `tx` seek the same index sub-range a read does:
give the predicate a filter on a column that **leads** an index and only
that sub-range is in the read set, so a concurrent write elsewhere in
the table no longer aborts you. The guarantee is unchanged — a
concurrent insert or update that *would* have matched the predicate
still conflicts, because its index entry lands inside the sub-range the
sweep walked. With no such filter they still scan, and an *unfiltered*
sweep ("update every row") reads the whole table because that is what it
is asking about.

**These reads take the whole table however you index it:**

- a bare `.count()` with no filter — it reads no rows (it counts row
  keys), but it does read the whole key range, so it conflicts with
  **any** concurrent write to that table: an insert, a delete, and an
  update too, since updating a row rewrites its key.

**`_id` leads no index**, by construction — so `where_in` over a list of
ids scans, and there is no index to add. Hydrate by id with `get_many`:
point gets, which conflict only on the rows they return.

**Index-served is not the same as narrow.** The read set is the
sub-range the seek covered, so an equality matching most of the table (a
status column where nearly every row has the same status) is
index-served and still conflicts with nearly every writer. Seek on the
*selective* column.

**There is a ceiling.** A search inside a transaction that has to work
through more than ~50,000 rows — matches on an index walk, rows touched
on a scan — is refused with an error pointing you at the
cursor/pagination API, rather than silently burning the ~5 s / 10 MB
envelope. Read a page, not a table.

## Conflicts are retried for you — and what 409 means now

**A commit conflict never reaches your client.** When the store aborts a
commit because another transaction's writes overlapped this one's
read/write set, `tx` **re-runs the closure and commits again**. Nothing
from an aborted attempt landed, so re-running is safe. The attempt budget
is set by the platform (3 total by default — the original attempt plus two
retries). There is no delay between attempts: the conflict resolved
because some other writer *won and committed*, so the next read sees a
settled value.

**So the closure must be re-runnable — this is what `Fn` means here.**
`tx` takes an `Fn`, not an `FnOnce`, precisely because it may run more than
once. Everything *before* the closure — parsing, auth, guards, expensive
computation — runs exactly once; everything *inside* it runs once per
attempt. That is why *Sequencing discipline* above says to compute before
opening the tx: under retry that guidance stops being about envelope
hygiene and becomes about correctness and cost. Two consequences:

- **No side effects in the closure.** Nothing that changes state outside
  the store — no counter you bump on a captured variable, no "we already
  charged them" flag. Attempt 2 would start from attempt 1's leftovers
  even though the store discarded attempt 1's writes, so your code and the
  database would disagree. (`outbound_http` and `signing` writes are denied
  inside a tx and a job enqueue is staged, so the platform already blocks the
  worst versions.)
- **A closure that must consume a value clones it inside**, or computes
  the value before the tx and borrows it.

**Retries exhausted is 503, not 409.** When what a transaction touched
stays contended for the whole attempt budget — the rows it writes, or the
rows its reads put in the read set — you get `TooContended` → **HTTP 503
with a retry
hint**. That is congestion, and it belongs with the platform's other
congestion codes (429 = you are too fast; 503 = the host is contended; 504
= the request took too long). Persistent `TooContended` is a signal about
the *data model* — a single row every request writes, **or** a search
inside the closure the planner could not serve from an index, which
conflict-ranged the whole table (see *Reads inside the tx* above). Split
the key, make the column a `#[counter]`, or narrow the read — filter on a
column that leads an index, and prefer a selective one.

**409 now means "your write genuinely conflicts"** — something the caller
must resolve — and never "the store was busy". Several outcomes still share
it, and none of them is retryable. Match the `StoreError` **variant**,
never the status and never the message text.

| Outcome | `StoreError` variant | Status | Client does |
|---------|----------------------|--------|-------------|
| Commit conflict (serialization abort) | `Conflict` | — | **Nothing — `tx` already retried it.** It surfaces (as 409) only if the platform has auto-retry switched off |
| Retry attempts exhausted — a contended row it writes, or a read whose conflict range was the whole table | `TooContended` | **503** | Retry with backoff — and fix the data model if it persists (split the key, `#[counter]`, or narrow the read — filter on a column that leads an index) |
| Platform saturated with concurrent transactions | `ResourceExhausted` | 503 | Retry shortly |
| Unique-index duplicate, a **not-null column left null or absent** on a row-creating write, or "already exists" | `ConstraintViolation` | **409** | **Do not retry** — deterministic, it fails identically every time. Change the input |
| A participant service in the transaction failed | `Poisoned` | **409** | **Deliberately not retried** — re-running would re-execute the participant that already failed, once per attempt, and across a call tree once per callee per attempt. Fix the participant |
| Commit outcome genuinely unknown | `CommitUnknown` | 409 | **Do not blindly retry** — it may have landed. Read the state back first |
| Domain error you raised in-closure | — | 409 / 422 / 404 | Fix input. An `Err` from the closure is never retried — it is deterministic, so it rolls back and propagates unchanged |
| Success | — | 2xx | Done |

`Conflict` means exactly one thing — a serialization abort — which is why
it is the only arm the retry loop touches. That is also why a duplicate-key
insert is `ConstraintViolation` and not `Conflict`: keyed on the old
overloaded meaning, the loop would have retried a duplicate insert to
exhaustion.

```rust
// Re-roll a slug ONLY on a unique rejection — that is deterministic, so
// nothing retries it for you and a different slug is the actual fix.
// A serialization abort does not appear here: `tx` retried it.
fn insert_with_free_slug(mut link: Link) -> Result<u64, ApiError> {
    for _ in 0..5 {                     // bound it; a re-roll loop must terminate
        match db_insert(&link) {
            Ok(id) => return Ok(id),
            Err(StoreError::ConstraintViolation(_)) => {
                link.slug = fresh_slug();               // taken; try another
                continue;
            }
            Err(e) => return Err(e.into()),
        }
    }
    Err(ApiError::conflict("could not allocate a free slug"))
}
```

**Never write a `_ =>` catch-all over these arms.** It silently folds
`Poisoned` and `CommitUnknown` into whatever the fallback does — which is
the exact failure the separate variants exist to prevent.

## Cross-service consistency — open the tx at the entry handler

When a mutation must stay consistent **across a `peer::fetch`**, open the
`tx` once, at the **entry handler** (the root of the call tree) — never in
a callee. It then spans the **entire call tree as one store transaction**,
under the enrollment / poisoning / one-envelope semantics listed above. A
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
| A filtered `Query` / `.count()` **inside** a `tx` where no filter is on a column that **leads** an index | Declare the access pattern so it's index-served — otherwise the read takes the whole table as its read set and every concurrent writer conflicts with you. The same declaration narrows an `update_where`/`delete_where` in that closure; without one, a predicate write scans too. |
| `.fetch_all_with_total()` inside a `tx` where nothing reads the total | Use `.fetch_all()` / `.fetch_page()` — the exact total forces a drain, and an unnarrowed one forces a scan. |
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
| "A counter is just read, add one, write back — the tx makes it safe" | The tx makes it *correct*, not *scalable*: every concurrent bump conflicts, and a whole-row `db_update` loses increments outright. The conflicts are retried, so you see latency and eventually a 503 rather than an error — which is exactly why this stays invisible until load. Use `upsert_increment`; add `#[counter]` if the row is hot. |
| "I read the counter inside the tx, so branching on it is safe" | No — a `#[counter]` read takes **no conflict range**. The value may be stale and a concurrent increment will NOT trigger a retry; it is silently discarded. Express the decision as a `delete_where` / `update_where` predicate, which serializes the rows it matches. Give that predicate a filter on a column that **leads** an index or the sweep takes the whole table as its read set. |
| "Wrap the whole handler in one tx — simpler to reason about" | It holds the ~5 s envelope open through your CPU and locks rows nothing is writing yet. Compute first, open late. |
| "Nobody writes the rows my tx reads, so the read can't conflict" | Only if the read was index-served, and only over the sub-range it seeked. If it scanned, the whole table is in your read set and *any* concurrent write to it aborts you, matching row or not. |
| "I added an index on that column, so the in-tx read is fine" | Only if the filtered column **leads** that index — its own, or the first column of a composite. A column appearing only *later* in a composite is a per-row filter, not a seek, so it narrows the result and not the conflict range. The same is true of an `update_where`/`delete_where` predicate. |
| "I checked the parent exists before opening the tx" | Stale by bump time — and the upsert won't error, it inserts a stub parent. Read it inside. |
| "The callee should open its own tx" | It must NOT — it auto-enrolls; a callee `tx` fails at commit. |
| "Call outbound inside the tx so it's atomic" | Denied + irreversible. Enqueue a staged job instead. |
| "Sign inside the tx so the signature and the row land together" | Denied. A retried closure would mint a fresh signature per attempt, and a signature can't be un-issued. Sign **before** the tx, then record the signature inside it. |
| "I'll write my own retry loop around `tx` for conflicts" | Already done, one layer down, where re-running costs only the closure. Yours re-runs the whole handler — parsing, auth, guards, the expensive work you carefully moved *out* of the tx. |
| "The closure can keep a bit of state between iterations / bump a local counter / fire a notification" | It may run more than once. Attempt 2 starts from attempt 1's leftovers while the store discarded attempt 1's writes, so your code and the database disagree. `Fn`, not `FnMut`, on purpose. |
| "A 409 means retry" | **No 409 is retryable.** `ConstraintViolation` (duplicate key, a required column left null or absent) is deterministic, `Poisoned` would re-run a failed participant, `CommitUnknown` may double-apply. The one retryable outcome, `Conflict`, is retried *for* you and doesn't reach the client. |
| "The 503 means the platform is broken" | It means the rows this transaction touched are contended past the retry budget (`TooContended`) — a hot row it writes, **or** a whole table an unindexed read put in its read set — or the platform is at its transaction cap (`ResourceExhausted`). Back off — then fix the data model, which is what a persistent `TooContended` is telling you. |

## Integration

← `boogy:boogy-data-modeling` (tables to write — including the counter
row: `upsert_increment`, not read-modify-write). Evolving schema:
`boogy:boogy-migrations` (separate `MigrationCtx::tx` surface; ships this
release). Handler-side job details: `boogy:boogy-background-jobs` (next
release).
