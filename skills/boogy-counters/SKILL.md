---
name: boogy-counters
description: Use when a value only ever goes up or down (views, likes, stock, quota, "last active at"), when a write is contending on a hot row, when deciding between a counter and a maintained rollup, or when a counter read is refused inside a transaction
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

The loser now gets a **409** it can retry, instead of a wrong answer it cannot
detect. That contention is not a regression — it is the cost of depending on the
value, and you have chosen to depend on it.

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

## 🚩 RED FLAGS

| Thought | Reality |
|---|---|
| "I'll read the counter and check the limit." | That is the oversell, and the store refuses it. `get_for_update`, or a rollup. |
| "`get_for_update` conflicts, so I'll use `get`." | The conflict IS the correctness. Using `get` does not remove the contention, it removes the serialization. |
| "It read the right number, so it is fine." | The number is right. It was never serialized — that is a different property, and the one you are relying on. |
| "I'll increment by reading and writing the row." | `db_update` writes the whole row and clobbers concurrent increments. Never read-modify-write a count. |
| "I need a total I can filter and sort on." | A counter cell is not an indexable column. If you need to query by the value, use a rollup. |
| "I'll spell the counter name as a string." | Name it through the handle's `NAME` const. A typo in a literal declares a *different* counter, which reads as zero forever. |

## See also

- `boogy:boogy-data-modeling` — declaring counter columns, `upsert_increment`,
  and the companion-column rules (`always` vs `on_insert`)
- `boogy:boogy-transactions` — what belongs in a `tx`, and handling 409s
- `boogy:boogy-access-patterns` — when a rollup stops you paying on every read
