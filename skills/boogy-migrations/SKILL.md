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

```rust
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

`.not_null()` on an added column is enforced **in both directions**: an
explicitly written null is rejected on any write, and *omitting* the column is
rejected on a write that CREATES a row (an insert, or the row-creating arm of
an upsert). On an update, omission still means "leave it alone".

**So pair `.not_null()` with `.default(...)`, as above, unless you have
audited every insert path.** A default exempts the column from the omission
check — the store materializes it into the row — so existing rows, partial
writes, and the insert arm of an `upsert_increment` all resolve to a real
value. Adding a bare `.not_null()` column to a live table is a breaking change
to every insert that does not yet mention it.

`MigrationCtx` (`m`) gives schema ops `add_column` / `rename_column` /
`drop_column` / `create_table` / `create_index` / `drop_index` /
`drop_table` (**destructive** — see *Resetting a table* below), plus
backfill ops `find_rows` / `count` / `insert` / `update_where` /
`delete_where`. Schema ops are **introspection-idempotent** (check the
live schema, no-op if already applied) — a migration that crashed
partway re-runs safely; no `IF NOT EXISTS` strings. There is **no SQL**
and no enqueue/jobs method on `MigrationCtx`.

**Every backfill op runs inside a transaction** — the runner wraps each
migration in one store tx — so a backfill read that scans puts the whole
table in that transaction's read set. A `find_rows`, `update_where` or
`delete_where` whose filters name no column that **leads** an index
scans. That is usually acceptable for a
migration (it is a maintenance operation, and the whole table is often
the point), but it counts against the ~5 s / 10 MB envelope — which is
exactly why the batched pattern below exists.
`boogy:boogy-transactions` has the detail.

**Changing a default is a one-line migration, not a backfill.** `add_column` on
a column that already exists updates its default, provided the column type and
nullability match exactly — any other difference is a type/nullability conflict
and is still refused (409). It rewrites **no rows**: rows written since the
column appeared keep the value recorded at write time, and only rows that still
have no value for it resolve against the new default on read. A row acquires a
value the first time anything **updates** it, and every row does when the column
is **indexed** (see below) — so a default change reaches a shrinking set. If
every existing row must hold the new value, that is the two-step backfill below,
not a default.

**Re-adding a name you dropped gives you a genuinely new column.**
`drop_column` hides a column; it does not reclaim its storage, and rows written
before the drop keep the old value in a slot nothing reads any more. A later
`add_column` with the same name — at any type — is therefore a *different*
column: it starts empty, so pre-existing rows resolve against its default (or
read null), and the old values are **not** recovered. That is usually what you
want, and it is the only supported way to change a column's type. What you must
not assume is that the old data comes back with the name.

**A migration cannot add a `#[counter]` column.** `add_column` **refuses**
one (a `ConstraintViolation`) — a counter's value lives in a per-row sidecar
cell that only an insert seeds, so flipping the flag on a populated table
would make every pre-existing row read as `0`. Establishing that invariant
needs a backfill, which `add_column` is not. A counter must be declared when
the table is **created**. To convert a live column: create a **new** table with
`#[counter]` declared up front and migrate the values across (drop +
recreate, below, if the table is disposable). See
`boogy:boogy-data-modeling`.

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

**The sentinel filter is index-backed and complete.** A row that holds a column's
default — whether the write omitted the column or the row predates it — is
findable by an equality or range query on that value, through an index, exactly
like a row that was written with it explicitly. Index the sentinel column and the
sweep seeks instead of scanning, which is what keeps each batch inside the
transaction envelope.

**Indexing a column fixes its default for the rows that predate it.** Building an
index reads every row, and a value an index covers has to be stored rather than
resolved per read — so rows that had no value for that column acquire one, the
default in force at the moment the index is built. After that they behave like
any row written with the column present: a later `add_column` changing the
default does **not** reach them. So order the two operations deliberately —
set the default you want *before* adding the index, or plan on a sweep.

**That makes step 1 + the index O(rows), and it can be refused.** Storing the
column on rows that predate it rewrites those rows, and the whole index build is
one transaction — so on a large table `create_index` fails with a 409 naming the
index and saying the table is too large to index in one go. It is deterministic:
retrying does the same work. Two ways out, both step 2 done first: write the
column explicitly on the existing rows in batches, **then** add the index; or
index the column at `create_table` time on tables you expect to grow. A table
whose rows already hold the column is never affected — indexing it rewrites
nothing.

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
| "I'll add `#[counter]` to the model and migrate the column." | `add_column` refuses a counter column, and the derive has already stopped writing the field — so the migration fails on a model that no longer matches the table. Declare counters at table-creation time; convert via a new table. |
| "I'll add the `not_null` column now and backfill the inserts later." | Omission is refused on a row-creating write, so every insert that doesn't yet name the column starts failing with a 409 the moment the migration lands. Add `.default(...)` in the same step. |
| "`col(...).unique()` makes the migrated column unique." | It enforces nothing and is deprecated — `add_column` creates no index, and it couldn't: every existing row would take the same value. Three steps: add the column, backfill distinct values, then `create_index` with `unique: true`. |

## Integration

← `boogy:boogy-data-modeling` / `boogy:boogy-access-patterns` (the
schema and queries you're evolving; prefer declaring an access-pattern
verb, which derives the index). ↔ `boogy:boogy-transactions` — the
migration transaction is a **separate** surface from the handler-facing
`tx` (DDL-oriented, returns `Result<(), String>`, no peer enrollment).
→ deploying: a deploy/redeploy is what triggers pending migrations.
