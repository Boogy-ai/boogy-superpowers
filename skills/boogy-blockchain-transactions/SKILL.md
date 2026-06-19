---
name: boogy-blockchain-transactions
description: Use when building a Boogy service that constructs, signs, or broadcasts blockchain transactions — a custodial wallet, an on-chain payments/payout service, a swap or bridge relayer, or any multi-chain (EVM/Cosmos/Solana/Bitcoin) signer that moves funds
---

# Boogy blockchain transactions

A service that turns a request into a signed, broadcastable on-chain
transaction is moving real money, irreversibly. The signature **is** the
spend — once it exists, whoever holds it can broadcast it; whether *your*
service broadcasts is irrelevant. So every control belongs at the signature,
and every input that feeds it is adversarial until proven otherwise.

This is the on-chain layer on top of `boogy:boogy-signing` (the general
host-held-key model). Read that first; this skill adds the
transaction-construction rules that general signing doesn't cover.

## The six non-negotiables

Each is a failure class that has shipped in a real custodial wallet review.
Treat them as a checklist for every chain you support.

### 1. One gate for every signing path

If your service exposes more than one path that produces a signature — per
chain, and a `/send` (sign+broadcast) **and** a `/sign` (sign-only, caller
broadcasts) — route them ALL through **one shared gate**, in this order:

```
block-check(principal)  →  spend policy (incl. fee bound)  →  accounting (debit)  →  sign
```

A "sign-only" endpoint that skips the gate the "send" endpoint enforces is a
**fund-drain bypass**: the caller signs N times and self-broadcasts, never
hitting the cap. Gate at the **signature**, not at the broadcast. Make the
gate one function the handlers can't sidestep, not copy-pasted per handler
(copies drift; one drifted copy is the hole).

The accounting debit must persist a durable record even on the sign-only
path — otherwise a retry double-counts or a sign bypasses the daily cap.

### 2. Bound TOTAL outflow, not just the transfer value

A spend cap that bounds `value` but not `fee` leaves the fee uncapped — and
the fee is often caller- or node-influenced (gas price × gas limit, a
fee_amount field). Cap **`value + fee`** against the daily limit, and enforce
a separate explicit **per-tx fee ceiling**. An unbounded fee drains the
wallet even when every transfer is "within limit."

### 3. Money is `(amount, denom)` — never a bare integer

Never compare or accumulate amounts as bare integers across denominations
(wei vs gwei, lamports, a Cosmos `uatom` vs `untrn`, sats). Key every cap and
accumulator on **`(owner, chain, denom)`**. A cap that collapses denoms lets
1000 of a worthless token and 1000 of a valuable one share — and exhaust —
one bucket. Carry amounts as **integers-in-strings**, never `f64` (chain
integers exceed f64's exact range).

### 4. Self-verify the assembled signature before you return or broadcast it

After you splice the host signature(s) into the transaction, **verify each
one against the exact message it should sign** — recover the signer (or
re-derive and check the digest/sighash) under the expected public key, and
reject on any mismatch. This is "sign what you see," enforced:

- **EVM** — check the recovery id ∈ {0,1}; fold the chain id into `v`
  (EIP-155) so the signed tx can't be replayed on another chain.
- **Bitcoin** — verify every input's signature against its **per-input BIP143
  sighash** under the sender pubkey before splicing; a wrong, misordered, or
  wrong-`SIGHASH` signature must fail loud, not broadcast.
- **Cosmos / Solana** — recover-and-compare against the canonical sign-bytes
  you built.

A wrong/misordered/garbage signature that you broadcast is a burned fee at
best and a lost transaction at worst. Failing closed here is cheap; the
broadcast is irreversible.

### 5. RPC/node values are adversarial

A value from a chain RPC node — gas price, fee estimate, an "is this address
a contract" answer (`eth_getCode`/estimateGas), a nonce, a balance, a
broadcast receipt — is attacker-influenceable (a hostile node, a lying
endpoint, a caller who supplies the `rpc_url`). **Never let a node value drive
an allow/deny decision or an unbounded spend.**

- Clamp gas/fee to a sane **ceiling** before it enters a signed tx; fail
  closed above it.
- Build allowlists from **trusted config**, not node-derived signals — a
  recipient allowlist must be the union of *your* trusted lists, never gated
  on the node's `is_contract` answer (which the node can lie about to flip the
  decision).
- The RPC endpoint itself should be **operator-configured**, not taken from
  the request body.
- Treat a broadcast receipt as a claim; confirm inclusion independently.

### 6. Serialize nonce / sequence reservation

Concurrent sends for one account race on the next nonce/sequence. Reserve it
in a small dedicated transaction: `reserved = max(on-chain pending,
stored_next); stored_next = reserved + 1`, then sign with `reserved`.
Concurrent reservations conflict on the row → 409 (the client retries the
whole request). Document the known caveat: a permanently-failed tx leaves a
nonce gap (inherent to pending pipelines; a cancel/replace flow is separate
scope).

## Know you are custodial — verify it from the code

This whole skill assumes a **custodial** model: the host holds the key and
your service can sign for any label it names (see `boogy:boogy-signing`). Do
not trust a comment, a PR description, or a design doc that calls the service
"external-signer" or claims "signing is delegated, the threat surface is
small." **Verify the trust model from the code**: `signing = true` in
`boogy.toml` and the actual `sign-digest`/`sign-message` calls mean the
service is the custodian for every subject's funds — the threat surface is
maximal, and every rule above applies.

## Red flags

| Reach / claim | Reality |
|---|---|
| "`/send` is gated, so the service is safe" | Enumerate EVERY signing path (per chain, `/sign` and `/send`). One ungated path is a full drain. |
| "It's a sign-only endpoint, no guardrails needed" | The signature is the spend. Sign-only paths gate and debit exactly like send. |
| "The cap bounds the transfer, we're covered" | An uncapped fee drains the wallet. Bound `value + fee` and ceiling the fee. |
| "Amounts are all integers, I can compare them" | Not across denoms. Key caps on `(owner, chain, denom)`; amounts as strings. |
| "The node told me the gas price / that it's a contract" | The node is adversarial. Clamp + fail closed; never let a node value drive allow/deny or an unbounded spend. |
| "The host signs correctly, so the assembled tx is fine" | Splicing/encoding is on you. Recover-and-verify the signature against its sighash before broadcast. |
| "Concurrency is rare, the nonce will be fine" | Two simultaneous sends collide on the nonce. Serialize the reservation; conflict → 409. |
| "The doc says it's an external signer" | Verify from `boogy.toml` + the sign calls. Custodial vs external-signer changes the entire threat surface. |

## Integration

← Reach this from `boogy:designing-boogy-services` when the service signs or
broadcasts on-chain transactions (capability planning).
↔ `boogy:boogy-signing` — the general host-held-key model and the
`sign-digest`/`sign-message` contract this builds on.
→ `boogy:testing-boogy-services` — exercise every rule above adversarially:
enumerate the signing paths, attack the fee and the denom, point it at a
hostile RPC stub, race the nonce.
