---
name: boogy-observability
description: Use when an owner wants to see their own service usage (including live, as traffic lands), billing dimensions, what their usage costs (notional and billed, the daily credit, why their services are paused), raw events, a single request trace, audit tail, storage, or guest logs — via the /v1 REST API, MCP tools, or the live log and usage streams — or when building a live usage dashboard, or adding guest logging to a service so its logs become retrievable
---

# Boogy Observability

The platform exposes an **owner-scoped** observability surface: as the
owner of one or more deployed services you can pull usage metrics,
monthly usage summaries, raw events, a full trace of a single request, your
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
| `GET /v1/usage/summary?month=YYYY-MM` | One month's metered usage per service, across the 7 billing dimensions, **one page of services at a time**, plus the month's `totals` on the first page. A usage view, not an invoice: see [The monthly usage summary](#the-monthly-usage-summary). |
| `GET /v1/account` | Your money: the prepaid balance, and `daily_credit` (today's credit: `amount`, `spent`, `available`, `exhausted`, `paused`, `resets_at`). See [What your usage costs](#what-your-usage-costs). |
| `GET /v1/pricing` | The platform's price list, anonymous: each meter's free daily allowance and price past it, and the daily credit. |
| `GET /v1/usage/events` | Raw usage events, newest first. Filters: `service_id`, `kind`, `outcome`, `class`, `caller`, `path_prefix`, `min_wall_ms`, `since`, `until` (see "Filtering the request log" below). Keyset paginated via `cursor`; `limit` ≤ 500. Each call inspects a bounded number of events, so a page can be short with a `next_cursor` still set. A JSON-RPC call's `inbound_http` event names the method that answered in `rpc_method` (a `Router::rpc` mount's method; `null` for any other request, and for a method the service does not have). |
| `GET /v1/usage/requests/{request_id}` | The full trace of one request across every hop it touched — inbound, cross-service, MCP, and outbound. |
| `GET /v1/services/{id}/pricing` | What that service is actually charging, as compiled at deploy: every priced route with its payer, price, rate and `max`, plus whether the owner account resolved (if it did not, priced routes refuse). |
| `GET /v1/services` | Your active services (including any being deleted, with `deleting: true`), one page at a time in service-id byte order: `limit` (default 100, ≤ 500) and `cursor`; the response is `{items, next_cursor}`, `next_cursor` null on the last page. `module` keeps the instances of modules with that **name** — by name only, so two publishers' modules that share a name both match; `q` keeps ids that start with that text (literal, case-sensitive). A `cursor` resumes only with the `module` and `q` it was returned under; sent with any other values it is a 400. |
| `GET /v1/audit` | Your audit tail (owner-scoped), newest first: events you made, events on your resources, and your account's own billing events (`usage.credit_exhausted`, `usage.rates_overridden`). Filters: `service_id` (only events whose resource is exactly `<owner>/<service_id>` or under `<owner>/<service_id>/`; `notes` does not match `notes2`), `action_prefix`, `outcome` (`success`/`failure`), `since`, `class` (`changes`: anything but a sign-in; `deploys`: provisions and upgrades that succeeded; `refused`: refused provisions, upgrades and module uploads; `failures`: anything that did not succeed; `signins`: every sign-in to your account, whatever its outcome; any other `class` is a 400), and `q` (keeps the events of your instances whose id starts with this text, matched literally; an event on something inside an instance, such as one of its secrets, counts as the instance's. A sign-in's target is your account, so no `q` returns one. `q` never returns a module upload's event either, refused uploads included, whatever target the event names: `q=m` or `q=modules` finds an instance whose id starts so, never an upload. And `q` leaves out what you did to another owner's resources), and `module` (one of your modules' events: the module's own and every version's, `<owner>/modules/<module>` and `…@<version>`; `notes` does not match `notes2`; `module_owner` names the publisher, you when absent, and alone it is a 400). Keyset paginated: `limit` (default 100, ≤ 500) and `cursor`; the response is `{owner, count, items, next_cursor}`, `next_cursor` null on the last page. A `cursor` resumes only with the filters it was returned under; sent with other `service_id`, `action_prefix`, `outcome`, `since`, `class`, `q`, `module` or `module_owner` values it is a 400, so page with the same query string and only the `cursor` changing. |
| `GET /v1/storage` | Your account's storage, one budget for every service's tables and files: `used_bytes`, `allowance_bytes` (free), `ceiling_bytes`, `max_storage_bytes` (your own cap), `state` (`ok`, `nearing`, `paid`, `grace`, `refusing`, `ceiling`), `grace_ends_at`, the rate, `charged_this_month_usd`, `owed_usd` (every storage hour still owed, any month: a top-up pays these first, oldest first, before the current hour). Add `?per_service=1` for each service's bytes (`per_service`); without it the list is left out. In `refusing` or `ceiling` growing writes get 507; see `boogy:boogy-capability-limits`. |
| `GET /v1/quota` | Each of your services' stored bytes (`size_bytes` tables, `files_bytes`; `null` until first measured, with `sampled_at`), your **account's** ceiling (`quota_bytes`), `percent_used`, and whether the account refuses growing writes (`over_quota`, with `refusal`: `refusing` or `ceiling`). |
| `GET /v1/services/{id}/quota` | That row for one service: 200 for any service you own, measured or not; 404 if not yours / not found. |
| `GET /v1/services/{id}/logs?limit=N` | Snapshot of that service's recent guest logs, newest-first, up to 1000 lines. |
| `GET /v1/services/{id}/schema` | That service's tables and columns, including columns you **removed from your model**. A removed column is soft-dropped — its bytes stay so the removal is reversible, and they keep counting against your account's storage until the platform reclaims them **on its own** (see `boogy:boogy-migrations`). Each one reports `dropped_at`, an `estimated_bytes` figure, and a `reclamation` object: `state` (`retained_for_rollback` / `sweeping` / `done`), and while retained, a real `eligible_after` date it clears on by itself (`retained_by` is always `"age"`, naming that bound). Waiting is the only thing that brings the date forward — deploying again does not, since each deployment becomes a rollback target of its own. |

`estimated_bytes` is an **estimate**, and the payload says so
(`bytes_are_estimated`, `estimate_basis`): it divides the table's sampled size
evenly across its columns. An exact per-column figure would mean reading every
row, so the number is right for "which drop is costing me" and wrong for
anything that needs to balance. A dropped column's bytes come back by
themselves once its `reclamation.state` reaches `done` — no call required —
so this view is also the answer to "why hasn't my quota gone down yet" while
you wait: `eligible_after` is when it clears if you do nothing.

### Examples

```bash
# Last 24h of usage for one service, hourly
curl -H "Authorization: Bearer $TOKEN" \
  "https://<host>/v1/usage?service_id=notes"

# A bounded window with explicit RFC 3339 timestamps
curl -H "Authorization: Bearer $TOKEN" \
  "https://<host>/v1/usage?since=2026-06-01T00:00:00Z&until=2026-06-02T00:00:00Z"

# Raw events, only failed ones, paginated
curl -H "Authorization: Bearer $TOKEN" \
  "https://<host>/v1/usage/events?class=failed&limit=100"
# next page: pass the returned cursor
curl -H "Authorization: Bearer $TOKEN" \
  "https://<host>/v1/usage/events?class=failed&limit=100&cursor=$CURSOR"

# Most recent guest logs for a service
curl -H "Authorization: Bearer $TOKEN" \
  "https://<host>/v1/services/notes/logs?limit=200"
```

### The monthly usage summary

`GET /v1/usage/summary` reports one calendar month in UTC (`month=YYYY-MM`;
the current month if you leave it out). Each item is one of your services
that had usage or stored data that month, deleted services included, with
seven measures: `requests`, `compute_seconds`, `occupancy_gb_seconds`,
`egress_gb`, `data_op_units`, `conflicts` and `storage_gb_month`.

- **It pages.** `limit` is 100 by default and at most 500, and items come in
  service-id byte order. Follow `next_cursor` until it is `null`, sending the
  same `month` with every page: a cursor resumes only the month it came from,
  and sent with another month it is a 400. One page is not the month.
- **`totals` is on the first page only.** It holds the seven measures over
  every service of the month. Every later page carries `totals: null`, so take
  the month's totals from the first page rather than adding pages up.
- **It is current to `as_of`.** Usage after that instant is not counted yet.
  While `backfill_pending` is `true`, older history is still being rolled up,
  and an older month can undercount until it finishes.
- **Storage is month-to-date.** `storage_gb_month` covers the days so far,
  current to `storage_as_of`, spread over the whole month, so during the month
  it reads below where the month will end.

**The items are quantities, not charges.** What they cost is the `cost`
object, on the **first page of the current month only** (`null` on later
pages and for past months): see [What your usage costs](#what-your-usage-costs).
There is no invoice endpoint. Money that moves for priced routes (charges,
credits, earnings) is in your ledger: `GET /v1/ledger/balance` and
`GET /v1/ledger/entries`.

```bash
# One month's usage, every page: follow next_cursor until it is null.
MONTH=2026-06
PAGE=$(curl -s -H "Authorization: Bearer $TOKEN" \
  "https://<host>/v1/usage/summary?month=$MONTH&limit=500")
echo "$PAGE" | jq '.totals'          # the month's totals: first page only
while :; do
  echo "$PAGE" | jq -c '.items[]'    # this page's services
  CURSOR=$(echo "$PAGE" | jq -r '.next_cursor // empty')
  [ -z "$CURSOR" ] && break
  PAGE=$(curl -s -G -H "Authorization: Bearer $TOKEN" "https://<host>/v1/usage/summary" \
    --data-urlencode "month=$MONTH" --data-urlencode "limit=500" \
    --data-urlencode "cursor=$CURSOR")
done
```

### Filtering the request log

`GET /v1/usage/events` filters on the server, so ask for what you want
instead of paging through everything and filtering yourself. Filters
combine (all must match); an unknown value is a **400** that names it.

| Parameter | Matches |
|---|---|
| `kind` | One event kind, e.g. `inbound_http` (a request to your service). |
| `outcome` | A comma list of outcomes: `success`, `client_error`, `unauthorized`, `policy_denied`, `rate_limited`, `server_error`, `trap`, `oom`, `deadline`. |
| `class` | A comma list of `served` (`success`), `rejected` (`client_error`, `unauthorized`, `policy_denied`: the caller's side), `refused` (`rate_limited`) or `failed` (`server_error`, `trap`, `oom`, `deadline`). With `outcome` too, only events in both. |
| `caller` | Exactly this `caller_principal`. |
| `path_prefix` | Paths that start with this text, literally: `%`, `_` and `\` are ordinary characters, not wildcards. At most 512 bytes. |
| `min_wall_ms` | Requests that took at least this many milliseconds; a non-negative integer. |
| `since`, `until` | RFC 3339 bounds, `since` inclusive, `until` exclusive. |

```bash
# Slow failures from one caller on one route family
curl -H "Authorization: Bearer $TOKEN" \
  "https://<host>/v1/usage/events?service_id=notes&kind=inbound_http&class=failed&caller=$PRINCIPAL&path_prefix=/notes/&min_wall_ms=100"
```

**Each call reads a bounded window.** A call inspects at most 20,000
events, newest first, from the cursor, applies the filters to those, and
returns up to `limit` matches. So a rare filter never makes one call scan
months of events, and the answer says how far it looked:

- `searched_until` is the timestamp of the oldest event inspected (`null`
  when none was).
- `next_cursor` is set when the page is full, **and** when the call used its
  whole budget. The second case is a **short page, even an empty one, with a
  cursor**: nothing matched in what was inspected, and older events are
  unread. Pass the cursor back to continue exactly where the call stopped;
  no event is read twice or skipped.
- `next_cursor` is `null` only when nothing further can match.

To find a rare event, follow the cursor until you have the rows you want
or it is `null`, and tell the person how far back you have looked
(`searched_until`). Don't read an empty page with a cursor as "none":
say "none since <`searched_until`>" and offer to search further. Send the
same filters back with the cursor.

### Tracing one request end-to-end

Every response carries an `x-boogy-request-id` header. Capture it from
the response you care about, then pull the full trace — every hop the
request fanned out to (cross-service calls, MCP, outbound) shows up under
the one id:

```bash
RID=$(curl -sD - -o /dev/null -H "Authorization: Bearer $TOKEN" \
  "https://alice.<base>/notes/api/notes" \
  | tr -d '\r' | awk -F': ' '/^x-boogy-request-id:/{print $2}')

curl -H "Authorization: Bearer $TOKEN" \
  "https://<host>/v1/usage/requests/$RID"
```

## What your usage costs

Usage is priced per meter per UTC day: requests, compute, occupancy and
egress each have a **free daily allowance**, and past it a price; storage has
a free amount held and a monthly price, charged by the hour. The list is
public: `GET /v1/pricing` (no token) returns each meter's `free` allowance,
its `price_usd` per `per`, its `window` (`day`, or `held` for storage) and
`daily_credit_usd`.

**The daily credit.** Every account gets a credit each UTC day (currently
$10 during the preview), resetting at 00:00 UTC. A charge is paid from the
day's credit first, then from your prepaid balance, and what neither covers
is recorded as owed. The credit pays only platform usage and storage: a
priced route of another service is always paid from your balance, never
from the credit. Read it on `GET /v1/account`:

```bash
curl -s -H "Authorization: Bearer $TOKEN" https://<host>/v1/account | jq '.daily_credit'
# { "amount": "10.00", "spent": "0.42", "available": "9.58",
#   "exhausted": false, "paused": false, "resets_at": "2026-10-29T00:00:00Z" }
```

`exhausted` says today's credit and your balance ran out; `paused` says your
services are actually paused for it. The two differ only while the platform
is not enforcing pauses: then an exhausted day is recorded as owed and
nothing is paused. `daily_credit` is `null` when it could not be read; that
is not a zero credit.

**Notional and billed.** The first page of the current month of
`GET /v1/usage/summary` carries `cost`, with `today` and `month_to_date`:

| Field | Means |
|---|---|
| `notional_usd` | What the usage is worth at list price, ignoring the free allowances. |
| `billed_usd` | What was actually charged: the usage past each day's allowance, at your rate. For storage, the hours charged in the period. |
| `meters[]` | Per meter: `quantity` and `allowance` (today; in the meter's unit from `/v1/pricing`), `rate_usd` (list price), `billed_rate_usd` (the rate you are billed at), and both amounts. |
| `as_of` | What billed is current to. Charges trail usage by a minute or so; usage after `as_of` is not charged yet. |

The gap between notional and billed is what the free allowances saved you.
Billed only ever rises during a day: usage that arrives late (up to two days)
is added to the day it happened, against that day's credit.

**What the platform refuses is not billed as requests.** Requests the
platform turns away before your code runs (rate limited, refused by your
ingress policy, unauthenticated, or shed because a host is busy) are not
counted on the requests meter, so a flood your rate limit stops does not
spend your credit on requests.

### When your services are paused

When today's charges pass the day's credit **and** your balance cannot cover
the rest, your account is **paused until 00:00 UTC**:

- Requests that reach your code, on every one of your services, and calls
  into them from other services, get the answer a busy host gives: **503**
  with a short `Retry-After`. Your users see an ordinary temporary outage.
  Nothing in the response mentions billing, credit or your account, to them
  or to another service calling you.
- What a busy host answers without running your code is answered the same
  way while you are paused: your frontend's static assets are still served,
  and sign-in and authentication answers (a `401` for a missing token, a CORS
  preflight) come back as usual.
- Your background jobs wait and run after the reset; none is dropped.
- Your services' websocket publishes fail as if the real-time backend were
  unavailable.
- Sign-in on your services still works, and so does everything you do as the
  owner: the console, deploys and every `/v1` read.

Only you are told why: `daily_credit.paused` is `true` on
`GET /v1/account`, the console shows a banner on every page, and your audit
tail (`GET /v1/audit`) holds a `usage.credit_exhausted` event. At 00:00 UTC the credit resets and the pause
ends on its own; there is nothing to call. To keep serving past the credit,
keep a prepaid balance: charges past the credit are paid from it before
anything is paused. If you believe a pause is a mistake, ask Boogy support:
the platform can lift it for the rest of the day, after which
`daily_credit` reads `exhausted: true, paused: false` and your services
serve again (usage that day is still charged).

## Measuring a route before you price it

If you are deciding what a route should charge, this surface is where the numbers
come from — guessing them is the mistake `boogy:boogy-route-pricing` exists to
prevent. Deploy the route **unpriced**, drive traffic that looks like real
traffic, then read:

| Question | Where |
|---|---|
| What does a typical call consume? | `GET /v1/usage/events` — per-request rows carrying fuel consumed and request/response bytes |
| How wide is the spread? | `GET /v1/usage` — p50/p95/p99 latency per bucket. A route whose p99 is fifty times its p50 needs a very different `max` from one whose p99 is double |
| What did one specific call do? | `GET /v1/usage/requests/{request_id}` — every hop it touched, which is how you find the call that cost far more than the rest |

Once it IS priced, each settled charge appears as its own usage event carrying the
amount, so the same two endpoints answer "what am I actually earning per call?"
and "which calls hit the `max`?" — the second being the signal that your ceiling
is truncating real charges rather than catching runaways.

## Fleet views (`GET /v1/fleet/*`)

The owner's whole fleet in four reads, the ones a console draws. Per-owner
numbers come from a snapshot kept for about a minute (`computed_at`), so
two reads in that minute agree; latency is in milliseconds. All four take
`window`: `24h` (default; the 24 hours ending now), `7d` or `30d` (whole
UTC days including today). Any other value is a 400.

| Endpoint | Parameters beyond `window` | Returns |
|---|---|---|
| `GET /v1/fleet/summary` | none | Headline numbers, the hourly series, your five busiest modules and the rest, attention items, deploy markers, per-day counts, the health list, what you publish. |
| `GET /v1/fleet/instances` | `sort` (`name`, `requests` (default), `failed`, `refused`, `p95`, `size`, `deployed`, `behind`), `dir` (`asc` or `desc`; `asc` for `name`, else `desc`), `module`, `module_owner`, `q` (service ids starting with this, literal, case-sensitive), `limit` (default 50, max 200), `cursor` | One page of your active instances with `total` (rows matching `module`, `module_owner` and `q`) and `next_cursor`. |
| `GET /v1/fleet/modules` | `limit` (default 50, max 200), `cursor` | One page of the modules you run, or ran in the window, by requests descending. |
| `GET /v1/fleet/series` | `services` (**required**: 1 to 10 comma-separated service ids), `shape` (`points`, the default, or `columns`), with `shape=columns`: `group` (hours per count column: 1, 6 or 24) and `p95_first` (how many of the ids carry their hourly p95) | Each named instance's hours with traffic, the points a chart draws; `columns` returns arrays on the window's hours instead, a fraction of the size. |

- **A row's id.** An instance row is keyed by its `service_id`, the value
  `series` takes in `services` and a live `fleet_live` socket takes in
  `instances`. A module row has no single id field: it is the pair
  `module_owner` + `module_name` (two publishers can share a name), and a
  module with exactly one active instance names it in `only_instance`
  (`service_id`, `deployment_shape`).
- **Paging.** Follow `next_cursor` until it is `null`, sending the same
  `window`, `sort`, `dir` and filters with it; a cursor reused with other
  ones, or on another route, is a 400. A row's sort value can change
  between two pages while the snapshot is recomputed, so a row can move past
  the cursor or back behind it.
- **Isolation.** Owner-only, like every read here. In `series`, an id with no
  traffic, unknown, or not yours has no points; nothing tells them apart.
- **Meta.** Responses say `as_of` (what the usage rollups are current to)
  and `backfill_pending` (older history still being rolled up): numbers
  before `as_of` are final, later ones are still landing. The platform's
  `/openapi.json` has every field.

## MCP tools

The same data is reachable as MCP tools for LLM clients — same identity,
same owner-scoping:

| Tool | Maps to |
|---|---|
| `list_my_services` | your active services, a page at a time (`limit` default 100, ≤ 500; pass the returned `next_cursor` back as `cursor`) |
| `query_my_usage` | one service's usage series over a time window |
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

// A snapshot of recent lines, oldest-first, on subscribe. It can come
// again later (your connection fell behind, or the stream was reopened):
// each one REPLACES what you show, so keep a list and swap it.
let shown = [];
socket.on("logs:snapshot", (lines) => {
  shown = lines;
});

// Then live lines as they're emitted, appended after the snapshot:
socket.on("logs", (line) => {
  // { ts_ms, level, msg, request_id? }
  shown.push(line);
});

// Stop receiving:
socket.emit("unsubscribe", { kind: "logs", service_id: "notes" });
```

The subscribe envelope is `{ kind, ... }`. The kinds are `logs` (above),
`service_live` and `fleet_live` (your usage, live: next section) and
`service` (a service's own channels: below). They share the one
`subscribe`/`unsubscribe` envelope, so write clients to switch on `kind`
rather than assuming logs are the only stream. Every ack is `{ ok: true, ... }`
or `{ ok: false, error }`; read `error` rather than retrying blindly.

## Live usage (`service_live`, `fleet_live`)

The same `/v1/stream` connection streams **your usage as it lands**. Every
host serving your services flushes its usage about every 10 s, and the
totals reach your socket within a couple of seconds of that (a very large
fleet's busiest rows can take a flush or two longer), so a live dashboard
needs no polling. Both kinds are yours only: the owner is always
your token's, never anything in the payload.

| Subscribe with | Event | What it carries |
|---|---|---|
| `{ kind: "service_live", service_id }` | `service_live` | One service's hourly rows for the current hour and the two before, in `GET /v1/usage`'s row shape, as **absolute totals**. |
| `{ kind: "fleet_live", window }`, `window` = `"24h"`, `"7d"` or `"30d"` | `fleet_live` | Your fleet over that window, in the shapes of the fleet views (`GET /v1/fleet/summary`, `/v1/fleet/instances`, `/v1/fleet/modules`, `/v1/fleet/series`, all in the platform's `/openapi.json`): the headline numbers, the current hour's point, attention items, two rankings, and the rows **your socket declares** it shows. |

Every event also carries `status` (`"live"`, or `"paused"` with a `reason`)
and `updated_at`.

```js
// One service, live. Rows are totals: keep the larger value per
// (hour_bucket, kind). Never add them.
socket.emit("subscribe", { kind: "service_live", service_id: "notes" }, (ack) => {
  if (!ack.ok) console.warn(ack.error);
});
socket.on("service_live", (e) => {
  // { service_id, status, reason, updated_at, rows: [{ hour_bucket, kind, event_count, ... }] }
  for (const row of e.rows) {
    const key = `${row.hour_bucket}|${row.kind}`;
    const had = rows.get(key);
    if (!had || row.event_count >= had.event_count) rows.set(key, row);
  }
});

// The fleet, live: name the instance and module rows on screen.
socket.emit("subscribe", {
  kind: "fleet_live",
  window: "24h",
  instances: ["notes", "billing"],
  modules: [{ module_owner: "alice", module_name: "notes" }],
}, (ack) => { /* { ok: true, room } */ });
socket.on("fleet_live", (e) => {
  // The same for every socket: e.headline, e.series_point, e.attention,
  // e.busiest (service ids), e.top_modules ({ module_owner, module_name }).
  // Yours alone: e.instances, e.modules (whole rows: replace by id),
  // e.instance_points, e.module_points (the current hour's points).
});

// The page changed: declare its rows. Your new scope's rows arrive at once.
socket.emit("fleet_live_interest", { window: "24h", instances: nextPageIds, modules: [] }, (ack) => {});
```

- **A `fleet_live` event holds your scope, not your whole fleet.** Your
  scope is the rows you declared (at most 200 instances and 200 modules, on
  the subscribe or with `fleet_live_interest`) plus the platform's rankings:
  `busiest`, up to 10 of your busiest services by requests, and
  `top_modules`, up to 5 modules. A row in scope is sent when it changed
  since your socket's last event, and whole, whatever it equals, when it
  newly entered your scope: your first event and the answer to each
  `fleet_live_interest` carry every row and point of your scope. An event
  is therefore small whatever your fleet's size; declare what you show, or
  you get nothing for it.
- **When events come.** A `fleet_live` socket's first event follows its
  ack (for a window nobody was watching, it comes with the first push). A
  `service_live` socket gets the service's rows on joining, or nothing if
  the service is idle. After that, an event whenever values in scope change,
  on average at most one every 2 s per window.
- **Events carry changes, not state.** Read the REST view first, then patch
  it; after a reconnect, read it again and resubscribe (the subscribe can
  carry your rows again).
- **`"paused"` is late, not wrong.** `backend_down`, `rollups_behind`,
  `host_capacity` or `disabled`: keep showing what you have, and the REST
  views still answer. Show the pause; don't hide it.
- **Isolation.** An anonymous socket is refused `not found`. A
  `service_live` id you do not have is accepted and never fires, exactly
  like an idle service of yours, so it reveals nothing about which exist.
- **Refusals to handle:** `too many ids` (over 200 in a list; nothing
  changed), `bad window`, `subscribe rate exceeded` (a `fleet_live_interest`
  counts against the same budget as a subscribe, so debounce it),
  `channel at capacity` (too many of your sockets on one window at once),
  `live rooms at capacity`.

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

## Your file storage

`GET /v1/services/{service_id}/files` reports per-collection file counts and
bytes for one of your services, with **stored** and **reserved** kept apart.

Reserved bytes are held by uploads that were started and never completed. They
count against your quota and serve nothing — so a bill that looks too high is
often reserved bytes, not files you can find. The platform expires them on its
own; deleting a file releases its bytes immediately.

Files bill the **storage**, **egress** and **requests** dimensions you already
have. There is no separate files dimension, and a file read costs no compute.

## Red flags

| Thought | Reality |
|---------|---------|
| "I can see usage across all services on the host." | Owner-scoped only. You see your own services; others' are invisible (404, same as not-found). |
| "The usage summary is only quantities; I'll multiply by the prices myself." | Read `cost` on the summary's first page for the current month: `billed_usd` is what was actually charged, after allowances and your rate. Your own arithmetic is notional at best. |
| "My service returns 503 to everyone; the platform is down." | Check `daily_credit.paused` on `GET /v1/account` first. A paused account looks exactly like a busy host to callers, on purpose, and ends at 00:00 UTC. |
| "I'll pay for priced routes with the daily credit." | The credit pays platform usage and storage only. A priced route is paid from your prepaid balance. |
| "Logs are a permanent record I can query for last month." | Recent-tail only — ~1000 most-recent lines per service, capped at 2 KiB each. For durable history ship to an external sink via `outbound_http`. |
| "My `log::info!` calls will show up in the logs endpoint." | Only if the manifest grants `[capabilities] logging = true`. Without it the macros are inert. |
| "I'll log inside a tight loop to trace everything." | Emission is rate-limited (~50/s, burst ~200); excess is dropped. Log decisions/events, not every iteration. |
| "I need to build a request-tracing system to follow a call across services." | Grab `x-boogy-request-id` from the response and `GET /v1/usage/requests/{id}` — the platform already correlates every hop. |
| "To find failures or slow requests, I'll page through `/v1/usage/events` and filter them myself." | Ask the server: `class`, `outcome`, `caller`, `path_prefix`, `min_wall_ms`. A call reads a bounded window, so a short page with a `next_cursor` means "keep going", not "no more", and `searched_until` says how far back it looked. |
| "An empty events page means there are none." | With a `next_cursor` it means none in the events inspected (back to `searched_until`). Follow the cursor, or report the time you searched to. |
| "Streaming logs needs a custom WebSocket endpoint in my service." | The `/v1/stream` Socket.IO gateway streams owner logs already — connect a client, no service code. |
| "I'll only handle a `logs` event from the stream." | Also handle `logs:snapshot` (the oldest-first batch, which replaces what you show each time it comes) and switch on `kind` — more channel kinds use the same envelope. |
| "I'll poll `/v1/usage` every few seconds for a live dashboard." | Subscribe to `service_live` or `fleet_live` on `/v1/stream`: about every 10 s, no polling. |
| "I'll add each pushed row to my running total." | Pushed rows are absolute totals. Keep the larger value per hour and kind; adding double counts. |
| "A `fleet_live` event lists every instance that changed." | Only the rows your socket declared, plus the `busiest` and `top_modules` rankings. Declare your page with `fleet_live_interest`. |
