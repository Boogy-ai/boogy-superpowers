---
name: boogy-route-pricing
description: Use when deciding what a service should charge for a route — picking a flat price or a rate, choosing which unit to rate on, setting the `max` that callers must hold, working out whether a price covers what a call costs to run, or diagnosing callers refused with 402
---

# Pricing your own routes

You declare prices in your manifest. The platform sets money aside from the
payer before your route runs, charges the actual amount after it completes, and
credits your owner account. Your code never moves money, reads a balance, or
decides who pays.

So the platform handles the mechanism. What it cannot decide for you is **which
numbers to write**, and that is what this skill is about. The syntax — every
field, its type, and the refusal codes — is in the `[pricing]` section of the
manifest reference; come here for how to choose.

**Before you write TOML, read the `[pricing]` section of the manifest reference.**
This skill does not carry the full schema, and the shape is not guessable: routes
are a **table keyed by route id**, not an array; every amount is a **decimal
string**, never a number; the matcher is a `match = { … }` table; and a unit is
declared in its own `[pricing.units.<name>]` block, not inside `rate`. One
complete example, so the shape is in front of you:

```toml
[pricing.units.tokens]
source = "guest"

[pricing.routes.summarize]
match = { path = "/summarize", methods = ["POST"] }
payer = "principal"
price = "0.0005"
rate = { unit = "tokens", per = 1000, price = "0.0020" }
max = "0.0500"
```

Two ideas do most of the work:

- **A flat `price` is a claim about what a call is worth to the caller. A `rate`
  is a claim about what the call costs you to run.** Most useful routes want
  both: a small fixed part that covers being asked at all, plus a rate that
  tracks the work.
- **`max` is not a price.** It is the balance a caller must be holding before
  you will serve them. Setting it carelessly is the most common way a priced
  service becomes uncallable.

## `max` is an admission bar, not just a ceiling

On a rated route, `max` is the amount set aside before your handler runs — not
the amount you end up charging. A caller holding less than `max` is refused
before any work happens, **even when the call would only have cost a fraction of
it**.

That makes `max` do two jobs at once:

| Job | Effect of raising it | Effect of lowering it |
|---|---|---|
| Cap a runaway rated call | Caps less | Caps more, and truncates real charges |
| Minimum balance a caller needs | Excludes more callers | Includes more callers |

The two pull in opposite directions, and only the second is invisible to you —
a caller excluded by your `max` shows up as a refusal, not as a complaint.

**How to gauge it.** Read your own charges (see *Measure first* below), take the
tail you actually intend to serve — p95, p99 if the expensive calls are the ones
that matter — and set `max` a little above that. Do not set it to the
theoretical worst case: `max = 100 × typical` caps nothing that was ever going
to happen and quietly locks out every caller running a small balance.

A flat-price route with no rate reserves the price itself, so none of this
tension exists. It is specific to rates.

**Bound a pathological request in code, not with `max`.** If what is driving your
`max` upward is a request that could consume a million units, the answer is to
refuse that request rather than to price it: check the input and reject it before
doing the work. Then set `max` from the worst *legitimate* call, which is a much
smaller number. Using `max` as the guard against abuse prices out every honest
caller to bound a request you did not want to serve anyway — and note the
rejection itself is charged if you return a 4xx from a priced route, so put the
check on an unpriced route if callers are expected to probe.

## Choosing what to rate on

Four units the platform measures for you, and any unit you declare and report
yourself:

| Unit | Who measures it | When it is the right basis |
|---|---|---|
| `fuel` | platform | **The stable basis for "what this cost me to run."** Deterministic: the same input consumes the same fuel, so your revenue tracks the work rather than the weather. |
| `wall_ms` | platform | Only when you are explicitly selling elapsed time. Otherwise avoid: it moves with how busy the machine is, so identical calls bill differently and your revenue drifts for reasons your caller cannot see or control. |
| `request_bytes` | platform | Routes where the payload *is* the work — uploads, bulk submits, anything whose cost scales with what arrived. |
| `response_bytes` | platform | Routes that return bulk data, where the size of the answer is the product. |
| a unit you declare | your handler | **When you are selling domain work rather than machine consumption** — tokens, rows, pages, messages, records processed. |

Prefer a unit your caller can predict. A caller who can estimate their bill
before calling will call more; one who cannot will cap their spending limit low
and stop.

Declare your own unit with `source = "guest"` and report it once per request:

```rust ignore-snippet: one call in isolation as a reference; the surrounding handler and its Req are not the point here
boogy_sdk::pricing::report_units("tokens", 1_430)?;
```

Because your own code reports that number, the platform bounds the charge by
`max` — which is the other reason `max` is required on a rated route, and the
reason a caller can read `max` as "the most this can cost me."

## Measure first, then price

Price from a measurement, not from a guess. Before you pick numbers, deploy the
route unpriced and drive realistic traffic through it, then read what it
actually consumed from your own usage:

- `GET /v1/usage/summary` — totals per dimension.
- `GET /v1/usage/events` — per-request rows, including `fuel_consumed`, request
  and response bytes, and (once priced) `cost_micros` per charge.
- `GET /v1/usage` — latency percentiles, p50/p95/p99.

Two numbers come out of that and both matter:

1. **What a typical call consumes**, which sets your rate.
2. **How wide the spread is**, which sets your `max`. A route whose p99 is twice
   its p50 wants a very different `max` from one whose p99 is fifty times it.

Then sanity-check the direction of the trade: if your rate and your `max` mean a
typical call costs the caller less than a tenth of what they must hold to make
it, expect low adoption from small-balance callers — and consider a flat price
instead, which reserves only what it charges.

## Rounding: whole micros, up, once per call

The rated part of a charge is `ceil(units × price ÷ per)`, in whole micros
(`$0.000001`), rounded **up**, once per call. Then the total is capped at `max`.

The practical consequence is a floor: any call that consumes anything at all
costs at least one micro. If your intended price for a small call works out
below that, every small call bills the same one micro — which may be many times
what you meant to charge.

Fix it by moving `per`, not the price. Choose `per` so a *typical* call lands
comfortably above a single micro: rate 1,000 tokens at a time rather than one,
and the arithmetic stops being dominated by rounding.

## What is charged, and what is free

- **A completed call is charged, including a 4xx.** Your handler ran and decided
  to reject; that decision cost you the work of making it.
- **A server-side failure charges nothing** — a 5xx, a crash, a timeout.

So a route that validates input and returns 400 charges for the rejection. That
is usually right. If it is not right for your route — because callers are
expected to probe, or because a rejection is genuinely free for you — then move
the validation to an unpriced route and charge only once the work is real.

If your route runs as part of a larger request that might fail later, consider
`refund_if_request_fails = true`, which charges nothing when the request that
reached you ultimately fails server-side.

## Who pays

`payer = "principal"` charges the signed-in user who sent the request. Use it
for a service people call directly.

`payer = "caller_service"` charges the owner of the service that called yours,
and refuses a direct call from outside. Use it when you are a building block
other services compose — your customer is the developer, not their end user.

If someone needs to spend on a user's behalf — a delegated call, a background
job running as that user, an app calling a service that is not its own — that
requires a spending grant the user created. You do not configure this; it is the
caller's side. But it shapes your pricing: a price above what callers typically
grant per charge will be refused by the grant rather than by the balance.

## Reading refusals as pricing feedback

Which 402 your callers get tells you whether the price is wrong or the caller is:

| Refusal | What it usually means about your pricing |
|---|---|
| `insufficient_funds` | The payer cannot cover your `max`. If this is common, your `max` is probably too high for the callers you want. |
| `spend_limit` | The payer's own cap stopped it. Your price may sit above what callers in your market allow per call or per hour. |
| `spending_grant_required` | Not a pricing problem: someone is spending another user's balance without that user's grant. |
| `payer_unavailable` | Not a pricing problem: a `caller_service` route was called directly, or a `principal` route by a service identity. |
| `payment_requires_identity` | A `principal` route was called by someone not signed in. |

The first two are the ones to watch as prices, not as errors. A rising
`insufficient_funds` rate with no change in your traffic means your `max` is
excluding callers who could have afforded the actual call.

Every response also carries `X-Boogy-Charged`, so a caller can see what a
request cost — including one that failed. Expect them to read it.

## Common mistakes

| Mistake | What happens | Do instead |
|---|---|---|
| `max` set to the theoretical worst case | Callers with modest balances are refused before any work happens; the cap never binds | Set it just above the tail you intend to serve, from measured charges |
| Rating on `wall_ms` for ordinary work | Identical calls bill differently depending on machine load | Rate on `fuel` for compute, or on a unit you report |
| `per` too small for the unit | Rounding up to one micro dominates, and small calls cost far more than intended | Raise `per` so a typical call is comfortably above one micro |
| Pricing from a guess | The rate does not track what the route costs you, in either direction | Deploy unpriced, measure, then price |
| A rate with no flat `price` | Being asked at all is free, so cheap-but-frequent calls cost you more than they pay | Add a small fixed part |
| Charging for validation rejections without deciding to | Callers probing your API pay for 400s | Either accept it deliberately or move validation to an unpriced route |

## Red flags

- You picked a price before measuring what the route consumes.
- You set `max` from the worst case you can imagine rather than from data.
- You cannot say what a typical call will cost a caller, to one significant
  figure.
- You are rating on `wall_ms` and not selling time.
- Your `insufficient_funds` refusals are rising and you have not looked at
  `max`.
- You expect a 4xx to be free.

## Where to look next

- The `[pricing]` section of the manifest reference — every field, its type, and
  the full refusal table.
- `GET <mount>/pricing.json` on any priced service — the price list it publishes
  to callers, which is what your own callers will read.
- `GET /v1/services/{service_id}/pricing` — your own view of what a deployment
  is actually charging, as compiled.
