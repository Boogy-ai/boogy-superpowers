---
name: boogy-data-modeling
description: Use when declaring tables, designing schemas, or choosing how to represent data in a Boogy service
---

# Modeling data on Boogy

The store is a typed, columnar, ACID table store with a `u64` auto
primary key per row. It is **not** schemaless: there is no JSON column
type and no JSON-path filter — model your data as columns up front.

## The one standard way: `#[derive(Model)]`

A table is a Rust struct deriving `Model`. The derive maps each field to
a typed column, emits the per-field column-name consts, generates the
`schema()` (columns **and** the indexes implied by your declared access
patterns), and gives you `from_row` / `to_columns` / `id`. You then
declare it in `schema` with `s.model::<M>()` and do all CRUD
through `db_insert` / `db_get` / `db_find_by` / `db_update` / `db_delete`
+ the `Query` DSL. This is the canonical chat example — `Conversation`
and `Message`:

```rust
use boogy_sdk::model::{Id, Timestamp};
use boogy_sdk::Model;

/// One conversation with a peer. `peer` is the natural key
/// (`#[lookup_by]` → unique point-lookup index); `ranked_by(highest =
/// "last_at")` powers the newest-activity-first list.
#[derive(Model)]
#[model(table = "conversations", ranked_by(highest = "last_at"))]
pub struct Conversation {
    #[pk]
    pub id: Id<Conversation>,
    #[lookup_by]
    pub peer: String,
    pub last_body: String,
    pub last_at: Timestamp,
    pub last_from: String,
}

/// One message in a conversation. `list_by(filter = "peer", newest =
/// "created_at")` powers the per-peer, newest-first message list.
#[derive(Model)]
#[model(table = "messages", list_by(filter = "peer", newest = "created_at"))]
pub struct Message {
    #[pk]
    pub id: Id<Message>,
    pub peer: String,
    pub direction: String, // "out" | "in"
    pub body: String,
    pub created_at: Timestamp,
}
```

Register both, then never touch raw columns again:

```rust
impl Api for ChatApi {
    fn schema(s: &mut Schema) {
        // Each model's schema (columns + the indexes its declared access
        // patterns imply) comes from the struct — no hand-built Table.
        // Declaration only: the SDK creates missing tables and reconciles
        // the physical index set against what is declared here.
        s.model::<Conversation>();
        s.model::<Message>();
    }
    // `build_router` is the trait's one required method — `schema`
    // has a no-op default, so an impl that omits the router does not build.
    fn build_router() -> Router {
        Router::new()   // …routes…
    }
}
```

### Indexes follow the model, automatically

You never create or drop an index by hand. On each deploy the physical index
set is **reconciled** against what your models declare:

| You did | What happens |
|---|---|
| added an access pattern | the index is created |
| changed one (different columns, `unique`, `covering`) | the index is rebuilt |
| removed one | the index is dropped |

So changing an index is a one-line edit to the model — no migration, no
`create_index` call. This is safe because an index is rebuildable from the
rows: dropping one cannot lose data.

Two consequences worth internalising:

- **Do not create a permanent index from a migration.** An `ix_`/`idx_`-named
  index your models do not declare is indistinguishable from one whose
  declaration you deleted, so the reconcile removes it on the next deploy.
- **Tables and columns are NOT reconciled.** Dropping those *is* lossy, so they
  stay behind explicit versioned migrations — see `boogy:boogy-migrations`.

## 🚩 RED FLAG — raw schema is a regression, not a choice

If you find yourself writing **any** of these for a normal table, stop —
you are regressing off the standard layer:

- `Table::new("posts").text("body").index(...)` — hand-built schema
- `create_table_from(&Table::new(...))` — hand-built registration
- a hand-written `cols` module / `pub struct Posts { pub const TABLE … }`
  of bare-string column consts
- `store::insert` / `store::update` / `store::find` for ordinary CRUD

The Model derive **emits** the column consts (`Message::PEER`,
`Message::CREATED_AT`, …) and the schema for you. Hand-writing them is
duplicate, drift-prone, and untyped. The raw `store::*` schema API is an
**escape hatch ONLY** for genuinely dynamic, unknown-at-compile-time
schemas (a table whose columns aren't known until runtime). You almost
never need it. For everything with a fixed shape — which is essentially
every table you will ever write — derive `Model`.

## Field types

Each field's Rust type maps to a column via the `Field` trait:

| You want | Field type |
|----------|------------|
| text | `String` |
| whole number | `i64` / `u64` |
| true/false | `bool` |
| float | `f64` |
| decimal money / score / weight | `Decimal` (exact fixed-point — see below) |
| timestamp (unix millis) | `Timestamp` (integer column) |
| typed foreign / primary id | `Id<T>` (a typed `u64`; `Id<Post>` ≠ `Id<User>`) |
| optional / nullable | `Option<T>` (the only thing that makes a column nullable) |

### `Decimal` — exact, for money, scores, and weights

`Decimal` is a fixed-point decimal, exact to **6 decimal places**. It
sorts and range-filters correctly at any magnitude and either sign
(`order_by`, `keyset_by`, `where_gt`/`where_lt` all rank it as a genuine
number, never as text), and its arithmetic is exact — no binary
floating-point rounding error:

```rust
use boogy_sdk::model::Decimal;

fn decimal_addition_is_exact() {
    let a: Decimal = "0.1".parse().unwrap();
    let b: Decimal = "0.2".parse().unwrap();
    // holds exactly — this does NOT hold for f64 (0.1 + 0.2 != 0.3)
    assert_eq!(a + b, "0.3".parse().unwrap());
}
```

That makes `Decimal` a genuinely safe choice for money — not just for
scores and weights — including sums, splits, and running balances that
must reconcile exactly.

Build one from a decimal literal or string, the natural way to write a
price, a rate, or a weight:

```rust
use boogy_sdk::model::Decimal;

fn a_price() -> Decimal {
    let price: Decimal = "19.99".parse().unwrap();
    let total = price + price;   // exact: "39.98"
    debug_assert_eq!(total.to_string(), "39.980000"); // Display form
    total
}
```

A `Decimal` field on a DTO serializes to and from JSON as that same
decimal string (`"19.990000"`), never as a float — a client reads and
writes the value it expects, with no float rounding introduced on the
wire.

**Range and overflow.** Six decimal places gives a usable range of about
±9.22 trillion (`i64::MAX` at that scale) — far past any plausible
money, score, or weight value. `+`/`-`/unary `-` are exact within that
range and **panic on overflow** rather than silently wrapping, the same
posture as an unexpected integer overflow anywhere else: loud, not a
quietly corrupted balance. A literal needing a 7th decimal digit, or a
magnitude outside the range, is a **parse error** — refused rather than
silently rounded or truncated.

Two more constructors exist for specific situations: `from_minor_units`
for a caller that already holds an exact integer count from elsewhere (a
payment provider, an invoice import) — an additional constructor, not
the primary way to build one; and `Decimal::new(f64)` / `.get() -> f64`
for interop with code that already computes in `f64` — a value built or
read that way carries ordinary float rounding at that boundary, same as
any `f64`.

Not provided: multiplication and division as operators. A rate times a
quantity, or splitting a total, needs a rounding rule only the caller
can decide correctly (round up? down? to the nearest cent?) — compute in
minor units explicitly and re-wrap with the rounding you intend.

### `Decimal` vs `f64` vs a plain integer column

| You want | Use |
|---|---|
| A decimal quantity where the value matters exactly — a price, a rate, a running balance, a weight or score you'll sum or compare exactly | `Decimal` |
| A measurement with no decimal-exactness expectation — a coordinate, a ratio, a sensor reading | `f64` |
| You already think in whole minor units yourself and never want a decimal view | a plain `i64`/`u64` column, counting cents (or whatever the unit is) directly |

All three are legitimate — pick by how the field is actually used, not
by which "sounds more precise." Counting minor units in a plain integer
column is exactly as valid as `Decimal` for an author who prefers to
work in cents directly and never format a decimal string. `Decimal` is
for the author who wants to write, read, and reason about decimal
values (`"19.99"`, not `1999`) while still getting exact arithmetic
underneath — it does not force a conversion to minor units at every call
site.

**The column type binds the stored value, not just the declaration.** A whole
number written to a `f64` column is stored as a float, and a float written to an
`i64` column is stored as a whole number — the store normalizes to what the
column declares, so a search on that column always finds it. A float that cannot
be represented as a whole number (`1.5` into an `i64` column) is **rejected**
with a 409 `ConstraintViolation` naming the column, deterministic and never
retried. Two things follow that are easy to be surprised by: inside a `tx` the
refusal **poisons the whole closure**, not just that one write, so the
transaction cannot commit — the same as any other constraint violation; and a
value aimed at a column you no longer use (dropped, or a `#[counter]` field in
an update) is checked too, so a bad float there now fails where it used to be
discarded in silence. This only ever applies between whole numbers and floats;
no other pair of types is converted.

You will not meet this through `#[derive(Model)]`, which gives every field the
column type its Rust type implies. It is reachable when you hand-build column
values yourself.

A non-`Option` column is **NOT NULL, and it binds in both directions**:

- **An explicitly written null is rejected** — `db_insert` or `db_update`
  sending null for the column fails with a 409 `ConstraintViolation`, which is
  deterministic and never retried.
- **Omitting the column is rejected too, on any write that CREATES a row** —
  an insert, or the row-creating arm of an upsert. On an *update* omission is
  still fine and keeps its ordinary meaning, "leave this column alone".

Omission is refused rather than treated as a zero because the two are not the
same thing: a row stored without a value reads the column back as the type's
zero (`""`, `0`, `false`) but has **no index entry** for it, so that row is
visible to a point lookup and invisible to a seek over that column.

Two things are exempt: a column carrying a **default** (below), and a
`#[counter]` column (its value lives in its own cell, and an absent counter
already reads as `0`). Use `Option<T>` when absence is genuinely meaningful,
and a default when every row must carry a value.

### Defaults

`#[default = <literal>]` is how a column gets a value when a write omits it —
the equivalent of `status TEXT DEFAULT 'pending'`:

```rust
use boogy_sdk::model::Id;
use boogy_sdk::Model;

#[derive(Model)]
#[model(table = "orders")]
pub struct Order {
    #[pk] pub id: Id<Order>,
    #[default = "pending"] pub status: String,
    #[default = 0]         pub retries: i64,
}
```

Three things to know, in the order they bite:

1. **A default satisfies the not-null requirement — in both directions.** A
   non-`Option` column carrying one can never end up value-less, so this is the
   sane way to declare a required field, and the way to add one to a table that
   already has rows. Omitting it from a write is fine (the store materializes
   the default into the row); writing an *explicit* null is still a 409. This
   is also the clean answer to `upsert_increment`'s coverage rule — see
   **Counters** below.
2. **Nothing is backfilled, ever.** Declaring or changing a default never
   rewrites a stored row. A write that omits the column records the default in
   force *at that moment*, so changing the default later does not move that row.
   Rows that predate the column entirely have no value recorded and resolve
   against the current default on every read, so those do change. If you need
   every existing row to hold a new value, that is a backfill — a migration that
   writes the rows, not a default.
3. **A malformed default does not compile.** A bare `#[default]`, a non-literal
   (`#[default = SOME_CONST]`), or a literal whose kind does not match the
   field's column type (`#[default = "0"]` on an `i64`) is a compile error, not
   a silently discarded declaration. `#[default]` is also refused on `#[pk]`
   (the store assigns the key) and on `#[counter]` (a counter's value is read
   from its own cell, so a default could never be observed — an absent counter
   already reads as `0`).

Adding a default to a column of a **deployed** table is an `add_column`
migration with the same column type and nullability; that also updates a default
already there, and re-running it is a no-op rather than an error. See the
`boogy-migrations` skill.

`Id<T>`, `Timestamp`, and `Decimal` come from `boogy_sdk::model`. Build
values with `Id::new(0)` (the placeholder PK on insert — the store
assigns the real `_id` and `db_insert` returns it), `Timestamp::new(ms)`,
`Decimal::new(f)`.

### Nullable vs. sentinel

Making a column `Option<T>` decides whether a query on it is an index seek.
The rule: **a column you will `where_eq`/seek on must not be nullable; a
column you only post-filter on may be.** NULL is matched by a *different
operator* (`where_null`), never by equality — so a nullable column can't
supply the equality half of a `list_by(filter, order)` index, that bounded
ordered walk is not chosen, and the query degrades to reading every
matching row and sorting in memory. (`where_not_null` never seeks at all.)

- **Seek column → sentinel.** "List open polls, newest first" is
  `list_by(filter = "closed_at", newest = "created_at")`. Declare
  `closed_at: Timestamp` with a non-null `OPEN` sentinel (`0`), so
  `where_eq(CLOSED_AT, 0)` is a bounded, ordered index walk.
- **Post-filter column → nullable is honest.** `deleted_at:
  Option<Timestamp>` on a table listed by `list_by(filter = "room_id",
  newest = "created_at")`: the `room_id` equality drives the index and
  `where_null(DELETED_AT)` is a residual filter applied during that walk.
  A live row has no timestamp, so `Option` is the truthful type.

Pick per column, not per table — the same model routinely has both.

## Attribute reference (all verified)

**Field-level:**
- `#[pk]` — maps to the store auto-PK `_id`; excluded from `to_columns`;
  read from `_id`. At most one per struct. A model may have *no* `#[pk]`
  (identity is then a composite unique index; the store still assigns an
  `_id` used by `db_get`/`db_delete`).
- `#[unique]` — **does not exist; the derive rejects it.** It used to
  compile and enforce nothing: it set a column flag with no index behind
  it, so duplicate values were accepted silently by a model that had
  declared they could not be. Uniqueness is an *index* property. Use
  `#[lookup_by]` (one column) or `unique_index` (composite).
- `#[index]` — single-column index `idx_<table>_<col>`.
- `#[covering_index]` — single-column covering index (stores a row copy
  in the index entry so a walk skips the per-row fetch; costs write
  amplification).
- `#[lookup_by]` — declares a unique point-lookup access pattern → UNIQUE
  single-column index. (Cannot be the `#[pk]` field.) This is the
  attribute a single-column counter key needs — see **Counters** below.
- `#[default = <literal>]` — the column's default: the value a read gives
  back when the row carries none. `#[default = "pending"] status: String`,
  `#[default = 0] retries: i64`, `#[default = 1.5] weight: f64`,
  `#[default = true] active: bool`. A **negative** number needs the
  parenthesized form, `#[default(-1)]` — rustc rejects a non-literal after
  `=` in any attribute, so `#[default = -1]` never reaches the derive.
  Literal values only; there are no expression defaults (no `now()`).
  See **Defaults** below for what it does and does not do.
- `#[model(column = "name")]` — override the column name.

**Struct-level `#[model(...)]`:**
- `table = "name"` — table name (defaults to snake_case of the struct).
- `list_by(filter = "col", newest = "col" | oldest = "col")` — filtered,
  ordered list pattern → covering composite `(filter, order)` index.
- `ranked_by(highest = "col" | lowest = "col")` — global ranked feed →
  covering single-column index.
- `lookup_by` is field-level (above); `tagged_by(tag = "col", refs =
  "col")` — junction/side-table membership → covering `(tag, refs)`.
- `index(name = "...", cols = ["a", "b"])` /
  `unique_index(name = "...", cols = [...])` /
  `covering_index(name = "...", cols = [...])` — explicit composite
  indexes (use when an access-pattern verb doesn't express the shape, as
  in tokenfeed's `Investment`/`Edge`). The `name` you pass is **vestigial**:
  the index is canonically named `ix_<table>_<cols>` regardless. Never use
  that declared name as a stable handle — never hardcode an index name in a
  handler. Reference data by **columns** (the Query DSL / `db_find_by` —
  the planner picks the index by the query's columns); a literal index name
  silently drifts from the canonical one. See `boogy:boogy-access-patterns`.

The access-pattern verbs (`list_by`/`ranked_by`/`lookup_by`/`tagged_by`)
are the altitude — declare *intent* and let the derive shape and name the
index. See `boogy:boogy-access-patterns` for which verb backs which
query.

**The struct-level verbs repeat.** One model routinely serves several
filtered lists; declare one verb per read, not one per table (and don't
drop to explicit `index(cols = [...])` for the second shape — that throws
away the altitude). Multiple `#[model(...)]` attributes accumulate too.

```rust
use boogy_sdk::model::{Id, Timestamp};
use boogy_sdk::Model;

#[derive(Model)]
#[model(
    table = "posts",
    list_by(filter = "room_id", newest = "created_at"),        // ?sort=recent
    list_by(filter = "room_id", newest = "vote_score"),        // ?sort=top
    list_by(filter = "owner_principal", newest = "created_at") // an author's posts
)]
pub struct Post {
    #[pk] pub id: Id<Post>,
    pub room_id: i64,
    pub owner_principal: String,
    pub vote_score: i64,
    pub created_at: Timestamp,
}
```

Resolution keys the physical index set by ordered column tuple, so
identical patterns **dedupe** (and flags merge) — repeating a verb is
safe and never doubles an index.

### Indexes decide contention, not just speed

An index earns its keep twice. Outside a transaction it saves ops.
**Inside one it decides how much of the table the transaction conflicts
on:** a read the planner can serve from an index conflicts only on the
sub-range it walked plus the rows it fetched, while a read with no usable
index scans — and a scan puts **every row of the table** into the
transaction's read set, so any concurrent write to that table aborts the
commit, even to a row the filter never matched.

On a table written concurrently that makes "which columns does a
transaction filter on?" a schema question with a correctness-under-load
answer, not a tuning one. Declare an access pattern for every read a
`tx` closure performs — including the ones that only *check* something
(an existence read, a `count`).

**But a declaration is not always enough.** What the planner seeks on is
a filter whose column **leads** an index — equality, `where_in`,
`where_null` or a range. So the composite a
`list_by(filter = "author", newest = "created_at")` derives serves any
read filtering on `author`, whatever the sort; a read filtering only on
`created_at` is not served by it, because `created_at` does not lead it.
The same rule narrows an `update_where` / `delete_where` predicate:
declare the pattern its filter uses, or the sweep scans. No declaration
rescues these: a bare `count()` with **no
filter**, which reads the whole key range without consulting the planner
at all (a *filtered* count does, and is served by the same rule); and an
ordered read with no filter on a leading index column, which takes the
whole table unless it also skips the total.
`boogy:boogy-transactions` has the detail — check it before designing a
schema around a read an index cannot serve.

**"Has an index" is not the test — "leads one" is.** Given
`unique_index(cols = ["room", "slot"])`, filtering `room` seeks;
filtering `slot` alone scans, because the index is ordered by `room`
first and the `slot = 1` rows are scattered through it. The fix is an
index that column leads — `#[index] slot`, or an access pattern whose
filter column is `slot`. And a seek is only as narrow as the sub-range
it covers: an equality matching most of the table is index-served and
still conflicts with nearly every writer. See
`boogy:boogy-transactions`.

## Modeling patterns

| Pattern | Shape |
|---------|-------|
| Entity | one `#[derive(Model)]` struct per noun; `#[pk] id: Id<Self>` |
| Owned entity | add an `owner_principal: String` field; scope rows by the current principal (see the `auth` owner-scoped helpers) |
| Junction / edge | a model for a relationship (`follows`, an affinity `Edge`); usually **no owner column**; composite `unique_index` on the pair |
| Counter | `upsert_increment` for atomic keyed counts — never read-modify-write. Add `#[counter]` when the row is **hot** (conflict-free, but then the value can't be indexed). See below |

## Counters — `upsert_increment`

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

### 🚩 Satisfy the coverage rule with `#[default]` or `on_insert`, NOT by padding `always`

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
use boogy_sdk::Model;

#[derive(Model)]
#[model(table = "rollups")]
pub struct Rollup {
    #[pk] pub id: Id<Rollup>,
    #[lookup_by] pub key: String,          // the upsert's conflict target
    #[counter] pub hits: i64,              // the one counter this call bumps
    #[default = 0] pub total_bytes: i64,   // seeds the insert arm, and only it
}
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
which is what a `#[counter]` column needs to stay conflict-free.

Now the computed case — a value `#[default]` cannot express because it isn't
known until the call:

```rust
// `stamp` here plays a *creation* timestamp, computed at call time. It rides
// `on_insert`, not `always`: written once, when the row is created, and never
// rewritten by a later bump — so it costs this `#[counter]` nothing.
upsert_increment(
    Rollup::TABLE,
    &key,
    Rollup::HITS,
    store::Value::Integer(1),
    UpsertColumns::on_insert_only(&[stamp]),
)?;
```

## 🚩 RED FLAG — a companion column updated with `db_update`

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

## `#[counter]` — the conflict-free variant, for hot counters

`upsert_increment` on a **plain** column (everything above) is atomic and
loses no updates, but it still **rewrites the row**, so it takes a
read-conflict range. Under real contention — a like button, a view count,
a rate meter — concurrent bumps on the same row conflict. Those conflicts
are retried automatically (see `boogy:boogy-transactions`), so the first
symptom is latency rather than an error; past the attempt budget the
request gets a 503. Correct, but it does not scale, and the cost hides
until load.

`#[counter]` removes that. The column is stored in its **own cell**, not
packed into the row, and an increment is an atomic add that registers **no
read-conflict range**. Concurrent increments compose instead of conflicting.

That covers the **counter write**, not the rest of the transaction. If the
closure that bumps the counter also runs a filtered search the planner
can't serve from an index, that search scans and takes every row of the
table as its read set. The bumps still don't collide with each other — an
empty-`always` increment on an existing row touches only the counter cell,
which is outside the row range the scan read — but any concurrent **row**
write to that table (an insert, an update, or the first bump for a key,
which inserts the row) now aborts the scanning transaction. Narrow the
reads in that closure too — filter on a column that leads an index (see
*Indexes decide contention* above).

```rust
use boogy_sdk::model::Id;
use boogy_sdk::Model;

#[derive(Model)]
#[model(table = "posts")]
pub struct Post {
    #[pk]
    pub id: Id<Post>,
    #[lookup_by]
    pub slug: String,
    pub title: String,
    /// Read-only from Rust. Reads merge the real value in; writes go ONLY
    /// through `upsert_increment`.
    #[counter]
    pub vote_score: i64,
}
```

You still increment with `upsert_increment` — `#[counter]` changes how the
column is *stored*, not how you call it. **The conflict-freedom holds only
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
avoid a second write. Pick per column: **hot and standalone → `#[counter]`
with an empty `always`; needed once, at creation → `#[counter]` with
`on_insert`; updated together with companion fields on every call → plain
column + `always`.**

### The field is read-only — that is the point

A `#[counter]` field is excluded from `to_columns()`, so `db_insert` starts
it at zero and **`db_update` does not mention the column at all**. This is
what makes the struct-update idiom safe:

```rust
// SAFE on a #[counter] column — `vote_score` is not in the written column
// set, so the value read earlier cannot be written back.
db_update(post.id.get(), &Post { title: new_title, ..post })?;
```

On a **plain** counter column that same line is the silent lost-update bug
the RED FLAG above describes. `#[counter]` is the structural fix for it.

### A counter cannot back an index — enforced at compile time

Index maintenance needs the previous value to clear the stale entry, and an
atomic add never reads one. So the derive **refuses to build**:

| You wrote | Result |
|---|---|
| `#[counter]` + `#[index]` / `#[lookup_by]` / `#[covering_index]` | compile error |
| `#[counter]` column named in a struct-level `index(cols = [...])` | compile error |
| `#[counter]` column named by `list_by` / `ranked_by` / `tagged_by` | compile error |
| `#[counter]` on the `#[pk]` field | compile error |

This is deliberately a compile error, not a runtime one: the alternative is
an index that *looks* maintained and silently is not — wrong answers rather
than a failure.

**So you cannot sort, rank, or seek by a counter.** "Top posts by score"
is not available as an indexed read. The two sanctioned escape hatches:
scope the ranking to a **bounded sub-range and sort in memory**, or
**materialize the value into a separate plain column** refreshed by a
background job (see `boogy:boogy-background-jobs`) and index *that*.

## `#[counter(index = true)]` does not exist — and won't build

`#[counter]` takes **no arguments**, and neither do the other field markers
(`#[pk]`, `#[index]`, `#[covering_index]`, `#[lookup_by]`).
Passing one is a compile error naming the fix:

```rust ignore-snippet: shows code the derive is meant to REJECT — compiling it would assert the opposite of what it teaches
#[counter(index = true)]     // compile error: #[counter] takes no arguments
pub vote_score: i64,
```

If you have seen `#[counter(index = true)]` in a design note, it is **not
built** — and an indexed counter is refused at compile time anyway, for the
reason above. Write bare `#[counter]` and use one of the two escape hatches.

Note the related shape this catches: `#[index(cols = [...])]` on a *field*.
The multi-column form is declared on the **struct**
(`#[model(index(cols = [...]))]`) — better still, declare an access-pattern
verb and let the derive derive it.

## 🚩 RED FLAG — you cannot add a `#[counter]` to a deployed table

A migration-added column is **never** a counter: `add_column` **refuses** a
counter column outright (a `ConstraintViolation`). A counter's value lives in
a per-row sidecar cell that `insert` seeds, and every read path assumes every
row of that table owns one — flipping the flag on a populated table would make
every pre-existing row read as `0`. Establishing the invariant needs a
backfill, which `add_column` is not.

**Consequence: decide `#[counter]` when you create the table.** The refusal is
loud, which is the good half — but it lands at migration time, on a model
whose derive has *already* stopped writing the field (counter fields are
excluded from `to_columns()`). So the model and the deployed table disagree
until you resolve it; a counter is not something to retrofit.

If you need to convert a live column, the supported route today is a **new
table** with the counter declared up front, plus a migration that copies
the values across (see `boogy:boogy-migrations`).

**Overflow wraps.** The column is a 64-bit signed integer and the add
**wraps** past `i64::MAX` to `i64::MIN` rather than erroring or saturating.
Irrelevant at 9.2 quintillion for a counting workload, but real for a
counter accumulating large deltas (byte totals, currency in minor units) —
clamp the delta on the way in. The delta must be an **integer**; a
fractional delta on a counter column is rejected by the store.

**Public ids.** `Id<T>` is a typed `u64`, not enumeration-resistant. For
opaque user-facing ids use an `IdCodec` at the API edge or a TEXT
`public_id` column carrying a UNIQUE index —
`#[lookup_by] pub public_id: String`, which is also the point lookup every
item route on that id needs. Not `#[unique]`: the derive rejects it, and
before it did it enforced nothing.

**JSON-blob anti-pattern.** "One `data` table with a JSON text column"
looks flexible, but the store has no JSON type and no JSON-path operator:
the blob is opaque text, so every query over a field inside it is a
**full-table scan** plus in-Wasm parsing. Model the fields as real
columns. Sanctioned compromise when structure is *genuinely* unknown: a
real, indexed `kind` column with the variable part as an opaque payload —
promote fields to real columns later via a migration.

## Red flags

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
- "`#[unique]` makes it a unique key" → it isn't an index, nothing is
  enforced, nothing can be sought — and the derive now refuses to build it
  rather than let that pass silently. Use `#[lookup_by]`.
- "One `upsert_increment` can bump both counters" → one counter per call.
  Two calls, same key; the second column starts at `delta` if absent.
- "This field is optional, so `Option<T>`" → not if you'll `where_eq` on
  it. NULL isn't equality; the ordered index walk is never chosen. Sentinel.
- "One `list_by` per model" → the verbs repeat, and identical ones dedupe.
  Declare one per read instead of hand-rolling `index(cols = [...])`.
- "`#[counter]` so I can rank by it" → backwards. `#[counter]` makes a
  column *unindexable* (compile error on any index or `ranked_by` naming
  it). Materialize into a plain column via a job, or sort a bounded
  sub-range in memory.
- "`#[counter(index = true)]` gives me a sortable counter" → the feature
  does not exist; field markers take no arguments and the derive rejects it.
- "`#[counter]` plus an `always` column, still conflict-free" → a non-empty
  `always` rewrites the row and conflicts like any other write. Empty
  `always`, or a value moved to `on_insert` if it's only needed at creation,
  or it isn't conflict-free.

## Integration

← `boogy:designing-boogy-services` (data sketch). This skill is
schema-only. → `boogy:boogy-access-patterns` (the typed `db_*` + `Query`
read surface that consumes these models) → `boogy:boogy-rest-apis`
(handlers that call them). Handlers whose writes must roll back on a
later error — multi-write (insert + a dependent counter / summary, debit +
credit) or a single write with fallible work after it: see
`boogy:boogy-transactions`.
Evolving a deployed schema lives in `boogy:boogy-migrations`.
