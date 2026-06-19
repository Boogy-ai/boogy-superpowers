---
name: testing-boogy-services
description: Use when testing a Boogy service or before claiming one works
---

# Testing a Boogy service

A green build and passing unit tests do not mean a Boogy service works.
The wiring, the store writes, and the authorization boundary only exist
once the service is deployed and answering real requests. Test in three
layers and claim done only after the third.

## The test pyramid for Boogy

**Layer 1 — pure logic → sibling plain-Rust crate.** Ranking, scoring,
parsing, validation, bucketing: extract it BY DESIGN into a sibling
plain-Rust library crate with **no `boogy-sdk` / `wit-bindgen` deps**
(default `rlib`, not `cdylib`). The service crate depends on it. This
crate compiles for the host, so `cargo test` runs its `#[cfg(test)]`
tests natively. Cover boundaries (`>=` vs `>`), monotonicity, and
NaN/negative/empty guards here — and **feed garbage to every parser /
decoder and assert `Err`, never a panic** (malformed/oversized/wrong-type
input). For any guardrail, cap, or validation logic, ambiguous or
unparseable input must **fail closed** (reject), never silently allow.

**Layer 2 — the wasm crate is glue. Keep it thin; do NOT unit-test it.**
The service crate is `[lib] crate-type = ["cdylib"]` with WIT bindings.
It has **no `cargo test` target** — the generated WIT symbols don't
host-link, so building a test variant fails at link time. There is no
local host to call into, and request/param types are host-constructed:
**any "test constructor" you reach for (e.g. building a request or
params object yourself) does not exist and will not compile.** Don't
write `#[cfg(test)]` integration tests inside this crate. Move logic
down to Layer 1; verify everything else at Layer 3.

**Layer 3 — the deployed service → real requests.** Build, deploy, and
hit the running service with `curl` or an API client. This IS the
integration layer; there is no local substitute. Cover, per endpoint:

- **Happy path** — expected status + response shape.
- **Authz negatives** (non-negotiable): no credential on a protected
  route → **401**; a credential for a *different* principal asking for
  someone else's resource → **404** (existence-mask — missing and
  not-yours look identical; it is NOT 403).
- **One error-shape check** — malformed body / bad input returns the
  documented error, not a 500.

**Adversarial cases are first-class — and matter MOST for the service that
doesn't *look* risky** (the attacker doesn't care that it's "just a notes
app"; the un-tested hole ships in the boring service). Beyond the authz
negatives above, cover, where they apply:

- **Identity can't be forged from the body.** A request whose body carries
  an `owner` / `author` / `principal` / `actor` field naming someone else is
  IGNORED — the resource stays owned/authorized by the *attested caller*. A
  404 on a cross-principal `GET` does **not** prove a `POST`/`PUT` body can't
  set ownership to another principal; test that directly. (The
  deployed-request proof of authorize-on-the-attested-principal.)
- **Guardrail / limit bypass.** If the service enforces a cap, quota,
  allowlist, or state machine, attack it: exactly-at vs over the limit;
  concurrent / duplicate requests racing a capped or single-use resource; a
  disallowed transition. The limit must hold under the race, and a *rejected*
  request must leave **no partial side effect** — nothing written, nothing
  sent/signed/broadcast. **Enumerate every path that performs the sensitive
  action** (sign, send, broadcast, spend) and confirm they ALL gate — a green
  test on `/send` does **not** cover a `/sign` that skips the same check.
  Probe what the cap *doesn't* count: a cap on the transfer **value** but not
  the **fee** is a drain (fees are often caller/node-influenced — bound
  `value + fee`); a cap compared as a bare integer **across units/denoms**
  collapses different assets into one bucket.
- **Hostile external responses.** If the service calls outbound (webhook,
  API, RPC, oracle), a dependency that returns **malformed / oversized /
  unexpected / hostile data** — not just an unreachable one — must not crash,
  hang, or be trusted blindly. Point it at a hostile stub, not only a down
  one, and assert it fails closed on a bad or missing response. A node value
  that feeds an **allow/deny decision or a spend** (a gas price, an
  "is-contract" flag) is the dangerous case — a lying node must not be able to
  flip the decision.

- **Verify the trust model and every security claim from the CODE.** Don't
  inherit the framing from the PR description, a module comment, or a design
  doc. "External-signer, small threat surface", "mirrors X exactly", "no
  guardrails needed — validated upstream", "verified" — each is a **claim to
  test, not a fact**. Read `boogy.toml` (what capabilities are granted — e.g.
  `signing = true` means the service holds keys and is *custodial*, threat
  surface maximal) and the actual call sites. A comment asserting a security
  property must be backed by a test that exercises it; a provably-unreachable
  "defense" branch is dead code masquerading as protection. Flag both.

MCP tools: same three layers — extract pure logic to Layer 1, then
exercise the tools through a **real MCP client connection** (same
auth/principal path), never by calling the tool function in isolation.

## Iron Law

**NO completion claim without a deployed-and-exercised service.** Green
build + passing unit tests ≠ done. "Works" means: deployed, and real
requests — including the authz negatives — returned the right answers.

## Rationalizations

| Thought | Reality |
|---------|---------|
| "Build is green, so the wiring works." | A green build proves it compiles, not that it routes, stores, or authorizes. Only a real request proves that. |
| "I'll write a local integration harness for the handler." | There isn't one. The cdylib + WIT crate has no test target and no constructible request type. Deploy-and-exercise IS the integration layer. |
| "Unit tests pass, ship it." | Which tests? The store write and the authz boundary are untested until a real request hits the deployed service. |
| "It's read-only, auth doesn't matter." | The existence-mask (404 not 403) is a behavior you must verify, not assume. |
| "It's a mundane CRUD app — adversarial testing is overkill." | The boring-looking service is exactly where the un-tested forgery/limit hole ships. Test identity-from-body, limit-bypass, and hostile upstream responses regardless of domain. |
| "Auth is enforced, so ownership is safe." | A 404 on a cross-principal `GET` doesn't prove a `POST`/`PUT` body can't set `owner`/`principal` to someone else. Test that the body can't forge identity. |
| "I tested the dependency being down." | Down is the easy half. Also test the dependency returning malformed / oversized / hostile DATA — that's where a parser panics or a bad value gets trusted. |
| "I tested `/send`, the cap holds." | A `/sign` (or any sibling path) that skips the same gate is a separate hole. Enumerate every path that signs/sends/broadcasts and test each. |
| "The cap is enforced." | Test what it doesn't count: an uncapped fee while value is capped, or a cap compared across denoms/units. Bound `value + fee`; never collapse units. |
| "The PR says it's an external signer / it mirrors X." | That's a claim, not a fact. Verify the trust model and the invariant from `boogy.toml` + the code; a comment is not a test. |

## Integration

- ← `boogy:scaffolding-a-service` (extract Layer-1 logic into the
  sibling crate as you build).
- → `boogy:deploying-boogy-services` — you need a deployed service to
  exercise Layer 3.
- **REQUIRED BACKGROUND for any completion claim:** Layer 3 must have
  run.
