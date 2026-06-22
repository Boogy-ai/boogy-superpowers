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
| **1 — Always ask** (lead with a default) | The person | Reach (who can use it) · Provisioning (can others run their own copy) · Surface (web page or just an API) · Real-world stakes (signs/moves money, holds a secret, irreversible/external) |
| **2 — Decide, then report one line** | You | Ingress *mechanism* (`authenticated`/`allowlist`/`internal`/`mixed`, delegation) once reach is known · capability minimization · data model + indexes · transactions · peer wiring · mounts · CORS |
| **3 — Do silently** | You | `cols` modules, `#[derive(Model)]`, validation, error wire format, OpenAPI annotations, the actual TOML |

Tier-2 transparency matters: after you build, tell them the Tier-2 choices in
one line each ("Locked it to logged-in users, each person sees only their own
rows, and writes roll back together") — visibility without burden.

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
| "I'll ask them which ingress mode / capabilities / indexes to use." | Those are yours (Tier 2/3). Decide the smart default and report it in one line. Don't make a vibe coder choose wiring. |
| "I'll just ask every manifest field to be safe." | That's an interrogation. Ask only Tier-1, lead with a recommendation, and apply the rest. |
| "Simple app — I'll split it into five services." | Default to full-stack. Split only on a clear reuse signal. |
| "I'll build the thing they asked for." | Search the registry first — it may already exist. Reuse grows the mesh faster than rebuilding. |
| "This util holds user data but I'll make it public-provisionable." | Public provisioning suits **stateless / bring-your-own-config** utilities. A data-holding app is `private`. |
| "I built it; they'll trust it works." | Report the Tier-2 choices you made, in plain language. Transparency is part of the deal. |

## Integration

→ `boogy:designing-boogy-services` runs the per-service decision detail (shape,
surface, capabilities, ingress, data) once you've framed the piece.
→ `boogy:boogy-registry-and-provisioning` is discover-before-build + publish-for-
others (the shared library + provisioning modes).
→ `boogy:boogy-serving-frontends` for the web surface + GEO/SEO.
→ `boogy:boogy-mesh-architecture` / `boogy:boogy-obo-delegation` for wiring
services together. ← `boogy:using-boogy` routes you here.
