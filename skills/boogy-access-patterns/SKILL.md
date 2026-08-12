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
and the right index is derived. (Inside a `tx` a scan costs correctness
under load rather than just ops, and some reads no declaration rescues —
see *Inside a `tx`* below.)

## Iron Law

**Declare the access pattern on the model; read through `db_*` + `Query`.**
Each query you write maps to a verb you declared on the struct. Raw
`store::find` / `FindOptions` is an **escape hatch** for shapes the DSL
can't express — never the default for normal reads.

**Every list read is bounded — there is no "fetch the whole table."** A
list a client (or your own agent) walks through **keyset-paginates**
(`.keyset_by(…).cursor(…).fetch_page(…)` → `CursorPage`); a one-shot
internal read carries an explicit `.limit(n)`. **`.fetch_all()` with no
`.limit()` is a bug** — it streams every matching row into memory and is
exactly the "blindly load the whole table" mistake. Size the cap to row
density: **~100** when rows are fat (large text / blobs / nested JSON),
up to **~1000** when they're slim (a few scalar columns). Past that — or
for anything a client scrolls — **keyset-paginate; don't just raise the
cap.** A bigger `.limit()` still has a ceiling; a cursor doesn't.

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
| all rows where `col == v` | `db_find_by::<M>(M::COL, val)` | `Result<Vec<M>>` — **bounded only on a unique column**, see below |
| insert (auto-PK) | `db_insert(&m)` | `Result<u64>` (the new `_id`) |
| overwrite a row | `db_update(id, &m)` | `Result<()>` |
| delete a row | `db_delete(id)` | `Result<()>` |

`db_find_by` takes a `boogy_sdk::store::Val` (e.g.
`Val::Text(peer.to_string())`, `Val::Integer(post_id as i64)`) — so the
calling module needs `use boogy_sdk::store::Val;`. Note the asymmetry with its
neighbour: the `Query` DSL's `where_*` builders take bare `&str` / `i64` via
`IntoVal`, while `db_find_by` takes a `Val` only. Two adjacent read APIs, two
argument conventions.

A `#[lookup_by]` lookup returns a `Vec` of length 0 or 1 — take
`.into_iter().next()` for the single row.

> **`db_find_by` is bounded ONLY on a unique / `#[lookup_by]` column.** It pages
> internally until *every* matching row is in memory — no caller limit, no
> cursor. On a unique column that is at most one row, which is the intended use.
> On any other column it loads the whole matching set, the same failure mode as
> an unbounded `.fetch_all()`. For a non-unique filter use the `Query` DSL:
> `.fetch_one()` for a single row, `.limit(n)` for a capped read, `.fetch_page()`
> for a client-paged list. This is the canonical upsert
shape (from chat):

```rust
// `Val` is the read-side value type; `wit_glue!` deliberately does NOT
// re-export it, so import it explicitly for a by-column lookup.
use boogy_sdk::store::Val;

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

```rust
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
- `.fetch_all()` → `Result<Vec<Row>>` — all matches **up to `.limit()`**; an unbounded `.fetch_all()` (no `.limit()`) loads the whole table and is a bug — always cap it (~100–1000 by row density) or keyset instead
- `.fetch_one()` → `Result<Option<Row>>` — first match (`limit` forced to 1)
- `.fetch_all_with_total()` → `Result<(Vec<Row>, u64)>` — rows + count
- `.count()` → `Result<u64>` — count only (ignores `.or()`, sort, page)
- `.fetch_page(|row| …)` → `CursorPage<T>` — keyset pagination (below)

## The canonical paginated-list recipe

Keyset, not offset. `fetch_page` appends the keyset resume filter,
overfetches by 1, builds the `Cursor` from the last kept row, and returns
`CursorPage<T>` — no manual cursor arithmetic.

**Keyset endpoints take a single opaque `?cursor=`** (the encoded
boundary returned as the previous page's `next_cursor`) — there is **no**
`before`/`after`/`offset` param; do not design one. And `.keyset_by(col,
dir)` MUST match the column/direction the model declared via its
`ranked_by`/`list_by` order, or the read errors instead of paging.

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
  An OR is seeked only when **every** arm carries an equality on a
  column that leads an index; the `< c OR (= c AND < cursor)` keyset
  shape has a bare range in its first arm, so it never qualifies. What
  keeps this read narrow is therefore the AND-prefix: give it a filter
  on a leading index column. See *Inside a `tx`* below.
- **Junction hydration** — page the side table with `fetch_page`, then
  batch-hydrate parents in one read with `where_in(REFS, ids)` /
  `get_many`. The DSL has no JOIN primitive; this two-step is the pattern.
  `where_in` seeks when its column **leads an index** — but `_id` leads
  none, so hydrating *by id* means `get_many` (point gets), in a `tx` or
  out.
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

## Counter columns — readable everywhere, sortable nowhere

A `#[counter]` column (see `boogy:boogy-data-modeling`) is stored in its own
cell, not inside the row. **Reads merge it back transparently** — a point
read, a list page, an index walk, and `count` all see the live value, so
nothing about the `db_*` / `Query` surface changes for reading one.

What changes is what you may **declare**. A counter cannot back an index, so
naming it in an access-pattern verb is a **compile error**:

```rust ignore-snippet: shows code the derive is meant to REJECT — compiling it would assert the opposite of what it teaches
// COMPILE ERROR — ranked_by is backed by an index, a counter can't back one.
#[model(table = "posts", ranked_by(highest = "vote_score"))]
pub struct Post {
    #[counter] pub vote_score: i64,
}
```

So there is no `keyset_by(Post::VOTE_SCORE, …)` page and no "top N by score"
index read. Two sanctioned ways to get a ranked view anyway:

| Approach | When |
|---|---|
| Scope to a **bounded sub-range** (a declared verb that *is* indexed — e.g. newest 500 in a room) and sort those in memory | the ranking is over a slice you can bound |
| **Materialize** the counter into a separate plain column refreshed by a background job, and index *that* | you need a global ranked feed |

The second is a deliberate staleness-for-scalability trade: the ranked column
lags the live counter by the job interval. Say so in the endpoint's docs.

### 🚩 Never branch on a counter you read, then write

A counter read takes **no read-conflict range** — that is exactly what keeps
reading one from re-introducing the conflict the atomic add removes. So a
value you read may already be stale, and an increment landing before your
commit **does not** conflict, so it does not trigger the automatic retry
that would otherwise re-read it. The staleness is silently accepted.

```rust
// WRONG — a read-then-write decision on a counter, or anything derived
// from one (a count, a filter, a sort over it).
tx::<_, _, ApiError>(|| {
    let post = db_get::<Post>(id)?.ok_or_else(ApiError::not_found)?;
    if post.vote_score < -10 { db_delete::<Post>(id)?; }   // 🚩 stale
    Ok(())
})
```

When the decision must hold, express it as a **predicate** instead —
`store::delete_where` / `store::update_where` with the counter in the
filters. Those serialize the rows they actually MATCH against concurrent
increments, so an increment that lifts a matched row out of the predicate
becomes a serialization conflict rather than a row acted on with a stale
value — and a serialization conflict is retried automatically, so the
transaction re-runs against the settled value and you never see it.

Reads that only *report* a value (get, list, count) need none of this. The
rule is about branch-then-write.

## Unindexed-scan guardrail

A query with no usable index that scans past the row threshold **errors**
(strict mode), with a hint naming the fix:
*declare an access pattern so
the index is derived.* `.allow_full_scan("reason")` is an audited
**opt-out**, not a fix — the scan is still O(table). Use it only for
genuinely intentional small/single-owner/admin scans (chat's
`list_conversations` does this for a single-owner table).

### Inside a `tx`, an unindexed read costs correctness, not just ops

The planner is the same one; what changes is the price of an unindexed
read. The guardrail applies inside a `tx(|| …)` closure too, at **half
the row threshold** — because the same scan costs more here — and its
error names the table, the conflict range the read just took, and either
the index that would serve the query or, when you already have one, what
would have bounded it (and when the query constrains no column at all,
that there is nothing to index). Being a store error, the refusal also
**poisons the transaction** — you cannot catch it and carry on; commit is
refused and the closure rolls back. `.allow_scan("reason")` downgrades it to a warning
here as it does outside, but it buys **strictly less**: outside a `tx` it
means "this scan is intentional", inside one it also means "and I accept
losing to any concurrent write to this table", because the scan
puts **every row of the table into the transaction's read set**, so any
concurrent write to that table aborts your commit, even to a row your
filter never matched. An index-served read conflicts only on the
sub-range it seeked plus the rows it fetched. Consequences for reads a
`tx` closure performs:

- **Give it a filter on a column that LEADS an index.** Equality,
  `where_in`, `where_null` and a range all seek — including on the first
  column of the composite a `list_by` derives. One such AND-filter is
  enough; failing that, an `.or()` seeks when *every* arm carries an
  equality on a leading index column. A filter on a column that appears
  only *later* in a composite is applied per row, so it narrows the
  result but not the conflict range; that one needs its own index.
  The same rule narrows an `update_where` / `delete_where` predicate;
  without a leading-index filter the sweep scans. So does a
  bare `.count()` with no filter, which reads the whole key range without
  consulting the planner at all (a *filtered* `.count()` does).
  `boogy:boogy-transactions` has the detail.
- **Don't ask for a total you won't use.** A read whose only narrowing is
  its SORT takes the whole table inside a `tx` unless it skips the total.
  `.fetch_page()`, `.fetch_one()` and a `.limit()`ed `.fetch_all()` ask
  for no total — that, plus the page bound, is what lets such a read stop
  at the page and ride the sort index. `.fetch_all_with_total()` and a
  *filtered* `.count()` ask for an exact number, so they drain the whole
  match set.
- **Index-served is not the same as narrow.** The read set is the
  sub-range the seek covered, so an equality matching most of the table
  is index-served and still conflicts with nearly every writer. Seek on
  the *selective* column.

Either way there is a ceiling: a search inside a transaction that has to
work through more than ~50,000 rows (matches on an index walk, rows touched
on a scan) is refused with an error pointing you at the cursor/pagination
API.

## Red flags

- "I'll just load all rows and sort in memory" → O(N) reads + memory blowup. Declare the verb, use `Query`.
- "I'll reach for `store::find` / `FindOptions`" → that's the escape hatch. Use `db_find_by` / `Query` and a declared access pattern.
- "I'll hand-write the index name" → the derive names it (`ix_<table>_<cols>`); the `name` you declared is discarded. Reference data by **columns** via `db_find_by` / the Query DSL — never by a hardcoded index name. A literal name passed to `for_each_batch`/`open_cursor` drifts from the canonical one and the cursor returns NotFound at runtime.
- "Offset pagination is fine" → not for deep pages. `fetch_page` (keyset).
- "I'll `ranked_by` my `#[counter]` column" → compile error; a counter can't back an index. Bounded sub-range sorted in memory, or materialize into a plain column via a job.
- "I read the counter inside the tx, so the check is safe" → counter reads take no conflict range. The value may be stale, and because a concurrent increment doesn't conflict, the automatic retry never fires to re-read it. Use a `delete_where`/`update_where` predicate.
- "The read inside my `tx` only touches a few rows" → only if a filter is on a column that LEADS an index, and only over the sub-range that seek covered — an equality matching most of the table is index-served and still conflicts with nearly every writer. If nothing seeked, the whole table is in the transaction's read set.
- "I'll batch-hydrate by id inside the `tx` with `where_in`" → `_id` leads no index, so that scans. Use `get_many` (point gets by id), in a `tx` or out.
- "I'll just `fetch_all()` the table" / "no limit needed, it's small for now" → unbounded read; today's small table is tomorrow's OOM and a slow query. Keyset-paginate a list anyone scrolls; cap a one-shot read with an explicit `.limit(100..=1000)` sized to row density.

## Integration

← `boogy:boogy-data-modeling` (the `#[derive(Model)]` structs + access-
pattern verbs these queries consume). **REQUIRED BACKGROUND for any list
endpoint.** → `boogy:boogy-rest-apis` (handlers that call `db_*`/`Query`).
→ `boogy:boogy-migrations` to add an access pattern to a deployed service.
