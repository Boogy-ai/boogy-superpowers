---
name: boogy-capability-limits
description: Use when a requirement might not be supported on Boogy, or when designing any new service or feature
---

# Boogy capability limits

Boogy is capability-scoped and request/response shaped. Some requirements
have **no primitive** on the platform. Naming the gap and the sanctioned
alternative up front beats deriving it from scratch — and beats faking it.

## Honest gap list

**WebSockets / server-push / SSE-from-the-service.** The HTTP handler is
strict request → one response. There is no streaming, WebSocket, or
server-sent-events export. *What to do instead:* a notifications table
keyed `(recipient, created_at)` + a cheap keyset-paginated short-poll
endpoint with a cursor; optionally fan out via SSE/WebSocket in the
client's own web tier; optionally push to an external push provider via
`outbound_http`.

**Large files / blobs.** There is no file-storage capability. The `blob`
column type is for *small binary values*, not files — it does not change
the per-request memory, body, or transaction ceilings. *What to do
instead:* the presigned-URL pattern — keep only metadata rows in the
store; bytes go client → external object storage directly; serve playback
via a presigned-GET redirect.

**Long-running synchronous work.** A request that exceeds its wall-clock
budget is killed. *What to do instead:* enqueue a background job
(`background_jobs` capability + a `[background_jobs.handlers.*]` handler)
and return immediately; the client polls for status.

**Sub-second / instant push.** No realtime delivery primitive exists.
Short-polling is the supported pattern; true push lives outside the
service (client tier or an external provider via `outbound_http`).

**Vector / semantic search.** Not yet available — there is no working
embedding or similarity-search capability. *What to do instead:* keyword
search via the store's filter/LIKE queries; if semantic search is a hard
requirement, generate embeddings and search via an external service
through `outbound_http`, keeping only metadata in the store.

**Extreme write rates.** The built-in store handles typical CRUD plus
most write-heavy workloads. Genuinely extreme write rates (large
payloads, write-amplifying secondary indexes) → bring your own database
and reach it via `outbound_http`, keeping only what you must in the store.

## Quick reference — ceilings

| Limit | Default | Note |
|-------|---------|------|
| Per-request memory | 32 MiB | `[limits] memory_mb`; per-request linear-memory cap |
| Request wall-clock budget | 30000 ms | `[limits] cpu_deadline_ms`; range 1–600000 |
| Store transaction envelope | ~5s / 10MB | spans the whole `peer::fetch` call tree; one tx |
| Outbound request body | 1 MiB | `[outbound] max_request_bytes` |
| Outbound response body | 10 MiB | `[outbound] max_response_bytes` |
| Outbound timeout | 30000 ms max / 10000 ms default | `[outbound] max_timeout_ms` / `default_timeout_ms` |

Inside an open transaction, `outbound_http` and `background_jobs` are
refused. Per-request store-op rate/count limits are
operator-configured (off by default). Request bodies and responses ride
the per-request memory cap — don't route large payloads through the
service.

## Red flags

| Thought | Reality |
|---------|---------|
| "The blob column type exists, so it's fine for files." | Blob columns are for small binary values. Files blow the 32 MiB memory default and ~5s/10MB tx envelope — use presigned upload to object storage. |
| "I'll just guess the outbound API shape / secret-header semantics." | Verify every `outbound_http` and `[secrets]` signature against the SDK source/docs; never ship an unverified call. |
| "I'll add a WebSocket upgrade handler." | There is no ws/streaming export. Short-poll a keyset endpoint; push from the client tier or an external provider. |
| "It's just a demo, store the file in a column." | Same ceilings apply in a demo. Presigned upload + a metadata row is the fastest path that actually works. |

## Integration

REQUIRED BACKGROUND for `boogy:designing-boogy-services` (ships next) —
the design questionnaire checks every feature against these limits before
any code.
