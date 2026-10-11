---
name: boogy-transaction-conflicts
description: Use when a Boogy transaction conflicts or retries, answers 409 or 503 (TooContended, ResourceExhausted, Poisoned, CommitUnknown), reads, counts or sweeps rows (update_where, delete_where) inside a tx, is refused for scanning too many rows, or slows down under concurrent writers
---

# Transaction conflicts: read sets, retries, 409 and 503

Part of `boogy:boogy-transactions`, which holds when to open a transaction and what goes in it: read it first.

## Reads inside the tx — the whole table is your read set unless the planner can narrow it

A transaction conflicts on what it **read**, not only on what it wrote.
Reads inside the closure go through the same planner as reads outside
it. *Which* read you wrote decides how much of the table you conflict
with:

- **The planner can serve the query from an index** → the transaction
  conflicts only on the index sub-range(s) it seeked plus the rows it
  actually fetched. A concurrent write outside those bounds is invisible
  to you.
- **No usable index** → the read scans, and **every row of that table
  joins your read set**. Any concurrent write anywhere in that table
  aborts your commit — including rows your filter never matched. Past a
  row threshold (half the one that guards a scan outside a transaction,
  because this scan costs more) the read is **refused** in dev/CI with an
  error naming the table, the conflict range the read took, and the fix
  it can honestly name — the index that would serve the query, or, when
  an index already leads a column you constrained, what would have
  *bounded* the walk instead, or, when the query constrains no column at
  all, that there is nothing to index. So you meet this while writing the
  handler rather than as intermittent 409s later. It is a WARNING, not a
  refusal: the read is served and the transaction is not poisoned. Act on
  it anyway — index the read, bound it, or hoist it out of the closure —
  because the conflict range it describes is what turns into intermittent
  409s under concurrency.

So on a table anyone else writes, **narrowing the reads a transaction
performs is a contention fix, not a speed optimization**. It is also
why a counter column alone may not quiet a hot path: the counter removes the
*write* conflict, and an unindexed search in the same closure puts a
whole-table one straight back.

**The rule: give the read a filter on a column that LEADS an index.**
Equality, `is_in`, `is_null` and a range (`gt` / `gte` / `lt` / `lte`)
all seek — each becomes one bounded index sub-range, or a fan-out of
them, and the fan-out is the read set. It is enough that **one** of the
AND-filters does this; if none does, an `.or()` still seeks when *every*
arm carries an equality on a leading index column. A filter on a column
that appears only *later* in a composite index does not seek — it is
applied per row afterwards, so it narrows the result but not the
conflict range. This is the same rule that decides whether a read is
index-served outside a `tx`; what changes inside one is the price of
missing it.

**One thing is stricter inside a `tx`.** A read whose *only* narrowing
is its SORT — ordered, with no filter on any leading index column —
takes the whole table unless it also skips the total. `.fetch_page(…)`,
`.fetch_one()` and a `.limit()`ed `.fetch_all()` ask for no total; that,
plus the page bound, is what lets such a read stop at the page and ride
the sort index. `.fetch_all_with_total()` and a *filtered* `.count()`
want an exact number, so they drain. Inside a tx, don't ask for a total
you won't use.

**Predicate writes follow the same rule.** `update_where` /
`delete_where` inside a `tx` seek the same index sub-range a read does:
give the predicate a filter on a column that **leads** an index and only
that sub-range is in the read set, so a concurrent write elsewhere in
the table no longer aborts you. The guarantee is unchanged — a
concurrent insert or update that *would* have matched the predicate
still conflicts, because its index entry lands inside the sub-range the
sweep walked. With no such filter they still scan, and an *unfiltered*
sweep ("update every row") reads the whole table because that is what it
is asking about.

**These reads take the whole table however you index it:**

- a bare `.count()` with no filter — it reads no rows (it counts row
  keys), but it does read the whole key range, so it conflicts with
  **any** concurrent write to that table: an insert, a delete, and an
  update too, since updating a row rewrites its key.

**`_id` leads no index**, by construction — so `is_in` over a list of
ids scans, and there is no index to add. Hydrate by id with `get_many`:
point gets, which conflict only on the rows they return.

**Index-served is not the same as narrow.** The read set is the
sub-range the seek covered, so an equality matching most of the table (a
status column where nearly every row has the same status) is
index-served and still conflicts with nearly every writer. Seek on the
*selective* column.

**There is a ceiling.** A search inside a transaction that has to work
through more than ~50,000 rows — matches on an index walk, rows touched
on a scan — is refused with an error pointing you at the
cursor/pagination API, rather than silently burning the ~5 s / 10 MB
envelope. Read a page, not a table.

## Conflicts are retried for you — and what 409 means now

**A commit conflict never reaches your client.** When the store aborts a
commit because another transaction's writes overlapped this one's
read/write set, `tx` **re-runs the closure and commits again**. Nothing
from an aborted attempt landed, so re-running is safe. The attempt budget
is set by the platform (3 total by default — the original attempt plus two
retries). There is no delay between attempts: the conflict resolved
because some other writer *won and committed*, so the next read sees a
settled value.

**So the closure must be re-runnable — this is what `Fn` means here.**
`tx` takes an `Fn`, not an `FnOnce`, precisely because it may run more than
once. Everything *before* the closure — parsing, auth, guards, expensive
computation — runs exactly once; everything *inside* it runs once per
attempt. That is why *Sequencing discipline* (`boogy:boogy-transactions`) says to compute before
opening the tx: under retry that guidance stops being about envelope
hygiene and becomes about correctness and cost. Two consequences:

- **No side effects in the closure.** Nothing that changes state outside
  the store — no counter you bump on a captured variable, no "we already
  charged them" flag. Attempt 2 would start from attempt 1's leftovers
  even though the store discarded attempt 1's writes, so your code and the
  database would disagree. (`outbound_http` and `signing` writes are denied
  inside a tx and a job enqueue is staged, so the platform already blocks the
  worst versions.)
- **A closure that must consume a value clones it inside**, or computes
  the value before the tx and borrows it.

**Retries exhausted is 503, not 409.** When what a transaction touched
stays contended for the whole attempt budget — the rows it writes, or the
rows its reads put in the read set — you get `TooContended` → **HTTP 503
with a retry
hint**. That is congestion, and it belongs with the platform's other
congestion codes (429 = you are too fast; 503 = the host is contended; 504
= the request took too long). Persistent `TooContended` is a signal about
the *data model* — a single row every request writes, **or** a search
inside the closure the planner could not serve from an index, which
conflict-ranged the whole table (see *Reads inside the tx* above). Split
the key, declare it a counter column (`#[model(counter(name = "..."))]`), or narrow the read — filter on a
column that leads an index, and prefer a selective one.

**409 now means "your write genuinely conflicts"** — something the caller
must resolve — and never "the store was busy". Several outcomes still share
it, and none of them is retryable. Match the `StoreError` **variant**,
never the status and never the message text.

| Outcome | `StoreError` variant | Status | Client does |
|---------|----------------------|--------|-------------|
| Commit conflict (serialization abort) | `Conflict` | — | **Nothing — `tx` already retried it.** It surfaces (as 409) only if the platform has auto-retry switched off |
| Retry attempts exhausted — a contended row it writes, or a read whose conflict range was the whole table | `TooContended` | **503** | Retry with backoff — and fix the data model if it persists (split the key, a counter column, or narrow the read — filter on a column that leads an index) |
| Platform saturated with concurrent transactions | `ResourceExhausted` | 503 | Retry shortly |
| Unique-index duplicate, a **not-null column left null or absent** on a row-creating write, or "already exists" | `ConstraintViolation` | **409** | **Do not retry** — deterministic, it fails identically every time. Change the input |
| A participant service in the transaction failed | `Poisoned` | **409** | **Deliberately not retried** — re-running would re-execute the participant that already failed, once per attempt, and across a call tree once per callee per attempt. Fix the participant |
| Commit outcome genuinely unknown | `CommitUnknown` | 409 | **Do not blindly retry** — it may have landed. Read the state back first |
| Domain error you raised in-closure | — | 409 / 422 / 404 | Fix input. An `Err` from the closure is never retried — it is deterministic, so it rolls back and propagates unchanged |
| Success | — | 2xx | Done |

`Conflict` means exactly one thing — a serialization abort — which is why
it is the only arm the retry loop touches. That is also why a duplicate-key
insert is `ConstraintViolation` and not `Conflict`: keyed on the old
overloaded meaning, the loop would have retried a duplicate insert to
exhaustion.

```rust
// Re-roll a slug ONLY on a unique rejection — that is deterministic, so
// nothing retries it for you and a different slug is the actual fix.
// A serialization abort does not appear here: `tx` retried it.
fn insert_with_free_slug(mut link: Link) -> Result<u64, ApiError> {
    for _ in 0..5 {                     // bound it; a re-roll loop must terminate
        match db_insert(&link) {
            Ok(id) => return Ok(id),
            Err(StoreError::ConstraintViolation(_)) => {
                link.slug = fresh_slug();               // taken; try another
                continue;
            }
            Err(e) => return Err(e.into()),
        }
    }
    Err(ApiError::conflict("could not allocate a free slug"))
}
```

**Never write a `_ =>` catch-all over these arms.** It silently folds
`Poisoned` and `CommitUnknown` into whatever the fallback does — which is
the exact failure the separate variants exist to prevent.

## Smells

| Smell in the code | Fix |
|-------------------|-----|
| A filtered `Query` / `.count()` **inside** a `tx` where no filter is on a column that **leads** an index | Declare the access pattern so it's index-served — otherwise the read takes the whole table as its read set and every concurrent writer conflicts with you. The same declaration narrows an `update_where`/`delete_where` in that closure; without one, a predicate write scans too. |
| `.fetch_all_with_total()` inside a `tx` where nothing reads the total | Use `.limit(n).fetch_all()` / `.fetch_page()` — the exact total forces a drain, and an unnarrowed one forces a scan. (Both `fetch_all` forms require the `.limit(n)`; without one they do not compile.) |

## Red flags

| Thought | Reality |
|---|---|
| "Nobody writes the rows my tx reads, so the read can't conflict" | Only if the read was index-served, and only over the sub-range it seeked. If it scanned, the whole table is in your read set and *any* concurrent write to it aborts you, matching row or not. |
| "I added an index on that column, so the in-tx read is fine" | Only if the filtered column **leads** that index — its own, or the first column of a composite. A column appearing only *later* in a composite is a per-row filter, not a seek, so it narrows the result and not the conflict range. The same is true of an `update_where`/`delete_where` predicate. |
| "I'll write my own retry loop around `tx` for conflicts" | Already done, one layer down, where re-running costs only the closure. Yours re-runs the whole handler — parsing, auth, guards, the expensive work you carefully moved *out* of the tx. |
| "The 503 means the platform is broken" | It means the rows this transaction touched are contended past the retry budget (`TooContended`) — a hot row it writes, **or** a whole table an unindexed read put in its read set — or the platform is at its transaction cap (`ResourceExhausted`). Back off — then fix the data model, which is what a persistent `TooContended` is telling you. |
| "Retrying inside the closure is cheaper than failing the request" | The closure is re-run by the retry loop. A retry inside a retry multiplies your own demand against the transaction-admission budget and turns contention into 503s. |

## Integration

↑ `boogy:boogy-transactions`. → `boogy:boogy-data-modeling` for the access patterns that make a read index-served. → `boogy:boogy-counters` for a hot row. → `boogy:boogy-performance-and-scaling` for 429/503/504 in general.
