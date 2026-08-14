---
name: boogy-background-jobs
description: Use when work should run outside the request — scheduled tasks, deferred or retried work, fan-out sweeps — or when asking whether a job runs exactly once
---

# Boogy Background Jobs

Jobs run a declared handler outside the request lifecycle: on a
schedule, after a delay, or enqueued from a handler. A job is
self-targeted — the platform pins it to the calling service's identity
and replays it, so `auth::current_principal()` works in the handler
exactly as in a request.

## Wiring (the world is not optional)

A service that *processes* jobs targets the jobs world and exports the
handler entry point:

```rust ignore-snippet: a second wit_glue! invocation; the gate crate already invokes it once, and the macro's trait impls are crate-level, so any harness holding both is a duplicate-impl error by construction
// wit_bindgen::generate!({ world: "service-with-jobs", ... });
wit_glue!(bindings, Api, with_jobs);   // 3-arg form adds the job export
```

Implement `build_job_router()` on your `Api`:

```rust
use boogy_sdk::{job, JobRouter};

#[derive(serde::Deserialize)]
struct Spec { /* ... */ }

#[job("send_nightly_digest")]              // exact match
fn send_nightly_digest() -> Result<(), String> { /* ... */ Ok(()) }

#[job(prefix = "export_")]                  // suffix passed to the fn
fn export(suffix: &str, payload: Spec) -> Result<(), String> { /* ... */ Ok(()) }

fn build_job_router() -> JobRouter {
    JobRouter::new()
        .exact(send_nightly_digest)
        .prefix(export)
}
```

`#[job]` accepts `fn() -> Result<R, E>`, `fn(payload: T)` (T:
`DeserializeOwned`), `fn(payload: Vec<u8>)`, the prefix forms with a leading
`suffix: &str`, and an optional leading `ctx: JobContext` (carries
`job_id` / `handler` / `attempts`). `E` is `String` (retryable) or
`boogy_sdk::JobError` (explicit `Retry`/`Terminal`). **`service-with-jobs` without a working job
export fails to compile** — start from a stub if needed.

## Declaring handlers (manifest)

Every handler the worker may call is declared, whether scheduled or
enqueued:

```toml
[capabilities]
background_jobs = true       # needed to ENQUEUE; processing-only services may omit it

[background_jobs.handlers.send_nightly_digest]
schedule = "0 0 2 * * *"     # 6-field cron: sec min hour day month dow → 02:00 UTC
# deadline_ms = 30000              # max wall-clock per invocation
# max_attempts = 3                 # retry limit (>= 1)
# backoff_ms = 1000                # delay between retries
# max_concurrent_per_tenant = null # per-tenant in-flight cap (null = unlimited)
# pin_version = false              # opt-in: run jobs on the version that enqueued them
```

A handler with a `schedule` fires on that cadence automatically — do NOT
build your own cron loop or background timer. A service has no async runtime
and no threads: a handler runs, returns, and the instance goes away.

## Which version runs a job

By default a job runs on **whatever version of your service is active when
the worker picks it up** — not the version that enqueued it. Jobs benefit
from bug fixes deployed after they were queued, and recurring work always
tracks your latest code. The catch: if a deploy changes a handler's
`payload` shape, the new handler may receive an old job's payload (or, after
a retry across a deploy, vice-versa).

Set `pin_version = true` on a handler to instead run each of its jobs on the
**exact version that enqueued it**, even after newer deploys. Use it when a
job's payload is only meaningful to the code that created it.

- Pinning keeps **code and payload** in sync. It does **not** snapshot your
  data: the per-service store still migrates forward, so a pinned old handler
  runs against the current schema. Keep store migrations additive.
- **Cron fires and admin replays always run active** — pinning applies only
  to jobs enqueued from a handler.
- If the pinned version is gone (service deleted), the job dead-letters with
  `pinned_version_gone` rather than silently running different code.

Prefer the default (unpinned) unless you have a concrete payload-compatibility
reason — pinned jobs don't pick up handler bug fixes.

## Enqueuing

```rust
use boogy_sdk::jobs::JobSpec;

fn enqueue(p: &impl Serialize, user_id: u64, run_at: u64)
    -> Result<String, Box<dyn std::error::Error>>
{
    let job_id = jobs_enqueue(JobSpec {
        handler: "send_welcome_email".into(),
        payload: serde_json::to_vec(&p)?,
        idempotency_key: Some(format!("welcome:{user_id}")),
        not_before_unix_s: Some(run_at),   // optional delay
        ..Default::default()               // max_attempts inherits the manifest
    })?;
    Ok(job_id)
}
```

`jobs_enqueue` / `jobs_cancel` / `jobs_status` are emitted by `wit_glue!`.
You cannot enqueue for another service — call it via `peer` and let it
enqueue its own. `EnqueueError`: `QueueFull`, `InvalidHandler` (not
declared), `InvalidSpec`, `BackendUnavailable` (also = capability not
granted).

## Inside a transaction

Enqueuing inside `tx(...)` is allowed and **staged**: the job is
submitted only if the transaction commits (a rollback discards it),
atomically with your writes — the durable way to make a side effect
follow a commit. `cancel`/`status` are denied in-tx (the job isn't
persisted yet; use the returned `job_id` after commit). See
`boogy:boogy-transactions`.

## At-least-once — the Iron Law

**Delivery is at-least-once, never exactly-once.** A handler CAN run more
than once: a lease can expire and be retried, a failover can replay an
in-flight job, a cron tick can double-fire. **Handlers MUST be
idempotent.**

`idempotency_key` dedupes *enqueues* — a collision returns the existing
`job_id` and inserts no duplicate. It does NOT make the handler body run
once. For handler-level safety: use the stable `ctx.job_id` as the
`Idempotency-Key` on outbound calls, and `INSERT … ON CONFLICT DO
NOTHING` for store writes.

**The dedup window is bounded, and you should size your key to it.** A key
keeps deduping while the job is pending or running AND for a retention
period after it reaches a terminal state — long enough to absorb the case
this exists for, an upstream redelivering the same webhook minutes or
hours later. Past that the binding is reclaimed and the same key enqueues
fresh work.

So a key must identify the WORK, not the caller's intent, and must stop
being reused once the work is genuinely different. `welcome:{user_id}` is
right if a user should get exactly one welcome ever — but understand that
it stops protecting you once the window lapses, so the handler still needs
to be safe to run twice. For recurring work, put the occurrence in the key
(`digest:{user_id}:{yyyy-mm-dd}`) rather than reusing a bare name, which
would either dedupe against a run you wanted or silently stop deduping
once the old binding aged out.

**Errors and retries.** A bare `Err(String)` is **retryable** — the worker
backs off and re-runs (up to `max_attempts`, then dead-letters), the same as a
wasm trap (panic, OOM, deadline). For explicit control, return a
`boogy_sdk::JobError`: `Terminal(msg)` dead-letters immediately (a failure that
can never succeed on retry — bad payload, a missing parent row), `Retry(msg)` is
a transient one. To recognize the FINAL attempt — e.g. to record a terminal
`failed` status on your own row before the job dead-letters — take a leading
`ctx: JobContext` and compare `ctx.attempts` (1-based) against your manifest
`max_attempts`.

**Prefer enqueuing a job over a synchronous side effect when it should be
transactional.** Enqueuing inside `tx(...)` is **staged**: the job is submitted
only if the transaction commits (a rollback discards it) — so a durable job is
the way to make a side effect (send an email, call a third party, fan out)
happen *iff your writes commit*. A synchronous `outbound_http` call can't do
this: it's denied inside an open `tx`, and a completed external call can't be
rolled back. Make the endpoint enqueue by default; offer a synchronous flag only
for fire-now cases outside a transaction.

## Large sweeps

For a job scanning a big table (digests, exports, decay), use
`for_each_batch` — bounded memory. Its `order_col` is an **index name,
not a column name** (a bare column errors; `None` = primary-key order),
and it cannot run inside a transaction (gather ids first).

**Every row is visited once only in primary-key order** (`order_col =
None`), where the cursor resumes from the row key and that key never
moves. Walk an INDEX instead and the resume point is the index entry,
which embeds the indexed VALUE — so a row whose indexed column is
updated while the sweep runs moves: backward past the cursor it is
visited **twice**, forward it is **skipped**.

That is the difference between a digest that mails one summary and one
that mails two. Sweeps are the place non-idempotent work lives, so
either walk in primary-key order, or write the batch body so repeating
it is harmless (check-then-act on a persisted marker, not a bare
increment or send).

When you then act on those ids inside a `tx`, fetch them with `get_many`
— point gets, which conflict only on the rows they return. Do **not**
re-read them with `where_in`: `_id` leads no index, so an IN-list over
ids scans, taking the whole table as the transaction's read set and
undoing the batching. See `boogy:boogy-transactions`.

## Red flags

| Thought | Reality |
|---------|---------|
| "I'll spawn a background timer for the schedule." | There is no runtime to spawn on. Declare `schedule` on the handler; the platform fires it. |
| "Jobs run exactly once." | At-least-once. Handlers must be idempotent. |
| "`idempotency_key` guarantees one execution." | It dedupes enqueues, not handler runs. |
| "Use the default world." | Processing jobs needs `service-with-jobs` + the job export, or it won't compile. |
| "Enqueue a job for the other service directly." | Self-targeted only. Call it via `peer`; it enqueues its own. |
| "`order_col` is the column to sort by." | It's an index name in `for_each_batch`; a column errors. |
