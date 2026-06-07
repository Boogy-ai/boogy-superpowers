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

```rust
// wit_bindgen::generate!({ world: "service-with-jobs", ... });
wit_glue!(bindings, Api, with_jobs);   // 3-arg form adds the job export
```

Implement `build_job_router()` on your `Api`:

```rust
#[job("send_nightly_digest")]              // exact match
fn send_nightly_digest() -> Result<(), String> { /* ... */ }

#[job(prefix = "export_")]                  // suffix passed to the fn
fn export(suffix: &str, payload: Spec) -> Result<(), String> { /* ... */ }

fn build_job_router() -> JobRouter {
    JobRouter::new()
        .exact(send_nightly_digest)
        .prefix(export)
}
```

`#[job]` accepts `fn() -> Result<R, String>`, `fn(payload: T)` (T:
`DeserializeOwned`), `fn(payload: Vec<u8>)`, and the prefix forms with a
leading `suffix: &str`. **`service-with-jobs` without a working job
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
```

A handler with a `schedule` fires on that cadence automatically — do NOT
build your own cron loop or `tokio::spawn` timer.

## Enqueuing

```rust
let job_id = jobs_enqueue(JobSpec {
    handler: "send_welcome_email".into(),
    payload: serde_json::to_vec(&p)?,
    idempotency_key: Some(format!("welcome:{user_id}")),
    not_before_unix_s: Some(run_at),   // optional delay
    ..Default::default()               // max_attempts inherits the manifest
})?;
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
`job_id` and inserts no duplicate, within the active+terminal window. It
does NOT make the handler body run once. For handler-level safety: use
the stable `ctx.job_id` as the `Idempotency-Key` on outbound calls, and
`INSERT … ON CONFLICT DO NOTHING` for store writes.

**Errors and retries:** an `Err(String)` from the `#[job]`/`JobRouter`
path is treated as terminal (straight to dead letter). A wasm trap
(panic, OOM, deadline) is retryable and counts against `max_attempts`.
For a soft retry on a transient failure, trap rather than return `Err`.

## Large sweeps

For a job scanning a big table (digests, exports, decay), use
`for_each_batch` — bounded memory, every row visited once. Its
`order_col` is an **index name, not a column name** (a bare column
errors; `None` = primary-key order), and it cannot run inside a
transaction (gather ids first).

## Red flags

| Thought | Reality |
|---------|---------|
| "I'll `tokio::spawn` a timer for the schedule." | Declare `schedule` on the handler; the platform fires it. |
| "Jobs run exactly once." | At-least-once. Handlers must be idempotent. |
| "`idempotency_key` guarantees one execution." | It dedupes enqueues, not handler runs. |
| "Use the default world." | Processing jobs needs `service-with-jobs` + the job export, or it won't compile. |
| "Enqueue a job for the other service directly." | Self-targeted only. Call it via `peer`; it enqueues its own. |
| "`order_col` is the column to sort by." | It's an index name in `for_each_batch`; a column errors. |
