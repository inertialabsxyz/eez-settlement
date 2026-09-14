# Moving the solver auction on-chain

*A proposal to extend the CoW model, and a working prototype.*

> **Draft.** Two things in this document are not yet verified and are marked inline:
> claims about CoW Protocol's parameters, which need sourcing before this is sent
> anywhere (see *Claims to verify*), and one experimental result that has been
> implemented but not yet run (see §5).

---

## 1. What CoW already gets right

Batch auctions with a uniform clearing price are the right mechanism for retail and treasury flow,
and CoW Protocol demonstrated it in production. Orders in a batch clear at one price, so there is no
ordering advantage to sell. Coincidences of wants net internally and never touch an AMM, so those
trades pay no fee and take no slippage. A competitive solver market does the routing, and users sign
a limit rather than a route.

That design is not in question here. Everything below assumes it and builds on it.

Users are already protected on-chain by the limit price they signed. A solver cannot fill an order
worse than its limit, whatever else happens in the batch. That is a real and load-bearing guarantee.

## 2. The one thing that is still trusted

What a user cannot check on-chain is **auction fairness**: whether the winning solution really was
the best one submitted, and whether the surplus that should have reached them did.

This is not an integrity claim about anyone. It is a structural consequence of running the
competition off-chain. The bids are not public artefacts, the scoring is not executed by a contract,
and so the outcome cannot be recomputed by a third party from public data. What exists instead is a
process, run well, that participants trust.

For retail that is usually fine. For the flow this design is aimed at — desks and DAO treasuries
whose approval process has to be satisfied in writing — "trust the operator's auction" is the item
that stays open, and no amount of operational quality closes it. It is a question about what can be
*proved*, not about what is happening.

## 3. Why the auction has not moved on-chain, and what changes

The obvious fix is to run the auction in a contract. Nobody does, because a solver competition on L1
costs more than the surplus it allocates.

An L2 solves the cost problem and creates a worse one: the auction is now on a different chain from
the liquidity. Settlement has to reach L1 pools, and the usual answers — bridging, an inventory
buffer, an optimistic window — reintroduce exactly the trust and capital costs the exercise was meant
to remove.

**The enabling piece is a synchronous cross-chain dispatch.** One L2 transaction makes one L1 call,
inside the same atomic scope: the settlement lands on both chains or on neither. That is what EEZ
provides, and it is the reason this design is possible rather than merely desirable.

With it, the split falls out naturally:

```
  L2 ──────────────────────────────      L1 ──────────────────────────────────────
  Book       intents                     Executor   verify → pull → interact → pay
             sealed-bid auction                     → sweep → prove exact
             deterministic scoring
                    │                                       ▲
                    └──────── one dispatch per settlement ───┘
```

`Book` holds intents, runs a sealed-bid auction, scores the revealed solution with deterministic
on-chain code, and emits exactly one call. `Executor` understands nothing about auctions: it verifies
signatures, performs the payload, and refuses to end the transaction holding a different balance than
it started with.

Two consequences worth stating plainly:

**The auction is recomputable.** Intents are on-chain, the winning solution is revealed on-chain, and
the score is computed by a contract. Any observer can replay it and confirm the winner won. The thing
that was trusted is now checkable.

**A compromised L2 cannot move funds.** `Executor.settle` is reachable only from `Book`'s cross-chain
proxy — but that authenticates the *caller*, not the *trade*. What makes it safe is that every pull
carries the user's own EIP-712 signature over the exact terms. An attacker who fully controls the L2,
sequencer and all, still cannot forge a signature over terms a user did not sign.

## 4. What this removes for solvers

Verifiability matters to users and integrators, not to solvers. Solvers follow order flow. So the
question that decides whether this design ever sees a batch is what it does for *them*, and the
answer is capital relief.

- **No bond.** Overclaiming is self-defeating without one: the score is recomputed from on-chain
  intents at reveal, and a claim the solution cannot back is rejected, having cost the claimant gas.
  There is nothing for a bond to secure. `[cow-1]`
- **No penalty regime.** A penalty regime exists to cover the gap between auction and settlement,
  where reverts strand people. Atomic settlement closes the gap — there is no interval in which a
  revert can leave anyone worse off than before. `[cow-2]`
- **No inventory.** The pull precedes the interactions, so the batch funds its own route. A solver
  needs no tokens at all.
- **Paid at settlement**, in-band, rather than through periodic accounting.
- **Permissionless entry**, rather than governance whitelisting. `[cow-3]`
- **Bounded cost of losing** — one commitment's gas, flat, independent of batch size.

## 5. What has been demonstrated

A prototype settles end to end against a live devnet: two chains, a real cross-chain dispatch, real
Uniswap V2 pools.

**Solvers hold nothing.** In a ten-minute run with eight users and five competing solvers, the
solvers were funded with L2 gas and nothing else — no tokens, no approvals, no L1 balance — and
settled 33 intents across 6 auctions. Capital relief is not an argument here; it is the operating
condition.

**Competition is real and legible.** Solvers differed only in how hard they searched. In one auction
the three that path-found across venues found a two-hop route and delivered 5.3% more surplus than
the two that only quoted direct pools, and fitted an extra intent into the batch. Nothing about that
was configured; it followed from where a background trader had left the pools.

**Overclaiming fails in public.** One solver was built to inflate its claimed score. It wins the
auction — a sealed bid cannot be checked, which is precisely what sealing costs — and then dies at
reveal when the score is recomputed, having paid gas for nothing. A losing solver promotes the runner
up and the batch settles.

> **§5 is incomplete.** The remaining claim — that a settlement which *fails* on L1 leaves no trace on
> L2, which is the whole basis of the "no penalty regime" argument — is implemented but has not yet
> been run. It must not be written up until it has been observed. The experiment: submit a valid
> intent, then dispatch a settlement carrying a signature over different terms. L2 cannot detect it;
> L1 must reject it; nothing may move on either chain.

## 6. What it costs

**No direct A↔B matching.** Every trade must have the numeraire on one leg. A `DAI → WETH` intent is
not expressible: it would be routed as two legs against the numeraire. This is a real regression
against CoW's matching, and it is the honest weak point of the design.

The constraint exists because the clearing price vector needs an anchor. Without one, quoting the
whole vector in larger units inflates the score for free. Pinning the numeraire is the cheap fix;
allowing arbitrary pairs turns the rule into a reference-price oracle, which needs its own security
review and has not had one.

**A dependency on EEZ.** The atomic cross-chain dispatch is not a property of Ethereum. This design
is only as available as the execution environment that provides it.

**An unfinished parameter set.** Batching cadence is undesigned, and the residue recipient does not
yet have an address.

## 7. What is established, and what is not

| | |
|---|---|
| Contracts | Five, ~34KB of runtime, `Executor` and `Relayer` small enough to audit exhaustively |
| Tests | 152, across unit, integration, fuzz and invariant suites |
| Invariants | 19, numbered, each cited at its enforcement site |
| Devnet | Settles end to end, including liquidity sourced on L1 inside the dispatch |
| Gas | Measured, and labelled measured rather than estimated |

Eight questions are open and written down as open. Two of them block deployment: the batching cadence
and the residue recipient. Two more are design questions this proposal would answer: whether direct
matching is a product requirement, and whether a user's payment should be independently verified
rather than inferred from the balance invariants.

The specification is 2,000 lines and its appendices are the contracts. It argues against itself in
several places and records where the code and the prose disagreed and which one was wrong.

## 8. The ask

*[To be completed — scope, duration, deliverables.]*

The work this would fund is not "build the thing"; the thing settles today. It is the part that
decides whether it should exist: resolving the direct-matching question, designing the batching
cadence against real flow, an audit of the L1 half, and an honest economic comparison against running
the same flow through an off-chain auction.

---

## Claims to verify

Written from the project's own notes and **not independently checked**. Each needs a source before
this leaves the building; a wrong figure about CoW in a document sent to Gnosis costs more than the
argument gains.

- `[cow-1]` That CoW solvers post a bond, and the scale of it. The project's notes cite one pool
  holding 500,000 USDC plus 1.5M COW.
- `[cow-2]` That CIP-87 exists to cover the auction-to-settlement gap, and that reverts in that gap
  are the motivation. The characterisation of what CIP-87 does needs checking against the CIP.
- `[cow-3]` That solver entry is governance-gated rather than permissionless, and roughly 15–25
  solvers are active.

Also unverified: whether "no penalty regime is needed" survives contact with someone who has operated
one. It follows from atomicity as argued, but operators usually know a failure mode the design does
not anticipate — and that is worth asking directly rather than asserting.
