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
NaN/negative/empty guards here.

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

## Integration

- ← `boogy:scaffolding-a-service` (extract Layer-1 logic into the
  sibling crate as you build).
- → `boogy:deploying-boogy-services` — you need a deployed service to
  exercise Layer 3.
- **REQUIRED BACKGROUND for any completion claim:** Layer 3 must have
  run.
