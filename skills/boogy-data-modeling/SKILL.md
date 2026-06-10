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
register it in `init_tables` with `create_model::<M>()` and do all CRUD
through `db_insert` / `db_get` / `db_find_by` / `db_update` / `db_delete`
+ the `Query` DSL. This is the canonical chat example — `Conversation`
and `Message`:

```rust boogy-snippet
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
    fn init_tables() {
        // Each model's schema (columns + the indexes its declared access
        // patterns imply) is created from the struct — no hand-built Table.
        create_model::<Conversation>();
        create_model::<Message>();
    }
    // build_router() below ...
}
```

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
| decimal money / score / weight | `Decimal` (stored as 6-dp text) |
| timestamp (unix millis) | `Timestamp` (integer column) |
| typed foreign / primary id | `Id<T>` (a typed `u64`; `Id<Post>` ≠ `Id<User>`) |
| optional / nullable | `Option<T>` (the only thing that makes a column nullable) |

`Id<T>`, `Timestamp`, and `Decimal` come from `boogy_sdk::model`. Build
values with `Id::new(0)` (the placeholder PK on insert — the store
assigns the real `_id` and `db_insert` returns it), `Timestamp::new(ms)`,
`Decimal::new(f)`.

## Attribute reference (all verified)

**Field-level:**
- `#[pk]` — maps to the store auto-PK `_id`; excluded from `to_columns`;
  read from `_id`. At most one per struct. A model may have *no* `#[pk]`
  (identity is then a composite unique index; the store still assigns an
  `_id` used by `db_get`/`db_delete`).
- `#[unique]` — column-level UNIQUE.
- `#[index]` — single-column index `idx_<table>_<col>`.
- `#[covering_index]` — single-column covering index (stores a row copy
  in the index entry so a walk skips the per-row fetch; costs write
  amplification).
- `#[lookup_by]` — declares a unique point-lookup access pattern → UNIQUE
  single-column index. (Cannot be the `#[pk]` field.)
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

## Modeling patterns

| Pattern | Shape |
|---------|-------|
| Entity | one `#[derive(Model)]` struct per noun; `#[pk] id: Id<Self>` |
| Owned entity | add an `owner_principal: String` field; scope rows by the current principal (see the `auth` owner-scoped helpers) |
| Junction / edge | a model for a relationship (`follows`, an affinity `Edge`); usually **no owner column**; composite `unique_index` on the pair |
| Counter | `upsert_increment(table, key, counter, delta, set)` for atomic keyed counts — not read-modify-write |

**Public ids.** `Id<T>` is a typed `u64`, not enumeration-resistant. For
opaque user-facing ids use an `IdCodec` at the API edge or a unique TEXT
`public_id` column (`#[unique] pub public_id: String`).

**JSON-blob anti-pattern.** "One `data` table with a JSON text column"
looks flexible, but the store has no JSON type and no JSON-path operator:
the blob is opaque text, so every query over a field inside it is a
**full-table scan** plus in-Wasm parsing. Model the fields as real
columns. Sanctioned compromise when structure is *genuinely* unknown: a
real, indexed `kind` column with the variable part as an opaque payload —
promote fields to real columns later via a migration.

## Integration

← `boogy:designing-boogy-services` (data sketch). This skill is
schema-only. → `boogy:boogy-access-patterns` (the typed `db_*` + `Query`
read surface that consumes these models) → `boogy:boogy-rest-apis`
(handlers that call them). Multi-write handlers (insert + a dependent
counter / summary, debit + credit): see `boogy:boogy-transactions`.
Evolving a deployed schema lives in `boogy:boogy-migrations`.
