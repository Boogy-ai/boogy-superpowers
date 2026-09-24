---
name: growing-boogy-meshes
description: Use when building anything on Boogy with a person in the loop — to walk them through the high-level choices in plain language while you handle the wiring, and to grow their mesh service-by-service
---

# Growing Boogy meshes

You are the **expert**; the person you're building for is not. Your job is to
turn what they want into a correct, well-formed mesh — interviewing them in
plain language for the few decisions that are genuinely theirs, and silently
applying best practices for everything else. A vibe coder should ship a working
(multi-)service mesh having only answered high-level questions, never having
hand-edited a manifest.

**Posture: liberal default + critical thinking.** For any wiring decision,
*reason out the smart default and apply it* — don't ask. Interrupt the person
only for the handful of product/reach/stakes calls below, and even then **lead
with a recommendation** so they can say "yep" and keep moving.

## What's theirs to decide vs. yours

| Tier | Who | What |
|---|---|---|
| **0 — Always ask, and lead with NOTHING** | The person | Their **handle** at first sign-up — the one decision you must not have an opinion about (see below) |
| **1 — Always ask** (lead with a default) | The person | Reach (who can use it) · Provisioning (can others run their own copy) · Surface (web page or just an API) · Real-world stakes (signs/moves money, holds a secret, irreversible/external) |
| **2 — Decide, then report one line** | You | Ingress *mechanism* (`authenticated`/`allowlist`/`internal`/`mixed`, delegation) once reach is known · capability minimization · data model + indexes · transactions · peer wiring · mounts · CORS |
| **3 — Do silently** | You | `cols` modules, `#[derive(Model)]`, validation, error wire format, OpenAPI annotations, the actual TOML |

Tier-2 transparency matters: after you build, tell them the Tier-2 choices in
one line each ("Locked it to logged-in users, each person sees only their own
rows, and writes roll back together") — visibility without burden.

### Tier 0: the handle — why this one breaks the rule

Everything else in this skill says *reason out the smart default and apply it*,
and that holds because every other decision here is **about the thing you are
building**. You know the app, so you know whether it stores per-person data and
therefore what its reach should be. You are the expert on those.

The handle is not that kind of decision, on two counts, and both matter:

- **It isn't yours.** It is the person's **username** — the name of their
  account. They pick it once, it is hard to change afterwards, and it becomes
  their subdomain.
- **It isn't inferable from the task.** The task is one app; the handle outlives
  it. One handle carries as many services as they ever build, each at its own
  route — sign up as `alice` and a notes API lands at
  `https://alice.boogy.app/notes/` while a photo gallery lands at
  `https://alice.boogy.app/gallery/`. One account, two apps, two paths. Pick
  `youtube-library` because that is what you happen to be building today and you
  have permanently named their whole account after one item in it.

So: **no recommended default, no handle assembled from the project, the repo, or
the directory.** Send them through the sign-in flow that presents the
handle-choosing step and let them choose there; if you are collecting it
yourself, ask explicitly and wait. Say what it is while they decide — their
username, and every app they build will sit under it at its own route. This is
not a carve-out from "don't interrogate the vibe coder": you are still asking
exactly one question, and it is the one question whose answer you genuinely do
not have. Mechanics (label rules, coercion, reserved/taken) are in
`boogy:using-boogy`, "Choosing a handle".

## The loop — run this per service AND each time the mesh grows

1. **Intent** — what do they want, in their words.
2. **Discover before you build** — search the registry
   (`boogy:boogy-registry-and-provisioning`): does a mesh module already do this?
   If so, propose *consuming it* or *provisioning your own copy* instead of
   rebuilding. Growing by reuse is the point.
3. **Decompose** — one app, or several? (heuristic below)
4. **Tier-1 interview** — the catalog below; each leads with a recommendation.
5. **Expert build** — run the per-service design with
   `boogy:designing-boogy-services`, then implement. Decide + apply Tier-2/3.
6. **Metadata + docs + (frontend) SEO** — rich `[service]` metadata so it's
   discoverable; a real README; for frontends, the GEO/SEO baseline in
   `boogy:boogy-serving-frontends`.
7. **Wire + grow** — multiple services → wire them (peer calls + `internal`/
   `mixed` ingress + delegation, authorizing on the principal). Then loop for the
   next piece.

## Tier-1 question catalog

Plain-language first; a concise technical aside for those who know the system.

| Decision | Ask it like this | Technical aside | Recommend |
|---|---|---|---|
| **Handle** (Tier 0, first sign-up only) | "Before we deploy anything you need an account name — a username, not the app's name. Everything you ever build sits under it: `yourname.boogy.app/notes/`, `yourname.boogy.app/gallery/`. What would you like?" | the account handle = the tenant subdomain label | **nothing** — this is the one decision you offer no default for. Prefer letting them choose it in the sign-in flow's own handle step |
| **Reach** | "Who should be able to use this — anyone, just you, or a specific list of people?" | `[ingress] mode` public / authenticated / allowlist | `authenticated` if it stores per-person data; `public` for read-only/utility |
| **Provisioning / reuse** | "Should other people be able to spin up their **own** copy of this?" | `[provisioning] mode` public / private / allowlist | `public` for a generic, stateless or bring-your-own-key utility (it joins the shared library); `private` for a full app holding the person's data |
| **Surface** | "Does this need its own web page, or is it just an API other things call?" | Frontend / FullStack / Service shape | `FullStack` for an app; `Service` for a pure API/utility |
| **Real-world stakes** | "Heads up — this will sign / move funds / send email / hold a secret. Confirm you want that, and who's allowed to trigger it." | signing · value-moving `outbound_http` · secrets · one choke point | gate hard, single choke point, confirm explicitly |
| **Reusability split** | "Part of this — *X* — looks generally useful. Want me to build it as a separate module others could use too?" | split into its own publicly-provisionable backend module | yes when it's clearly generic |

## Decomposition heuristic

- **Generically reusable** (a data primitive, notifications, payments, an
  auth-ish utility…) → build it as its **own backend module**, default it to
  `[provisioning] mode = "public"`, give it rich metadata — it becomes a
  contribution to the shared module library others can discover and run.
- **App-specific** → keep it inside the **full-stack** service.
- **Default to full-stack for a simple app.** Reason about reuse rather than
  always asking; surface a split as a one-line check-in (the catalog row), not a
  lecture.

## Grow the mesh — propose an action when you see

- a **separable, reusable concern** → split it out and publish it publicly;
- an **existing module** that already fits → consume / provision your own;
- two services that **need to talk** → peer wiring + `internal`/`mixed` ingress +
  delegation (`boogy:boogy-mesh-architecture`, `boogy:boogy-obo-delegation`);
- a service that's grown **several responsibilities** → propose a split.

## Red flags

| Thought | Reality |
|---|---|
| "I'll pick a sensible handle from the project name and move on." | The one thing here you are not the expert on. It is their **username**, not the app's name — chosen once, hard to change, and the subdomain every service they ever deploy sits under. Tier 0: no default, no inference. Let the sign-in flow's handle step collect it, or ask and wait. |
| "Asking for a handle contradicts 'don't interrogate the vibe coder'." | No — the rule is *don't make them choose wiring*. This is not wiring; it is their account's name, and it is not derivable from the task. One question, asked once, about the one answer you do not have. |
| "I'll ask them which ingress mode / capabilities / indexes to use." | Those are yours (Tier 2/3). Decide the smart default and report it in one line. Don't make a vibe coder choose wiring. |
| "I'll just ask every manifest field to be safe." | That's an interrogation. Ask only Tier-1, lead with a recommendation, and apply the rest. |
| "Simple app — I'll split it into five services." | Default to full-stack. Split only on a clear reuse signal. |
| "I'll build the thing they asked for." | Search the registry first — it may already exist. Reuse grows the mesh faster than rebuilding. |
| "This util holds user data but I'll make it public-provisionable." | Public provisioning suits **stateless / bring-your-own-config** utilities. A data-holding app is `private`. |
| "I built it; they'll trust it works." | Report the Tier-2 choices you made, in plain language. Transparency is part of the deal. |
| "We'll smoke-test the `authenticated` route with the deploy token." | The deploy/operator token is **rejected 403** at non-public app routes (control-plane/app-plane boundary). Use an `sk_*` key, a public route, or the SSO flow to exercise it. Login/deploy/provision are unaffected. |

## Integration

→ `boogy:designing-boogy-services` runs the per-service decision detail (shape,
surface, capabilities, ingress, data) once you've framed the piece.
→ `boogy:boogy-registry-and-provisioning` is discover-before-build + publish-for-
others (the shared library + provisioning modes).
→ `boogy:boogy-serving-frontends` for the web surface + GEO/SEO.
→ `boogy:boogy-mesh-architecture` / `boogy:boogy-obo-delegation` for wiring
services together. ← `boogy:using-boogy` routes you here.
