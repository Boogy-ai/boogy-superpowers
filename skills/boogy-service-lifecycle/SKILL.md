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

**The export window closes at the DELETE call itself, not when the
teardown finishes.** The route is dropped the instant the request is
accepted, so the service can no longer serve its own export endpoint even
though the deletion is still in progress underneath.

## Removal is accepted, then completed

`DELETE` answers **202** with `{"state": "deleting"}`. It does not mean
"deleted" — it means the platform has accepted the removal and started
it:

- The route is gone immediately; callers see the service as absent from
  that moment.
- Nothing is destroyed yet. The deployment record, the stored data and
  any OAuth connections survive the call, because tearing those down
  needs the live deployment to still be there.
- The platform finishes in the background: it revokes each OAuth grant at
  its provider, deleting that grant's row only once the provider has
  actually settled it, and performs the real delete when none remain. A
  provider outage means a retry later, not a stranded grant.
- **Re-creating a service with the same id is refused (409) until the
  teardown finishes.** That is the one user-visible consequence worth
  planning around: if you are replacing a service by removing and
  re-adding it under the same id, don't — upgrade in place (see below).
- **You can see it directly, not only by being refused:** the service
  stays in `boogy list` / `GET /v1/services` with `"deleting": true` and
  a `delete_requested_at`, until the teardown finishes and it disappears.

You do not have to wait for anything or poll anything; the teardown has
no failure mode that needs your attention. The one case that surfaces to
you is a provider that refuses to revoke indefinitely: rather than leave
the service undeletable, the platform deletes it anyway and writes
`service.deleted_with_unrevoked_grants` to your audit tail, carrying how
many grants were left live. When that row appears, the remedy is the
provider's own account page — nothing on the platform can reach those
grants any more. (See `boogy:boogy-oauth-connections`.)

## Old versions clean themselves up

Every redeploy leaves the previous module version published and serving as a
rollback target. That is deliberate and bounded: once the version leaves the
platform's rollback retention window, its deployment history is pruned, the
module version is deleted and its wasm is reclaimed — automatically.

Two consequences worth knowing:

* **You do not need to delete old versions to reclaim space.** Deleting one
  *while* it is still a rollback target is refused (`409`, with a `reason` of
  `active` or `retained`), and deleting one after it has aged out is
  unnecessary.
* **Reclamation is irreversible and takes the archived manifest with it.** A
  pruned deployment row carried the full manifest of that deploy, which is a
  recovery path if a wasm blob ever goes missing. The ACTIVE deployment is
  never pruned, so what is running is always recoverable.

If you need a version gone before the window expires, `DELETE
/v1/modules/{name}/{version}?force=true` gives up rollback to it. It cannot
remove a version a service is actively serving.


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
| "The DELETE returned, so the service is gone — I can re-add the id now." | It returned **202**: accepted, not finished. The route is gone but the teardown is still running, and re-creating the same id is refused (409) until it completes. |
| "I'll unbind the OAuth client secret first, then delete the service." | Backwards. The platform needs that secret to authenticate each revoke call; removing it first means every revoke fails, the teardown waits out its give-up bound, and the grants are stranded at the provider. Delete the service, let it finish, then remove the secret. |
| "No need to export — we can always recover it." | There is no read/recover/export path after removal. Export while the service is still deployed. |
| "We're replacing it, so remove the old one and add the new." | If it's the same service, upgrade in place — re-add ≠ upgrade and strands the old data. |
| "Set `allowed_origins = []` to lock it down." | Empty `allowed_origins` fails manifest validation. Narrow the list or ship a `410 Gone` stub instead. |
