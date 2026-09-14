# eez-settlement

Verifiable batch settlement: intents and a sealed-bid solver auction on an L2, liquidity sourced on
L1 inside a single cross-chain dispatch. Users keep custody throughout; the auction is recomputable
from on-chain data; every L1 pull carries the user's own EIP-712 signature.

The point of comparison is CoW Protocol, which runs its solver competition off-chain. Users there are
already protected on-chain by their signed limit price. What they trust off-chain is *auction
fairness* — whether the winning solution really was the best available. This design moves that
question on-chain.

**The design of record is `settlement-spec.md`, maintained privately** in
`github.com/inertialabsxyz/eez-settlement-planning`. Appendices A–E are the five contracts and `src/` is
those appendices extracted; where this README and the spec disagree, the spec wins.

That has a consequence worth stating plainly: the `§N` and `I<n>` citations throughout this
repository — in contract comments, tests and scripts — refer to a document that is not public. They
are load-bearing rather than decorative, and without the spec a reader can see *what* the code
enforces but not *why* it is the right thing to enforce.

## Three properties

- **Users never lose custody.** Tokens move exactly twice — out of the user's wallet and into it —
  both in the same L1 transaction. Nothing is held between transactions.
- **The auction is recomputable.** The winning solution is revealed on-chain and scored by
  deterministic code over on-chain intents. Any observer can verify the winner won.
- **The L1 leg authorises itself.** Every pull carries the user's EIP-712 signature over the exact
  terms, so neither the L2 nor the bridge can move funds a user did not sign for.

## Architecture

```
  L2 ──────────────────────────────      L1 ──────────────────────────────────────
  TokenRegistry   uint24 → address       Relayer    holds approvals, nothing else
  Book            intents                Executor   verify → pull → interact → pay
                  sealed-bid auction                → sweep → prove exact
                  deterministic scoring
                        │                                   ▲
                        └──────── EEZ, synchronous ─────────┘
                                  one dispatch per settlement
```

`Executor` understands nothing about intents, auctions or pricing. `Book` understands nothing about
liquidity. That separation is what lets the L1 half be small enough to reason about exhaustively, and
the L2 half be replaced without touching anything that holds an approval.

`Relayer` exists because `Executor` runs solver-supplied arbitrary calls. If it also held approvals,
an interaction could hand it `token.transferFrom(victim, attacker, …)` and the balance invariant
would not notice, because those tokens never pass through `Executor` at all (§3.1).

## The trust model is the point

A **fully compromised L2** — sequencer, `Book`, everything — still cannot move a user's funds.
`Executor.settle` is reachable only from `Book`'s cross-chain proxy, but that authenticates the
*caller*, not the *trade*. What makes it unexploitable is that every pull carries a per-intent
signature: an attacker who could present as that proxy still cannot forge a signature over terms the
user did not sign.

Invariants **I9–I13** are the set that survives that scenario, and they are the audit priority (§10).

## What is actually established

| | |
|---|---|
| `forge test` | 152 tests, 10 suites — unit, integration, fuzz and invariant |
| Invariants | I1–I19 numbered in §10, cited at their enforcement sites, matrix in the spec repository |
| Devnet end-to-end | Two settlements on a live EEZ enclave: one netting to zero, one routed through a real Uniswap V2 pool |
| Live market | 197 intents, 9 auctions, 6 settlements filling 33 intents, five competing solvers |
| Gas | §11, each figure labelled **measured** or **estimated** |

I16, I18 and I19 are deliberately *not* runtime checks — a straight-line loop is provably
unconditional, and a contract cannot inspect its own opcodes. They are review obligations and are
listed anyway.

## Layout

```
src/                 the five contracts, extracted from Appendices A–E
test/                the quality gate: unit, integration, fuzz, invariant
script/              devnet deployment and a scripted end-to-end settlement
demo/                a live market — users, competing solvers, a noise trader
```

The specification and invariant coverage matrix live in a separate private repository.

## Running it

The quality gate, and the only thing that gates a commit:

```sh
forge test
```

`forge build` is not a substitute — this codebase's whole argument is that its invariants hold, and
only the tests demonstrate that.

Against a live EEZ devnet, in order:

```sh
# a running enclave (see eez-rollup0/testing/kurtosis)
npm install
bash script/install-l1.sh     # tokens, Uniswap venues, Executor (+Relayer)
bash script/install-l2.sh     # TokenRegistry, Book, both cross-chain proxies
bash script/e2e.sh all        # scripted: coincidence-of-wants, then a routed fill

cd demo && npm install
npm run bootstrap && npm run doctor && npm run swarm 10
```

`script/README.md` and `demo/README.md` document the devnet's failure modes, several of which fail
silently. Run `npm run doctor` before anything else — it checks that L1 is including transactions and
the L2 safe head is advancing, which is the failure that most convincingly imitates an application
bug.

## Status: what is not decided

§13 of the spec lists eight open questions. Two of them block implementation and **must not be
resolved by picking a value**:

- **§13.2** — the address `windfallRecipient` sweeps residue to. §9.1 settles that it cannot be
  solver-nominated; it still needs an address.
- **§13.3** — `COMMIT_WINDOW` and the batching cadence are undesigned. The values in `Book` are
  placeholders that make the contract runnable, not answers.

Two more worth knowing before reading the code:

- **§13.4** — that a *failing* L1 leg unwinds the L2 writes is narrowed but not closed.
- **§13.5** — I7 requires the numeraire on one leg of every trade, so the intent space is a star
  around it and a direct `DAI → WETH` intent is not expressible. Whether direct matching is a product
  requirement is undecided; making it one turns the rule into a reference-price oracle and needs its
  own security review.

## Conventions

`CLAUDE.md` and `.claude/rules/` carry the working conventions: the spec is the source of truth,
invariants are numbered and cited, and spec and code move in the same commit.
