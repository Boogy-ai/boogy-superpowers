---
name: boogy-observability
description: Use when an owner wants to see their own service usage, billing dimensions, raw events, a single request trace, audit tail, storage quota, or guest logs — via the /v1 REST API, MCP tools, or the live log stream — or when adding guest logging to a service so its logs become retrievable
---

# Boogy Observability

The platform exposes an **owner-scoped** observability surface: as the
owner of one or more deployed services you can pull usage metrics,
billing summaries, raw events, a full trace of a single request, your
audit tail, storage-quota status, and your services' recent guest logs —
over REST, MCP tools, or a live stream. There is no setup; these
endpoints exist for every owner.

**Everything here is yours only.** Every read is scoped to the calling
principal's own services. A service you don't own and a service that
doesn't exist are indistinguishable — both return **404**. There is no
cross-owner view.

## Auth

All `/v1/*` reads use a **PASETO bearer token** (your session token) in
the `Authorization` header:

```bash
curl -H "Authorization: Bearer $TOKEN" https://<host>/v1/usage
```

The MCP tools and the live stream use the same identity (the stream
takes the token in its handshake; see below).

## REST surface (`/v1`)

| Endpoint | Returns |
|---|---|
| `GET /v1/usage` | Hourly usage series. Fields per bucket include fuel consumed, store ops, cold starts, peak memory, and request-latency percentiles (p50/p95/p99). Filters: `service_id`, `kind`, `since`, `until` (RFC 3339). Default window: last 24h. |
| `GET /v1/usage/summary?month=YYYY-MM` | Billing summary for the month across the 7 billing dimensions. |
| `GET /v1/usage/events` | Raw usage events. Filters: `kind`, `outcome`, `since`, `until`. Keyset paginated via `cursor`; `limit` ≤ 500. |
| `GET /v1/usage/requests/{request_id}` | The full trace of one request across every hop it touched — inbound, cross-service, MCP, and outbound. |
| `GET /v1/audit` | Your audit tail (owner-scoped). Filters: `action_prefix`, `since`. |
| `GET /v1/quota` | Storage-quota status across your services. |
| `GET /v1/services/{id}/quota` | Storage-quota status for one service (404 if not yours / not found). |
| `GET /v1/services/{id}/logs?limit=N` | Snapshot of that service's recent guest logs, newest-first, up to 1000 lines. |

### Examples

```bash
# Last 24h of usage for one service, hourly
curl -H "Authorization: Bearer $TOKEN" \
  "https://<host>/v1/usage?service_id=notes"

# A bounded window with explicit RFC 3339 timestamps
curl -H "Authorization: Bearer $TOKEN" \
  "https://<host>/v1/usage?since=2026-06-01T00:00:00Z&until=2026-06-02T00:00:00Z"

# This month's billing summary
curl -H "Authorization: Bearer $TOKEN" \
  "https://<host>/v1/usage/summary?month=2026-06"

# Raw events, only failed ones, paginated
curl -H "Authorization: Bearer $TOKEN" \
  "https://<host>/v1/usage/events?outcome=error&limit=100"
# next page: pass the returned cursor
curl -H "Authorization: Bearer $TOKEN" \
  "https://<host>/v1/usage/events?outcome=error&limit=100&cursor=$CURSOR"

# Most recent guest logs for a service
curl -H "Authorization: Bearer $TOKEN" \
  "https://<host>/v1/services/notes/logs?limit=200"
```

### Tracing one request end-to-end

Every response carries an `x-boogy-request-id` header. Capture it from
the response you care about, then pull the full trace — every hop the
request fanned out to (cross-service calls, MCP, outbound) shows up under
the one id:

```bash
RID=$(curl -sD - -o /dev/null -H "Authorization: Bearer $TOKEN" \
  "https://<host>/alice/notes/api/notes" \
  | tr -d '\r' | awk -F': ' '/^x-boogy-request-id:/{print $2}')

curl -H "Authorization: Bearer $TOKEN" \
  "https://<host>/v1/usage/requests/$RID"
```

## MCP tools

The same data is reachable as MCP tools for LLM clients — same identity,
same owner-scoping:

| Tool | Maps to |
|---|---|
| `query_my_usage` | usage series / summary |
| `tail_my_audit_events` | your audit tail |
| `get_service_logs` | a service's recent guest logs |

Point an MCP client at the platform's MCP surface and these appear in
`tools/list`. Scoping is enforced by the caller's identity — a tool only
ever returns the caller's own data.

## Live log stream (Socket.IO)

For live tailing rather than snapshots, connect a Socket.IO client to the
`/v1/stream` gateway. Pass your PASETO token in the handshake `auth`,
then `subscribe` with a channel envelope:

```js
import { io } from "socket.io-client";

const socket = io("https://<host>", {
  path: "/v1/stream",
  auth: { token: TOKEN },          // PASETO bearer
});

socket.on("connect", () => {
  socket.emit("subscribe", { kind: "logs", service_id: "notes" }, (ack) => {
    // ack confirms the subscription
  });
});

// One snapshot of recent lines, oldest-first, on subscribe:
socket.on("logs:snapshot", (lines) => {
  for (const line of lines) console.log(line.ts_ms, line.level, line.msg);
});

// Then live lines as they're emitted:
socket.on("logs", (line) => {
  // { ts_ms, level, msg, request_id? }
  console.log(line.ts_ms, line.level, line.msg, line.request_id);
});

// Stop receiving:
socket.emit("unsubscribe", { kind: "logs", service_id: "notes" });
```

The subscribe envelope is `{ kind, ... }`. Today `kind: "logs"` is
supported (it takes a `service_id`); additional channel kinds use the
same `subscribe`/`unsubscribe` envelope with new `kind` values, so write
clients to switch on `kind` rather than assuming logs are the only stream.

### Service channels (subscribing to a service's real-time messages)

The same `/v1/stream` gateway also carries **service-published** channels —
real-time messages a service pushes to its end users (not owner logs).
Subscribe with `{ kind: "service", owner, service_id, channel }` (public
channels need no token; private channels carry a service-minted `grant`);
events are `svc:snapshot` (replay) then `svc` (live). Publishing those
channels is a service-AUTHORING concern — see `boogy:boogy-websockets`.

## Guest logging (making your logs retrievable)

Service logs are **opt-in** per service. Grant the capability and emit
from your handlers; the lines then show up in `GET
/v1/services/{id}/logs` and the live stream above.

1. Grant the capability in the manifest:

```toml
[capabilities]
logging = true
```

2. Emit from handlers with the SDK macros:

```rust
use boogy_sdk::log;

fn create_widget(req: &mut Req<'_>) -> Result<NoContent, ApiError> {
    log::info!("creating widget");
    // ... on a recoverable problem:
    log::warn!("retrying downstream call");
    // ... on failure:
    log::error!("downstream call failed");
    log::debug!("low-level detail");
    Ok(NoContent)
}
```

### Logging behavior (platform-enforced)

- Each line is capped at **2 KiB** (longer lines are truncated).
- The platform keeps the **most recent ~1000 lines per service** — older
  lines age out as new ones arrive. Logs are a recent-tail buffer, not a
  durable archive; ship anything you must retain to an external sink via
  `outbound_http`.
- Emission is **rate-limited** (about 50 lines/s sustained, burst ~200);
  beyond that, excess lines are dropped rather than queued. Log
  decisions and notable events, not a line per loop iteration.

Without `logging = true`, the macros are inert and nothing is captured.

## Red flags

| Thought | Reality |
|---------|---------|
| "I can see usage across all services on the host." | Owner-scoped only. You see your own services; others' are invisible (404, same as not-found). |
| "Logs are a permanent record I can query for last month." | Recent-tail only — ~1000 most-recent lines per service, capped at 2 KiB each. For durable history ship to an external sink via `outbound_http`. |
| "My `log::info!` calls will show up in the logs endpoint." | Only if the manifest grants `[capabilities] logging = true`. Without it the macros are inert. |
| "I'll log inside a tight loop to trace everything." | Emission is rate-limited (~50/s, burst ~200); excess is dropped. Log decisions/events, not every iteration. |
| "I need to build a request-tracing system to follow a call across services." | Grab `x-boogy-request-id` from the response and `GET /v1/usage/requests/{id}` — the platform already correlates every hop. |
| "Streaming logs needs a custom WebSocket endpoint in my service." | The `/v1/stream` Socket.IO gateway streams owner logs already — connect a client, no service code. |
| "I'll only handle a `logs` event from the stream." | Also handle `logs:snapshot` (the oldest-first initial batch) and switch on `kind` — more channel kinds use the same envelope. |
