---
name: boogy-access-patterns
description: Use when adding a list, lookup, ranking, filter, tag, or pagination query to a Boogy service
---

# Querying data on Boogy

Every query needs an index, or it degrades to a full-table scan. You do
**not** hand-name indexes: you declare the *access pattern* with a verb
on the table, and the resolver derives the right index shape.

## Iron Law

**Declare the access pattern with a verb. Never hand-roll a secondary
index for a query path a verb covers, and never hand-write a derived
index name.** Declaring intent (`list_by`/`ranked_by`/…) — not the
physical index — is the altitude. The resolver names and shapes it.

## Verb quick-reference

Order is expressed in English by free functions: `newest(col)` /
`oldest(col)` (timestamps), `highest(col)` / `lowest(col)` (scores).

| Verb | Query it serves | Declaration | Derives |
|------|-----------------|-------------|---------|
| `.list_by(filter, order)` | rows where `filter == v`, ordered, paginated ("my links by clicks") | `.list_by(OWNER, highest(CLICKS))` | covering composite `(filter, order)` |
| `.ranked_by(order)` | top rows by `order`, no filter (global feed / leaderboard) | `.ranked_by(highest(SCORE))` | covering single-col `(order)` |
| `.lookup_by(column)` | the unique row where `column == v` (point lookup) | `.lookup_by(SLUG)` | unique `(column)` |
| `.tagged_by(tag, refs)` | junction/side table: rows tagged `tag`, exposing `refs` to join back | `.tagged_by(TAG, POST_ID)` | covering `(tag, refs)` |

Derived names follow a deterministic `ix_<table>_<cols>` rule and merge
by column tuple (flags OR together; duplicate patterns dedupe). **You
never write that name** — read `.resolved_indices()` if you must see it.
An owner-scoped list already has its index from `.owned()` /
`.owned_by()` (data-modeling skill) — don't redeclare it.

## When raw `find_rows` is right

The verbs cover the common shapes. Drop to raw reads for multi-filter
combos or OR-groups the verbs don't express. Read-helper decision table:

| Need | Use |
|------|-----|
| one row by primary key | `get_row(table, id)` (never filter on `_id`) |
| first row matching one column | `find_row_by(table, col, val)` |
| all rows for the current principal | `auth::find_owned(table, owner_col)` |
| one filter, all matches | `find_rows_by(table, col, val)` |
| multi-filter AND + composite sort + page | `find_rows(table, filters, sort, page)` |
| OR-of-AND (incl. keyset pagination) | `find_rows_grouped(table, filters, or_groups, sort, page)` |
| stream a whole table in a batch job | `for_each_batch(...)` — **`order_col` is an INDEX NAME, not a column** (or `None` for PK order); cannot run inside `tx` |

## The canonical paginated-list recipe

Keyset, not offset. The typed Query DSL (emitted by `wit_glue!`) is the
primary recipe — no manual cursor arithmetic:

```rust boogy-snippet
use boogy_sdk::pagination::{decode, CursorPage};
use boogy_sdk::store::SortDir;

struct T; impl T { const POSTS: &str = "posts"; }
struct C; impl C { const OWNER: &str = "owner_principal"; const CREATED_AT: &str = "created_at"; }

#[derive(serde::Serialize)]
struct PostView { id: u64 }
impl PostView {
    fn from_row(row: &Row) -> PostView { PostView { id: row.int("_id") as u64 } }
}

fn list(req: &mut Req<'_>, principal: String) -> Result<CursorPage<PostView>, ApiError> {
    // Decode the inbound ?cursor= (None on first page).
    let c = req.query("cursor").and_then(decode);

    // Build and execute; fetch_page defaults to limit=20 when .limit() is omitted.
    let page = Query::on(T::POSTS)
        .where_eq(C::OWNER, principal)   // access-pattern-backed filter
        .keyset_by(C::CREATED_AT, SortDir::Desc)   // keyset column + direction
        .limit(20)
        .cursor(c)
        .fetch_page(|row| PostView::from_row(row))?;

    // page: CursorPage<PostView> — { items, next_cursor? }
    Ok(page)
}
```

`fetch_page` handles everything internally: it appends the keyset resume
filter (`keyset_resume_filter`), overfetches by 1, builds the composite
`Cursor` from the last kept row, and returns `CursorPage<T>`.

**Other terminal methods on `Query`:**
- `.fetch_one()` → `Result<Option<Row>>` — first match, `limit` overridden to 1
- `.fetch_all()` → `Result<Vec<Row>>` — all matches (subject to `.limit()`)
- `.fetch_all_with_total()` → `Result<(Vec<Row>, u64)>` — rows + count in one call
- `.count()` → `Result<u64>` — count only (ignores `.or()`, sort, page)

**Offset vs keyset:** offset shifts under concurrent inserts and
`OFFSET 10000` scans 10001 rows — a deep-page cliff. Keyset (`_id > last`)
is a constant-cost indexed lookup. Always keyset for client-facing lists.

### The layer underneath — for shapes the DSL doesn't cover

`Query` delegates to `find_rows_grouped` + `keyset_paginate` (both
emitted by `wit_glue!`). Drop to them when needed:

- **OR-groups the `.or()` builder can't express in a single query** —
  e.g. a tagged-junction page where the keyset OR must merge with
  caller-supplied domain filters that aren't representable as simple
  AND-chains in the DSL.
- **Junction hydration** — page the side table (with `fetch_page` or
  `keyset_paginate`), then batch-hydrate parents in one read with
  `filter_in(REFS, ids)`. The DSL has no JOIN primitive; this is the
  correct two-step pattern.
- **`CursorPage::from_overfetched` directly** — rare; only when you
  need full control over the `(item, Cursor)` derivation per row that
  `.fetch_page`'s closure doesn't give you.

`keyset_resume_filter`, `Cursor`, `decode`/`encode`, and
`CursorPage::from_overfetched` are all in `boogy_sdk::pagination`
when you need them raw. Don't re-derive the overfetch logic — use the
helper.

## Unindexed-scan guardrail

A query with no usable index that scans past the row threshold **errors**
(strict mode), with a hint naming the fix: *declare an access pattern
(`list_by`/`ranked_by`/`lookup_by`/`tagged_by`) so the index is derived.*
`.allow_scan("reason")` is an audited **opt-out**, not a fix — the scan is
still O(table). Use it only for genuinely intentional small/admin scans.

## Red flags

- "I'll just load all rows and sort in memory" → O(N) reads + memory blowup. Declare the pattern.
- "I'll hand-write the index name" → that's the resolver's job. Use the verb.
- "Offset pagination is fine" → not for deep pages. Keyset.

## Integration

← `boogy:boogy-data-modeling` (tables + owner columns). **REQUIRED
BACKGROUND for any list endpoint.** → `boogy:boogy-migrations` to add an
access pattern (and its index) to an already-deployed service.
