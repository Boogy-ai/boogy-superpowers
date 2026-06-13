---
name: boogy-access-patterns
description: Use when adding a list, lookup, ranking, filter, tag, or pagination query to a Boogy service
---

# Querying data on Boogy

You read data through the **typed model layer**: `db_get` / `db_find_by`
for point reads and the `Query` DSL for lists, mapping rows back with
`M::from_row`. Every query needs an index, or it degrades to a
full-table scan — and you don't hand-name indexes: you declare the
*access pattern* on the `#[derive(Model)]` struct (data-modeling skill)
and the right index is derived.

## Iron Law

**Declare the access pattern on the model; read through `db_*` + `Query`.**
Each query you write maps to a verb you declared on the struct. Raw
`store::find` / `FindOptions` is an **escape hatch** for shapes the DSL
can't express — never the default for normal reads.

## Verb → query mapping

The verb you put on the model (see `boogy:boogy-data-modeling`) is the
index that backs the query:

| Model declaration | Backs this read |
|-------------------|-----------------|
| `#[lookup_by]` on a field | point lookup: `db_find_by::<M>(M::COL, val)` (the unique row where `col == v`) |
| `#[model(list_by(filter = "peer", newest = "created_at"))]` | filtered newest-first list. **Default (client-facing) → keyset:** `Query::on(M::TABLE).where_eq(M::PEER, v).keyset_by(M::CREATED_AT, SortDir::Desc).cursor(c).limit(n).fetch_page(…)`. A small bounded "last N" internal read may use `.order_by_desc(M::CREATED_AT).limit(n).fetch_all()`. |
| `#[model(ranked_by(highest = "score"))]` | global ranked feed. **Default → keyset:** `Query::on(M::TABLE).keyset_by(M::SCORE, SortDir::Desc).cursor(c).limit(n).fetch_page(…)`. Bounded top-N → `.order_by_desc(M::SCORE).limit(n).fetch_all()`. |
| `#[model(tagged_by(tag, refs))]` | junction page: seek the tag, expose `refs` to hydrate parents |

**Default any list a client pages through to keyset** (`.keyset_by(…).cursor(…)
.fetch_page(…)` → `CursorPage`) — see the recipe below. `.fetch_all()` is for a
small bounded internal read, never an unbounded client list. Offset is never the
answer for deep pages.

You write the column **consts the derive emitted** (`Message::PEER`,
`Conversation::LAST_AT`) — never bare strings, never a hand-rolled index
name.

## Point reads — `db_*`

| Need | Call | Returns |
|------|------|---------|
| one row by primary key | `db_get::<M>(id)` | `Result<Option<M>>` |
| all rows where `col == v` | `db_find_by::<M>(M::COL, val)` | `Result<Vec<M>>` |
| insert (auto-PK) | `db_insert(&m)` | `Result<u64>` (the new `_id`) |
| overwrite a row | `db_update(id, &m)` | `Result<()>` |
| delete a row | `db_delete(id)` | `Result<()>` |

`db_find_by` takes a `boogy_sdk::store::Val` (e.g.
`Val::Text(peer.to_string())`, `Val::Integer(post_id as i64)`). A
`#[lookup_by]` lookup returns a `Vec` of length 0 or 1 — take
`.into_iter().next()` for the single row. This is the canonical upsert
shape (from chat):

```rust
// Point-lookup by the natural key, then update-or-insert.
let existing: Option<Conversation> =
    db_find_by::<Conversation>(Conversation::PEER, Val::Text(peer.to_string()))?
        .into_iter()
        .next();
match existing {
    Some(c) => db_update(c.id.get(), &updated_conversation)?,
    None    => { db_insert(&new_conversation)?; }
}
```

## Lists — the `Query` DSL

`Query::on(M::TABLE)` builds a typed query; chain filters and order, then
a terminal. `fetch_all`/`fetch_page` return raw `Row`s — map each with
`M::from_row(&row)`.

The two examples below end in `.limit(n).fetch_all()` — that is the
**bounded read**: a fixed "last N" / "top N" you size yourself, never an
unbounded list. **A list a client pages through defaults to keyset**
(`.fetch_page` → `CursorPage`) — the recipe section right after these:

```rust boogy-snippet
// The `Model` trait (in scope here) provides `TABLE` + `from_row` to the
// query/read code below. In a real service the struct lives in its own
// `models.rs` (which imports `boogy_sdk::Model` for the derive) and the
// handler module imports the trait — see the chat example.
use boogy_sdk::model::{Id, Model, Timestamp};

#[derive(boogy_sdk::Model)]
#[model(table = "messages", list_by(filter = "peer", newest = "created_at"))]
pub struct Message {
    #[pk] pub id: Id<Message>,
    pub peer: String,
    pub direction: String,
    pub body: String,
    pub created_at: Timestamp,
}

// list_by(filter = peer, newest = created_at) backs this seek: equality
// on peer, newest-first within it. Bounded "last N" read — caller-sized
// `limit`, no cursor. A client-paged inbox uses `fetch_page` (recipe below).
pub fn last_messages(peer: &str, limit: usize) -> Result<Vec<Message>, ApiError> {
    let rows = Query::on(Message::TABLE)
        .where_eq(Message::PEER, peer)
        .order_by_desc(Message::CREATED_AT)
        .limit(limit)
        .fetch_all()?;
    Ok(rows.iter().map(Message::from_row).collect())
}
```

A `ranked_by` feed is the same minus the filter — again a **bounded**
read (a fixed top-N for an internal aggregate, not a client list):

```rust
// ranked_by(highest = last_at) backs a global newest-activity-first walk.
// Bounded top-500 internal read; a client feed keysets (recipe below).
let rows = Query::on(Conversation::TABLE)
    .order_by_desc(Conversation::LAST_AT)
    .limit(500)
    .fetch_all()?;
let items: Vec<Conversation> = rows.iter().map(Conversation::from_row).collect();
```

**Filter builders** (all `where_*`): `where_eq`, `where_neq`, `where_gt`,
`where_gte`, `where_lt`, `where_lte`, `where_like`, `where_not_like`,
`where_null`, `where_not_null`, `where_in(col, iter)`, and `.or(|q| …)`
for an OR-of-AND group. Order: `order_by_asc`/`order_by_desc`/`order_by`.

**Terminals:**
- `.fetch_all()` → `Result<Vec<Row>>` — all matches (subject to `.limit()`)
- `.fetch_one()` → `Result<Option<Row>>` — first match (`limit` forced to 1)
- `.fetch_all_with_total()` → `Result<(Vec<Row>, u64)>` — rows + count
- `.count()` → `Result<u64>` — count only (ignores `.or()`, sort, page)
- `.fetch_page(|row| …)` → `CursorPage<T>` — keyset pagination (below)

## The canonical paginated-list recipe

Keyset, not offset. `fetch_page` appends the keyset resume filter,
overfetches by 1, builds the `Cursor` from the last kept row, and returns
`CursorPage<T>` — no manual cursor arithmetic:

```rust
use boogy_sdk::pagination::decode;
use boogy_sdk::store::SortDir;

// Decode the inbound ?cursor= (None on first page); page a ranked feed.
let cursor = req.query("cursor").and_then(decode);
let page = Query::on(Post::TABLE)
    .keyset_by(Post::SCORE_TOTAL, SortDir::Desc)  // keyset column + direction
    .limit(20)
    .cursor(cursor)
    .fetch_page(|row| PostView::from_row(row))?;   // map Row -> your DTO
// page: CursorPage<PostView> — { items, next_cursor? }
```

**Offset vs keyset:** offset shifts under concurrent inserts and
`OFFSET 10000` scans 10001 rows — a deep-page cliff. Keyset is a
constant-cost indexed lookup. Always keyset for client-facing lists.

## When raw `store::find` is the escape hatch

The DSL covers the common shapes. Drop *below* it only for what it can't
express:

- **OR-groups the `.or()` builder can't represent** — a keyset OR that
  must merge with caller-supplied domain filters (`find_rows_grouped`).
- **Junction hydration** — page the side table with `fetch_page`, then
  batch-hydrate parents in one read with `where_in(REFS, ids)` /
  `get_many`. The DSL has no JOIN primitive; this two-step is the pattern.
- **Streaming a whole table in a batch job** — `for_each_batch(...)`
  (`order_col` is an INDEX NAME, not a column; cannot run inside `tx`).
  Index names are **schema-canonical** — derived as `ix_<table>_<cols>`,
  NOT the `name` you wrote in the access-pattern/index declaration (that
  arg is canonicalized and discarded). A hand-typed name silently drifts
  from the real one: the cursor returns NotFound (a hard-to-trace 404/500
  at runtime, not a compile error). When you genuinely need this
  low-level cursor, pass the **canonical** `ix_<table>_<col1>_<col2>…`
  name and annotate the call `// index-name-ok: <reason>`. Prefer the
  Query DSL — `where_eq(...).keyset_by(...).fetch_page(...)` — which lets
  the planner pick the index **by the query's columns**, so there's no
  name to drift.

`Cursor`, `decode`/`encode`, `CursorPage::from_overfetched`, and
`keyset_resume_filter` live in `boogy_sdk::pagination` when you need them
raw. Don't re-derive the overfetch logic — use the helper.

## Unindexed-scan guardrail

A query with no usable index that scans past the row threshold **errors**
(strict mode), with a hint naming the fix: *declare an access pattern so
the index is derived.* `.allow_full_scan("reason")` is an audited
**opt-out**, not a fix — the scan is still O(table). Use it only for
genuinely intentional small/single-owner/admin scans (chat's
`list_conversations` does this for a single-owner table).

## Red flags

- "I'll just load all rows and sort in memory" → O(N) reads + memory blowup. Declare the verb, use `Query`.
- "I'll reach for `store::find` / `FindOptions`" → that's the escape hatch. Use `db_find_by` / `Query` and a declared access pattern.
- "I'll hand-write the index name" → the derive names it (`ix_<table>_<cols>`); the `name` you declared is discarded. Reference data by **columns** via `db_find_by` / the Query DSL — never by a hardcoded index name. A literal name passed to `for_each_batch`/`open_cursor` drifts from the canonical one and the cursor returns NotFound at runtime.
- "Offset pagination is fine" → not for deep pages. `fetch_page` (keyset).

## Integration

← `boogy:boogy-data-modeling` (the `#[derive(Model)]` structs + access-
pattern verbs these queries consume). **REQUIRED BACKGROUND for any list
endpoint.** → `boogy:boogy-rest-apis` (handlers that call `db_*`/`Query`).
→ `boogy:boogy-migrations` to add an access pattern to a deployed service.
