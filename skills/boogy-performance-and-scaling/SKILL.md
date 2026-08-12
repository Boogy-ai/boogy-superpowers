---
name: boogy-performance-and-scaling
description: Use when a Boogy service is throttled or slow under load — 429s, 503s, 504s, Retry-After, or "make this endpoint faster"
---

# Performance and scaling on Boogy

Each throttle code means a different problem, and one code — 503 — has two
quite different causes. Diagnose before you change anything; most "fix the
load" requests pick the wrong lever.

## Triage table — the throttle codes

| Code | Layer | Meaning | Server lever | Client behavior |
|------|-------|---------|--------------|-----------------|
| **429** | rate limiter (per service) | "you're sending too fast" — over your refill rate | raise `[ingress.rate_limit] burst` for spiky-but-acceptable traffic, or `rpm` for sustained | slow down; honor `Retry-After` if present |
| **503 + Retry-After** | scheduler admission (host) | "host is contended; your share is full" — concurrency, not rate | reduce per-request work (fewer ops, shorter handlers); raise host capacity (operator-controlled) | back off and retry per `Retry-After`; never retry immediately |
| **503** (`too_contended`) | store transaction | "**these rows** are contended" — a transaction exhausted its automatic retry budget | **the data model**, not capacity: split the key, make the column a `#[counter]`, and **narrow every search the closure runs** — an in-tx read the planner can't serve takes the whole table as its read set. Give each one a filter on a column that **leads** an index; the same rule narrows an `update_where`/`delete_where` predicate. More host capacity does nothing here | back off and retry; the retry hint is in the problem+json `detail` |
| **504** | request budget | "this request exceeded its wall-clock budget" | raise `[limits] cpu_deadline_ms` ONLY if the work is genuinely long and CPU-light; otherwise it's a 503 problem | retry the whole request (idempotently) |

**Enforcement order:** rate limiter (429) → scheduler admission (503) →
instantiate → run under the `cpu_deadline_ms` budget (504 backstop). A
request rejected early never reaches the later stages. The store's 503 is
different in kind — it comes from *inside* a handler that ran, so it tells
you about your schema rather than about the fleet.

**A 409 is never a throttle code.** Commit conflicts are retried
automatically inside `tx`, so a 409 always means the write genuinely
conflicts — a duplicate on a unique index, a required column left null or
absent, a transaction poisoned by a failed participant. Retrying it is
wasted work. See `boogy:boogy-transactions`.

## Four rules that catch the common mistakes

1. **A 504 under load is usually a 503 problem.** If requests are slow
   because the host is saturated (queue time), raising `cpu_deadline_ms`
   does NOT help — the request was waiting, not computing. Reduce
   contention instead.
2. **Raising `cpu_deadline_ms` while saturated makes 503s worse.** A
   bigger budget = each request holds its slot longer = more
   contention = more 503s. Only raise it for genuinely long,
   CPU-light work, and prefer a background job (cross-ref
   `boogy:boogy-background-jobs`) over a long synchronous request.
3. **`burst` is the lever for spiky traffic.** `rpm` is the steady
   refill rate; `burst` is how much instantaneous spike you tolerate
   before 429. Bursty-but-bounded traffic → raise `burst`, not `rpm`.
4. **Retry-After is a contract.** On 503 (and 429 when present), wait
   the hint and retry with backoff. Hammering retries deepens the
   contention you're being shed for.

## Op-budget levers (the developer's axis)

Host capacity is operator-controlled. What *you* control is how much
work each request does — and shorter requests hold their slot less,
which directly reduces 503s. Cut the per-request op budget:

- **Declare access patterns** so every query is index-served, not
  table-scanned. An unindexed list/filter walks the whole table — many
  ops, long slot hold. **Inside a `tx` it costs more than ops:** the scan
  takes the whole table as the transaction's read set, so every
  concurrent write to that table conflicts with you — retries first, then
  a `too_contended` 503. Narrowing the reads that closure runs is the fix
  for that 503, not more capacity. **Give each one a filter on a column
  that LEADS an index** — equality, `where_in`, `where_null` and ranges
  all seek there — and the same rule narrows an
  `update_where`/`delete_where` predicate, which otherwise scans. No
  index rescues these: a
  bare `count()` with no filter, which reads the whole key range; and an
  ordered read with no such filter, which takes the whole table unless it
  also skips the total.
  And an index-served read is still only as narrow as its seek: an
  equality matching most of the table conflicts with nearly every writer.
  `boogy:boogy-transactions` has the detail. See also
  `boogy:boogy-access-patterns`.
- **Keyset pagination, not offset.** Offset re-scans every skipped row
  on each page; keyset (cursor) resumes after the last row. Big lists
  on offset are a silent op-budget sink. See `boogy:boogy-access-patterns`.
- **Batch point-reads instead of N separate round-trips.** `filter_in`
  is the tool when its column **leads an index** — then it fans out into
  one bounded seek per value, in a `tx` or out. Batching **by id** is
  `get_many` instead: `_id` leads no index, so a `filter_in` over ids
  scans, which inside a `tx` is the whole table as your read set.
- **Don't route large payloads through the service** — request/response
  bodies ride the per-request memory cap and the transaction envelope.
  Recap of the ceilings (memory, tx envelope, outbound caps) is in
  `boogy:boogy-capability-limits`.

## Throughput vs latency

If a single service genuinely needs more concurrency than its fair
share allows, that is a *capacity* decision (operator) — not something
a manifest knob raises. For genuinely extreme write rates, bring your
own database via `outbound_http` (see `boogy:boogy-capability-limits`).
A commit conflict is **retried for you** inside `tx`, so contention shows up
as latency first, not as an error. When the attempt budget is exhausted
against a genuinely hot row — or against a table an unindexed in-tx search
took as its read set — you get a **503** with a retry hint. Back off, then
fix the data model (split the key, make the column a `#[counter]`, or narrow
the read — filter on a column that leads an index, and prefer a selective
one), because more capacity divides neither one row every request
writes nor a read that conflicts with every writer. A
**409** never means "busy": it means the write genuinely conflicts — a
duplicate on a unique index, a required column left null or absent, a
transaction poisoned by a failed participant. See
`boogy:boogy-transactions`.

## Red flags

| Thought | Reality |
|---------|---------|
| "Just raise all the limits until the errors stop." | Each code has a different cause. Raising `cpu_deadline_ms` to fix 503s/504s-under-load makes contention *worse*. Diagnose the code first. |
| "Retry the 503 immediately." | 503 means the host is shedding you, or a row is contended past its retry budget. Immediate retries deepen both. Back off. |
| "The 503s are load — raise capacity." | Check which 503. A `too_contended` one is a *schema* problem: one row every request writes, or an unindexed search inside a `tx` whose read set is the whole table. Capacity divides neither. |
| "The endpoint is slow, raise the timeout." | Slow-under-load is usually queue time (503 territory) or too many ops per request — not a budget that's too small. Reduce work per request first. |
| "Add a cache before reducing ops." | First make the query index-served and keyset-paginated; a scanning query behind a cache is still a scanning query on every miss. |
| "`too_contended` means one hot row — my transaction only *reads* that table." | Reads conflict too, and it is your transaction's own **write** that gets aborted for it (a genuinely read-only tx commits regardless). A search with no filter on a column that **leads** an index scans inside the closure, putting every row of that table in the read set, so any concurrent write to it aborts you. Index the filtered column so it leads — that applies to an `update_where`/`delete_where` predicate too — and check `boogy:boogy-transactions` for the cases no index rescues: an unfiltered `count()`, and an ordered read that asks for a total it doesn't use. |
