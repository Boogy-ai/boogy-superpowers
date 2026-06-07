---
name: boogy-performance-and-scaling
description: Use when a Boogy service is throttled or slow under load — 429s, 503s, 504s, Retry-After, or "make this endpoint faster"
---

# Performance and scaling on Boogy

Three different status codes mean three different problems. Diagnose the
code before you change anything — most "fix the load" requests pick the
wrong lever.

## Triage table — the three throttle codes

| Code | Layer | Meaning | Server lever | Client behavior |
|------|-------|---------|--------------|-----------------|
| **429** | rate limiter (per service) | "you're sending too fast" — over your refill rate | raise `[ingress.rate_limit] burst` for spiky-but-acceptable traffic, or `rpm` for sustained | slow down; honor `Retry-After` if present |
| **503 + Retry-After** | scheduler admission (host) | "host is contended; your share is full" — concurrency, not rate | reduce per-request work (fewer ops, shorter handlers); raise host capacity (operator-controlled) | back off and retry per `Retry-After`; never retry immediately |
| **504** | request budget | "this request exceeded its wall-clock budget" | raise `[limits] cpu_deadline_ms` ONLY if the work is genuinely long and CPU-light; otherwise it's a 503 problem | retry the whole request (idempotently) |

**Enforcement order:** rate limiter (429) → scheduler admission (503) →
instantiate → run under the `cpu_deadline_ms` budget (504 backstop). A
request rejected early never reaches the later stages.

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
  ops, long slot hold. See `boogy:boogy-access-patterns`.
- **Keyset pagination, not offset.** Offset re-scans every skipped row
  on each page; keyset (cursor) resumes after the last row. Big lists
  on offset are a silent op-budget sink. See `boogy:boogy-access-patterns`.
- **Batch point-reads with `filter_in`** instead of N separate
  round-trips.
- **Don't route large payloads through the service** — request/response
  bodies ride the per-request memory cap and the transaction envelope.
  Recap of the ceilings (memory, tx envelope, outbound caps) is in
  `boogy:boogy-capability-limits`.

## Throughput vs latency

If a single service genuinely needs more concurrency than its fair
share allows, that is a *capacity* decision (operator) — not something
a manifest knob raises. For genuinely extreme write rates, bring your
own database via `outbound_http` (see `boogy:boogy-capability-limits`).
On a commit conflict you get a **409**: retry the whole request
idempotently — there is no auto-retry (see `boogy:boogy-transactions`).

## Red flags

| Thought | Reality |
|---------|---------|
| "Just raise all the limits until the errors stop." | Each code has a different cause. Raising `cpu_deadline_ms` to fix 503s/504s-under-load makes contention *worse*. Diagnose the code first. |
| "Retry the 503 immediately." | 503 means the host is shedding you. Immediate retries deepen contention. Honor `Retry-After` with backoff. |
| "The endpoint is slow, raise the timeout." | Slow-under-load is usually queue time (503 territory) or too many ops per request — not a budget that's too small. Reduce work per request first. |
| "Add a cache before reducing ops." | First make the query index-served and keyset-paginated; an unindexed scan behind a cache is still an unindexed scan on every miss. |
