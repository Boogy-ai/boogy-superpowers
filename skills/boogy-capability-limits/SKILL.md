---
name: boogy-capability-limits
description: Use when a requirement might not be supported on Boogy, or when designing any new service or feature
---

# Boogy capability limits

Boogy is capability-scoped and request/response shaped. Some requirements
have **no primitive** on the platform. Naming the gap and the sanctioned
alternative up front beats deriving it from scratch — and beats faking it.

## Honest gap list

**Real-time push — via the capability, not a handler upgrade.** You do
**not** write a WebSocket-upgrade or SSE handler in your service code, and
your handler always returns exactly one response and returns it
*immediately*. What that response may do is name a stream the platform
then relays on your behalf — the host owns the connection, never your
guest. Two shapes, and they are for different audiences:

- **Many subscribers, ongoing** — declare channels in the manifest and
  publish to them with the `websockets` capability; the platform's
  streaming gateway fans messages out (public, private-grant, or
  per-principal channels). See `boogy:boogy-websockets`.
- **One caller, this request** — a *request-scoped* stream: your handler
  starts the work (typically a background job), returns immediately, and
  the platform streams frames to that caller as SSE. No channel to
  declare, no grant to mint — the reader is the connection that made the
  request.

**Reconnects re-run your handler.** A browser's `EventSource` reconnects by
itself when a connection drops, which re-issues the request — so your
handler runs again and starts the work again. Have the client send a
stable key and pass it as your job's `idempotency_key`, and the reconnect
rejoins the same job instead of paying for it twice. (The reconnecting
request still gets a fresh stream and will not replay what it missed;
today it is cheap to reconnect, not useful.)

**The rule that catches people: validate in the handler, not in the job.**
Once your handler returns a streaming response the request is accepted and
the status code is spent, so a later failure can only be an error *frame*.
Bad input, auth failures and unknown resources must be rejected while the
handler is still running.
For simple cases a notifications table keyed `(recipient, created_at)` +
a keyset-paginated short-poll endpoint is still a fine, cheaper option.
(Separately, the platform streams *your own* observability data — guest
logs and more — to you as the owner; see `boogy:boogy-observability`.
That's an owner-side surface, distinct from the service push channel.)

**Large files / blobs — SUPPORTED, via the `files` capability.** The `blob`
column type is still for *small binary values*, not files: it does not
change the per-request memory, body, or transaction ceilings, and a
user-sized file will not fit through them. *What to do instead:* declare
`[capabilities] files` and a `[[files.collections]]` block, then mint an
upload ticket — the client sends the bytes to a platform route and the
platform serves them back, with **your service never carrying them**. Do
not hand-roll a presigned-URL flow against an external bucket; that is
what this capability replaces. See `boogy:boogy-file-storage`.

**Long-running synchronous work.** A request that exceeds its wall-clock
budget is killed. *What to do instead:* enqueue a background job
(`background_jobs` capability + a `[background_jobs.handlers.*]` handler)
and return immediately; the client polls for status.

**Streaming protobuf methods — refused at DEPLOY, not at runtime.** A
service can serve protobuf (gRPC, Connect, gRPC-Web) from a `.proto`, but
only **unary** methods. Client-streaming, server-streaming and
bidirectional are all unsupported, and the refusal is not a runtime error a
caller sees: the `stream` keyword anywhere in a declared service's methods
makes the whole deployment a **provision-time 409**. The deployment is not
activated at all, and where a previous version exists the platform restores
it so your service keeps serving — the 409 body says whether that restore
succeeded, which is worth reading rather than assuming. That placement is
deliberate — the alternative is activating
a deployment that mis-serves a streaming method as unary, failing per
request, in production, at a moment nobody chose. *What to do instead:*
make the method unary (most "streaming" first drafts are a paginated list —
return a page and a cursor); or push instead of stream, with the
`websockets` capability for many subscribers and a request-scoped stream
(above) for one caller; or leave the streaming service out of the
manifest's declared protobuf services entirely — an undeclared service is
not refused, it is simply not served over protobuf. See
`boogy:boogy-protobuf-rpc`.

**Vector / semantic search.** Not yet available — there is no working
embedding or similarity-search capability. *What to do instead:* keyword
search via the store's filter/LIKE queries; if semantic search is a hard
requirement, generate embeddings and search via an external service
through `outbound_http`, keeping only metadata in the store.

**Extreme write rates.** The built-in store handles typical CRUD plus
most write-heavy workloads. Genuinely extreme write rates (large
payloads, write-amplifying secondary indexes) → bring your own database
and reach it via `outbound_http`, keeping only what you must in the store.

**Oversized deployed artifact.** Your compiled `.wasm` must fit the
artifact size cap: up to **8 MiB on the free tier**, and a **32 MiB hard
maximum** even on a paid plan — measured on the *uncompressed* `.wasm`,
not gzipped. Typical Rust services compile to well under 1 MiB; large
dependency trees, embedded assets, or image/crypto-heavy crates inflate
that fast. An upload over 8 MiB without a paid plan is rejected (HTTP
402); over 32 MiB is rejected for everyone (HTTP 413). *What to do
instead:* trim features and dependencies, move large embedded data out of
the binary (fetch or presign it at runtime), or split the work across
multiple services. A leaner `.wasm` also **cold-starts faster** — a
service that hasn't been hit for a while may pay a one-time cold-start
(reload + recompile) on its next request, and binary size drives that
latency.

**`clock` / `entropy` are real host-level grants, not app-level toggles.**
Denying `clock` freezes the wall clock a guest observes at the Unix epoch —
`std::time::SystemTime::now()` returns it, not just the SDK's
`now_millis()` wrapper. Denying `entropy` returns an all-zero deterministic
stream from `wasi:random/random` — `getrandom`, `rand`, `rand_core::OsRng`,
and `uuid::Uuid::new_v4()` all get it, not just `random_bytes()`. There is no way
to get real calendar time or real secure randomness into a service without
granting the matching capability, regardless of which API (Boogy's wrapper
or a raw crate) the code calls. `api_keys_glue!` needs *both*: key
generation uses `OsRng` directly and expiry checks use the raw wall clock,
so a service issuing API keys without `clock = true` / `entropy = true`
gets keys generated from a constant stream and expiry that never advances.
(Relative timing — `std::time::Instant` / `wasi:clocks/monotonic-clock` —
stays real regardless of `clock`; it never reveals calendar time and every
compiled component depends on it structurally.)

## Quick reference — ceilings

| Limit | Default | Note |
|-------|---------|------|
| Per-request memory | 32 MiB | `[limits] memory_mb`; per-request linear-memory cap |
| Request wall-clock budget | 30000 ms | `[limits] cpu_deadline_ms`; range 1–600000 |
| Store transaction envelope | ~5s / 10MB | spans the whole `peer::fetch` call tree; one tx |
| Outbound request body | 1 MiB | `[outbound] max_request_bytes` |
| Outbound response body | 10 MiB | `[outbound] max_response_bytes` |
| Outbound timeout | 30000 ms max / 10000 ms default | `[outbound] max_timeout_ms` / `default_timeout_ms` |
| File per-object ceiling | 5 GiB platform max | `[[files.collections]] max_bytes` sets a lower one |
| File collections per service | 32 | `[[files.collections]]` blocks |
| Inline file read/write | a few MiB | `files_put_bytes` / `files_read_bytes`; above it, `TooLarge` |
| Deployed wasm artifact | 8 MiB free / 32 MiB hard max | uncompressed `.wasm`; >8 MiB needs a paid plan, >32 MiB rejected for all |

Inside an open transaction, `outbound_http` and `background_jobs` are
refused. Per-request store-op rate/count limits are
operator-configured (off by default). Request bodies and responses ride
the per-request memory cap — don't route large payloads through the
service.

### Who sets what: defaults vs deployment config

The `[limits]` a module ships are **defaults**, not a ceiling. They are
**deployment-settable**: whoever provisions an instance may raise *or*
lower each limit, bounded only by the **platform hard caps** (the most a
host can safely grant) — not by the module's declared value. The platform
caps are surfaced on the module's manifest endpoint so a provisioner sees
the ceiling for each field; a value above its cap is rejected at provision
time.

`[capabilities]`, by contrast, stay **module-author-only**: a provisioner
can never widen them (no adding `outbound_http` to a module that didn't
declare it). Authors grant capabilities; provisioners size limits.

`[outbound] allowed_hosts` is **provisioner-configurable** — the instance
owner sets the egress allowlist for their own instance. Independently of
the allowlist, the runtime IP firewall blocks internal/loopback addresses
(link-local, private ranges, `127.0.0.0/8`, `::1`, …), so a permissive
allowlist still cannot reach the host's own network.

## Pattern — bounding a client-supplied cost parameter

Any endpoint that lets the caller size the work — iteration or round count, page
size, batch width, fan-out degree, payload length — must bound that input against
`cpu_deadline_ms`. Two facts make this non-optional:

- The budget is **wall-clock**, not CPU-seconds. Store round-trips, cross-service
  hops, outbound calls, and time lost to a busy host all spend it.
- Exceeding it **traps the guest**. There is no catchable error, no `Result`, no
  partial response — the handler is cut off mid-execution. And because a new
  deployment is verified by its first request, a trap *there* can roll the
  deployment back: one oversized first request can undo a deploy.

The shape:

```rust
const DEFAULT_ROUNDS: u32 = 4;
const MAX_ROUNDS: u32 = 16;
const MAX_CONTENT_BYTES: usize = 64 * 1024;
/// Your manifest's `[limits] cpu_deadline_ms` — the platform does not hand it
/// to the guest, so keep the two in step yourself.
const CPU_DEADLINE_MS: u64 = 30_000;

/// Clamp, don't trust. A cost *hint* gets clamped; a nonsensical value is a 400.
pub fn clamp_rounds(requested: Option<u32>) -> u32 {
    requested.unwrap_or(DEFAULT_ROUNDS).min(MAX_ROUNDS)
}

#[test]
fn worst_case_fits_the_cpu_budget() {
    // `fx_time_one_call` stands in for your own measurement of one call.
    let t = fx_time_one_call(MAX_CONTENT_BYTES, MAX_ROUNDS);
    assert!(t < CPU_DEADLINE_MS / 10, "worst legal input must fit with margin");
}
```

Put the bound in a **pure, host-testable function** with a test that runs the
worst *legal* input and asserts it fits. Aim an order of magnitude under the
deadline: `cargo test` builds in debug, which is far slower than the release wasm
you deploy — so passing in debug is the conservative direction, and passing only
in release proves very little. The host is shared, so the real number moves.

If the honest worst case doesn't fit, you have two options and neither is
"hope": raise `cpu_deadline_ms` (it is deployment-settable, bounded by the
platform cap), or move the work into a background job and let the client poll.

## Red flags

| Thought | Reality |
|---------|---------|
| "The blob column type exists, so it's fine for files." | Blob columns are for small binary values. A file blows the per-request memory cap and the transaction envelope. Declare a `[[files.collections]]` block and mint an upload ticket — the client sends the bytes to the platform and your service never carries them. See `boogy:boogy-file-storage`. |
| "I'll accept the upload in a handler and write it somewhere." | A service instance is fresh per request under a memory cap, so it cannot hold a user-sized file. `files_create_upload` returns a ticket the client uploads to directly; no request that reads a file runs your code at all. |
| "I'll just guess the outbound API shape / secret-header semantics." | Verify every `outbound_http` and `[secrets]` signature against the SDK source/docs; never ship an unverified call. |
| "I'll add a WebSocket upgrade handler." | The handler stays request/response — you don't upgrade it. Real-time push is the `websockets` capability (declare channels + publish to them); see `boogy:boogy-websockets`. |
| "My `.proto` has a `stream` method — worst case it errors at runtime." | It errors at **deploy**: a streaming method makes the whole deployment a 409 at provision and it never becomes routable. Make the method unary, or leave that service out of the manifest's declared protobuf services. See `boogy:boogy-protobuf-rpc`. |
| "It's just a demo, store the file in a column." | Same ceilings apply in a demo. Presigned upload + a metadata row is the fastest path that actually works. |
| "I'll pull in whatever crates are convenient — size doesn't matter." | The compiled `.wasm` has an 8 MiB free-tier cap (32 MiB hard max, uncompressed) and binary size drives cold-start latency. Keep dependencies lean; move big embedded data out of the binary. |
| "The client asked for 10 million rounds — that's their problem." | It's yours: exceeding the wall-clock budget **traps** the guest, and a trap on a deployment's first request can roll the deploy back. Clamp caller-supplied cost inputs and test the worst legal one. |

## Integration

REQUIRED BACKGROUND for `boogy:designing-boogy-services` (ships next) —
the design questionnaire checks every feature against these limits before
any code.
