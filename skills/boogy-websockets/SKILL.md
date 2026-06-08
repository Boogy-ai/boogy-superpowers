---
name: boogy-websockets
description: Use when building a Boogy service that pushes real-time messages to end-user clients — declaring public/private channels in the manifest, publishing with the websockets capability, minting subscription grants for private channels, or wiring a browser/socket.io client to subscribe
---

# Boogy Websockets

A Boogy service can push real-time messages to end-user clients over
**named channels**. The service only *publishes*; clients *subscribe*
through the platform's streaming gateway — you never run a WebSocket
server, manage connections, or fan out yourself. The platform handles
connection lifecycle, fan-out, replay, and back-pressure.

Two halves:

1. **Service side (authoring).** Grant the `websockets` capability,
   declare each channel in the manifest, and call `ws_publish` from your
   handlers (or background jobs). For private channels, mint a short-lived
   grant with `ws_mint_subscribe_grant` and hand it to your user.
2. **Client side (subscribing).** A browser/Node client connects a
   Socket.IO client to `/v1/stream` and subscribes with a `service`
   channel envelope. Public channels need nothing; private channels carry
   the grant.

## 1. Declare channels (manifest)

```toml
[capabilities]
websockets = true

# Public channel — anyone may subscribe, no grant needed. `replay` keeps
# the last N messages so late joiners get a snapshot on subscribe.
[[websockets.channels]]
name = "ticker"
class = "public"
replay = 5

# Private channel — subscribers must present a grant minted by the service.
[[websockets.channels]]
name = "inbox"
class = "private"
replay = 50            # optional; 0/omitted = no replay
```

A channel must be declared to be publishable or subscribable — publishing
to an undeclared name fails with `UnknownChannel`. `class` is `public`
(open subscribe) or `private` (grant required). `replay` is the size of
the per-channel replay ring (late joiners receive up to that many recent
messages as a snapshot); omit it for no replay.

## 2. Publish (service handlers)

`wit_glue!` emits the functions unqualified:

```rust
use boogy_sdk::websockets::{PublishError, GrantError};

// Broadcast JSON (by convention) to a declared channel.
fn push_price(req: &mut Req<'_>) -> Result<NoContent, ApiError> {
    let input: PriceInput = validate_body(req.body())?;
    let payload = json::json!({ "px": input.px }).to_string();
    match ws_publish("ticker", &payload) {
        Ok(()) => Ok(NoContent),
        Err(PublishError::RateLimited)      => Err(ApiError::too_many_requests("slow down")),
        Err(PublishError::PayloadTooLarge)  => Err(ApiError::bad_request("message too large")),
        Err(PublishError::UnknownChannel)   => Err(ApiError::internal("undeclared channel")),
        Err(PublishError::CapabilityDenied) => Err(ApiError::internal("websockets not granted")),
        Err(PublishError::BackendUnavailable) => Err(ApiError::service_unavailable("retry")),
    }
}
```

`ws_publish(channel, payload)` returns `Result<(), PublishError>`:

| `PublishError` | Cause |
|---|---|
| `RateLimited` | Publish rate exceeded (100 msg/s, burst 500, per service) |
| `PayloadTooLarge` | Payload over 16 KiB (UTF-8) |
| `UnknownChannel` | Channel not declared in the manifest |
| `CapabilityDenied` | `websockets = true` not granted |
| `BackendUnavailable` | Transient delivery-backend failure |

You can also publish from **background jobs** — same `ws_publish` call,
same channels (useful for scheduled or async fan-out). Jobs can publish
but cannot mint grants.

### Minting a grant for a private channel

A private channel needs a grant. The service mints one (scoped to that
channel, short-lived) and returns it to the authenticated end-user via
its own API; the user presents it when subscribing.

```rust
fn subscribe_token(req: &mut Req<'_>) -> Result<Json<json::Value>, ApiError> {
    // Gate this behind YOUR end-user auth and scope per user before minting.
    let grant = ws_mint_subscribe_grant("inbox", 300)   // ttl_seconds
        .map_err(|e| match e {
            GrantError::RateLimited      => ApiError::too_many_requests("slow down"),
            GrantError::InvalidTtl       => ApiError::bad_request("ttl out of range"),
            GrantError::NotPrivate       => ApiError::bad_request("channel is public"),
            GrantError::UnknownChannel   => ApiError::internal("undeclared channel"),
            GrantError::CapabilityDenied => ApiError::internal("websockets not granted"),
        })?;
    Ok(Json(json::json!({ "grant": grant })))
}
```

`ws_mint_subscribe_grant(channel, ttl_seconds)` returns
`Result<String, GrantError>`. `ttl_seconds` must be **10..=3600** — out of
range is **rejected** (`InvalidTtl`), never clamped. Minting public
channels returns `NotPrivate` (public channels need no grant).

| `GrantError` | Cause |
|---|---|
| `RateLimited` | Mint rate exceeded (20/s, burst 100, per service) |
| `InvalidTtl` | `ttl_seconds` outside 10..=3600 |
| `NotPrivate` | Channel is public (no grant needed) |
| `UnknownChannel` | Channel not declared |
| `CapabilityDenied` | `websockets = true` not granted |

## 3. Subscribe (client side)

Clients connect a Socket.IO client to the gateway `/v1/stream` and
subscribe with a `service` channel envelope. Anonymous connections are
allowed (no token for public channels); private channels carry the
service-minted `grant`.

```js
import { io } from "socket.io-client";

const socket = io("https://<host>", { path: "/v1/stream" });

// ── Public channel: no grant.
socket.on("connect", () => {
  socket.emit("subscribe", {
    kind: "service",
    owner: "alice",          // the service owner's handle
    service_id: "prices",
    channel: "ticker",
  }, (ack) => { /* { ok: true, room } | { ok: false, error } */ });
});

// ── Private channel: include the grant your service handed you.
socket.emit("subscribe", {
  kind: "service",
  owner: "alice",
  service_id: "prices",
  channel: "inbox",
  grant: GRANT,              // from the service's mint endpoint
}, (ack) => { /* ... */ });

// On subscribe to a replay channel: one snapshot of recent messages first.
socket.on("svc:snapshot", (messages) => {
  for (const m of messages) handle(m);
});

// Then live messages as the service publishes them.
socket.on("svc", (message) => {
  handle(message);          // the JSON payload the service published
});

// Stop receiving:
socket.emit("unsubscribe", {
  kind: "service", owner: "alice", service_id: "prices", channel: "ticker",
});
```

Events: `svc:snapshot` (oldest-first replay batch, sent once on subscribe
to a channel with replay) then `svc` (one event per live publish). A
private subscribe without a valid grant — and an unknown/undeclared
channel — both return the same masked `not found` ack (a subscriber can't
probe which channels exist).

## Limits (platform-enforced)

| Limit | Value |
|---|---|
| Payload size | ≤ 16 KiB (UTF-8) |
| Publish rate / service | 100 msg/s, burst 500 |
| Declared channels / service | ≤ 32 |
| Replay ring / channel | ≤ 256 messages |
| Grant TTL | 10 s – 1 h |
| Grant mint rate / service | 20/s, burst 100 |
| Subscribers / channel | ≤ 10,000 |
| Subscribers / service | ≤ 20,000 |

Connection-layer abuse caps (per-IP connect rate and concurrency) are
enforced by the gateway and need no service configuration.

## Pricing posture

There is **no websockets-specific premium**: delivery is billed as plain
egress (per delivered byte, the standard egress rate) — no per-message,
per-connection, or connection-time fee — so small frequent messages cost
exactly what their bytes cost.

## Red flags

| Thought | Reality |
|---------|---------|
| "I'll run my own WebSocket server inside the service." | You can't and don't need to. Declare channels + `ws_publish`; the platform's `/v1/stream` gateway owns connections and fan-out. |
| "I'll publish to a channel on the fly without declaring it." | Undeclared channels fail with `UnknownChannel`. Declare every channel in the manifest (≤ 32). |
| "Private channels just need the user logged in." | Subscribers present a **grant** your service mints (`ws_mint_subscribe_grant`) and hands them. Gate the mint behind your own auth and scope per user. |
| "I'll mint a long-lived grant so the client never re-fetches." | Grant TTL is capped at 10 s – 1 h; out-of-range is rejected, not clamped. Re-mint as needed. |
| "Late subscribers will miss everything before they joined." | Set `replay` on the channel (≤ 256); new subscribers get a `svc:snapshot` of recent messages. |
| "Fan-out is free, so I'll blast huge messages to everyone." | Delivery is metered as egress (bytes × subscribers) and rate/size-capped (16 KiB, 100 msg/s). Amplification costs the tenant. |
| "A failed private subscribe tells the client the channel is wrong." | Bad grant and unknown channel both return the same masked `not found` — by design. |
