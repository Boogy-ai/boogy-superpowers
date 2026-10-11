---
name: boogy-counters
description: Use when a value only ever goes up or down (views, likes, stock, quota, "last active at"), when incrementing a count with upsert_increment or declaring a counter column, when a write is contending on a hot row, when deciding between a counter and a maintained rollup, or when a counter read is refused inside a transaction
---

# Counters and accumulators

A **counter** is a single cell holding a number, moved by an atomic operation
that never reads the previous value. Two writers to the same counter never
conflict — that is the entire reason it exists, and every rule below follows
from it.

Two kinds, same shape:

| | moves by | keeps |
|---|---|---|
| **counter** | `add(delta)` | the running sum |
| **max accumulator** | `observe(value)` | the largest value ever observed |

Declare them beside the model, not as fields — they are cells, not columns:

```rust
use boogy_sdk::model::Id;
use boogy_sdk::{Counter, Model};

#[derive(Model)]
#[model(table = "fx_clicky_links", counter(name = "clicks"))]
pub struct ClickyLink {
    #[pk] pub id: Id<ClickyLink>,
    #[lookup_by] pub slug: String,
}

/// The typed handle. `ClickyLinkClicks::NAME` is `"fx_clicky_links.clicks"` —
/// the string every store verb below names the cell by, so it is never spelled
/// as a literal at a call site.
#[derive(Counter)]
#[counter(of = ClickyLink, name = "clicks")]
pub struct ClickyLinkClicks;
```

Reads and writes go through the handle. `BOOGY_COUNTERS` is the store handle
`wit_glue!` emits into your crate — you do not import or construct it:

```rust ignore-snippet: the three verbs in one place as a reference table rather than a handler, so id and the model have no surrounding definitions
ClickyLinkClicks::add(&BOOGY_COUNTERS, id, 1)?;             // accumulate
ClickyLinkClicks::get(&BOOGY_COUNTERS, id)?;                // display  (snapshot)
ClickyLinkClicks::get_for_update(&BOOGY_COUNTERS, id)?;     // decide   (takes the conflict range)
```

The key is whatever the declaration says: for `of = Model` it is that model's
`Id<T>`; for `key = (a, b)` it is `[Val; 2]`, one value per declared column.

**`get` versus `get_for_update` is the whole subject of this skill.** `get` is a
snapshot read that takes no read-conflict range; `get_for_update` takes one.

## The one rule

**A counter read at snapshot must never decide anything.**

```rust ignore-snippet: the defect this skill exists to prevent — the store refuses it at runtime, so compiling it would assert the opposite of what it teaches
tx::<_, _, ApiError>(|| {
    let key = [st::Value::Integer(id)];
    let taken = ClickyLinkClicks::get(&BOOGY_COUNTERS, id)?;   // no conflict range
    if taken < LIMIT {                                          // a decision from it
        ClickyLinkClicks::add(&BOOGY_COUNTERS, id, 1)?;         // REFUSED
    }
    Ok(())
})
```

Why it is wrong is worth holding onto, because the failure is silent everywhere
the platform cannot see it. A snapshot read takes **no read-conflict range**:
nothing serializes it against anyone else's write. So two callers read the same
number, both conclude there is room for one more, and both commit. Measured: a
counter one below a limit of 5 lands on **6**, with correct arithmetic
throughout and no error anywhere.

```rust ignore-snippet: the corrected shape of the fence above, shown as a pair with it — the two differ by one argument and must be read side by side
tx::<_, _, ApiError>(|| {
    let key = [st::Value::Integer(id)];
    let taken = ClickyLinkClicks::get_for_update(&BOOGY_COUNTERS, id)?;  // takes the range
    if taken < LIMIT {
        ClickyLinkClicks::add(&BOOGY_COUNTERS, id, 1)?;
    }
    Ok(())
})
```

The loser now takes a **commit conflict** — which `tx` retries for you, so it
re-reads the winner's committed value and decides again — instead of a wrong
answer it cannot detect. Only a row contended past the attempt budget reaches
the caller, and it does so as a **503** (`TooContended`), never a 409. That
contention is not a regression — it is the cost of depending on the value, and
you have chosen to depend on it.

## Three verbs, and which to reach for

| call | conflicts? | use it when |
|---|---|---|
| `add` / `observe` | never | accumulating. The common case. |
| `get` | never | **displaying** the number. Never deciding with it. |
| `get_for_update` | yes, by design | **deciding** with the number — a limit, a gate, a branch. |

A snapshot read outside a transaction is always fine: each call is its own
transaction, so there is nothing for it to be inconsistent with. The rule is
about reading and writing the same cell *within one* transaction.

## What the platform does about it

Three layers, and the earliest is the cheapest to act on.

1. **`boogy check` flags it before you deploy** — a snapshot read and a write of
   the same counter inside one `tx` body. Run it in your loop; the builder MCP's
   `check_service` runs the same checks.
2. **The store refuses the write at runtime**, naming the counter and both
   remedies. Deterministic: a retry cannot make it succeed.
3. If the read is genuinely only decorative — echoed into a response, never
   branched on — mark it and move on:

```rust ignore-snippet: shows the suppression marker in place, and a marked fence is by definition code the check is told not to reason about
tx::<_, _, ApiError>(|| {
    let key = [st::Value::Integer(id)];
    // counter-read-display-only: echoed into the response, never branched on
    let shown = ClickyLinkClicks::get(&BOOGY_COUNTERS, id)?;
    ClickyLinkClicks::add(&BOOGY_COUNTERS, id, 1)?;
    Ok(shown)
})
```

Marking it does not make the number serialized. It records that you do not need
it to be.

## When a counter is the wrong tool

**If you are going to gate on the total, do not accumulate it — aggregate it.**
A maintained `rollup(...)` over rows is serializable by construction, so the
question this whole skill is about does not arise:

```rust
#[derive(Model)]
#[model(table = "fx_ballots", rollup(group = ["poll_id", "option_id"]))]
pub struct Ballot {
    #[pk] pub id: Id<Ballot>,
    #[index] pub poll_id: i64,
    pub option_id: i64,
}
```

```rust
// Every option's tally in ONE read, from maintained totals — not a scan.
fn fx_tallies(poll_id: i64) -> Result<Vec<(i64, i64)>, ApiError> {
    Ok(Query::on(Sale::TABLE)
        .filter(Sale::customer.eq(poll_id.to_string()))
        .group_by(Sale::AMOUNT)
        .count_all()
        .limit(100)
        .fetch_groups(|g| (g.key().map(Val::as_int).unwrap_or(0), g.count_all()))?)
}
```

Reach for a counter instead when there are **no rows to aggregate** — the thing
counted is an event you never store. A click on a short link is the canonical
case: writing a row per click to obtain a total means paying N rows and N index
entries to arrive at the identical single cell the counter already gives you.

Choose by asking what the number is FOR:

| the number is… | use |
|---|---|
| shown to a user, and drifting a little is fine | **counter** |
| a gate — stock, a quota, a limit | **rollup**, or `get_for_update` |
| derived from rows you are storing anyway | **rollup** |
| counting events you do not store | **counter** |

## Declaring a max accumulator

Same shape as a counter, with `max` instead of `counter`:

```rust
use boogy_sdk::model::Id;
use boogy_sdk::{Model};

#[derive(Model)]
#[model(table = "fx_busy_rooms", max(name = "last_post_at"))]
pub struct BusyRoom {
    #[pk] pub id: Id<BusyRoom>,
    pub slug: String,
}
```

There is no backing field, exactly as for a counter — the cell lives outside the
packed row. Observe into it with `observe(..)` and read it with `get(..)`, which
returns `Option<i64>`.

## A max accumulator only moves forward

`observe(v)` keeps `v` only if it is larger than what is stored. A smaller
observation is a **silent no-op, not an error** — "the latest post is older than
the latest post" is a race between two writers, and the cell already holds the
right answer.

It follows that there is no un-observe: deleting the newest post does not roll
`last_post_at` back. Where that matters the value is derived data and should be
recomputed, not accumulated.

`get` returns `Option` — `None` means nothing has ever been observed, which is
distinct from every value that has been.

## Why this beats stamping a column

Writing "last activity" the obvious way — a `last_post_at` column on the parent,
rewritten on every child write — rewrites the whole parent row every time, so
every writer contends with every other. Measured on a message-board service at
600 concurrent writers: **59.4%** of commit attempts conflicted, against **2**
for the accumulator cell beside it. Moving that one column into an accumulator
took it to **0.1%**.

## Counts kept on a row: `upsert_increment` and counter columns

Above, a counter cell is moved through its handle. A count can also be bumped
by key with `upsert_increment`, on a plain column or on a counter column; the
rules below are what its signature does not tell you.

### `upsert_increment`

`upsert_increment(table, key, counter, delta, columns)` finds the row matching
`key`, adds `delta` to `counter`, and writes `columns.always` — inserting the
row (`key` + `columns.always` + `columns.on_insert` + `counter = delta`) if it
isn't there. `columns` is an `UpsertColumns { always, on_insert }`: `always`
is written on **every** call (insert and update alike); `on_insert` only by
the call that creates the row, and never touched again. Concurrent bumps
compose; a read-modify-write of the same count loses updates.

```rust
use boogy_sdk::model::{Id, Model as _, Timestamp}; // `Model as _` for `TABLE`
use boogy_sdk::Model;

/// `slug` is `#[lookup_by]` for two jobs at once: the point lookup every
/// `/rooms/{slug}` route performs, AND the UNIQUE index `upsert_increment`
/// keys `post_count` by. One declaration, both obligations.
#[derive(Model)]
#[model(table = "rooms", list_by(filter = "visibility", newest = "last_post_at"))]
pub struct Room {
    #[pk]
    pub id: Id<Room>,
    #[lookup_by]
    pub slug: String,
    pub visibility: String,
    pub post_count: i64,
    pub last_post_at: Timestamp,
}

/// `post_count += 1` AND `last_post_at = now`, in ONE call.
fn on_new_post(slug: &str, now: i64) -> Result<(), ApiError> {
    upsert_increment(
        Room::TABLE,
        &[store::Column {                                   // key: the unique index
            name: Room::SLUG.to_string(),
            val: store::Value::Text(slug.to_string()),
        }],
        Room::POST_COUNT,                                   // the one counter
        store::Value::Integer(1),                           // delta
        UpsertColumns::always(&[store::Column {              // `always`: rewritten every call
            name: Room::LAST_POST_AT.to_string(),
            val: store::Value::Integer(now),
        }]),
    )?;
    Ok(())
}
```

Rules the signature does not tell you:

| Rule | Consequence of missing it |
|------|---------------------------|
| The `key` columns need a **UNIQUE index** covering them — `#[lookup_by]` for one column, `unique_index(cols = [...])` for a composite | the key is the conflict target. Without one the call is **refused** with a `ConstraintViolation` naming the key columns and the remedy. There is no scan fallback: find-then-write over a scan has no single-row meaning, since two concurrent upserts on the same key could both find nothing and both insert |
| The **auto-PK is not a usable key** | `_id` is the row's identity, not an indexed *column*, so no unique index covers it and the call is refused. This is why a model carrying a counter needs an opaque `#[lookup_by]` column |
| `#[unique]` does **not** satisfy it | it isn't an index, and the derive no longer accepts it at all. Use `#[lookup_by]` |
| **`key ∪ always ∪ on_insert` must cover every non-nullable column that has no default** | the first call for a key **inserts**, so a required column that appears in none of them is a row-creating write that omits it → refused with `ConstraintViolation` naming the column. See the fix below — it is not "add it to `always`" |
| **One counter per call** | a two-counter rollup (`receipt_count` + `total_bytes`) is two calls on the same `key`. A missing counter column starts at `delta`, so call order is irrelevant — never RMW the second one |
| It **inserts** when the key matches nothing | see `boogy:boogy-transactions`: load the parent inside the same `tx` so a bump can't resurrect a deleted row as a stub |

#### 🚩 Satisfy the coverage rule with `#[default]` or `on_insert`, NOT by padding `always`

Adding the missing column to `always` makes the *insert* legal and silently
breaks every *update*: `always` columns are written on **both** arms, so each
later bump rewrites that column — resetting an accumulator, or stamping a
`created_at` on every increment.

Two ways out, and they answer different questions:

- **A static starting value** (a counter's zero, a status's default) — declare
  it **on the column** with `#[default = ...]`. It is consulted only when a
  write omits the column, so it seeds the insert arm and never touches the
  update arm.
- **A value computed at call time** (`now()`, a derived id) — a `default` can't
  express it; a `default` is always a static literal. Put it in `on_insert`
  instead: written only by the call that creates the row, never touched again.

```rust
use boogy_sdk::model::Id;
use boogy_sdk::{Counter, Model};

#[derive(Model)]
#[model(table = "rollups", counter(name = "hits"))]  // the one counter this call bumps — no field
pub struct Rollup {
    #[pk] pub id: Id<Rollup>,
    #[lookup_by] pub key: String,          // the upsert's conflict target
    #[default = 0] pub total_bytes: i64,   // seeds the insert arm, and only it
}

/// Names the cell `#[model(counter(name = "hits"))]` above declared —
/// `Rollup::HITS` (a `&'static str` const the derive still emits, struct- or
/// field-declared alike) works directly with `upsert_increment` below; this
/// marker type is what a READ goes through instead.
#[derive(Counter)]
#[counter(of = Rollup, name = "hits")]
pub struct RollupHits;
```

```rust
// WRONG — `total_bytes` is now reset to 0 on every single bump.
upsert_increment(Rollup::TABLE, &key, Rollup::HITS, store::Value::Integer(1),
                 UpsertColumns::always(&[store::Column { name: Rollup::TOTAL_BYTES.to_string(),
                                   val: store::Value::Integer(0) }]))?;

// RIGHT — the `#[default = 0]` above covers the insert; `always` stays empty.
upsert_increment(Rollup::TABLE, &key, Rollup::HITS, store::Value::Integer(1), UpsertColumns::none())?;
```

A default is consulted only when a write omits the column, so it seeds the
insert arm and never touches the update arm. It also keeps `always` empty,
which is what a counter column needs to stay conflict-free.

Now the computed case — a value `#[default]` cannot express because it isn't
known until the call:

```rust
// `stamp` here plays a *creation* timestamp, computed at call time. It rides
// `on_insert`, not `always`: written once, when the row is created, and never
// rewritten by a later bump — so it costs this counter column nothing.
upsert_increment(
    Rollup::TABLE,
    &key,
    Rollup::HITS,
    store::Value::Integer(1),
    UpsertColumns::on_insert_only(&[stamp]),
)?;
```

### 🚩 RED FLAG — a companion column updated with `db_update`

`always` columns are written on **both** the insert and the update path. That
is the entire point: a counter row's companion columns that must keep
changing on every call are updated via `always` in the **same**
`upsert_increment` call, not a second write.

```rust
// WRONG — silent lost update on the hottest write path
// (`tx` takes an `Fn` closure, so build the row OUTSIDE it — a struct-update
//  `..room` inside the closure would move a captured value and not compile.)
let bumped = Room { last_post_at: now, ..room };
tx::<_, _, ApiError>(|| {
    db_insert(&post)?;
    upsert_increment(Room::TABLE, &key, Room::POST_COUNT, store::Value::Integer(1), UpsertColumns::none())?;
    db_update(bumped.id.get(), &bumped)?;                            // 🚩
    Ok(())
})
```

`db_update` writes **every** column of the model — including the
`post_count` that was read *before* the increment. Every concurrent post's
count is lost. No error, no conflict, no failing test unless someone
writes a concurrency test. Fold the field into `always` instead — `on_insert`
does not fit here, because `last_post_at` must keep advancing on every post,
not just the row's first.

### Counter columns — the conflict-free variant, for hot counters

`upsert_increment` on a **plain** column (everything above) is atomic and
loses no updates, but it still **rewrites the row**, so it takes a
read-conflict range. Under real contention — a like button, a view count,
a rate meter — concurrent bumps on the same row conflict. Those conflicts
are retried automatically (see `boogy:boogy-transaction-conflicts`), so the first
symptom is latency rather than an error; past the attempt budget the
request gets a 503. Correct, but it does not scale, and the cost hides
until load.

A **counter column** removes that: `#[model(counter(name = "<column>"))]`
on the struct — **not a field**, there is no backing field at all — plus a
companion `#[derive(Counter)] #[counter(of = <Self>, name = "<column>")]`
marker type that gives the cell a name and a typed key to read or add it
through. The column is stored in its **own cell**, not packed into the row,
and an increment is an atomic add that registers **no read-conflict range**.
Concurrent increments compose instead of conflicting.

That covers the **counter write**, not the rest of the transaction. If the
closure that bumps the counter also runs a filtered search the planner
can't serve from an index, that search scans and takes every row of the
table as its read set. The bumps still don't collide with each other — an
empty-`always` increment on an existing row touches only the counter cell,
which is outside the row range the scan read — but any concurrent **row**
write to that table (an insert, an update, or the first bump for a key,
which inserts the row) now aborts the scanning transaction. Narrow the
reads in that closure too — filter on a column that leads an index (see
*Indexes decide contention* in `boogy:boogy-data-modeling`).

```rust
use boogy_sdk::model::Id;
use boogy_sdk::{Counter, Model};

#[derive(Model)]
#[model(table = "posts", counter(name = "vote_score"))]
pub struct Post {
    #[pk]
    pub id: Id<Post>,
    #[lookup_by]
    pub slug: String,
    pub title: String,
}

/// The read/add handle for `vote_score` — see "Reading a counter" below.
#[derive(Counter)]
#[counter(of = Post, name = "vote_score")]
pub struct PostVoteScore;
```

You still increment with `upsert_increment` (`Post::VOTE_SCORE` is the
`&'static str` const the derive still emits for a struct-level counter,
just like it would for a field) — a counter column changes how the value is
*stored*, not how you call it. **The conflict-freedom holds only
with an EMPTY `always`:**

```rust
// Conflict-free: nothing but the counter cell is touched.
upsert_increment(Post::TABLE, &key, Post::VOTE_SCORE, store::Value::Integer(1), UpsertColumns::none())?;

// NOT conflict-free: a non-empty `always` rewrites the row, which is an
// ordinary read-modify-write and conflicts like any other.
upsert_increment(Post::TABLE, &key, Post::VOTE_SCORE, store::Value::Integer(1), UpsertColumns::always(&[stamp]))?;

// Still conflict-free — `on_insert` writes only the arm that creates the
// row, so it costs a later bump nothing. Only useful for a value the row
// needs once, at creation.
upsert_increment(Post::TABLE, &key, Post::VOTE_SCORE, store::Value::Integer(1),
                  UpsertColumns::on_insert_only(&[stamp]))?;
```

That is a genuine trade-off against the plain-column pattern above, which
folds companion columns that must keep changing into `always` precisely to
avoid a second write. Pick per column: **hot and standalone → a counter
column with an empty `always`; needed once, at creation → a counter column
with `on_insert`; updated together with companion fields on every call → plain
column + `always`.**

#### There is no field — writes cannot clobber it, and reads are an explicit opt-in

A counter column has **no backing struct field at all**, so `Post` above
carries no `vote_score` member to accidentally round-trip. `db_insert`
starts the column at zero (there is nothing to write) and `db_update`
**never mentions the column** — a struct-update write can't write back a
value it never held:

```rust
// SAFE — `Post` has no `vote_score` field to read a stale value from or
// write one back through.
db_update(post.id.get(), &Post { title: new_title, ..post })?;
```

On a **plain** counter column that same line is the silent lost-update bug
the RED FLAG above describes. A counter column is the structural fix for
it — more structural than the old field form, which excluded the field from
writes but still let a caller read it as an ordinary struct member.

The trade is on the READ side: nothing merges a counter's value in for you
any more. `Post::schema()`/`db_get`/`db_find_by`/plain `Query::fetch_*` all
return the row with the counter cell unmerged — reading it is always an
explicit ask, through one of:

- **`Query::on(Post::TABLE)...with_counter(PostVoteScore::NAME, &[])`** — the
  ordinary row-listing path. `key_cols` is empty for an `of = Model`
  counter (it is keyed by the row's own id implicitly); a `key = (...)`
  standalone counter passes the column names that supply its key.
- **`for_each_batch(..., counters: &[PostVoteScore::NAME], f)`** — the
  streaming-cursor twin, same opt-in.
- **`.order(Post::vote_score.desc())`** — ranking BY a counter's cells is
  the one path that merges it without a separate `.with_counter(..)`, since
  sorting by it is already an explicit ask.

Naming one counter opts in every LIVE counter column the table declares
(per-table granularity, not per-column) — cheap on the common one-counter
table, worth knowing on a table with several.

#### A counter cannot back an index — enforced at compile time

Index maintenance needs the previous value to clear the stale entry, and an
atomic add never reads one. So the derive **refuses to build**:

| You wrote | Result |
|---|---|
| `counter(name = "x")` sharing a name with a declared `#[index]` / `#[lookup_by]` / `#[covering_index]` / struct-level `index(cols = [...])` column | compile error |
| A `counter(...)` column named by `list_by` / `ranked_by` / `tagged_by` | compile error |
<!-- retired-spelling: the field form is retired — `#[model(counter(name =
     ..))]` on the struct is the replacement, which this row already
     names. -->
| `#[counter]` written as a FIELD attribute at all | compile error naming the replacement — there is no field form any more |

This is deliberately a compile error, not a runtime one: the alternative is
an index that *looks* maintained and silently is not — wrong answers rather
than a failure.

**So you cannot sort, rank, or seek by a counter.** "Top posts by score"
is not available as an indexed read (except by `.order(...)`, which reads
the cells directly rather than through an index — see "Reading a counter"
above). The two sanctioned escape hatches for anything an ordered PAGE
needs to seek into rather than sort in memory: scope the ranking to a
**bounded sub-range and sort in memory**, or **materialize the value into a
separate plain column** refreshed by a background job (see
`boogy:boogy-background-jobs`) and index *that*.

<!-- retired-spelling: this section teaches the retired field form as a
     NEGATIVE — the live declaration is `#[model(counter(name = ..))]`
     plus a `#[derive(Counter)]` marker type. -->
### There is no field form — `#[counter]` on a field is a compile error

A counter has no field of its own. Declaring one is always
`#[model(counter(name = "<column>"))]` on the **struct**, read through a
companion `#[derive(Counter)]` marker type — never a field-level
<!-- retired-spelling: the paragraph below names the retired field form so a
     reader recognises it in an older note; the live declaration is
     `#[model(counter(name = "..."))]` plus a `#[derive(Counter)]` marker. -->
`#[counter]` attribute. If you have seen `#[counter] pub x: i64` in an
older note, it predates this: the derive now rejects it outright, naming
the replacement.

<!-- retired-spelling: the fence below is the RETIRED field form, shown so it
     is recognised and never written; `#[model(counter(name = ..))]` on the
     struct is the replacement, as the fence's own comment says. -->
```rust ignore-snippet: shows code the derive is meant to REJECT — compiling it would assert the opposite of what it teaches
#[counter]                   // compile error: no field form — declare
pub vote_score: i64,         // #[model(counter(name = "vote_score"))] on the struct instead
```

`#[model(counter(...))]` itself takes **no arguments other than the
required `name = "..."`** — in particular no `index` option:

```rust ignore-snippet: shows code the derive is meant to REJECT — compiling it would assert the opposite of what it teaches
#[model(table = "posts", counter(name = "vote_score", index = true))]     // compile error
```

If you have seen `#[counter(index = true)]` in a design note, it is **not
built** — and an indexed counter is refused at compile time anyway, for the
reason above. Write `counter(name = "...")` with nothing else, and use one
of the two escape hatches above if you need to rank by the value.

### 🚩 RED FLAG — you cannot add a counter column to a deployed table

A migration-added column is **never** a counter: `add_column` **refuses** a
counter column outright (a `ConstraintViolation`). A counter's value lives in
a per-row sidecar cell that `insert` seeds, and every read path assumes every
row of that table owns one — flipping the flag on a populated table would make
every pre-existing row read as `0`. Establishing the invariant needs a
backfill, which `add_column` is not.

**Consequence: decide the counter when you create the table.** Whichever way
you reach for the conversion, the refusal is loud rather than silent: an
in-migration `add_column` refuses at that call with a `ConstraintViolation`,
and declaring `#[model(counter(...))]` on a model whose table already has a
plain column under that name is caught by the same column reconciliation
that catches a type or nullability change — the deploy is refused before the
new version ever goes live, not accepted and then left disagreeing with the
deployed table. Either way, a counter is not something to retrofit.

If you need to convert a live column, the supported route today is a **new
table** with the counter declared up front, plus a migration that copies
the values across (see `boogy:boogy-migrations`).

**Overflow wraps.** The column is a 64-bit signed integer and the add
**wraps** past `i64::MAX` to `i64::MIN` rather than erroring or saturating.
Irrelevant at 9.2 quintillion for a counting workload, but real for a
counter accumulating large deltas (byte totals, currency in minor units) —
clamp the delta on the way in. The delta must be an **integer**; a
fractional delta on a counter column is rejected by the store.

## 🚩 RED FLAGS

| Thought | Reality |
|---|---|
| "I'll read the counter and check the limit." | That is the oversell, and the store refuses it. `get_for_update`, or a rollup. |
| "`get_for_update` conflicts, so I'll use `get`." | The conflict IS the correctness. Using `get` does not remove the contention, it removes the serialization. |
| "It read the right number, so it is fine." | The number is right. It was never serialized — that is a different property, and the one you are relying on. |
| "I'll increment by reading and writing the row." | `db_update` writes the whole row and clobbers concurrent increments. Never read-modify-write a count. |
| "I need a total I can filter and sort on." | A counter cell is not an indexable column. If you need to query by the value, use a rollup. |
| "I'll spell the counter name as a string." | Name it through the handle's `NAME` const. A typo in a literal declares a *different* counter, which reads as zero forever. |

### `upsert_increment` and counter columns

- "I'll bump the counter, then `db_update` the row's other columns" → the
  update clobbers the counter with its pre-increment value. Companion
  columns that must keep changing go in `upsert_increment`'s `always`, same
  call; a companion needed only once, at creation, goes in `on_insert`
  instead.
- "The counter keys on `_id` — that's the row's identity" → not an indexed
  column, so no unique index covers it and the call is refused. Key on a
  `#[lookup_by]` column.
- "The upsert's first call inserts, so I'll pad `always` with the required
  columns" → `always` is written on the update arm too, so every later bump
  rewrites them. Give those columns a `#[default = …]` for a static value, or
  `on_insert` for one computed at call time, and leave `always` alone.
- "One `upsert_increment` can bump both counters" → one counter per call.
  Two calls, same key; the second column starts at `delta` if absent.
- "I'll make it a counter column so I can rank by it" → backwards. A counter
  column is *unindexable* (compile error on any index or `ranked_by` naming
  it) — `.order(...)` reads its cells directly instead. Materialize into a
  plain column via a job if you need a true indexed seek, or sort a bounded
  sub-range in memory.
- "`#[counter(index = true)]` gives me a sortable counter" → the feature
  does not exist; `#[model(counter(...))]` takes only `name = "..."` and
  the derive rejects anything else.
     `#[model(counter(name = ..))]` as the replacement, which is why it is
     listed as a red flag at all. -->
<!-- retired-spelling: the field form is retired; the bullet below names
- "I'll write `#[counter]` on the field like I used to" → there is no field
  form any more; it is a compile error naming the replacement,
  `#[model(counter(name = "..."))]` on the struct.
- "A counter column plus an `always` column, still conflict-free" → a non-empty
  `always` rewrites the row and conflicts like any other write. Empty
  `always`, or a value moved to `on_insert` if it's only needed at creation,
  or it isn't conflict-free.

## See also

- `boogy:boogy-data-modeling` — the model a counter sits on, its keys and indexes
- `boogy:boogy-transactions` — what belongs in a `tx`, and handling 409s
- `boogy:boogy-access-patterns` — when a rollup stops you paying on every read
