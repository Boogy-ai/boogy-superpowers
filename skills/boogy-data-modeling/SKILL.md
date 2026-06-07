---
name: boogy-data-modeling
description: Use when declaring tables, designing schemas, or choosing how to represent data in a Boogy service
---

# Modeling data on Boogy

The store is a typed, columnar, ACID table store with a `u64` auto
primary key per row. It is **not** schemaless: there is no JSON column
type and no JSON-path filter — model your data as columns up front.

## Iron Law: no bare names

Every table, column, **and index** name lives in a `cols` module — one
tag struct per table with `pub const` items (`TABLE`, one per column,
one per index). Handlers, init, jobs, and migrations reference the
consts. A rename is one edit; a typo is a compile error, not a 500.

```rust boogy-snippet
pub struct Posts;
impl Posts {
    pub const TABLE: &str = "posts";
    pub const BODY: &str = "body";
    pub const CREATED_AT: &str = "created_at";
    pub const IDX_BY_CREATED: &str = "by_created";
}
```

(Exceptions: migration literals — a shipped migration is frozen — and
HTTP route param names.)

## Table-design quick reference

Build tables with the `Table` builder; column types map from Rust via
the `Field` trait:

| You want | Column / Rust type |
|----------|--------------------|
| text | `.text(c)` / `String` |
| whole number | `.integer(c)` / `i64`, `u64` |
| decimal money/score | `Decimal` (stored as text, 6 dp) |
| timestamp (unix millis) | `Timestamp` / `.integer(c)` |
| true/false | `.boolean(c)` / `bool` |
| float | `.real(c)` / `f64` |
| typed foreign id | `Id<T>` (a typed `u64`) |
| optional | `.nullable_text/.nullable_integer` / `Option<T>` |

- **Auto PK:** the store owns `_id` (a `u64`). Do **not** add your own
  `id` column. Look up a row by PK with `get_row(table, id)` — never a
  filter on `_id`.
- **Public ids:** `Id<T>` is a typed `u64`, not enumeration-resistant.
  For opaque user-facing ids use `IdCodec` (encode/decode at the API
  edge) or a unique TEXT `public_id` column.
- **`.unique()`** marks the *last declared* column unique. For compound
  uniqueness use `.unique_index(name, &cols)`.
- **`.owned()`** declares the conventional owner column **and** its
  index in one call — use it for any table whose rows belong to a
  principal (served via the `auth` owner-scoped helpers). `.owned_by(c)`
  for a custom owner-column name.

## Modeling patterns

| Pattern | Shape |
|---------|-------|
| Entity | one table per noun; `_id` is the PK |
| Owned entity | add `.owned()`; rows scoped to a principal |
| Junction / edge | a table for a relationship (`follows`, `likes`); usually **no owner column** (the edge belongs to neither side); composite `.unique_index` on the pair |
| Counter | `upsert_increment(table, key, counter, delta, set)` for atomic keyed counts — not read-modify-write |

**Author vs owner.** The owner column (set by `.owned()`) drives the
auth helpers' "is this yours?" check; a display `author` field is
separate data. Authorize on the owner column; show the author field.

**JSON-blob anti-pattern.** "One `data` table with a JSON text column"
looks flexible, but the store has no JSON type and no JSON-path
operator: the blob is opaque text, so every query over a field inside
it is a **full-table scan** plus in-Wasm parsing — no indexes, no typed
reads. Sanctioned compromise when structure is genuinely unknown: a
real, indexed `kind` column with the variable part as an opaque
payload. The hot query (by `kind`) stays index-backed; promote fields
to real columns later via a migration.

## `#[derive(Model)]` vs raw store calls

`#[derive(Model)]` on a struct of `Field` types emits per-field column
consts, `schema()`, `from_row`, `to_columns` (excludes the `_id` PK),
and `id()`. Register with `create_model::<M>()` in init; CRUD via
`db_insert` / `db_get` / `db_find_by` / `db_update` / `db_delete`.
Verified attributes: `#[pk]`, `#[unique]`, `#[index]`,
`#[covering_index]`, `#[lookup_by]`, `#[model(column = "...")]`, plus the
struct-level access-pattern verbs.

**Use raw store calls** for one-off or dynamically-shaped tables, rows
you never deserialize, or columns with no `Field` impl.

## Integration

← `boogy:designing-boogy-services` (data sketch). This skill is
schema-only: declaring queries/indexes lives in
`boogy:boogy-access-patterns`, and evolving a deployed schema in
`boogy:boogy-migrations` (both ship this release).
