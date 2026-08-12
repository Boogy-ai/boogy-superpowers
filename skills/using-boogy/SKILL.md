---
name: using-boogy
description: Use when building, modifying, debugging, or reviewing anything that runs on Boogy — services, agent backends, MCP tools, or multi-service meshes
---

# Using Boogy

Boogy has hard invariants and a specific SDK surface. Do NOT build from
memory. Before ANY Boogy work, scan the catalog below: if there is even
a 1% chance a skill applies, read it BEFORE acting. When no skill
covers your task, work against the SDK reference docs — never invent
APIs.

**Design-first hard gate.** For a new service or feature, answer the
design questions — **deployment shape (frontend / full-stack / backend
service)**, then backend kind + surface (REST / MCP / RPC),
capabilities, ingress mode, data sketch — BEFORE writing any code or
scaffolding. Shape comes first: a frontend-only site runs no wasm, so it
skips capabilities, ingress, and data entirely. The
`designing-boogy-services` skill runs this questionnaire once installed;
until then, answer them yourself first.

## Interaction model — you wire, the person decides the shape

When there's a person in the loop (a "vibe coder" who wants to build, not to learn
the manifest), **you are the expert**: walk them through the few high-level choices
that are genuinely theirs — who can use it, whether others can run their own copy,
whether it needs a web page, anything that moves money or holds a secret — in plain
language, **leading with a recommended answer**. Decide and apply everything else
(ingress mechanism, capabilities, data model, transactions, wiring, the TOML)
yourself with the smart default, then report those choices in one line each. Don't
turn a build into an interrogation. `boogy:growing-boogy-meshes` is the full
playbook (the ask/decide tiers, the interview loop, and how to grow a mesh
service-by-service).

## Skill catalog

*Catalog grows as skills ship; current entries below.*

| Skill | Read when... |
|-------|--------------|
| `using-boogy` | starting any Boogy work — routes you to the right skill |
| `boogy-onramp` | **BEFORE any build, deploy, or platform call** — establishes the required setup contract |
| `growing-boogy-meshes` | building with a person in the loop — walking them through high-level choices in plain language while you handle the wiring, and growing their mesh service-by-service |
| `designing-boogy-services` | starting a new service or major feature — runs the design questionnaire before any code |
| `boogy-capability-limits` | a requirement might not be supported, or designing any new service/feature |
| `scaffolding-a-service` | starting implementation of a designed service — project, manifest, build loop |
| `testing-boogy-services` | testing a service, or before claiming one works — the test pyramid + deploy-and-exercise |
| `deploying-boogy-services` | deploying, updating, or removing a deployed service — CLI commands, config, deploy errors |
| `boogy-data-modeling` | declaring tables, designing schemas, or choosing how to represent data |
| `boogy-access-patterns` | adding a list, lookup, ranking, filter, tag, or pagination query |
| `boogy-transactions` | a write that must roll back if later work fails, writing multiple rows atomically, combining writes with cross-service calls, handling 409s, or placing side effects near writes |
| `boogy-migrations` | changing the schema of a deployed service — adding columns or indexes, or backfilling data |
| `boogy-auth` | adding authorization — per-user data, ownership checks, "only my X" endpoints, API keys, or scope gating |
| `boogy-account-auth` | wiring login/signup for a service's users, or asking where principals and tokens come from |
| `boogy-obo-delegation` | one service must act on a user's behalf when calling another service — delegation config, principal-vs-actor authorization |
| `boogy-mesh-architecture` | composing multiple services, deciding whether to split a service, or passing identity/data between services |
| `boogy-registry-and-provisioning` | needing functionality that might already exist in the mesh, publishing a module, or deciding whether to run your own instance of one |
| `boogy-secrets` | a service needs an API key or credential for an external call, host-side HMAC signature verification, or asking how secrets work |
| `boogy-signing` | a service must produce a cryptographic signature — signing keys, per-user or wallet keys, blockchain transactions, signed receipts or attestations — with a private key the host holds and your code never touches |
| `boogy-blockchain-transactions` | a service constructs, signs, or broadcasts on-chain transactions — a custodial wallet, on-chain payments/payouts, a swap or bridge relayer, or any EVM/Cosmos/Solana/Bitcoin signer that moves funds (fund-safety: one gate per sign path, total-outflow + fee bounds, denom-aware caps, signature self-verify, adversarial RPC, nonce serialization) |
| `boogy-webhooks` | building a service that RECEIVES and verifies inbound webhooks from a third party (Stripe, GitHub, Twilio, any HMAC-signed callback) |
| `boogy-serving-frontends` | a service must serve a web frontend — a reactive UI, SPA, dashboard, static HTML/JS/CSS, or a full-stack app serving both the page and its API (arrow-js, TypeScript-with-no-build, host-served assets) |
| `boogy-custom-domains` | serving a service on a tenant's own domain instead of the platform subdomain — registration, DNS records, verification, root-serve semantics |
| `boogy-rest-apis` | building HTTP/REST or JSON-RPC endpoints — routing, guards, request parsing/validation, response types, error wire format |
| `boogy-mcp-services` | exposing MCP tools/resources/prompts to LLM clients, or adding MCP alongside an existing REST service |
| `boogy-api-specs` | questions about the auto-served spec docs (openapi.json / openrpc.json / MCP discovery), Router::info, two-tier visibility, undocumented routes, or the JsonSchema derive requirement |
| `boogy-outbound-http` | a service must call an external HTTP API or bring its own database/backend — egress allowlist, request shape, caps, credentials |
| `boogy-background-jobs` | work should run outside the request — scheduled, deferred, retried, or fan-out — or asking whether a job runs exactly once |
| `boogy-performance-and-scaling` | a service is throttled or slow under load — 429/503/504, Retry-After, or "make this endpoint faster" |
| `boogy-observability` | viewing your own service usage, billing, raw events, a single request trace, audit tail, storage quota, or guest logs — via /v1 REST, MCP tools, or the live log stream — or adding guest logging to a service |
| `boogy-websockets` | a service pushes real-time messages to end-user clients — declaring public/private/principal channels, publishing with the websockets capability, minting subscription grants, or wiring a browser/socket.io client |
| `boogy-service-lifecycle` | retiring, deprecating, replacing, or removing a deployed service — especially when other services call it, or its data matters |

No matching skill? Say so explicitly and work from the SDK reference
docs rather than guessing.

## Worked examples — the service catalog

First-party example services live in the public catalog repo,
**[Boogy-ai/boogy-catalog](https://github.com/Boogy-ai/boogy-catalog)** — real,
deployable Boogy wasms you can read end-to-end as canonical, idiomatic
references (manifest, capabilities, ingress, data layer, handlers). When a skill
names one (e.g. `stripe-base`, `resend-base`), that's where the source lives.
Before inventing structure for a new service, read the catalog example closest
to your use case — it shows the conventions in working code. Each is
BYO-config: you provision your own instance and bind your own keys.

## Sign in (get a deploy token)

Deploying requires a token. Two paths — the MCP path requires no install.

A first-time sign-in picks a **handle**, and **your handle IS your subdomain** —
a DNS label, lowercase `[a-z0-9-]`, **3–30 characters** (no `_`, `.`, or spaces). Your services
are reached at `https://<handle>.<base>/<service>/<path>`. Messy input is coerced
(`my_app` → `my-app`) and the final handle is returned; reserved/taken → pick
another. (There is no path-based `/<owner>/<service>` form — routing is
subdomain-only, so a non-label handle would be unroutable.)

**`<base>` is the app plane — in production it is `boogy.app`, NOT `boogy.ai`.**
Your live URL is `https://<handle>.boogy.app/<service>/`. `boogy.ai` is the
**control/marketing plane** (`api.boogy.ai` for login + the `/v1` API, the docs
site, the landing page) and **never serves your deployed app**. These two planes
do not alias each other. Do **not** infer your app's domain from what the user
typed ("deploy to boogy.ai"), from this skill's generic `<base>` placeholder, or
from the host you logged in against — the **`boogy deploy` output prints the
authoritative live URL** (`URL: https://<handle>.boogy.app/<service>`). Read it
from there; treat anything you assembled by hand as a guess until the deploy
confirms it. See `boogy:boogy-custom-domains` to serve on your own domain instead.

**MCP (primary — zero install):** If you are connected to Boogy's MCP server,
call the `login` tool. It returns a `user_code`, a verification URL, and a
`device_code`. Show the human the URL + `user_code` and ask them to open it,
sign in, and confirm the code **matches** (anti-phishing). Then poll
`login_status` with the `device_code` every few seconds until it returns
`{status: "complete", token: "v4.public.…"}`. Pass that token as
`BOOGY_TOKEN` or `--token`.

**CLI (alternative):** `boogy login` — same device flow, auto-opens the
browser, saves the token to `~/.config/boogy/credentials.toml` so later CLI
commands pick it up automatically.

**This token is a control-plane credential.** It works for deploy, provision,
`/_admin`, and the CLI/MCP. It is **NOT accepted at a deployed app's non-public
routes** (403 — control-plane/app-plane boundary). See `boogy:boogy-account-auth`
for the end-user SSO flow, and `boogy:deploying-boogy-services` for what to do
when smoke-testing your own service.

`boogy-account-auth` is a different concern: it covers how a **service's own
end-users** log in to your deployed service (via "Sign in with Boogy" SSO —
delivering a per-app pairwise pseudonym). This section is about *you* (the
developer / agent) signing in to the platform to deploy.

## Red flags

| Thought | Reality |
|---------|---------|
| "It's a small service, I'll just start from the template." | Small services still need ingress mode and capabilities decided. Design, then scaffold. |
| "I know the SDK from training data." | The SDK surface is specific and moves. Confirm every call against the docs; never fabricate signatures. |
| "This endpoint is too simple to need the catalog." | Simple endpoints still hit store/query/auth invariants. Scan first; if no skill fits, say what you're relying on. |
| "I'll wire the happy path and worry about integrity later." | Treat each request as a **unit of work** — on ANY error the caller sees no partial state. Decide transactions and write-ordering as you write the handler, not after — **read `boogy:boogy-transactions` first**. |
| "Integrity = wrap the whole handler in a `tx`." | No — a `tx` guards **store writes only**, and an `outbound_http` call (or other irreversible effect) inside one is **denied**. `boogy:boogy-transactions` already has the rule + the patterns to use instead (staged job in-tx, or after commit). Don't guess — read it. |
| "The user said 'boogy.ai', so my app is at `<handle>.boogy.ai`." | No. The app plane is **`boogy.app`**; `boogy.ai` is control/marketing only. Your live URL is whatever the **`boogy deploy` output prints** — read it from there, never reconstruct it from the user's words or the login host. |
