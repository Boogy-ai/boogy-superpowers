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

One consequence worth internalising:

- **Do not create a permanent index from a migration.** An `ix_`/`idx_`-named
  index your models do not declare is indistinguishable from one whose
  declaration you deleted, so the reconcile removes it on the next deploy.

### Columns follow the model too, with narrower rules

Columns are reconciled on every deploy as well, but a column carries data, so
only an addition is automatic. A rename needs `#[renamed_from = "old"]` on the
new field, a removal needs `#[model(dropped("old"))]` on the struct, and a type
or nullability change, or a plain column made a counter, is refused: the
deployment never goes live. A required `#[belongs_to]` field added to a table
that has rows needs `Option<T>` or a `#[default]`. The full rules, including
what an unmarked rename silently does to the data: `boogy:boogy-migrations`.

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

### `Decimal` for exact decimals

`Decimal` is exact fixed-point (6 decimal places): safe for money, prices,
rates and running balances. `f64` is for measurements with no exactness
expectation, and a plain integer column counting minor units is just as valid
as `Decimal`. Choosing between them, its range, parsing and rounding:
`boogy:boogy-money-and-decimals`.

### What a column accepts

**The column type binds the stored value, not just the declaration.** A whole
number written to a `f64` column is stored as a float, and a float written to an
`i64` column is stored as a whole number — the store normalizes to what the
column declares, so a search on that column always finds it. A float that cannot
be represented as a whole number (`1.5` into an `i64` column) is **rejected**
with a 409 `ConstraintViolation` naming the column, deterministic and never
retried. Two things follow that are easy to be surprised by: inside a `tx` the
refusal **poisons the whole closure**, not just that one write, so the
transaction cannot commit — the same as any other constraint violation; and a
value aimed at a column you no longer use (dropped, or a counter column in
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
counter column (its value lives in its own cell, and an absent counter
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
   `boogy:boogy-counters`.
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
   (the store assigns the key). A counter column has no field to write
   `#[default]` on at all — `#[model(counter(...))]` takes only `name = "..."`
   — so the combination cannot even be written; its value is read from its own
   cell regardless, and an absent counter already reads as `0`.

Adding or changing a `#[default = ...]` on a column of a **deployed** table
needs no migration — it is part of the same column reconciliation
(`boogy:boogy-migrations`), so editing the attribute and redeploying is enough; the store applies
the new default in place. This is narrower than a type or nullability change,
which the reconcile still refuses: only the default itself may move.

`Id<T>`, `Timestamp`, and `Decimal` come from `boogy_sdk::model`. Build
values with `Id::new(0)` (the placeholder PK on insert — the store
assigns the real `_id` and `db_insert` returns it), `Timestamp::new(ms)`,
`Decimal::new(f)`.

### Nullable vs. sentinel

Making a column `Option<T>` decides whether a query on it is an index seek.
The rule: **a column you will `eq`/seek on must not be nullable; a
column you only post-filter on may be.** NULL is matched by a *different
operator* (`is_null`), never by equality — so a nullable column can't
supply the equality half of a `list_by(filter, order)` index, that bounded
ordered walk is not chosen, and the query degrades to reading every
matching row and sorting in memory. (`is_not_null` never seeks at all.)

- **Seek column → sentinel.** "List open polls, newest first" is
  `list_by(filter = "closed_at", newest = "created_at")`. Declare
  `closed_at: Timestamp` with a non-null `OPEN` sentinel (`0`), so
  `.filter(Poll::closed_at.eq(0))` is a bounded, ordered index walk.
- **Post-filter column → nullable is honest.** `deleted_at:
  Option<Timestamp>` on a table listed by `list_by(filter = "room_id",
  newest = "created_at")`: the `room_id` equality drives the index and
  `.filter(Post::deleted_at.is_null())` is a residual filter applied during
  that walk.
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
  attribute a single-column counter key needs — see `boogy:boogy-counters`.
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
a filter whose column **leads** an index — equality, `is_in`,
`is_null` or a range. So the composite a
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
`boogy:boogy-transaction-conflicts` has the detail — check it before designing a
schema around a read an index cannot serve.

**"Has an index" is not the test — "leads one" is.** Given
`unique_index(cols = ["room", "slot"])`, filtering `room` seeks;
filtering `slot` alone scans, because the index is ordered by `room`
first and the `slot = 1` rows are scattered through it. The fix is an
index that column leads — `#[index] slot`, or an access pattern whose
filter column is `slot`. And a seek is only as narrow as the sub-range
it covers: an equality matching most of the table is index-served and
still conflicts with nearly every writer. See
`boogy:boogy-transaction-conflicts`.

## Modeling patterns

| Pattern | Shape |
|---------|-------|
| Entity | one `#[derive(Model)]` struct per noun; `#[pk] id: Id<Self>` |
| Owned entity | add an `owner_principal: String` field; scope rows by the current principal (see the `auth` owner-scoped helpers) |
| Junction / edge | a model for a relationship (`follows`, an affinity `Edge`); usually **no owner column**; composite `unique_index` on the pair |
| Counter | `upsert_increment` for atomic keyed counts — never read-modify-write. Declare a struct-level `#[model(counter(name = "..."))]` column when the row is **hot** (conflict-free, but then the value can't be indexed, and reading it is an explicit opt-in). See `boogy:boogy-counters` |

## More modeling rules

**Public ids.** `Id<T>` is a typed `u64`, not enumeration-resistant. For
opaque user-facing ids use an `IdCodec` at the API edge or a TEXT
`public_id` column carrying a UNIQUE index —
`#[lookup_by] pub public_id: String`, which is also the point lookup every
item route on that id needs. Not `#[unique]`: the derive rejects it, and
before it did it enforced nothing.

**Bytes are not a column.** An image, a PDF, a video, an uploaded document
or a generated export does not belong in a table — a service instance is
fresh per request under a memory cap, so it cannot hold a user-sized file,
and a large value fights the transaction envelope. Declare a file
collection instead and store a **reference** on the row:

```rust ignore-snippet: a model shape shown against a manifest collection, so the collection and its access class are not in scope here
#[derive(Model)]
struct Profile {
    id: String,
    avatar: Option<FileRef>,   // stores (collection, key) — never a URL
}
```

`FileRef` exists because the reliable mistake is storing a generated URL,
which expires. Store the reference; mint the URL when you render. See
`boogy:boogy-file-storage`.

**JSON-blob anti-pattern.** "One `data` table with a JSON text column"
looks flexible, but the store has no JSON type and no JSON-path operator:
the blob is opaque text, so every query over a field inside it is a
**full-table scan** plus in-Wasm parsing. Model the fields as real
columns. Sanctioned compromise when structure is *genuinely* unknown: a
real, indexed `kind` column with the variable part as an opaque payload —
promote fields to real columns later via a migration.

## Red flags

- "`#[unique]` makes it a unique key" → it isn't an index, nothing is
  enforced, nothing can be sought — and the derive now refuses to build it
  rather than let that pass silently. Use `#[lookup_by]`.
- "This field is optional, so `Option<T>`" → not if you'll `eq`-filter on
  it. NULL isn't equality; the ordered index walk is never chosen. Sentinel.
- "One `list_by` per model" → the verbs repeat, and identical ones dedupe.
  Declare one per read instead of hand-rolling `index(cols = [...])`.
- "I'll keep a count on the row and bump it" → `upsert_increment` or a counter
  column, never read-modify-write; read `boogy:boogy-counters` first.

## Integration

← `boogy:designing-boogy-services` (data sketch). This skill is
schema-only. → `boogy:boogy-access-patterns` (the typed `db_*` + `Query`
read surface that consumes these models) → `boogy:boogy-rest-apis`
(handlers that call them). Handlers whose writes must roll back on a
later error — multi-write (insert + a dependent counter / summary, debit +
credit) or a single write with fallible work after it: see
`boogy:boogy-transactions`.
Counts, counter columns and `upsert_increment`: `boogy:boogy-counters`.
Money and exact decimals: `boogy:boogy-money-and-decimals`. Evolving a
deployed schema, the column reconcile included, lives in `boogy:boogy-migrations`.
