---
name: planning-boogy-work
description: Use when turning an approved Boogy design into an ordered implementation plan — before writing service code, or when work has drifted and needs re-sequencing
---

# Planning Boogy work

A plan turns an approved design into an ordered list of tasks a competent
engineer can execute without asking you what you meant.

**Do not plan unapproved work.** If the design has not been agreed, stop and use
`boogy:designing-boogy-services`. A plan for a design nobody accepted is a
confident answer to a question nobody asked.

## Map the files first

Before any task, list what gets created and modified and what each file is
responsible for. This is where the decomposition is decided; task boundaries
fall out of it.

## Right-size the tasks

A task is the smallest unit that carries its own test cycle and is worth a fresh
reviewer's gate. Fold setup, configuration and documentation into the task whose
deliverable needs them. **Split only where a reviewer could reject one task
while approving its neighbour.** Each task ends with something independently
testable.

Each step inside a task is ONE action, two to five minutes: write the failing
test; run it and watch it fail; write the minimal code; run it and watch it
pass; commit.

## No placeholders

These are plan failures, not style preferences:

- "TBD", "TODO", "handle edge cases", "add validation"
- "Write tests for the above" with no test shown
- "Similar to Task 3" — repeat the code; the engineer may read tasks out of order
- A type, function or route named in one task and defined in none

## The six requirements that make this a BOOGY plan

A generic plan skill does not know how this platform fails. These are not
style; each one is a defect class.

### 1. Task 1 is the manifest

Capabilities, ingress mode and routes are **declarations**. A plan that reaches
them at Task 6 has already built five tasks on guesses about what the service is
allowed to do.

### 2. Every task names the capabilities it needs

If a task needs `outbound_http` and the manifest grants `store` and `auth`, that
is a plan error you can see now, rather than a `CapabilityDenied` you discover
at runtime. Capabilities are deny-by-default: absence is refusal, not an oversight.

### 3. Every store read names its access pattern

A read is either served by a declared access pattern, or it is a scan. Both are
allowed; only one of them is allowed **silently**. Write which, per task.

An unindexed equality read is not a slow query — it is a full table scan whose
cost grows with the tenant's data, and it will pass every test you write against
a small fixture.

### 4. No task may say "write a failing test" for the service crate

The service crate is a `cdylib` with generated bindings. **It has no
`cargo test` target** — the generated symbols do not host-link, so a test binary
fails to build. A plan that instructs it wastes an hour before the engineer
discovers why.

RED/GREEN lives in two places instead:

- **Pure logic** — ranking, parsing, validation, money math — goes in a sibling
  plain-Rust library crate that DOES have tests. Design for this deliberately;
  it is the only layer where ordinary TDD works.
- **Glue** — routing, auth, store calls — is proven by deploying and exercising
  the live URL. The RED step is a request that returns the wrong thing; the
  GREEN step is the same request after the fix.

### 5. Every task ends with the same two commands

```
boogy check
cargo build --target wasm32-wasip2 --release
```

`boogy check` is the conventions gate — raw schema instead of a declared model,
untyped response bodies, multi-write handlers with no transaction, a counter read
at snapshot and written in the same transaction. It is offline, fast, and
belongs in the edit loop rather than before shipping.

Neither command proves the service works. See `boogy:testing-boogy-services`.

### 6. Every task names the skills to invoke before starting it

A task is executed by someone holding only the task text — often a fresh
subagent, with no memory of this plan being written and no reason to believe a
skill exists. A skill named in the task gets invoked; a skill named once in the
plan's preamble does not.

And the plan is a **summary** of those skills — the one thing they forbid
building from. Prose loses the error names, the refusal codes and the red flags,
so a task written from the plan alone re-derives a rule the skill states
outright, and re-derives it wrong.

Name them where you name capabilities:

```
**Skills:** boogy:boogy-auth, boogy:boogy-access-patterns
```

## A task, written out

```markdown
### Task 3: POST /rooms creates a room

**Files:**
- Modify: `src/lib.rs` (router + handler)
- Modify: `src/models.rs` (the Room model)
- Test: `crates/roomlogic/src/slug.rs` (sibling crate — slug validation)

**Skills:** `boogy:boogy-rest-apis`, `boogy:boogy-data-modeling`,
`boogy:boogy-access-patterns` — invoke before starting.
**Capabilities:** `store`, `auth`  (granted in Task 1)
**Access pattern:** `lookup_by = "slug"` — the uniqueness check is a point read,
not a scan.

- [ ] Write the failing test for slug validation in the sibling crate
- [ ] Run it; watch it fail
- [ ] Implement the validator
- [ ] Run it; watch it pass
- [ ] Add the model field and the handler
- [ ] `boogy check && cargo build --target wasm32-wasip2 --release`
- [ ] Deploy and exercise: `POST /rooms` returns 201 with the room id
- [ ] Commit
```

Note what is NOT there: no unit test for the handler, because the service crate
cannot host one; and the access pattern is stated, so a reviewer can see the read
is a point lookup without reading the code.

## 🚩 RED FLAGS

| Thought | Reality |
|---|---|
| "I'll write the manifest once I know what I need." | You already know: the design said so. A manifest written last is a manifest that documents whatever you happened to build. |
| "I'll add a unit test for the handler." | The service crate has no test target. Extract the logic or exercise it deployed. |
| "The query is fine, it's fast locally." | Locally you have twelve rows. State the access pattern or state that it is a scan. |
| "I'll check conventions before I ship." | `boogy check` is seconds. Running it once at the end means finding ten things at once, in code you have stopped thinking about. |
| "It builds, so the task is done." | A build proves it compiles. Only exercising the deployed URL proves it serves. |
| "I read the skills while writing the plan." | Whoever executes Task 7 did not, and cannot tell from the task that a skill exists. A skill not named in the task is a skill not invoked — and the plan is the summary it told you not to build from. |

## See also

- `boogy:designing-boogy-services` — the design this plan implements
- `boogy:testing-boogy-services` — RED/GREEN and what "done" requires
- `boogy:boogy-access-patterns` — declaring the reads named in requirement 3
- `boogy:boogy-capability-limits` — what each capability grants

---

Adapted from the MIT-licensed `writing-plans` skill (Jesse Vincent, 2025).
**What changed and why:** the six requirements above. A generic plan skill does
not know that the service crate cannot host a unit test, that capabilities are
deny-by-default declarations, that an undeclared read becomes a full table scan
every small-fixture test will pass, or that the plan will be executed by someone
who never read the skills it was compiled from.
