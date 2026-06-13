---
name: boogy-websockets
description: Use when building a Boogy service that pushes real-time messages to end-user clients — declaring public/private/principal channels in the manifest, publishing with the websockets capability, minting subscription grants for private or per-principal channels, or wiring a browser/socket.io client to subscribe
---

# Boogy Websockets

A Boogy service can push real-time messages to end-user clients over
**named channels**. The service only *publishes*; clients *subscribe*
through the platform's streaming gateway — you never run a WebSocket
server, manage connections, or fan out yourself. The platform handles
connection lifecycle, fan-out, replay, and back-pressure.

Two halves:

1. **Service side (authoring).** Grant the `websockets` capability,
   declare each channel in the manifest, and call `ws_publish` (broadcast)
   or `ws_publish_event` / `ws_publish_to_principal` (per-recipient) from
   your handlers (or background jobs). For private channels, mint a
   short-lived grant with `ws_mint_subscribe_grant`; for principal channels,
   use `ws_mint_principal_subscribe_grant`.
2. **Client side (subscribing).** A browser/Node client connects a
   Socket.IO client to `/v1/stream` and subscribes with a `service`
   channel envelope. Public channels need nothing; private and principal
   channels carry a grant (or, for principal channels, an authenticated
   agent session).

## Hard principle: typed envelopes on every channel

> **Every websocket message must be a typed envelope — never a bare payload.**

Shape:

```json
{ "type": "price.updated", "v": 1, "ts": 1718300000000, "data": { … } }
```

| Field | Meaning |
|---|---|
| `type` | Dot-namespaced event name (`"order.placed"`, `"tick"`, …) |
| `v` | Schema version integer — increment when the shape of `data` changes |
| `ts` | Publish timestamp, epoch milliseconds |
| `data` | The event payload |

Why: one channel carries **multiple, independently-versioned event kinds**.
Clients dispatch on `type` and ignore unknown ones; version bumps in `data`
are detected via `v` without a channel rename. The SDK provides helpers to
build this envelope — see §2 — so you never assemble the JSON by hand.

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

# Principal channel — one isolated room per recipient (identified by their
# principal string). Authenticated agents join their own room automatically;
# guests need a service-minted grant scoped to their principal.
[[websockets.channels]]
name = "orders"
class = "principal"
replay = 8             # capped at 16 for principal channels
```

A channel must be declared to be publishable or subscribable — publishing
to an undeclared name fails with `UnknownChannel`. `class` is:

| `class` | Who may subscribe | Grant required? |
|---|---|---|
| `public` | Anyone | No |
| `private` | Holder of a service-minted grant | Yes (service mints for any bearer) |
| `principal` | One named recipient per room | No for authenticated agents; yes for guests |

`replay` is the size of the per-channel replay ring (late joiners receive
up to that many recent messages as a snapshot); omit it for no replay.
Principal channels cap `replay` at **16**.

## 2. Publish (service handlers)

`wit_glue!` emits the functions unqualified:

```rust
use boogy_sdk::websockets::{Envelope, PublishError, GrantError};

// Broadcast a typed event to all subscribers of a public channel.
// Build an Envelope, then pass its JSON string to ws_publish.
fn push_price(req: &mut Req<'_>) -> Result<NoContent, ApiError> {
    let input: PriceInput = validate_body(req.body())?;
    let env = Envelope::new("price.updated", 1, now_millis(), json::json!({ "px": input.px }));
    match ws_publish("ticker", &env.to_json()) {
        Ok(()) => Ok(NoContent),
        Err(PublishError::RateLimited)        => Err(ApiError::too_many_requests("slow down")),
        Err(PublishError::PayloadTooLarge)    => Err(ApiError::bad_request("message too large")),
        Err(PublishError::UnknownChannel)     => Err(ApiError::internal("undeclared channel")),
        Err(PublishError::CapabilityDenied)   => Err(ApiError::internal("websockets not granted")),
        Err(PublishError::BackendUnavailable) => Err(ApiError::service_unavailable("retry")),
    }
}
```

`ws_publish(channel, payload)` sends a raw string payload to all
subscribers. For broadcast channels, build a typed envelope with
`Envelope::new(type_, v, ts, data)` (where `ts` is `now_millis()` and
`data` is a `serde_json::Value`) and pass `&env.to_json()` — this is
the correct way to honour the typed-envelope principle on public channels.

The ergonomic `ws_publish_event` helper exists for **per-principal
channels** (see below); there is no broadcast variant of it.

Both return `Result<(), PublishError>`:

| `PublishError` | Cause |
|---|---|
| `RateLimited` | Publish rate exceeded (100 msg/s, burst 500, per service) |
| `PayloadTooLarge` | Payload over 16 KiB (UTF-8) |
| `UnknownChannel` | Channel not declared in the manifest |
| `CapabilityDenied` | `websockets = true` not granted |
| `BackendUnavailable` | Transient delivery-backend failure |

You can also publish from **background jobs** — same calls, same channels
(useful for scheduled or async fan-out). Jobs can publish but cannot mint
grants.

### Publishing to a principal channel

Use `ws_publish_event` with the recipient's principal (preferred), or the
raw `ws_publish_to_principal` for a hand-built payload:

```rust
// Notify one recipient on a principal channel.
fn notify_order(req: &mut Req<'_>) -> Result<NoContent, ApiError> {
    let order: Order = validate_body(req.body())?;
    // principal must be path-safe: agent_<id> is fine; a raw email is NOT.
    let principal = order.owner_principal.as_str();
    ws_publish_event("orders", principal, "order.placed", 1, json::json!({ "order_id": order.id, "status": order.status }))
        .map_err(|e| match e {
            PublishError::RateLimited        => ApiError::too_many_requests("slow down"),
            PublishError::PayloadTooLarge    => ApiError::bad_request("message too large"),
            PublishError::UnknownChannel     => ApiError::internal("undeclared channel"),
            PublishError::CapabilityDenied   => ApiError::internal("websockets not granted"),
            PublishError::BackendUnavailable => ApiError::service_unavailable("retry"),
        })?;
    Ok(NoContent)
}
```

`ws_publish_event(channel, principal, type_, v, data)` — five arguments
in that order — stamps the current time and emits the typed envelope to
the named recipient's room. `data` is a `serde_json::Value` passed by
value (use `json::json!({…})` inline or bind it first without
`.to_string()`). The raw per-principal variant is
`ws_publish_to_principal(channel, principal, payload)` for hand-built
payloads.

**Principal ref rules:** the `principal` string must be path-safe —
ASCII alphanumeric, `-`, or `_` only. Agent principals (`agent_<uuid>`)
always satisfy this. A raw email address does **not** — store and pass an
opaque path-safe identifier for guest users instead.

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
            GrantError::NotPrivate       => ApiError::bad_request("channel is not private"),
            GrantError::UnknownChannel   => ApiError::internal("undeclared channel"),
            GrantError::CapabilityDenied => ApiError::internal("websockets not granted"),
        })?;
    Ok(Json(json::json!({ "grant": grant })))
}
```

`ws_mint_subscribe_grant(channel, ttl_seconds)` returns
`Result<String, GrantError>`. `ttl_seconds` must be **10..=3600** — out of
range is **rejected** (`InvalidTtl`), never clamped.

### Minting a grant for a principal channel (guest subscribers)

An authenticated agent joining a principal channel needs **no grant** —
the gateway derives their room from their verified session. A guest (no
agent auth) must present a service-minted grant scoped to their principal:

```rust
fn principal_subscribe_token(req: &mut Req<'_>) -> Result<Json<json::Value>, ApiError> {
    // Authenticate the guest via your own mechanism, resolve their opaque
    // path-safe principal ref, then mint a channel grant for that principal.
    let principal = "usr_a1b2c3";  // opaque path-safe ref — not a raw email
    let grant = ws_mint_principal_subscribe_grant("orders", principal, 300)
        .map_err(|e| match e {
            GrantError::RateLimited      => ApiError::too_many_requests("slow down"),
            GrantError::InvalidTtl       => ApiError::bad_request("ttl out of range"),
            GrantError::WrongClass       => ApiError::bad_request("channel is not a principal channel"),
            GrantError::UnknownChannel   => ApiError::internal("undeclared channel"),
            GrantError::CapabilityDenied => ApiError::internal("websockets not granted"),
        })?;
    Ok(Json(json::json!({ "grant": grant })))
}
```

`ws_mint_principal_subscribe_grant(channel, principal, ttl_seconds)` is
the per-principal twin of `ws_mint_subscribe_grant`. Same TTL rules apply.

| `GrantError` | Cause |
|---|---|
| `RateLimited` | Mint rate exceeded (20/s, burst 100, per service) |
| `InvalidTtl` | `ttl_seconds` outside 10..=3600 |
| `NotPrivate` | Channel class doesn't require a grant |
| `UnknownChannel` | Channel not declared |
| `CapabilityDenied` | `websockets = true` not granted |

## 3. Subscribe (client side)

Clients connect a Socket.IO client to the gateway `/v1/stream` and
subscribe with a `service` channel envelope. Anonymous connections are
allowed (no token for public channels); private channels carry the
service-minted `grant`; principal channels carry the `principal` field
(and a `grant` for guests).

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
  service_id: "orders",
  channel: "inbox",
  grant: GRANT,              // from the service's mint endpoint
}, (ack) => { /* ... */ });

// ── Principal channel, authenticated agent: no grant needed.
//   The gateway derives the room from the agent's verified session.
//   Pass auth.token in the handshake so the gateway can verify identity.
const authSocket = io("https://<host>", {
  path: "/v1/stream",
  auth: { token: AGENT_PASETO_TOKEN },
});
authSocket.emit("subscribe", {
  kind: "service",
  owner: "alice",
  service_id: "orders",
  channel: "orders",
  principal: "agent_abc123",   // must match the authenticated principal
}, (ack) => { /* ... */ });

// ── Principal channel, guest subscriber: present a service-minted grant.
socket.emit("subscribe", {
  kind: "service",
  owner: "alice",
  service_id: "orders",
  channel: "orders",
  principal: "usr_a1b2c3",     // the opaque path-safe ref the service issued
  grant: PRINCIPAL_GRANT,      // from ws_mint_principal_subscribe_grant
}, (ack) => { /* ... */ });

// On subscribe to a replay channel: one snapshot of recent messages first.
socket.on("svc:snapshot", (messages) => {
  for (const m of messages) handle(m);
});

// Then live messages — each is a typed envelope.
socket.on("svc", (message) => {
  // message = { type, v, ts, data }
  if (message.type === "order.placed" && message.v === 1) {
    handleOrderPlaced(message.data);
  }
  // unknown types are safely ignored — forward-compatible
});

// Stop receiving:
socket.emit("unsubscribe", {
  kind: "service", owner: "alice", service_id: "orders", channel: "ticker",
});
```

Events: `svc:snapshot` (oldest-first replay batch, sent once on subscribe
to a channel with replay) then `svc` (one event per live publish).

For principal channels, a subscriber can only join **their own** room: an
authenticated agent cannot request another principal's room — the gateway
enforces this. A bad grant, unknown channel, or mismatched principal all
return the same masked `not found` ack (subscribers cannot probe channel
existence or other principals' rooms).

## Limits (platform-enforced)

| Limit | Value |
|---|---|
| Payload size | ≤ 16 KiB (UTF-8) |
| Publish rate / service | 100 msg/s, burst 500 |
| Declared channels / service | ≤ 32 |
| Replay ring / channel | ≤ 256 messages (≤ 16 for `principal` channels) |
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
| "Late subscribers will miss everything before they joined." | Set `replay` on the channel (≤ 256; ≤ 16 for principal channels); new subscribers get a `svc:snapshot` of recent messages. |
| "Fan-out is free, so I'll blast huge messages to everyone." | Delivery is metered as egress (bytes × subscribers) and rate/size-capped (16 KiB, 100 msg/s). Amplification costs the tenant. |
| "A failed private subscribe tells the client the channel is wrong." | Bad grant and unknown channel both return the same masked `not found` — by design. Same masking applies to principal channels. |
| "I'll publish a raw JSON object as the payload." | Every message must be a typed envelope `{ type, v, ts, data }`. For broadcast channels use `Envelope::new` + `ws_publish`; for per-principal channels use `ws_publish_event`. Never send bare payloads. |
| "I need separate channels for each event type." | One channel carries multiple event kinds. Clients dispatch on `type`; they ignore unknown types. Use `v` to evolve a type's `data` schema independently. |
| "I'll use the user's email as the principal for a principal channel." | The `principal` ref must be path-safe (ASCII alphanumeric / `-` / `_`). Emails contain `@` and `.` — use an opaque path-safe ref instead (e.g. `usr_<id>`). |
| "Any authenticated subscriber can join a principal channel for another user." | The gateway enforces that a subscriber can only join their OWN room. An agent cannot request a room scoped to a different principal. |
