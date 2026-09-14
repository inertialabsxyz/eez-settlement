# eez-settlement

Verifiable batch settlement: intents and a sealed-bid solver auction on an L2, liquidity sourced on
L1 inside a single cross-chain dispatch. Users keep custody throughout; the auction is recomputable
from on-chain data; every L1 pull carries the user's own EIP-712 signature.

The point of comparison is CoW Protocol, which runs its solver competition off-chain. Users there are
already protected on-chain by their signed limit price. What they trust off-chain is *auction
fairness* — whether the winning solution really was the best available. This design moves that
question on-chain.

**`docs/settlement-spec.md` is the design of record.** Appendices A–E are reference implementations of
the five contracts and `src/` is those appendices extracted; where this README and the spec
disagree, the spec wins.

Every `§N` and `I<n>` in this repository — in contract comments, tests and scripts, roughly 180 of
them — refers to it. They are load-bearing rather than decorative: the spec is where the reasoning
lives, and §13 is where the unfinished parts are written down.

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
| Invariants | I1–I19 numbered in §10, each cited at its enforcement site |
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
docs/                settlement-spec.md — the design of record
```

## Running it

### The quality gate

The only thing that gates a commit:

```sh
forge test
```

`forge build` is not a substitute — this codebase's whole argument is that its invariants hold, and
only the tests demonstrate that.

### Against a live devnet

Everything below needs a running EEZ network. That comes from
**[eez-rollup0](https://github.com/inertialabsxyz/eez-rollup0)**, whose
[`testing/kurtosis/README.md`](https://github.com/inertialabsxyz/eez-rollup0/blob/main/testing/kurtosis/README.md)
is the authoritative guide — it covers the topology, the funded development accounts, the block
explorers, generating cross-chain traffic, and capturing diagnostics. Read it rather than relying on
the summary here.

The short version. You need Docker, the [Kurtosis CLI](https://docs.kurtosis.com/install/),
[Foundry](https://getfoundry.sh/introduction/installation/) v1.7.1, and the usual shell tools
(`jq`, `curl`, `openssl`, GNU `timeout`). Then, from an `eez-rollup0` checkout:

```sh
git submodule update --init --recursive eez-core-protocol
kurtosis engine start

export KURTOSIS_ENCLAVE=eez-dev
export KURTOSIS_ARGS_FILE="$PWD/testing/kurtosis/ci-args.yaml"
bash testing/kurtosis/start.sh "$KURTOSIS_ARGS_FILE"
```

The first start builds three images and takes several minutes. `bash testing/kurtosis/stop.sh` tears
it down and is destructive — it removes the enclave and its chain state.

Then, back in this repository:

```sh
export KURTOSIS_ENCLAVE=eez-dev   # every shell; script/dev.env reads it

npm install                       # prebuilt Uniswap V2 artefacts, devnet-only
bash script/install-l1.sh         # tokens, Uniswap venues, Executor (+Relayer)
bash script/install-l2.sh         # TokenRegistry, Book, both cross-chain proxies
bash script/e2e.sh all            # cow, then a routed fill, then the unwind

cd demo && npm install
npm run bootstrap                 # funds users; solvers get nothing but gas
npm run doctor                    # preflight — run this before anything else
npm run swarm 10
```

### Three things that will otherwise cost you an afternoon

**Run one enclave at a time.** Two full EEZ networks do not fit in a default Docker memory
allocation. The builder is the first thing the OOM killer takes, and when it dies no L1 transaction
from anyone is included — which looks exactly like an application bug and is not one.

**Wait for finality before deploying.** A fresh enclave produces empty L1 blocks and a safe head of
zero for two to three minutes while the builder registers with the relay. That is normal startup, not
failure.

**`npm run doctor` first, every time.** It checks the deployment is addressable, both chains agree on
the EIP-712 domain, and — the one that matters — that L1 is including transactions and the L2 safe
head is advancing. A stalled safe head means no settlement can complete, and every symptom above it
imitates a bug in this repository.

`script/README.md` and `demo/README.md` catalogue the rest, including several devnet behaviours that
fail silently rather than loudly.

## Status: what is not decided

§13 of the spec lists eight open questions. Two of them block implementation and **must not be
resolved by picking a value**:

- **§13.2** — the address `windfallRecipient` sweeps residue to. §9.1 settles that it cannot be
  solver-nominated; it still needs an address.
- **§13.3** — `COMMIT_WINDOW` and the batching cadence are undesigned. The values in `Book` are
  placeholders that make the contract runnable, not answers.

One more worth knowing before reading the code:

- **§13.5** — I7 requires the numeraire on one leg of every trade, so the intent space is a star
  around it and a direct `DAI → WETH` intent is not expressible. Whether direct matching is a product
  requirement is undecided; making it one turns the rule into a reference-price oracle and needs its
  own security review.

§13.4 — whether a *failing* L1 leg unwinds the L2 writes — is **closed**. `script/e2e.sh unwind`
dispatches a settlement carrying a signature over different terms than the trade it accompanies. L2
cannot detect that and accepts it; L1 re-derives the digest, rejects it (I9), and every L2 write
unwinds with it. Observed on a live devnet: auction unsettled, intent still `Live`, nonce unspent,
every balance untouched.

## Conventions

`CLAUDE.md` and `.claude/rules/` carry the working conventions: the spec is the source of truth,
invariants are numbered and cited, and spec and code move in the same commit.

The invariant coverage matrix, the agent prompts and the draft article live in a separate private
repository.
