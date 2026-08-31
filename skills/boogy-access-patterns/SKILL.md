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
(`.order(…).cursor(…).fetch_page(…)` → `CursorPage`); a one-shot
internal read carries an explicit `.limit(n)`.

**`.fetch_all()` without a `.limit()` does not compile.** The builder
tracks its row ceiling in its type, and the two row-materializing
terminals (`fetch_all`, `fetch_all_with_total`) exist only once
`.limit(n)` has stated one. You will get a compile error, not a listing
the store quietly cuts short at its own page cap. (`fetch_one`, `count`,
`fetch_page` and `fetch_one_group` bound themselves — no `.limit` needed.)

**`.group_by(col)` also requires a `.limit(n)`, and it is a DIFFERENT
bound.** `fetch_all` is bounded on ROW COUNT; `fetch_groups` is bounded on
GROUP CARDINALITY, and those are not the same quantity — a grouped query
over a million rows may return three groups. An UNGROUPED aggregate
(`.sum(..).fetch_one_group()`) is exactly one group whatever the table
holds, so it needs no ceiling at all. The moment you add `.group_by(col)`
the result gains one item per DISTINCT VALUE of `col`, which is a property
of the data and invisible in the query: `group_by(status)` may be three,
`group_by(user_id)` one per tenant user. So state the ceiling, or — when
the group count grows with the tenant — make it a listing:
`.order(agg::…().desc()).limit(n).cursor(token).fetch_group_page(|g| …)`.

Stating it bounds what YOUR component holds, not the fold that produces
it: a computed `GROUP BY` visits every matching row to know what the
groups are. That work is the platform's and it is metered; a declared
`rollup(...)` is how you stop paying for it on every read.

Size the cap to row density: **~100** when rows are fat (large text /
blobs / nested JSON), up to **~1000** when they're slim (a few scalar
columns). Past that — or for anything a client scrolls —
**keyset-paginate; don't just raise the cap.** A bigger `.limit()` still
has a ceiling; a cursor doesn't. And remember what `fetch_all` means once
it is bounded: **the first `n` rows in this order, with nothing said
about the rest.** That is right for a top-N, an `is_in` over `n` ids, or
`.limit(1)` as an existence probe. It is wrong for anything whose size
grows with the tenant — that needs `fetch_page`, which hands the caller
the token to continue.

**Never pass a client's `?limit=` straight through.** Clamp it
(`requested.unwrap_or(20).clamp(1, MAX)`). An untrusted limit is the same
unbounded read wearing a query parameter, and the type system cannot see
it.

## Verb → query mapping

The verb you put on the model (see `boogy:boogy-data-modeling`) is the
index that backs the query:

| Model declaration | Backs this read |
|-------------------|-----------------|
| `#[lookup_by]` on a field | point lookup: `db_find_by::<M>(M::COL, val)` (the unique row where `col == v`) |
| `#[model(list_by(filter = "peer", newest = "created_at"))]` | filtered newest-first list. **Default (client-facing) → paged:** `Query::on(M::TABLE).filter(M::peer.eq(v)).order(M::created_at.desc()).cursor(c).limit(n).fetch_page(…)`. A small bounded "last N" internal read may drop `.cursor(..)` and use `.limit(n).fetch_all()` — the `.limit(n)` is required either way. |
| `#[model(ranked_by(highest = "score"))]` | global ranked feed. **Default → paged:** `Query::on(M::TABLE).order(M::score.desc()).cursor(c).limit(n).fetch_page(…)`. Bounded top-N → same ordering, `.limit(n).fetch_all()`. |
| `#[model(tagged_by(tag, refs))]` | junction page: seek the tag, expose `refs` to hydrate parents |

**Default any list a client pages through to a cursor** (`.order(…).cursor(…)
.fetch_page(…)` → `CursorPage`) — see the recipe below. `.limit(n).fetch_all()`
is for a small bounded internal read; an unbounded client list has no spelling.
Offset is never the answer for deep pages.

**The ordering IS the cursor key.** There is no separate "page by this column"
verb: `.order(M::created_at.desc()).limit(n)` has already stated the sort key,
its direction and the page size, which is everything a cursor needs. Whether the
platform answers it with a keyset seek, an offset, or an epoch-pinned ranked
projection is its decision, not a semantic you opt into.

You write the handles **the derive emitted** — the typed column
(`Message::created_at`, a `Col<T>`) to build filters and orderings, and the
name const (`Message::PEER`, a `&'static str`) wherever a column is genuinely
just a name (row accessors, `agg::sum(..)`). Never bare strings, never a
hand-rolled index name.

## Point reads — `db_*`

| Need | Call | Returns |
|------|------|---------|
| one row by primary key | `db_get::<M>(id)` | `Result<Option<M>>` |
| rows where `col == v`, at most ONE PAGE | `db_find_by::<M>(M::COL, val)` | `Result<Vec<M>>` — errors past a page, see below |
| one page of rows where `col == v`, resumable | `db_find_by_page::<M>(M::COL, val, &page)` | `Result<ModelPage<M>>` — items + `next_cursor` |
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

> **`db_find_by` reads at most ONE PAGE, whatever the column.** On a
> `#[lookup_by]` column that is at most one row, which is the intended use. On
> any other column, if more rows match than one page holds you get an error
> naming the fix — never a prefix that looks like the whole set. It used to page
> internally until every matching row was in memory, which is how a listing
> exhausts a 32 MiB component heap.
>
> For a set that grows with the tenant, page it. `db_find_by_page::<M>(col, val,
> &PageRequest::new(limit, token))` returns one page plus the `next_cursor` that
> continues it; it needs the same declared order the model needs to page —
> `list_by(filter = col, newest = "<a timestamp or sequence column>")`, or an
> index over `[col, sort_col]` — and errors naming that declaration if it is
> absent. The `Query` DSL is the other route: `.fetch_one()` for a single row,
> `.limit(n).fetch_all()` for a capped read, `.fetch_page()` for a client-paged
> list.
>
> And when what you actually want is a NUMBER — "has this voter already voted",
> "what do these orders total" — do not read the rows at all. `.count()` and the
> aggregate terminals answer from the store, so the cost does not grow with the
> set. Reading rows to add them up is how an endpoint's cost comes to depend on
> how popular it has been.

This is the canonical upsert
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
        .filter(Message::peer.eq(peer))
        .order(Message::created_at.desc())
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
    .order(Conversation::last_at.desc())
    .limit(500)
    .fetch_all()?;
let items: Vec<Conversation> = rows.iter().map(Conversation::from_row).collect();
```

**Predicates are expressions on the typed column handle**, and `.filter(e)`
takes them. Repeated `.filter(..)` calls AND together; compose with
`.and(..)`/`.or(..)` for boolean structure.

| on any `Col<T>` | `eq` `ne` `gt` `gte` `lt` `lte` `between` `is_in` `asc` `desc` |
|---|---|
| on `Col<String>` only | `like` `not_like` |
| on a nullable column only | `is_null` `is_not_null` |

The comparison is type-checked against the schema: `M::room_id.eq("nope")` does
not compile when `room_id` is `Col<i64>`, and a non-nullable column has no
`is_null()` — asking would be a question with a constant answer. **An empty
`is_in` matches NOTHING**, as SQL says; reading it as "no filter" silently turns
a scoped query into an unscoped one.

**Ordering is one verb**, `.order(o)`, because `ORDER BY` is one clause. It
takes a column ordering (`M::created_at.desc()`) or an aggregate ordering
(`agg::sum(PostVote::DIRECTION).desc()`, ranking posts by a total their votes
carry) — both are `ORDER BY`.

**Terminals:**
- `.limit(n).fetch_all()` → `Result<Vec<Row>>` — the first `n` matches in this order, and nothing about the rest. **Requires the `.limit(n)`: without it the terminal does not exist and the call is a compile error.** Cap by row density (~100–1000), or keyset instead
- `.fetch_one()` → `Result<Option<Row>>` — first match (`limit` forced to 1)
- `.limit(n).fetch_all_with_total()` → `Result<(Vec<Row>, u64)>` — the same bounded page plus the total IGNORING it, so `rows.len() < total` is how you detect a prefix. Also requires the `.limit(n)`
- `.count()` → `Result<u64>` — count only; sort and page are ignored (they cannot change a count) and an OR predicate is **refused** rather than silently dropped
- `.fetch_page(|row| …)` → `CursorPage<T>` — cursor pagination (below)

## The canonical paginated-list recipe

Cursor, not offset. `fetch_page` resumes from the position in the token, asks
the store for exactly the page, and returns `CursorPage<T>` — no manual cursor
arithmetic.

`next_cursor` is present exactly while more rows follow, and that comes from the
store, not from counting rows. **Never decide a listing has ended from the size
of a page.** The platform clamps `limit` to its own per-call ceiling, so a page
can come back shorter than you asked for while rows remain, and a page can come
back full at the end. Both are answered for you: keep going while `next_cursor`
is present, stop when it is absent.

**Keyset endpoints take a single opaque `?cursor=`** (the encoded
boundary returned as the previous page's `next_cursor`) — there is **no**
`before`/`after`/`offset` param; do not design one.

**`.order(col.dir())` must be covered by an index that ALSO covers your
filter — and if it is not, nothing tells you.** This is the single most
expensive mistake you can make on a list endpoint, because every symptom of
it is silent:

- The read does **not** error. It returns the correct rows, in the correct
  order, with a working cursor.
- It is still index-backed, so no scan warning or scan counter fires.
- It only hurts at volume, so it passes every small-data test you write.

What actually happens: the filter is served by the index, the ORDER is not,
so the store reads **every row matching your filter** and sorts them to hand
back one page. Your `limit` bounds the response, not the work. Cost becomes
O(rows the caller owns) instead of O(page) — measured at roughly 30
microseconds per owned row, so a caller with a few thousand rows pays tens of
milliseconds per request on an idle host, and seconds once the service is
busy. The same endpoint costs ~1ms with a covering index, and stays flat as
rows accumulate.

The rule: **one index must cover the filter and the sort together, filter
first.** Declare it on the model — `list_by(filter = "<filter col>", newest
= "<sort col>")`, or an explicit `covering_index(cols = ["<filter col>",
"<sort col>"])` — and `.order(..)` by that same sort column and direction.

**Never page by `_id`.** The auto-primary-key is not a column and can
never join a composite, so a filter plus `.order(_id …)` cannot
be fixed by adding an index — it is O(rows matching the filter) forever. If
you want insertion order, add a real `created_at: Timestamp` column, declare
`list_by(filter = "<filter col>", oldest = "created_at")`, and order by
that. (Ordering by `_id` with **no** filter is fine — that is the natural
key order.)

```rust
// Page a ranked feed. `.cursor(..)` takes the opaque token the client
// round-trips, straight from the query string — there is no `decode` at the
// call site, and no second verb naming the keyset column: the ordering IS the
// cursor key.
let page = Query::on(Post::TABLE)
    .order(Post::score_total.desc())
    .limit(20)
    .cursor(req.query("cursor").map(str::to_string))
    .fetch_page(|row| PostView::from_row(row))?;   // map Row -> your DTO
// page: CursorPage<PostView> — { items, next_cursor? }
```

A token the platform cannot read is **kept, not discarded** — it answers `410`
rather than silently restarting the listing while the caller believes it is
continuing one.

**Ascending keyset can MISS a concurrently-inserted row — permanently, for
that walk.** `_id` is handed out before the inserting transaction commits, so
two concurrent inserts can take `_id` 100 and 101 and commit in the opposite
order. A cursor walking ASCENDING that already passed 101 will never return
100: it is not delayed, it is gone for that walk. A later, fresh walk sees it.

Descending keyset (`SortDir::Desc`, newest-first) does not have this problem —
it moves away from the region where new rows land, which is why every feed
example here is `Desc`.

So: **use `Desc` for client-facing feeds.** If you genuinely need ascending
order — a chronological export, a catch-up sweep — do not treat one pass as
complete. Either re-run from the last processed boundary until a pass yields
nothing new, or drive the pass from a column you control (a `created_at` you
stamp, with a lag window) rather than from `_id`.

**Offset vs keyset:** offset shifts under concurrent inserts and
`OFFSET 10000` scans 10001 rows — a deep-page cliff. Keyset is a
constant-cost indexed lookup **when a single index covers the filter and the
sort together** (see above); without that it quietly costs O(rows matching
the filter) per page. Always keyset for client-facing lists — and always
declare the covering index alongside it.

## When raw `store::find` is the escape hatch

The DSL covers the common shapes. Drop *below* it only for what it can't
express:

- **OR-groups the `.or()` builder can't represent** — a keyset OR that
  must merge with caller-supplied domain filters. That form is emitted
  PLUMBING (`__boogy_find_rows_grouped`), not authoring surface; the
  Query DSL's `fetch_page` builds the ordinary keyset shape for you.
  An OR is seeked only when **every** arm carries an equality on a
  column that leads an index; the `< c OR (= c AND < cursor)` keyset
  shape has a bare range in its first arm, so it never qualifies. What
  keeps this read narrow is therefore the AND-prefix: give it a filter
  on a leading index column. See *Inside a `tx`* below.
- **Junction hydration** — page the side table with `fetch_page`, then
  batch-hydrate parents in one read with `.filter(M::refs.is_in(ids))` /
  `get_many`. The DSL has no JOIN primitive; this two-step is the pattern.
  `is_in` seeks when its column **leads an index** — but `_id` leads
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
  Query DSL — `.filter(..).order(..).fetch_page(..)` — which lets
  the planner pick the index **by the query's columns**, so there's no
  name to drift.

`Cursor`, `decode`/`encode`, `CursorPage::from_overfetched`, and
`keyset_resume_filter` live in `boogy_sdk::pagination` when you need them
raw. Don't re-derive the overfetch logic — use the helper.

## Counter columns — never merged unless asked, sortable nowhere

A counter column (see `boogy:boogy-data-modeling`; declared
`#[model(counter(name = "..."))]` on the struct, no backing field) is stored
in its own cell, not inside the row. **Nothing merges it back for you.** A
point read (`db_get`, `db_find_by`), a plain list page, an index walk, and
`count` all return the row with the counter cell unmerged — a caller opts in
explicitly, per call, or the value never arrives:

| To get the value | Ask for it with |
|---|---|
| A row listing (`Query`) | `.with_counter(name, key_cols)` — `key_cols` is `&[]` for a counter attached to a model's row |
| A streaming batch (`for_each_batch`) | its `counters: &[&str]` parameter |
| Ranking BY the counter's own cells | `.order(T::the_counter.desc())` — sorting by it already implies reading it, so this merges without a separate `.with_counter(..)` |

Naming (or sorting by) one counter opts in every LIVE counter column the
table declares — per-table granularity, not per-column. `db_get` /
`db_find_by` / `get_many` have **no opt-in at all**: there is no wire path to
ask them for a counter, so a counter column read through one of those is
always `Val::Null` (`.as_int()` silently reports it as `0`) — go through
`Query`/`for_each_batch` whenever the counter's value matters.

What else changes is what you may **declare**. A counter cannot back an
index, so naming it in an access-pattern verb is a **compile error**:

```rust ignore-snippet: shows code the derive is meant to REJECT — compiling it would assert the opposite of what it teaches
// COMPILE ERROR — ranked_by is backed by an index, a counter can't back one.
#[model(table = "posts", ranked_by(highest = "vote_score"), counter(name = "vote_score"))]
pub struct Post {
    #[pk] pub id: Id<Post>,
}
```

So there is no `.order(Post::vote_score.desc())` page and no "top N by score"
index read **off a counter column**.

### Rank by the AGGREGATE instead — this is usually the answer

If the score is a total over child rows (votes, line items, reactions), do not
denormalise it at all. Order by the aggregate directly:

```rust ignore-snippet: a query fragment — the models, the relation and the handler's error type are not in scope in this block
// A room's topics, best first. The query names the PARENT table, orders by a
// total its CHILDREN carry, and gets parent rows back.
let rows = Query::on(Topic::TABLE)
    .filter(Topic::room_id.eq(room_id))
    .order(agg::sum(TopicVote::DIRECTION).desc())
    .limit(limit)
    .fetch_all()?;
```

Nothing there says "join", "rollup" or "projection" — the relation is declared
once on the model, and `.order(...)` is the same verb a column sort uses.
`agg::sum(col)`, `agg::count_all()` and friends have `.asc()` / `.desc()`
**inherently**, so an aggregate ordering needs no import that a column ordering
does not.

### The fallbacks, for when the score is not an aggregate

| Approach | When |
|---|---|
| Scope to a **bounded sub-range** (a declared verb that *is* indexed — e.g. newest 500 in a room) and sort those in memory | the ranking is over a slice you can bound |
| **Materialize** the counter into a separate plain column refreshed by a background job, and index *that* | the score is a bare counter with no child rows behind it |

The second is a deliberate staleness-for-scalability trade: the ranked column
lags the live counter by the job interval. Say so in the endpoint's docs — and
reach for it only after ruling out the aggregate ordering above, which has no
staleness at all.

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
    // `db_get` has no counter opt-in at all — reading `vote_score` goes
    // through `Query`, the same as any other counter read.
    let row = Query::on(Post::TABLE)
        .filter(Post::slug.eq(post.slug.clone()))
        .with_counter(FxPostVoteScore::NAME, &[])
        .fetch_one()?
        .ok_or_else(ApiError::not_found)?;
    if row.int("vote_score") < -10 { db_delete::<Post>(row.id())?; }   // 🚩 stale
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

A query with no usable index that scans past the row threshold is **warned
and metered, never refused** — the log carries a hint naming the fix
(*declare an access pattern so the index is derived*), and
`keys_examined` records what the read actually looked at, so the scan is
priced rather than free. There is no per-query opt-out to reach for and
no strict mode.

What actually stops a runaway scan is the platform, in two places you do
not configure: an unindexed read on a **declared column** fails the
service-conventions gate at build time, and a read that outruns
`[limits] cpu_deadline_ms` is cut off with a 504 — which also cancels the
scan, not just the caller. Deliberately scanning a small table is fine;
it costs what it costs.

### Inside a `tx`, an unindexed read costs correctness, not just ops

The planner is the same one; what changes is the price of an unindexed
read. The guardrail applies inside a `tx(|| …)` closure too, at **half
the row threshold** — because the same scan costs more here — and its
warning names the table, the conflict range the read just took, and
either the index that would serve the query or, when you already have
one, what would have bounded it (and when the query constrains no column
at all, that there is nothing to index). It does not refuse the read and
does not poison the transaction. The cost it is warning you about is
real and is not about ops: the scan
puts **every row of the table into the transaction's read set**, so any
concurrent write to that table aborts your commit, even to a row your
filter never matched. An index-served read conflicts only on the
sub-range it seeked plus the rows it fetched. Consequences for reads a
`tx` closure performs:

- **Give it a filter on a column that LEADS an index.** Equality,
  `is_in`, `is_null` and a range all seek — including on the first
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
- "I'll `ranked_by` my counter column" → compile error; a counter can't back an index. If the score totals CHILD rows, order by the aggregate (order by `agg::sum(...)` over the child column) — no denormalisation and no staleness. Only if it is a bare counter: bounded sub-range sorted in memory, or materialize into a plain column via a job.
- "I read the counter inside the tx, so the check is safe" → counter reads take no conflict range. The value may be stale, and because a concurrent increment doesn't conflict, the automatic retry never fires to re-read it. Use a `delete_where`/`update_where` predicate.
- "The read inside my `tx` only touches a few rows" → only if a filter is on a column that LEADS an index, and only over the sub-range that seek covered — an equality matching most of the table is index-served and still conflicts with nearly every writer. If nothing seeked, the whole table is in the transaction's read set.
- "I'll batch-hydrate by id inside the `tx` with `is_in`" → `_id` leads no index, so that scans. Use `get_many` (point gets by id), in a `tx` or out.
- "I'll just `fetch_all()` the table" / "no limit needed, it's small for now" → it will not compile: `fetch_all` has no unbounded form. Today's small table is tomorrow's OOM. Keyset-paginate a list anyone scrolls; cap a one-shot read with an explicit `.limit(100..=1000)` sized to row density.
- "I'll take the limit from the query string" → clamp it. An untrusted `?limit=` satisfies the type system and reopens the unbounded read.

## Integration

← `boogy:boogy-data-modeling` (the `#[derive(Model)]` structs + access-
pattern verbs these queries consume). **REQUIRED BACKGROUND for any list
endpoint.** → `boogy:boogy-rest-apis` (handlers that call `db_*`/`Query`).
→ `boogy:boogy-migrations` to add an access pattern to a deployed service.

## Red Flags

| Thought | Reality |
|---|---|
| "It's a small table, a scan is fine" | Tables grow. A full scan accumulates **every scanned row into host memory before filters apply** — the row cap is the only thing between one unindexed query and the host's RSS. Size the access pattern, not today's row count. |
| "The scan guardrail will protect me" | The guardrail warns; it is not the bound. What actually stops a large scan is the per-request wall-clock budget, which returns 504 — a *duration* bound, and duration is contention-dependent. Do not design against it. |
| "The query returned three rows, so it was cheap" | Rows returned is not work done. A filtered scan can examine tens of thousands of keys to return three; the keys-examined figure is the one that reflects cost. |
| "I'll add the index later when it's slow" | An unindexed keyset query is a **build failure**, not a runtime warning. Later is not a state this platform offers. |
| "I'll sort in the handler after fetching" | Fetching to sort is the scan you were avoiding. Declare the access pattern so the ordering is served from a covering composite. |
| "I'll paginate with an offset" | Deep offsets re-walk everything skipped. Keyset pagination costs the same on page 500 as page 1; the page request's limit is clamped precisely so an unbounded listing has no representation. |
