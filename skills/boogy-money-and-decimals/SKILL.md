---
name: boogy-money-and-decimals
description: Use when a Boogy field holds money, a price, a rate, a balance, a score or a weight, when choosing between Decimal, f64 and an integer count of minor units, or when parsing, serializing, summing or splitting decimal amounts
---

# Money and exact decimals

Part of `boogy:boogy-data-modeling`, which holds the model, its field types and defaults: read it first.

## `Decimal` — exact, for money, scores, and weights

`Decimal` is a fixed-point decimal, exact to **6 decimal places**. It
sorts and range-filters correctly at any magnitude and either sign
(`.order(..)`, and `gt`/`lt` range filters, all rank it as a genuine
number, never as text), and its arithmetic is exact — no binary
floating-point rounding error:

```rust
use boogy_sdk::model::Decimal;

fn decimal_addition_is_exact() {
    let a: Decimal = "0.1".parse().unwrap();
    let b: Decimal = "0.2".parse().unwrap();
    // holds exactly — this does NOT hold for f64 (0.1 + 0.2 != 0.3)
    assert_eq!(a + b, "0.3".parse().unwrap());
}
```

That makes `Decimal` a genuinely safe choice for money — not just for
scores and weights — including sums, splits, and running balances that
must reconcile exactly.

Build one from a decimal literal or string, the natural way to write a
price, a rate, or a weight:

```rust
use boogy_sdk::model::Decimal;

fn a_price() -> Decimal {
    let price: Decimal = "19.99".parse().unwrap();
    let total = price + price;   // exact: "39.98"
    debug_assert_eq!(total.to_string(), "39.980000"); // Display form
    total
}
```

A `Decimal` field on a DTO serializes to and from JSON as that same
decimal string (`"19.990000"`), never as a float — a client reads and
writes the value it expects, with no float rounding introduced on the
wire.

**Range and overflow.** Six decimal places gives a usable range of about
±9.22 trillion (`i64::MAX` at that scale) — far past any plausible
money, score, or weight value. `+`/`-`/unary `-` are exact within that
range and **panic on overflow** rather than silently wrapping, the same
posture as an unexpected integer overflow anywhere else: loud, not a
quietly corrupted balance. A literal needing a 7th decimal digit, or a
magnitude outside the range, is a **parse error** — refused rather than
silently rounded or truncated.

Two more constructors exist for specific situations: `from_minor_units`
for a caller that already holds an exact integer count from elsewhere (a
payment provider, an invoice import) — an additional constructor, not
the primary way to build one; and `Decimal::new(f64)` / `.get() -> f64`
for interop with code that already computes in `f64` — a value built or
read that way carries ordinary float rounding at that boundary, same as
any `f64`.

Not provided: multiplication and division as operators. A rate times a
quantity, or splitting a total, needs a rounding rule only the caller
can decide correctly (round up? down? to the nearest cent?) — compute in
minor units explicitly and re-wrap with the rounding you intend.

## `Decimal` vs `f64` vs a plain integer column

| You want | Use |
|---|---|
| A decimal quantity where the value matters exactly — a price, a rate, a running balance, a weight or score you'll sum or compare exactly | `Decimal` |
| A measurement with no decimal-exactness expectation — a coordinate, a ratio, a sensor reading | `f64` |
| You already think in whole minor units yourself and never want a decimal view | a plain `i64`/`u64` column, counting cents (or whatever the unit is) directly |

All three are legitimate — pick by how the field is actually used, not
by which "sounds more precise." Counting minor units in a plain integer
column is exactly as valid as `Decimal` for an author who prefers to
work in cents directly and never format a decimal string. `Decimal` is
for the author who wants to write, read, and reason about decimal
values (`"19.99"`, not `1999`) while still getting exact arithmetic
underneath — it does not force a conversion to minor units at every call
site.

## Integration

↑ `boogy:boogy-data-modeling`. → `boogy:boogy-counters` for a running total kept as a counter (integer deltas only). → `boogy:boogy-route-pricing` for what a route charges.
