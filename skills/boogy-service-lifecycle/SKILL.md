---
name: boogy-service-lifecycle
description: Use when retiring, deprecating, replacing, or removing a deployed Boogy service — especially when other services call it, or when its data matters
---

# Service lifecycle on Boogy

Removing a service is a one-way door for its callers and its data. The
order of operations matters more than the removal command.

## Data-fate truth (read this first)

**Removing a service deletes its route and its deployment record — it
does NOT delete the service's stored data.** The data is left intact but
**unreachable**: there is no route to reach it and **no user-facing or
admin API to read, export, or recover it afterward.**

So: **export the data BEFORE you remove the service.** Stream it out
while the service is still deployed (e.g. an export endpoint or job using
`for_each_batch` for bounded-memory streaming) to wherever you need it.
"We can always recover it later" is false — there is no recovery path
once the route is gone.

## Retirement sequence

1. **Find the callers first.** Identify every service that calls this
   one (`peer::fetch` to its workload URI) and any external clients.
   Announce and coordinate the cutover *before* touching anything.
   (See `boogy:boogy-mesh-architecture` for caller/peer routing.)
2. **Export the data** while the service is live (previous section).
3. **Harden callers for the transition.** Once removed, a caller's
   `peer::fetch` fails with `target-not-found`; if you instead narrow
   ingress to drop a caller, that caller gets `denied`. Both are real,
   discriminable error variants — callers should handle them, not crash.
4. **Run a deprecation window** before the hard removal: either narrow
   `allowed_origins` to cut off migrated callers progressively, or
   replace the handler with a `410 Gone` stub so callers get a clear
   signal instead of a hard route loss. (Do NOT try an empty
   `allowed_origins` — that fails manifest validation at deploy.)
5. **Remove** via the admin DELETE / CLI remove once callers are off,
   and confirm migration. (See `boogy:deploying-boogy-services` for the
   command surface.)

## Replace vs. upgrade — one-liner

If the new service is the *same* service with new code, **upgrade in
place** (re-deploy the new version; the route swaps atomically and a
rollback path exists) — don't remove + re-add, which strands data and
breaks callers. Only do a true remove when the service is genuinely
going away.

## Platform API reference

The platform API is self-describing: `GET <host>/openapi.json` returns
an OpenAPI 3.1 document covering the full deploy lifecycle (`/_agents/*`,
`/_admin/*`, `/v1/*`) — anonymous fetch OK, no token required.

## What does NOT exist yet (be honest)

- **No user-initiated data erasure / store-wipe API.** Removal does not
  erase stored data; nothing else exposes a "delete my data" operation.
  If erasure is a compliance requirement, surface that gap explicitly —
  don't pretend removal satisfies it.
- **No automatic caller migration.** Callers must be updated by their
  owners; the platform won't redirect them.

## Red flags

| Thought | Reality |
|---------|---------|
| "Remove it now, tell the other teams afterward." | The moment the route is gone, callers get `target-not-found` — a live outage. Notify and migrate callers first. |
| "Removal deletes the data, so we're clean." | False. Removal leaves the data intact but unreachable. Export before removing; there is no recovery API. |
| "No need to export — we can always recover it." | There is no read/recover/export path after removal. Export while the service is still deployed. |
| "We're replacing it, so remove the old one and add the new." | If it's the same service, upgrade in place — re-add ≠ upgrade and strands the old data. |
| "Set `allowed_origins = []` to lock it down." | Empty `allowed_origins` fails manifest validation. Narrow the list or ship a `410 Gone` stub instead. |
