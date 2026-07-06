---
name: boogy-migrations
description: Use when changing the schema of a deployed Boogy service — adding columns or indexes, or backfilling data
---

# Migrating a deployed Boogy schema

`init_tables` only *creates missing* tables and indexes — it never
alters a table already in production. Once deployed, schema changes go
through versioned **migrations**.

## Iron Law 1 — append-only

**Never edit or delete a published migration.** The runner records
applied versions in a per-service `__boogy_schema_version` table and
skips any migration it has already run — **by version number alone; no
hash of the body.** So editing a shipped migration does *nothing* on
any store that already ran it: the version row exists, the edited
closure never re-runs, existing rows keep their old values. Only a
*fresh* deployment runs the edited body — so an edit produces silent
**divergence** between old and new deployments, never a fix. To
correct a mistake, add a **new higher-version migration** that fixes
forward.

## Iron Law 2 — one migration fits one transaction envelope

Each migration runs as **one store transaction** (schema change +
backfill + version-row write commit or roll back together; never
half-applied), bounded by the store's **~5s / 10MB envelope**. A
backfill that rewrites a large table blows the envelope and rolls back
*perpetually*. **Split big backfills out** (two-step recipe below).

## Anatomy

Declare migrations in `init_tables`, after the `create_table_from`
calls for the tables they touch:

```rust boogy-snippet
use boogy_sdk::store::{col, ColType, Val};

fn init_tables() {
    migrations(&[
        migration(1, "add_priority", |m| {
            m.add_column("tasks",
                &col("priority", ColType::Integer).not_null().default(Val::Integer(0)))?;
            Ok(())
        }),
        migration(2, "index_priority", |m| {
            m.create_index("tasks", &store::IndexDef {
                name: "by_priority".into(), columns: vec!["priority".into()],
                unique: false, covering: false,
            })?;
            Ok(())
        }),
    ]).expect("migrations failed");
}
```

`MigrationCtx` (`m`) gives schema ops `add_column` / `rename_column` /
`drop_column` / `create_table` / `create_index` / `drop_index` /
`drop_table` (**destructive** — see *Resetting a table* below), plus
backfill ops `find_rows` / `count` / `insert` / `update_where` /
`delete_where`. Schema ops are **introspection-idempotent** (check the
live schema, no-op if already applied) — a migration that crashed
partway re-runs safely; no `IF NOT EXISTS` strings. There is **no SQL**
and no enqueue/jobs method on `MigrationCtx`.

## When migrations run

`init_tables` runs on **every request** (no-op fast-path = one
version-table read) and during deploy-time verification. Pending
migrations apply lazily on the first request after deploy; a migration
that panics fails verification and rolls the deploy back.

## The two-step backfill recipe (large tables)

1. **Add the column with a DDL-level default now**
   (`add_column(... .default(...))`). This writes only metadata —
   **O(1)** regardless of row count; the default is materialized on
   read, so existing rows read it immediately. No per-row cost, no
   envelope pressure.
2. **Backfill derived values as a separate idempotent sweep** —
   *outside* any one migration tx. Filter on the **sentinel** (the
   default, e.g. `priority == 0`) and stream batches with
   `for_each_batch`, committing each batch independently. The sentinel
   filter makes it **retry-resumable**: a re-run only re-touches
   not-yet-backfilled rows. New writes set the real value going forward.

Do **not** enqueue the backfill from inside a migration —
`MigrationCtx` has no enqueue. Run the sweep from a background job or
first-request logic.

## Resetting a table (drop + recreate)

Some changes can't be applied in place — e.g. adding a **unique** index to
an already-populated table (existing rows collide), which traps
`create_table_from`/`create_model` at init. When you must start the table
over, `drop_table` removes it entirely — **all rows, every index, its
counter, and its catalog entry, irreversibly** — then recreate it fresh.
Two rules make this work:

**1. Drop *and* recreate inside the migration.** Don't lean on
`init_tables`' `create_model` to rebuild it: `init_tables` runs the
`create_model`/`create_table_from` calls *before* `migrations()`, so by the
time a drop migration runs the table was already (re)created this pass, and
the drop is version-gated to run once. Recreate explicitly — the migration
tx sees its own pending drop, so the recreate lands on a clean slate:

```rust
// one entry in your `migrations(&[ … ])` list in init_tables:
migration(3, "reset_events", |m| {
    m.drop_table("events")?;            // clear the incompatible table
    m.create_table(&Event::schema())?;  // rebuild fresh from the model (columns + indexes)
    Ok(())                              // the new unique index is now safe — empty table
})
```

**2. Removing a *service* does not wipe its store.** Deleting or
redeploying a service leaves its tables intact; a table reset is an
in-migration `drop_table`, never an ops action.

`drop_table` is idempotent (no-op if the table is already gone) and
**irreversible** — treat it like `drop_column`: fix-forward only, never
edited once shipped (Iron Law 1).

## Common Mistakes

| Thought | Reality |
|---------|---------|
| "Just edit migration 3's bad default." | Version-skip means it never re-runs; existing data unchanged. Add a higher-version fix-forward migration. |
| "One migration backfills the whole 2M-row table." | Blows the ~5s/10MB envelope → perpetual rollback. Two-step: DDL default + sentinel-filtered batch sweep. |
| "Add the index by editing `init_tables` / `create_table_from`." | That only creates *missing* objects — it won't touch the deployed table. Add the index via a migration. |
| "`drop_table` alone resets it — `init_tables` recreates it." | `migrations()` runs *after* `create_model`, so recreate *inside* the migration. Drop + recreate together. |
| "Delete the service to wipe its data." | Removing a service leaves its store intact. Reset a table with an in-migration `drop_table`. |

## Integration

← `boogy:boogy-data-modeling` / `boogy:boogy-access-patterns` (the
schema and queries you're evolving; prefer declaring an access-pattern
verb, which derives the index). ↔ `boogy:boogy-transactions` — the
migration transaction is a **separate** surface from the handler-facing
`tx` (DDL-oriented, returns `Result<(), String>`, no peer enrollment).
→ deploying: a deploy/redeploy is what triggers pending migrations.
