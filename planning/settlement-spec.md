# Verifiable batch settlement — protocol specification

Status: **target design. Nothing in this document is implemented.**

> This specifies the system to be **built**, not the system that exists. Every contract, type,
> storage layout, invariant and parameter below is a proposal under review. The code in
> `src/settlement/` is an earlier prototype that satisfies almost none of it — different storage
> layouts, no signature verification, no auction phases, a weaker solvency invariant. Do not read
> this document as a description of running code, and do not read `src/settlement/` expecting to find
> it.
>
> The prose is written in the present indicative because that is how specifications read. It is not a
> claim that anything is built.

**Where to look for what:**

| Question | Document |
|---|---|
| What should be built? | **This document** |
| What exists today, and how does it behave? | `settlement-flow-current.md` |
| What is the gap, and in what order is it closed? | `settlement-implementation.md` |
| What will the flows look like once built? | `settlement-flow-target.md` |
| Why was custody abandoned? | `settlement-design.md` *(superseded, history only)* |
| The shared types and EIP-712 definition | **Appendix C**, extracted to `src/SettlementTypes.sol` |

This document is self-contained. It describes the system as designed, not how it got here.

---

## 1. What this is

A settlement venue in which users sign intents, solvers compete to fill them, and **the auction runs
on-chain, where anyone can recompute the winner from public data.** Intents and the auction live on
an L2. Liquidity is sourced on L1, atomically, inside a single cross-chain dispatch.

The point of comparison is CoW Protocol, which runs its solver competition off-chain. Users there are
already protected on-chain by their signed limit price. What they trust off-chain is *auction
fairness* — whether the winning solution really was the best available, and whether the solver passed
on the surplus they should have. This design moves that question on-chain.

Three properties define the system:

- **Users never lose custody.** Tokens move exactly twice: out of the user's wallet, and into it.
  Both movements happen in the same L1 transaction. Nothing is held between transactions.
- **The auction is recomputable.** The winning solution is revealed on-chain and scored by
  deterministic code over on-chain intents. Any observer can verify the winner won.
- **The L1 leg authorises itself.** Every pull carries the user's EIP-712 signature over the exact
  terms. Neither the L2 nor the bridge can move funds a user did not sign for.

## 2. Goals and non-goals

**Goals**

| | |
|---|---|
| G1 | A settlement that favours one account over another is not expressible in the payload |
| G2 | Auction outcomes are verifiable by any third party from on-chain data alone |
| G3 | No component can move user funds without the user's signature over those exact terms |
| G4 | A settlement that does not balance reverts rather than partially executing |
| G5 | Competing costs a solver a flat amount, independent of batch size or of losing |
| G6 | No bonds, no whitelist, no off-chain penalty regime |

**Non-goals.** Partial fills. Multi-block or recurring intents. Fee-on-transfer and rebasing token
support. Solver reputation or bonding. MEV protection beyond the sealed-bid mechanism. Cross-chain
settlement against more than one L1.

## 3. Architecture

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

`Executor` understands nothing about intents, auctions or pricing. It verifies signatures, performs a
payload, and refuses to end the transaction holding a different balance than it started with.

`Book` understands nothing about liquidity. It holds intents, runs the auction, and emits one call.

The separation is deliberate: it is what allows the L1 half to be small enough to reason about
exhaustively, and the L2 half to be replaced without touching anything that holds an approval.

### 3.1 Why `Relayer` is a separate contract

Interactions are solver-supplied arbitrary calls. An `Executor` that also held approvals could be
handed `token.transferFrom(victim, attacker, ...)` as an interaction and would drain every user who
had ever approved it. So approvals live in `Relayer`, `Relayer` answers only to `Executor`, and
`Executor` refuses any interaction targeting `Relayer`.

## 4. Trust model

| Party | Trusted with | Bounded by |
|---|---|---|
| Solver | Nothing | Signature verification, solvency invariant, on-chain scoring |
| `Book` (L2) | Auction fairness only | Cannot move funds — L1 verifies signatures independently |
| EEZ bridge | Liveness only | Cannot move funds — same reason |
| Numeraire allowlist | Which tokens may anchor a price vector | Governance, see §12 |

The bridge row is the one that shapes the design. `Executor.settle` is reachable only from the L2
`Book`'s cross-chain proxy, but that is an *authentication of the caller*, not of the trade. If an
attacker could present as that proxy — a flaw in address derivation, a composer bug, a compromise —
they would call `settle` with a payload of their choosing. Per-intent signatures make that
unexploitable: the attacker cannot forge a user's signature over terms the user did not sign.

**On what the signature adds.** The intent is already authenticated — `submitIntent` is a transaction
signed by the user's key, and `msg.sender` on L2 is the user. EIP-712 does not add authentication; it
adds **portability of that authentication across the chain boundary.** L1 cannot read L2 storage and
has no state proof available, so without a signature it would be trusting a chain of custody rather
than checking a proof.

## 5. Data model

### 5.1 L2 storage

```solidity
/// 2 slots, exactly full.
struct Intent {
    address account;      // slot 0, bytes 0–19
    uint24  sellTok;      //         bytes 20–22   registry id
    uint24  buyTok;       //         bytes 23–25
    uint40  deadline;     //         bytes 26–30   good to the year 36812
    uint8   state;        //         byte  31      Live | Filled | Cancelled
    uint128 sellAmount;   // slot 1, bytes 0–15
    uint128 limit;        //         bytes 16–31   minimum acceptable buy amount
}

/// 2 slots.
struct Bid {
    bytes32 commitment;   // slot 0
    address solver;       // slot 1, bytes 0–19
    uint88  claimedScore; //         bytes 20–30
    bool    out;          //         byte  31      revealed, skipped or disqualified
}

/// 3 slots.
struct Auction {
    bytes32 leadCommitment;  // slot 0
    address leader;          // slot 1, bytes 0–19
    uint88  leadScore;       //         bytes 20–30
    bool    settled;         //         byte  31
    uint40  commitDeadline;  // slot 2, bytes 0–4    T_C
    uint40  revealDeadline;  //         bytes 5–9    T_R
    uint16  leadIdx;         //         bytes 10–11  the cached leader's bid
}
```

`uint128` caps an amount at 3.4 × 10²⁰ whole units of an 18-decimal token. `uint88` caps a score at
3.1 × 10⁸ numeraire units at `PRICE_SCALE`, and is range-checked on the way in.

`uint24` token ids cap the registry at 16.7M entries. The narrower `uint16` would fit — slot 0 has two
spare bytes at that width — but registration is permissionless, and a 65,536-entry ceiling is
reachable by spam for roughly 2.6 billion gas, after which no further token could ever be listed.
`uint24` fills slot 0 exactly, costs nothing, and puts the ceiling out of reach.

### 5.1.1 `TokenRegistry`

```solidity
contract TokenRegistry {
    address[] public tokens;                 // id == index
    mapping(address => uint256) private _id; // stores id + 1, so 0 reads as unregistered

    function register(address token) external returns (uint24 id);  // idempotent
    function tokenAt(uint24 id) external view returns (address);

    /// Returns `found` separately: id 0 is a legitimate token, so a bare zero
    /// return cannot distinguish "the first token registered" from "not here".
    function idOf(address token) external view returns (uint24 id, bool found);
}
```

Append-only, permissionless, ungoverned. It exists for one reason: to compress `Intent` into two
slots. Registration is idempotent so a token cannot acquire two ids — not a safety issue, since
`Book` resolves id → address before matching a trade, but wasteful and confusing.

**An id confers nothing.** Every invariant in §10 holds regardless of what is registered. The
numeraire allowlist (§8, §12) is the governed surface and is entirely separate.

**The registry is L2-only.** The cross-chain payload carries full addresses, so L1 never resolves an
id and there is no mirror to keep in sync. A registry that both chains had to agree on would be a
synchronisation problem for no benefit.

**Two distinct index spaces.** These are unrelated and easy to conflate:

| | Where | Namespace | Width |
|---|---|---|---|
| `Intent.sellTok` / `buyTok` | L2 storage | Global registry id | `uint24` |
| `Trade.sellIdx` / `buyIdx` | Cross-chain payload | Index into that settlement's `tokens[]` | `uint8` |

`uint8` caps a single settlement at 256 distinct tokens, which is not a practical constraint.

**Signatures are transported, never stored.** The user passes their EIP-712 signature as calldata to
`submitIntent`; `Book` verifies it once, emits it in `IntentSubmitted`, and discards it. Solvers read
it from the event and carry it in the reveal payload. Storing 65 bytes on L2 would cost three storage
slots per intent and would erase the benefit of the two-slot layout above.

### 5.2 The cross-chain payload

```solidity
struct Trade {
    address account;
    uint8   sellIdx;      // index into SettlementData.tokens
    uint8   buyIdx;
    uint128 sellAmount;
    uint128 limit;
    uint40  deadline;     // signed; re-checked on L1
    uint64  nonce;        // signed; consumed on L1
}

struct Interaction {
    address target;
    bytes   callData;
}

struct SettlementData {
    address[]     tokens;
    uint256[]     clearingPrices;   // numeraire units per token; index 0 pinned to PRICE_SCALE
    Trade[]       trades;
    Interaction[] calls;            // arbitrary L1 venue calls sourcing the residual
}

function settle(SettlementData calldata d, bytes[] calldata signatures) external;
```

**`Trade` carries `deadline` and `nonce` because L1 must rebuild the digest.** Both are fields of the
signed intent (§5.3), and L1 has no other way to obtain them — it cannot read L2 storage, which is
the premise of the whole arrangement. Omitting them would make signature verification impossible.
They cost 64 bytes per trade in ABI encoding; §11 accounts for it.

**`Interaction` has no `value` field.** `Executor` has no `receive()` and therefore cannot hold ETH,
so a value field would always be zero — 32 bytes per interaction buying nothing, and the only path by
which an interaction could move native value. Removing it is both a payload saving and a surface
reduction. A route that needs to unwrap WETH is a deliberate future extension: add `receive()`, sweep
ETH surplus symmetrically in §9, and reinstate the field.

**There is no `surplusRecipient` in the payload.** A solver takes their profit explicitly, inside
`calls`, by routing it wherever they choose. Anything still in `Executor` at the end of the
settlement is residue by definition and goes to a protocol-controlled `windfallRecipient` that the
solver cannot name. §9.1 explains why that placement matters.

**Prices, not amounts.** Each trade's output is derived as `sellAmount · p[sell] / p[buy]`. Uniform
pricing is therefore *structural* — a settlement that favours one account over another cannot be
expressed in the payload at all (G1). It also compresses the payload, which matters when it crosses
chains.

**A coincidence of wants is an empty `calls` array.** That is the cheapest possible settlement and
needs no special path.

### 5.3 The signed intent

```solidity
bytes32 constant INTENT_TYPEHASH = keccak256(
    "Intent(address account,address sellToken,address buyToken,"
    "uint256 sellAmount,uint256 limit,uint256 deadline,uint256 nonce)"
);
```

The EIP-712 domain binds `name`, `version`, `chainId` of the **L1**, and the `Executor` address — the
signature is consumed on L1, so it must be scoped there. `Book`, verifying on L2 at submission, must
reproduce that same L1 domain rather than deriving one from its own chain.

Every numeric field is `uint256` even though `Trade` and `Intent` carry them narrow. EIP-712
`encodeData` pads to 32 bytes regardless, so nothing is saved by narrowing, and non-standard widths
are unevenly supported by wallet signing libraries. The type string is what wallets hash and render;
it uses only types every implementation agrees on. **Appendix C** holds the single shared definition
that both chains compute against — neither writes its own.

`nonce` is user-chosen and unordered. `Executor` keeps a bitmap: bit `nonce % 256` of word
`nonce / 256`, per account. Unordered nonces are required rather than preferred — a sequential nonce
would force a user's intents to settle in submission order, which cannot be guaranteed when different
intents land in different batches.

The nonce cannot be keyed on intent id. The user signs before `Book` assigns an id, so the id is not
in the signed message, and a signature not bound to it could be replayed under any unused id. §11
gives the cost consequence.

## 6. Lifecycle

```
  Intent      submitIntent ──▶ Live ──▶ Filled
                                 │
                                 └──▶ requestCancel ──[CANCEL_DELAY]──▶ Cancelled
                                      (still settleable until it lands)

  Auction     open ──▶ Committing ──[T_C]──▶ Revealing ──▶ Settled
                                                  │
                                                  ├──────▶ Dead   (no bids left to promote)
                                                  └──────▶ Dead   (T_C + MAX_REVEAL_PHASE)
```

| Phase | Window | Who may act |
|---|---|---|
| Committing | `[open, T_C)` | Any solver — `commitBid`, up to `MAX_BIDS` |
| — | `T_C` | Leader frozen. No later commitment can change it. |
| Revealing | `[T_C, T_R)` | The frozen leader only — `revealAndExecute` |
| Fallback | `T_R` elapsed | Anyone — `skipLeader` promotes next best, `T_R += REVEAL_WINDOW` |
| Dead | `T_C + MAX_REVEAL_PHASE` | Nobody. Intents are free again. |

Two properties fall out of the phase boundary at `T_C`, and both are load-bearing:

**A solver never has to expose their route to discover whether they won.** The leader is known before
any reveal happens. Without a hard boundary the leader can only be resolved at reveal time, which
means broadcasting the full payload to find out — and an observer can read it from the mempool,
outbid, and settle the stolen route.

**`skipLeader` terminates.** Because the candidate set cannot grow after `T_C`, every skip strictly
shrinks it. Without the boundary, a skipped solver simply re-commits and stalls the batch again, one
window at a time, indefinitely.

**Cancellation is delayed, not locked.** The converse leak is real: a user watches a reveal land in
the mempool, cancels, and voids a route that has just been made public — for the price of gas, and at
profit if the user is a rival solver who submitted an attractive intent precisely to do this.

An earlier draft closed it with a `Locked` intent state entered at `T_C`. That cannot be built.
**`Book` does not know which intents an auction covers until the reveal** — `intentIds` live inside
the commitment, which is the whole point of sealing it. There is no moment at `T_C` when the set is
known, so nothing can be locked then.

Instead, cancellation is a two-step: `requestCancel`, then `finalizeCancel` after `CANCEL_DELAY`. An
intent stays settleable until the cancellation lands, and a solver reads `cancelEffectiveAt` when
building a batch, including only intents whose cancellation cannot arrive before their auction ends.
`CANCEL_DELAY = COMMIT_WINDOW + MAX_REVEAL_PHASE` is the smallest delay no running auction can
outlive — which is why the reveal phase needs a hard stop, rather than extending indefinitely on
every skip.

Intent states are therefore **`Live`, `Filled`, `Cancelled`**. See Appendix D.

## 7. The auction

### 7.1 Why bids are sealed

A solver's route **is** their alpha. An auction that takes the full payload in calldata lets a
competitor copy the route, add a wei of surplus, and win — which punishes doing the routing work at
all.

Solvers therefore commit to

```
keccak256(abi.encode(d, intentIds, salt, msg.sender, auctionId, address(book), block.chainid))
```

plus a **claimed score**. The highest claim leads. Only the leader reveals, and only after `T_C`.
Losers keep their routes private permanently.

- `msg.sender` and `auctionId` prevent replay of another solver's commitment.
- `address(book)` and `block.chainid` prevent replay across deployments and forks.
- `salt` prevents brute-forcing a guessable solution space out of the hash.

The auction remains verifiable (G2) because the winner's solution is revealed on-chain and scored by
deterministic code over on-chain intents.

### 7.2 Why there is no bond

**Overclaiming is self-defeating.** The score is recomputed from on-chain intents at reveal, and a
claim the solution cannot back is rejected — the claimant has paid gas for nothing.

**A misbehaving solver cannot take funds.** Settlement is atomic and the L1 invariants hold
regardless of what the solver submitted. There is no gap between auction and settlement in which a
revert can strand anyone, so there is nothing for a bond to secure and no penalty regime to
administer (G6).

Ties go to the earlier commitment.

### 7.3 Scoring

Score is total surplus delivered to users above their own stated limits, valued in the settlement's
numeraire. For each trade:

```
score += (sellAmount · p[sell] − limit · p[buy]) / PRICE_SCALE
```

This is algebraically identical to `(buyAmount − limit) · p[buy] / PRICE_SCALE` with
`buyAmount = sellAmount · p[sell] / p[buy]`, but uses one `mulDiv` instead of two and carries no
intermediate rounding. The same expression is the limit check: the trade is acceptable exactly when
the score contribution is non-negative.

## 8. Pricing and the numeraire

Token index 0 is the numeraire and its price is pinned to `PRICE_SCALE`. Two further rules make that
pin actually bind:

1. **`tokens[0]` must be on the numeraire allowlist.** Otherwise a solver deploys a shell token,
   places it at index 0, and pins a price that anchors nothing.
2. **Every trade must have the numeraire on one side** — `sellIdx == 0 || buyIdx == 0`. Otherwise a
   settlement between two non-numeraire tokens leaves the pin floating: the whole price vector can be
   quoted in larger units, every fill is byte-identical, and the score is multiplied arbitrarily.

With both rules, one of `p[sell]` and `p[buy]` is always `PRICE_SCALE`, so from §7.3 the free price
enters the score linearly, with a sign that depends on which side of the trade the numeraire is on.
The two cases are not symmetric:

- **The numeraire is sold** (`sellIdx == 0`). The pin fixes `p[sell]`, so the free price appears only
  in `−limit·p[buy]`: the score is **strictly decreasing** in it. Inflating the price of the token the
  user is buying costs the solver score outright, and buys them nothing — the user simply receives
  less of it.
- **The numeraire is bought** (`buyIdx == 0`). The pin fixes `p[buy]`, and §7.3 reduces to
  `sellAmount·p[sell]/PRICE_SCALE − limit`. The free price enters with a **positive** coefficient, so
  here the score *rises* as it is inflated.

The second case does not open a strategy, but the reason is delivery rather than sign. That same
expression is the buy amount `Executor._pay` hands the user, so the two move together exactly: **every
point of score bought by inflating a price is one numeraire unit the settlement is then obliged to
deliver on L1**, where I11 checks that the solver actually sourced it. Stated generally, for any
`p′ ≥ p` componentwise with the numeraire pinned,

```
score(p′) − score(p)  ≤  N(p′) − N(p)
```

where `N` is the numeraire paid out across the batch's numeraire-buy legs. A batch with no
numeraire-buy leg has `N = 0`, which is the strictly-decreasing case above.

Either way price inflation stops being a strategy rather than being detected as one — this is the
property the auction's soundness rests on, and §10 asserts it as a fuzz invariant.

> **Corrected 2026-09-11.** This section previously claimed the score was "strictly decreasing in the
> free price" without qualification. That is true only of the numeraire-sell case; the fuzz tests for
> I8 found the numeraire-buy case, where a doubled free price takes a 1 WETH → 1,900 USDC intent from
> a score of 100 to 2,100. The conclusion survives, the mechanism stated above replaces it. The code
> comment in Appendix D `_validateAndScore` ("Monotone decreasing in the free price") carries the same
> error and is **not** yet corrected — `src/Book.sol` is that appendix verbatim, so the two must be
> changed in one commit.

**Cost.** A settlement cannot match token A directly against token B without a numeraire leg. On L1
that route goes through WETH or USDC in practice anyway. The alternative — per-token reference prices
maintained by the book — is an oracle, with a materially larger security surface. See §12.

## 9. Settlement on L1

```
settle(d, signatures)
  │
  ├─ require msg.sender == expectedProxy
  ├─ snapshot   opening[i] = balanceOf(tokens[i]) for each listed token; openingEth = balance
  ├─ verify     per trade: recover EIP-712 signer == account, terms match, consume nonce
  ├─ pull       one Relayer.pullBatch call — safeTransferFrom each seller
  ├─ interact   solver-supplied calls, rejecting any that target Relayer
  ├─ pay        buyAmount = mulDiv(sellAmount, p[sell], p[buy]); require >= limit; safeTransfer
  │             I16: the loop is unconditional — no runtime counter, see §9.1
  ├─ sweep      for each token: require bal >= opening[i]
  │             send bal − opening[i] to windfallRecipient
  └─ prove      for each token: require balanceOf(tokens[i]) == opening[i]
                require address(this).balance == openingEth
```

**The ordering is the design.** *Pull before interact* funds the route from the batch itself, so a
solver needs no capital of their own. *Interact before pay* lets the route produce the buy side.
Reordering any of the three breaks the system.

**The exact-balance invariant.** The executor must end every settlement holding precisely what it
started with — in steady state, nothing. A non-decreasing check would be sufficient to prevent theft
during the transaction, but it permits residue to accumulate, and accumulated residue is stealable
afterwards: an interaction can leave a standing `approve` that outlives the transaction, or transfer
out a token the solver simply did not list. Sweeping to exactly zero removes the premise. There is
nothing to take, so a standing allowance on the contract is worthless.

This is the one check that cannot be delegated to L2. It is a handful of `SLOAD`s that makes any
upstream pricing, routing or accounting bug **revert instead of drain** (G4), without L1 needing to
understand orders at all.

### 9.1 Why the residue must not go to the solver

The balance invariant protects `Executor`. It does **not** protect users, and the distinction is easy
to lose.

Consider a settlement where `_pay` fails to pay one trade — a loop-bound or indexing bug of exactly
the shape that has already been found once in this codebase. The user's tokens were pulled, so they
sit in `Executor`. If the sweep sent residue to a solver-nominated address, that shortfall would be
paid straight to the solver, and no balance check would notice: `bal >= opening[i]` holds throughout,
and the equality is restored by the very transfer that steals the funds. A verifiable auction would
have converted a bug into solver revenue.

So `windfallRecipient` is **immutable and protocol-controlled**, never named in the payload. A solver
who wants profit takes it explicitly inside `calls`, where it is visible and deliberate. Residue is
by definition value nobody claimed, and routing it somewhere the solver does not control removes any
incentive to engineer it.

This is not airtight and should not be read as such: a solver can still route value to themselves
inside `calls`, which is their prerogative and is the same economics. What it removes is the
*accidental* windfall — the case where a defect elsewhere silently enriches whoever submitted the
settlement.

**Declared surplus was considered and rejected.** Having the solver state expected surplus per token
and asserting equality would be stronger still, but AMM output depends on pool state at execution
time. A pool that moves *favourably* between solution-building and settlement would produce more than
declared and revert — turning a good outcome into a failed batch. The asymmetric form above keeps the
exact final balance without penalising favourable slippage.

**`_pay` must have no conditional path.** An earlier draft specified a runtime counter here —
increment per transfer, assert it equals `trades.length`. Writing the contract showed that to be dead
code: in a straight-line `for i < trades.length` loop with no `continue`, the counter is provably
equal and the check cannot fail. It would be error handling for an impossible case.

The property is real; the enforcement is not runtime. **`_pay` iterates every trade unconditionally,
and no branch may skip an iteration.** That is a constraint on the shape of the loop, checked by
review and by the test that every account's balance moves, not by an assertion inside it. If `_pay`
ever gains a conditional path, the counter comes back and so does the invariant.

All ERC-20 calls go through `SafeERC20`. Tokens that return no data on `transfer` — USDT among them —
are otherwise unsettleable, and USDT is the largest-volume ERC-20 in existence.

## 10. Invariants

Numbered so tests can cite them.

| | Invariant | Enforced |
|---|---|---|
| I1 | Every trade corresponds to a live intent matching on account, tokens, amount and limit | L2, at reveal |
| I2 | `intentIds.length == trades.length` | L2, at reveal |
| I3 | No intent id appears twice in one settlement | L2 — `state` written in-loop, so the second read fails |
| I4 | Every user receives at least the limit they signed | L2 at reveal, and again on L1 at pay |
| I5 | Every trade's buy amount derives from one shared price vector | Structural — not expressible otherwise |
| I6 | `tokens[0]` is allowlisted and `clearingPrices[0] == PRICE_SCALE` | L2, at reveal |
| I7 | Every trade has the numeraire on one side | L2, at reveal |
| I8 | Inflating a free price never gains score beyond the numeraire it obliges the batch to deliver; with no numeraire-buy leg, score is non-increasing in every free price (§8) | Property — fuzz invariant |
| I9 | Every pull is covered by the account's EIP-712 signature over those exact terms | **L1** |
| I10 | No nonce is consumed twice | **L1** |
| I11 | `Executor` holds exactly its opening balance of every listed token, and of ETH, at exit | **L1** — equality, not a bound |
| I12 | No interaction targets `Relayer` | **L1** |
| I13 | `Relayer` moves tokens only for `Executor` | **L1** |
| I14 | Only the frozen leader may reveal, and only within `[T_C, T_R)` | L2 |
| I15 | The candidate set cannot grow after `T_C` | L2 |
| I16 | `_pay` iterates every trade unconditionally — no branch skips one | Review + test, **not** a runtime check (§9.1) |
| I17 | Residue is unreachable by the solver | **L1** — `windfallRecipient` immutable, not in the payload |
| I18 | Interactions are dispatched with `call`, never `delegatecall` | Review — a one-word change voids I12 and I13 |
| I19 | `settle` is the only entry point that emits calls or moves value | Review — the reentrancy argument in §3.1 depends on it |

I11 is an **equality**. Stated as `>=` it would permit a settlement to end holding more than it
started with, which sounds harmless and is not: the excess is exactly the shape an unpaid user
leaves behind. See §9.1.

I16 and I17 exist because I11 protects the *contract*, not the *user*. Nothing in the balance
invariants notices a user who was pulled from and never paid — see §13.8.

I16, I18 and I19 are **not runtime checks**, and are listed anyway. Each is a property that
assertions cannot usefully express — the first because the check is provably true in a straight-line
loop, the latter two because a contract cannot inspect its own opcodes. They are review obligations,
and writing them down is the only enforcement available.

I9 through I13 are the ones that survive a fully compromised L2. That is the set worth auditing
hardest.

## 11. Costs

Measured figures are from `forge test` against the prototype at `3f54dd1`, using real Uniswap V2
bytecode. Target figures are **estimates** from storage-slot counts and published opcode costs, and
are replaced by measurements as the implementation lands. **The L1 `settle` figures are now measured
too**, by `test/gas/BatchScaling.t.sol`; see the note below the component table. Every figure in this
section is now labelled.

The "prototype" column is the *existing, superseded* code, included only to show what the target
figures are extrapolated from. It is not a partial implementation of this specification.

All L2 figures are now **measured against the reference implementations** in the appendices, not
estimated — see `scratch/` and the note below. The L1 figures were measured later, in this
repository's `test/gas/` suite.

| | Prototype (superseded) | This design |
|---|---|---|
| `submitIntent` (L2), steady state | 168,426 | **115,929** *(measured)* |
| `submitIntent` (L2), first use of a nonce word | — | **150,139** *(measured)* |
| `commitBid` (L2), subsequent bid | 119,217 | **99,336** *(measured)* |
| `commitBid` (L2), first bid, opens the auction | — | **143,121** *(measured)* |
| `settle` per trade (L1), returning user | 42,332 | **48,044** *(measured)* |
| `settle` per trade (L1), user's first trade | — | **65,518** *(measured)* |
| `settle` per trade (L1), first trade *in that token* | — | **82,146** *(measured)* |
| vs. direct swap (138,735) | −69% | **−65%** / −53% first *(measured)* |
| Payload | 166.6 B/trade | ~54 B/trade packed, see below |

**The earlier estimates in this section were wrong, and low.** They were derived from storage-slot
counts alone: 2 slots for `Intent`, 2 for `Bid`. The slot counts were right — `forge inspect`
confirms all three structs pack exactly as §5.1 claims — but the surrounding writes were not counted.
`submitIntent` also pays for the dynamic array's length slot and an event carrying the whole
`SignedIntent` plus a 65-byte signature; `commitBid` also pays for the array length, the O(1) leader
cache (a fresh `leadCommitment` slot at 20,000), and its own event.

Net effect on the efficiency argument: `submitIntent` improves **31%** against the prototype rather
than the 55% claimed, and `commitBid` **17%** rather than 34%. `commitBid` is also doing strictly
more work than the prototype's — caching the leader is what removes the unbounded-scan DoS — so the
comparison understates it.

L1 per-trade cost is close to its floor. It decomposes as two ERC-20 balance transitions per user,
two cold account accesses and two `Transfer` logs — the two-movement claim in §1, and there is no
third movement to remove. The signature premium on top of it is:

| Component | Gas |
|---|---|
| `ecrecover` | 3,000 |
| Struct hashing | ~500 |
| 65 bytes of signature calldata | ~1,040 |
| Nonce bitmap, word already dirty | 2,900 |
| Nonce bitmap, account's first touch of that word | 20,000 |

So roughly **+7,500 for a returning user and +24,600 on their first trade**. Replay protection
dominates, not `ecrecover`. In money at ETH $2,490 and L1 at 0.256 gwei, that is $0.0008 and $0.0026
per trade — against roughly $232 of price improvement on a netted 1 ETH order in a thin pool. **The
gas discussion is not decision-relevant** except for small orders in deep pools, where there is little
to win either way.

**The estimates above held, and the table was one row short.** `testGasSettleAcrossBatchSizes` in
`test/gas/BatchScaling.t.sol` measures `settle` at n = 1, 2, 4, 8, 16, 32, 64 and takes the marginal
cost across the 2 → 64 span, which averages out the constant overhead of the interaction block and
the restore loop. The returning-user figure came in at **48,044** against an estimated ~50,000, and
the first-trade figure at **65,518** against ~67,000 — both within 4%. The difference between them,
**17,474**, is the nonce word alone against the 17,100 this table predicts for it, within 2%.

What the table does not carry is that a settlement has a *second* cold slot per user: the recipient's
balance in the token they are buying, which `_pay` writes. A user who is new to the protocol and new
to the token pays both, at **82,146** per trade — 16,628 above the first-trade figure and outside
anything §11 previously contemplated. It is not a defect in the design and there is nothing to fix in
`Executor`; it is the ordinary cost of an ERC-20 balance going from zero, and it is listed now because
a first-trade figure that silently assumed a warm one understated the worst case by a quarter.

Cost of competing is **flat, and independent of batch size** — a commitment is a hash and a number.
Losing an auction no longer costs a solver in proportion to the solution they built (G5).

**Payload.** `Trade` ABI-encodes to **224 bytes**, not the prototype's 160: signature verification on
L1 requires `deadline` and `nonce` to travel with the trade (§5.2), adding two words. A 65-byte
signature per trade adds roughly a further 96 bytes encoded. Dropping `Interaction.value` returns 32
bytes per interaction, which does not offset it. Net, the payload roughly doubles per trade against
the measured prototype figure above — the price of an L1 leg that authorises itself.

Packing is deferred. `Trade` packs to 67 bytes against 224 encoded, a 70% reduction — but most of
what is removed is zero bytes at 4 gas each, so it is worth only about 1% of L1 execution gas. The
reduction may matter a great deal for cross-chain anchoring, where `calldata_bytes` is billed, but
that cost is unmeasured. **It is measured before it is built** — and the doubling above makes that
measurement more urgent than it was, since anchoring cost scales with exactly the bytes that just
grew.

Cross-chain dispatch is roughly 61.5k and flat regardless of L1 work, so the L1 leg is not billed into
the L2 transaction. **That figure is provisional**: every reading came from an execution that later
rolled back, because the harness stored `gasleft()`-derived values, which never commit on EEZ. See
`eez-gotchas.md`.

## 12. Parameters and governance

| Parameter | Purpose | Setting |
|---|---|---|
| `PRICE_SCALE` | Numeraire pin | `1e18`, constant |
| `COMMIT_WINDOW` | `T_C − open` | **Undesigned — see §13.3.** 60s in Appendix D as a placeholder |
| `REVEAL_WINDOW` | One leader's turn, and each skip extension | 60s |
| `MAX_REVEAL_PHASE` | Hard stop on the reveal phase, after which the auction dies | 480s — 8 turns |
| `CANCEL_DELAY` | `requestCancel` → `finalizeCancel` | `COMMIT_WINDOW + MAX_REVEAL_PHASE` = 540s |
| `MAX_BIDS` | Bound on the per-auction bid array | 64 — CoW sees 15–25 active solvers |
| Numeraire allowlist | Which tokens may sit at index 0 | Governed |
| `windfallRecipient` | Destination for unclaimed residue | Immutable, protocol-set — **see §13.2** |

The numeraire allowlist is the only governance surface with teeth, and it is deliberately narrow:
adding a token lets it anchor a price vector, but every safety invariant in §10 holds regardless of
what is on the list. The token registry is *not* governed — an id is an index, not an endorsement.

## 13. Open questions

1. **Will flow move?** The only question that matters, and it is not a technical one. Retail chooses
   on price and UX; auction fairness matters to institutions and DAOs. The test is whether any desk
   or treasury treats a trusted auction as an approval blocker today. If none does, the flow never
   arrives — and solvers follow flow, not verifiability.
2. **Who is `windfallRecipient`?** *Mostly resolved by §9.1, but still needs an address.* The solver
   takes their profit in-band, inside `calls`, so this is residue only — value nobody claimed. It
   must be somewhere the solver does not control, which rules out naming it in the payload. A
   protocol treasury is the obvious answer; pro-rata redistribution to the batch is defensible and
   materially more complex. Still blocks implementation, but it is now a smaller question than it
   was.
3. **`COMMIT_WINDOW` and batching cadence.** Undesigned. §6 shows lazy opening, where the first
   `commitBid` on an unallocated id opens the auction, as a placeholder. A scheduled cadence would
   replace that and nothing else.
4. **Atomicity under stress is assumed, not shown.** The existing harness passes vacuously — it
   captures the exit code of the send, not the transaction's outcome. `eez-gotchas.md` §4 gives the
   hook: the cross-chain front's nonce is the only reliable "settled on both chains" signal.
5. **Does direct A↔B matching matter?** §8 forbids a trade without a numeraire leg. If direct
   matching is a product requirement, the rule becomes a reference-price oracle and needs its own
   security review.
6. **Fee budget.** Proving and verification must fit inside roughly 5bps. Commit-reveal does so
   comfortably — about $0.006 against $0.50 on a $1,000 trade. ZK would not, at small trade sizes.
7. **Where should signature verification live — `Executor` or `Relayer`?** §9 puts it in `Executor`,
   which then calls `Relayer.pullBatch`; `Relayer` trusts its caller completely. The alternative is
   that the contract holding the authority verifies the authorisation itself, against the exact
   transfer it is about to make. Permit2 is built the second way, and it is the stronger arrangement:
   no bug in `Executor`'s payload handling could produce a pull that `Relayer` would accept, because
   `Relayer` would re-derive the digest from the `(token, from, amount)` it is executing.

   The cost is that `Relayer` stops being twenty lines. It gains the EIP-712 domain, the nonce
   bitmap, and real bug surface — which cuts directly against the argument in §3 that the L1 half is
   small enough to reason about exhaustively. There is also a partial-coverage problem: `Relayer`
   sees only the sell side, so it could confirm *"this user authorised selling X of T"* but not
   *"this user was paid"*. The limit check would stay in `Executor` regardless, so verification ends
   up split across both contracts either way.

   Not currently a deliberate choice, which is why it is listed. My inclination is to move it, on the
   principle that authority and authorisation belong together, and to accept a larger `Relayer`.
8. **Should a user's payment be independently verified?** I16's counter catches a *skipped* payment
   but not a payment to the wrong account or of the wrong amount. The only true independent check is
   to snapshot each account's buy-token balance and assert the delta covers `limit` — roughly 5,200
   gas per trade, about 10% on top of the L1 leg. That is a real cost for a guard against bugs in
   five lines of code, and I do not have a strong view. Worth deciding rather than defaulting.

## 14. Why a solver would participate

Solvers are a small set of professional teams — roughly 15–25 active on CoW — running several venues
at once. They follow order flow and will not move for verifiability, which matters to users and
integrators rather than to them. Flow has to come first.

What this design offers them is capital relief:

- **No bond.** CoW solvers are bonded; one pool held 500,000 USDC plus 1.5M COW. §7.2 explains why
  nothing here needs securing.
- **No penalty regime.** CIP-87 exists because there is a gap between auction and settlement where
  reverts happen. Atomic settlement closes the gap.
- **Paid at settlement**, not through weekly accounting — a direct working-capital improvement.
- **Permissionless entry**, rather than governance whitelisting.
- **No inventory required.** L1 liquidity is sourced atomically inside the settlement, and the pull
  precedes the interactions, so the batch funds the route.
- **Bounded cost of losing** — flat, and independent of batch size.

---

## Appendix A — `Relayer`

Reference implementation. Normative where it disagrees with the prose above.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// Holds user approvals, and nothing else.
///
/// The separation from `Executor` is structural, not defence in depth. `Executor`
/// runs solver-supplied arbitrary calls; if it also held approvals, an
/// interaction could call `token.transferFrom(victim, attacker, ...)` and drain
/// every user who had ever approved it — and the balance invariant would not
/// notice, because those tokens never pass through `Executor` at all.
contract Relayer {
    using SafeERC20 for IERC20;

    address public immutable executor;

    error NotExecutor();
    error LengthMismatch();

    constructor(address _executor) {
        executor = _executor;
    }

    /// No `to` parameter: funds always land in `Executor`. A caller-specified
    /// destination would be safe only for as long as every caller passed the
    /// right thing.
    function pullBatch(
        address[] calldata tokens,
        address[] calldata froms,
        uint128[] calldata amounts
    ) external {
        if (msg.sender != executor) revert NotExecutor();
        if (tokens.length != froms.length || tokens.length != amounts.length) {
            revert LengthMismatch();
        }
        for (uint256 i = 0; i < tokens.length; i++) {
            IERC20(tokens[i]).safeTransferFrom(froms[i], executor, amounts[i]);
        }
    }
}
```

No admin, no pause, no upgrade path, no token balances. Any privileged function here is a drain
vector, and the absence of one is the feature.

---

## Appendix B — `Executor`

Reference implementation. Normative where it disagrees with the prose above.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {
    SettlementData,
    Trade,
    Interaction,
    SignedIntent,
    SettlementEIP712
} from "./SettlementTypes.sol";
import {Relayer} from "./Relayer.sol";

interface IEEZ {
    function computeCrossChainProxyAddress(address target, uint64 rollupId)
        external view returns (address);
}

/// The L1 half. Verifies, performs a payload, and refuses to end the
/// transaction holding a different balance than it started with.
///
/// It understands nothing about intents, auctions or pricing — that is all L2.
/// What it does not delegate is authorisation: every pull carries the account's
/// own EIP-712 signature, so neither the L2 book nor the bridge can move funds
/// a user did not sign for.
contract Executor {
    using SafeERC20 for IERC20;

    Relayer public immutable relayer;
    address public immutable windfallRecipient;
    address public immutable eez;
    uint64  public immutable l2RollupId;
    address public immutable admin;

    /// Cached at setL2Caller: the derivation is a cold external call, and the
    /// result never changes.
    address public expectedProxy;

    /// account => nonce word => bitmap. Unordered, because a sequential nonce
    /// would force a user's intents to settle in submission order — which cannot
    /// hold when they land in different batches.
    mapping(address => mapping(uint256 => uint256)) public nonceBitmap;

    uint256 private immutable _cachedChainId;
    bytes32 private immutable _cachedSeparator;

    error NotProxy();
    error NotAdmin();
    error ProxyAlreadySet();
    error LengthMismatch();
    error BadSignature(uint256 index);
    error IntentExpired(uint256 index);
    error NonceUsed(uint256 index);
    error TargetForbidden(uint256 index);
    error InteractionFailed(uint256 index);
    error LimitNotMet(uint256 index, uint256 got, uint256 want);
    error NotSolvent(address token);
    error BalanceNotRestored(address token);
    error EthLeaked();

    event Settled(uint256 trades, uint256 interactions);

    constructor(address _eez, uint64 _l2RollupId, address _windfallRecipient) {
        require(_windfallRecipient != address(0), "windfall recipient required");
        admin             = msg.sender;
        eez               = _eez;
        l2RollupId        = _l2RollupId;
        windfallRecipient = _windfallRecipient;
        relayer           = new Relayer(address(this));

        _cachedChainId   = block.chainid;
        _cachedSeparator = SettlementEIP712.domainSeparator(block.chainid, address(this));
    }

    function setL2Caller(address book) external {
        if (msg.sender != admin) revert NotAdmin();
        if (expectedProxy != address(0)) revert ProxyAlreadySet();
        address p = IEEZ(eez).computeCrossChainProxyAddress(book, l2RollupId);
        require(p != address(0), "bad proxy");
        expectedProxy = p;
    }

    /// Re-derive across a chain split rather than caching blindly, or signatures
    /// from the original chain replay on the fork.
    ///
    /// `Book` reproduces this same value from the L1 chain id it was deployed
    /// against. Both sides compute it through `SettlementEIP712` and neither
    /// writes its own — a divergence here would pass on L2 at submission and
    /// fail on L1 after the batch had already crossed.
    function domainSeparator() public view returns (bytes32) {
        return block.chainid == _cachedChainId
            ? _cachedSeparator
            : SettlementEIP712.domainSeparator(block.chainid, address(this));
    }

    // ------------------------------------------------------------------
    // Settlement
    // ------------------------------------------------------------------

    /// @notice Perform a settlement. Callable only by the L2 book's cross-chain proxy.
    ///
    /// Ordering is verify -> pull -> interact -> pay -> restore. Pull before
    /// interact funds the route from the batch itself, so a solver needs no
    /// capital. Interact before pay lets the route produce the buy side. Any
    /// failure, on either chain, unwinds all of it.
    ///
    /// I19: this is the only entry point that emits calls or moves value. The
    /// reentrancy argument depends on it — a target re-entering here fails the
    /// proxy check, and there is nowhere else to enter.
    function settle(SettlementData calldata d, bytes[] calldata signatures) external {
        if (msg.sender != expectedProxy) revert NotProxy();
        if (signatures.length != d.trades.length) revert LengthMismatch();
        if (d.clearingPrices.length != d.tokens.length) revert LengthMismatch();

        uint256 nTokens = d.tokens.length;
        uint256[] memory opening = new uint256[](nTokens);
        for (uint256 i = 0; i < nTokens; i++) {
            opening[i] = IERC20(d.tokens[i]).balanceOf(address(this));
        }
        uint256 openingEth = address(this).balance;

        _verifyAndPull(d, signatures);
        _interact(d);
        _pay(d);
        _restore(d, opening, openingEth);

        emit Settled(d.trades.length, d.calls.length);
    }

    /// Recover each account's signature over the exact terms being executed, then
    /// pull in one call. I9 and I10 — the checks that survive a compromised L2.
    function _verifyAndPull(SettlementData calldata d, bytes[] calldata signatures) private {
        uint256 n = d.trades.length;
        address[] memory tokens  = new address[](n);
        address[] memory froms   = new address[](n);
        uint128[] memory amounts = new uint128[](n);

        bytes32 separator = domainSeparator();

        for (uint256 i = 0; i < n; i++) {
            Trade calldata t = d.trades[i];
            address sellToken = d.tokens[t.sellIdx];

            if (block.timestamp > t.deadline) revert IntentExpired(i);
            _consumeNonce(t.account, t.nonce, i);

            // The narrow payload widths widen implicitly into the signed form.
            // Only `SignedIntent` is canonical; `Trade` is an encoding of it
            // chosen for calldata size.
            bytes32 digest = SettlementEIP712.digest(
                separator,
                SignedIntent({
                    account:    t.account,
                    sellToken:  sellToken,
                    buyToken:   d.tokens[t.buyIdx],
                    sellAmount: t.sellAmount,
                    limit:      t.limit,
                    deadline:   t.deadline,
                    nonce:      t.nonce
                })
            );
            // OZ's recover reverts on a malleable or malformed signature rather
            // than returning address(0), so high-s is rejected for us.
            if (ECDSA.recover(digest, signatures[i]) != t.account) revert BadSignature(i);

            tokens[i]  = sellToken;
            froms[i]   = t.account;
            amounts[i] = t.sellAmount;
        }

        relayer.pullBatch(tokens, froms, amounts);
    }

    function _consumeNonce(address account, uint64 nonce, uint256 i) private {
        uint256 word = nonce >> 8;
        uint256 bit  = 1 << (nonce & 0xff);
        uint256 bits = nonceBitmap[account][word];
        if (bits & bit != 0) revert NonceUsed(i);
        nonceBitmap[account][word] = bits | bit;
    }

    /// Solver-supplied arbitrary calls. Two rules, both load-bearing:
    /// I12 — the relayer is unreachable, because it holds every approval and
    /// answers to this contract; and I18 — this is `call`, never `delegatecall`,
    /// which would let a target execute as this contract and void both.
    function _interact(SettlementData calldata d) private {
        address r = address(relayer);
        for (uint256 i = 0; i < d.calls.length; i++) {
            Interaction calldata c = d.calls[i];
            if (c.target == r) revert TargetForbidden(i);
            (bool ok,) = c.target.call(c.callData);
            if (!ok) revert InteractionFailed(i);
        }
    }

    /// Uniform pricing is structural: every output derives from the same vector,
    /// so a settlement favouring one account is not expressible.
    ///
    /// I16: this loop is unconditional. No branch may skip a trade — a skipped
    /// payment leaves the user's tokens in this contract, where `_restore` would
    /// sweep them away as residue.
    function _pay(SettlementData calldata d) private {
        for (uint256 i = 0; i < d.trades.length; i++) {
            Trade calldata t = d.trades[i];
            uint256 buyAmount = Math.mulDiv(
                t.sellAmount, d.clearingPrices[t.sellIdx], d.clearingPrices[t.buyIdx]
            );
            if (buyAmount < t.limit) revert LimitNotMet(i, buyAmount, t.limit);
            IERC20(d.tokens[t.buyIdx]).safeTransfer(t.account, buyAmount);
        }
    }

    /// I11 — the one check that cannot be delegated to L2. Every listed token
    /// must end at exactly its opening balance; in steady state, zero.
    ///
    /// I17 — residue goes to a protocol address the solver cannot name. A
    /// solver-nominated destination would turn any failure to pay a user into
    /// solver revenue, with every balance check still passing.
    function _restore(
        SettlementData calldata d,
        uint256[] memory opening,
        uint256 openingEth
    ) private {
        for (uint256 i = 0; i < d.tokens.length; i++) {
            IERC20 token = IERC20(d.tokens[i]);
            uint256 bal = token.balanceOf(address(this));
            if (bal < opening[i]) revert NotSolvent(d.tokens[i]);
            if (bal > opening[i]) {
                token.safeTransfer(windfallRecipient, bal - opening[i]);
                // Re-read rather than assume: a fee-on-transfer token would leave
                // residue behind, and this is what makes I11 an equality rather
                // than a bound.
                if (token.balanceOf(address(this)) != opening[i]) {
                    revert BalanceNotRestored(d.tokens[i]);
                }
            }
        }
        // No `receive()`, so this can only move if an interaction forced value in.
        if (address(this).balance != openingEth) revert EthLeaked();
    }
}
```

### Notes for review

- **`expectedProxy` is storage, not `immutable`.** The derivation needs a call to `IEEZ` after
  deployment, so it cannot be a constructor value. `setL2Caller` is one-shot and admin-only, and the
  zero-address guard means it cannot be re-armed by a registry returning nothing.
- **Before `setL2Caller`, `settle` is locked** — `expectedProxy` is zero and no caller matches. That
  is now deliberate rather than accidental.
- **`admin` cannot rotate `Book`.** Replacing the L2 half means a new `Executor`, hence a new
  `Relayer`, hence every user re-approving. §3 claims otherwise and is wrong; see the rotation gap
  noted against §13.
- **The nonce bitmap is the dominant cost**, not `ecrecover` — 20,000 on an account's first touch of
  a word, 2,900 thereafter. §11 has the decomposition.
- **It does not inherit OpenZeppelin's `EIP712`, deliberately.** Doing so would give `Executor` its
  own implementation of the domain, while `Book` — which must pin the *L1* chain id rather than its
  own — necessarily has another. Two computations of a hash that must agree byte-for-byte is a
  silent-divergence risk of the worst kind: it would pass on L2 at submission and fail on L1 after the
  batch had already crossed. Both contracts compute through `SettlementEIP712` in **Appendix C**. The
  fork re-derivation in `domainSeparator()` is the one behaviour worth keeping from OZ's version.
- **The signed form is the only canonical one.** `Trade` carries narrow widths for calldata size and
  widens implicitly into `SignedIntent`; `Intent` on L2 carries registry ids for storage cost. Both
  must reduce to the same digest — `Book` at submission, `Executor` here. That reduction is the most
  bug-prone seam in the design, which is why the hashing lives in one library rather than in each
  contract.

---

## Appendix C — the shared types and EIP-712 definition

Reference implementation. Normative where it disagrees with the prose above.

This is the single definition both chains compute against. `Book` verifies a signature at
submission to fail fast; `Executor` verifies it again at pull time because that is the check that
survives a compromised L2 (I9). Neither writes its own — see the review note against Appendix B.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

// ---------------------------------------------------------------------------
// The cross-chain payload
// ---------------------------------------------------------------------------

/// One user's participation in a settlement.
///
/// `sellAmount` is fixed; the buy amount is derived from the clearing price
/// vector, which is what makes uniform pricing structural rather than checked.
///
/// `deadline` and `nonce` are carried because L1 must rebuild the EIP-712 digest
/// and has no other way to obtain them — it cannot read L2 storage, which is the
/// premise of the whole arrangement.
struct Trade {
    address account;
    uint8 sellIdx; // index into SettlementData.tokens
    uint8 buyIdx;
    uint128 sellAmount;
    uint128 limit; // minimum acceptable buy amount
    uint40 deadline;
    uint64 nonce;
}

/// An arbitrary L1 call used to source the residual from a venue.
///
/// No `value` field: `Executor` has no `receive()` and cannot hold ETH, so it
/// would always be zero. Its absence also removes the only path by which an
/// interaction could move native value.
struct Interaction {
    address target;
    bytes callData;
}

/// The whole payload that crosses the chain boundary, in one dispatch.
struct SettlementData {
    address[] tokens;
    uint256[] clearingPrices; // numeraire units per token, indexed like `tokens`
    Trade[] trades;
    Interaction[] calls;
}

// ---------------------------------------------------------------------------
// The signed authorisation
// ---------------------------------------------------------------------------

/// What the user actually signs.
///
/// Distinct from `Book`'s stored `Intent`, which holds `uint24` registry ids:
/// this is the canonical form the signature covers, and it must be
/// reconstructible on L1, which has no registry. Addresses, therefore, not ids.
///
/// Every numeric field is `uint256` even though the payload carries them narrow.
/// EIP-712 `encodeData` pads to 32 bytes regardless, so this costs nothing
/// on-chain, and non-standard widths like `uint40` are unevenly supported by
/// wallet signing libraries. The type string is what wallets hash and render;
/// it should use only types every implementation agrees on.
struct SignedIntent {
    address account;
    address sellToken;
    address buyToken;
    uint256 sellAmount;
    uint256 limit;
    uint256 deadline;
    uint256 nonce;
}

/// One definition of the domain and struct hash, shared by both chains.
///
/// `Book` verifies a signature at submission to fail fast; `Executor` verifies it
/// again at pull time because that is the check that survives a compromised L2.
/// Those two must agree exactly, so neither computes its own — a divergence here
/// would be silent on L2 and fatal on L1.
library SettlementEIP712 {
    string internal constant NAME = "EEZ Settlement";
    string internal constant VERSION = "1";

    bytes32 internal constant INTENT_TYPEHASH = keccak256(
        "Intent(address account,address sellToken,address buyToken,"
        "uint256 sellAmount,uint256 limit,uint256 deadline,uint256 nonce)"
    );

    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// The domain is pinned to the **L1** chain and the `Executor` address,
    /// because that is where the signature is consumed. `Book` reproduces it
    /// with the L1 chain id it was deployed against — it must not use its own.
    function domainSeparator(uint256 l1ChainId, address executor) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(DOMAIN_TYPEHASH, keccak256(bytes(NAME)), keccak256(bytes(VERSION)), l1ChainId, executor)
            );
    }

    function hashStruct(SignedIntent memory intent) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                INTENT_TYPEHASH,
                intent.account,
                intent.sellToken,
                intent.buyToken,
                intent.sellAmount,
                intent.limit,
                intent.deadline,
                intent.nonce
            )
        );
    }

    function digest(bytes32 separator, SignedIntent memory intent) internal pure returns (bytes32) {
        return MessageHashUtils.toTypedDataHash(separator, hashStruct(intent));
    }
}
```

**Review notes**

- **Three representations of the same order exist deliberately**, and conflating them is the most
  likely source of bugs here. `Intent` (L2 storage) keys tokens by `uint24` registry id; `Trade`
  (cross-chain payload) keys them by `uint8` index into that settlement's `tokens[]`;
  `SignedIntent` (the EIP-712 message) keys them by address. **Only `SignedIntent` is canonical.**
  The other two are encodings chosen for storage cost and calldata size, and both must reduce to it
  exactly — see §5.1.1 and §5.2.
- **Every numeric field in the type string is `uint256`**, though `Trade` carries `uint128`,
  `uint40` and `uint64`. EIP-712 `encodeData` pads to 32 bytes regardless, so narrowing saves
  nothing on-chain, and non-standard widths are unevenly supported by wallet signing libraries.
  §5.3 gives the same string; the two must not drift.
- **The domain is pinned to the L1 chain id and the `Executor` address**, not to `Book`'s own —
  the signature is consumed on L1, so it must be scoped there.

---

## Appendix D — `Book`

Reference implementation. Normative where it disagrees with the prose above — and it disagrees in two
places, both noted after the listing.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {
    SettlementData,
    Trade,
    SignedIntent,
    SettlementEIP712
} from "./SettlementTypes.sol";
import {TokenRegistry} from "./TokenRegistry.sol";

interface IExecutor {
    function settle(SettlementData calldata d, bytes[] calldata signatures) external;
}

/// The L2 half: intents, a sealed-bid solver auction, and one dispatch to L1.
///
/// Nothing here holds funds, and nothing here can move them. Users keep custody
/// on L1 until a settlement pulls from them, and that pull is authorised by
/// their own signature — not by this contract. A bug in this file produces a bad
/// auction, not a bad transfer.
contract Book {
    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------

    IExecutor     public immutable executor;
    TokenRegistry public immutable registry;
    address       public immutable admin;

    /// The domain the user's signature is scoped to. Pinned to the **L1** chain
    /// and the `Executor` address, because that is where it is consumed. Computed
    /// through the shared library so it cannot drift from Executor's own.
    bytes32 public immutable domainSeparator;

    /// Token 0 is the numeraire and its price is pinned here. Without the pin,
    /// scaling an entire price vector leaves every derived buy amount unchanged —
    /// they are ratios — but multiplies the score.
    uint256 public constant PRICE_SCALE = 1e18;

    uint40 public constant COMMIT_WINDOW = 60;    // T_C - open
    uint40 public constant REVEAL_WINDOW = 60;    // one leader's turn
    uint40 public constant MAX_REVEAL_PHASE = 480; // 8 turns, then the auction dies

    /// A cancellation cannot take effect inside an auction that was already
    /// running when it was requested — otherwise a user front-runs a reveal and
    /// voids a route that has just been made public.
    ///
    /// COMMIT_WINDOW + MAX_REVEAL_PHASE is the longest an auction can live, so a
    /// delay of that length is the smallest one that is always safe.
    uint40 public constant CANCEL_DELAY = COMMIT_WINDOW + MAX_REVEAL_PHASE;

    uint16 public constant MAX_BIDS = 64;

    /// Which tokens may sit at index 0 and anchor a price vector. The only
    /// governance surface with teeth, and every invariant holds regardless of
    /// what is on it.
    mapping(address => bool) public isNumeraire;

    // ------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------

    uint8 constant LIVE = 1;
    uint8 constant FILLED = 2;
    uint8 constant CANCELLED = 3;

    /// 2 slots, exactly full.
    struct Intent {
        address account;
        uint24  sellTok;
        uint24  buyTok;
        uint40  deadline;
        uint8   state;
        uint128 sellAmount;
        uint128 limit;
    }

    /// 2 slots.
    struct Bid {
        bytes32 commitment;
        address solver;
        uint88  claimedScore;
        bool    out;
    }

    /// 3 slots.
    struct Auction {
        bytes32 leadCommitment;
        address leader;
        uint88  leadScore;
        bool    settled;
        uint40  commitDeadline;  // T_C
        uint40  revealDeadline;  // T_R
        uint16  leadIdx;
    }

    Intent[] public intents;
    mapping(uint256 => Auction) public auctions;
    mapping(uint256 => Bid[]) private _bids;
    uint256 public auctionCount;

    /// Paid for only by intents that are actually cancelled.
    mapping(uint256 => uint40) public cancelEffectiveAt;

    /// account => word => bitmap. Mirrors Executor's, so an intent that could
    /// never settle is rejected here rather than after crossing the chain.
    mapping(address => mapping(uint256 => uint256)) public nonceUsed;

    error NotAdmin();
    error NotOwner();
    error NotLive();
    error Expired();
    error NonceAlreadyUsed();
    error BadSignature();
    error UnknownToken();
    error AuctionMoved(uint256 liveId);
    error CommitPhaseClosed();
    error CommitPhaseOpen();
    error TooManyBids();
    error RevealWindowOpen();
    error RevealWindowClosed();
    error CancelNotReady();
    error AuctionDead();
    error AlreadySettled();
    error NoBids();
    error NotLeader();
    error BadCommitment();
    error LengthMismatch();
    error IntentMismatch(uint256 index);
    error LimitNotMet(uint256 index);
    error BadNumeraire();
    error NoNumeraireLeg(uint256 index);
    error ZeroPrice(uint256 index);
    error CancelPending(uint256 index);
    error ScoreOverclaimed(uint256 actual, uint256 claimed);

    event IntentSubmitted(uint256 indexed id, address indexed account, SignedIntent intent, bytes signature);
    event CancelRequested(uint256 indexed id, uint40 effectiveAt);
    event IntentCancelled(uint256 indexed id);
    event AuctionOpened(uint256 indexed auctionId, uint40 commitDeadline);
    event Committed(uint256 indexed auctionId, address indexed solver, uint88 claimedScore);
    event LeaderSkipped(uint256 indexed auctionId, address indexed solver);
    event Executed(uint256 indexed auctionId, address indexed solver, uint256 score, uint256 filled);

    constructor(IExecutor _executor, TokenRegistry _registry, uint256 l1ChainId) {
        executor = _executor;
        registry = _registry;
        admin = msg.sender;
        domainSeparator = SettlementEIP712.domainSeparator(l1ChainId, address(_executor));
    }

    function setNumeraire(address token, bool allowed) external {
        if (msg.sender != admin) revert NotAdmin();
        isNumeraire[token] = allowed;
    }

    // ------------------------------------------------------------------
    // Intents
    // ------------------------------------------------------------------

    /// @notice Record a signed intent. Two storage slots and no custody.
    ///
    /// The signature is verified here to fail fast, then **emitted and
    /// discarded**. Storing 65 bytes would cost three more slots per intent and
    /// erase the two-slot layout; solvers read it from the event and carry it in
    /// the reveal payload. The authoritative check is Executor's, on L1.
    function submitIntent(SignedIntent calldata intent, bytes calldata signature)
        external
        returns (uint256 id)
    {
        if (intent.account != msg.sender) revert NotOwner();
        if (block.timestamp > intent.deadline) revert Expired();
        if (intent.sellAmount > type(uint128).max || intent.limit > type(uint128).max) {
            revert IntentMismatch(0);
        }
        if (intent.deadline > type(uint40).max) revert Expired();

        bytes32 digest = SettlementEIP712.digest(domainSeparator, intent);
        if (ECDSA.recover(digest, signature) != intent.account) revert BadSignature();

        // Mirrors Executor's bitmap. A reused nonce would produce an intent that
        // can never settle, and a solver who batched it would lose the whole
        // settlement on L1 — harming the other traders in it, not just the user.
        uint256 word = intent.nonce >> 8;
        uint256 bit = 1 << (intent.nonce & 0xff);
        uint256 bits = nonceUsed[msg.sender][word];
        if (bits & bit != 0) revert NonceAlreadyUsed();
        nonceUsed[msg.sender][word] = bits | bit;

        id = intents.length;
        intents.push(
            Intent({
                account:    msg.sender,
                sellTok:    _idOf(intent.sellToken),
                buyTok:     _idOf(intent.buyToken),
                deadline:   uint40(intent.deadline),
                state:      LIVE,
                sellAmount: uint128(intent.sellAmount),
                limit:      uint128(intent.limit)
            })
        );

        emit IntentSubmitted(id, msg.sender, intent, signature);
    }

    /// @notice Ask to cancel. Effective after `CANCEL_DELAY`, not immediately.
    ///
    /// An immediate cancel would let a user watch a reveal land in the mempool,
    /// cancel, and void a route that had just been made public — destroying the
    /// solver's work for the price of gas, which a rival solver could do at
    /// profit. The delay is the smallest one that no running auction can outlive.
    function requestCancel(uint256 id) external {
        Intent storage n = intents[id];
        if (n.account != msg.sender) revert NotOwner();
        if (n.state != LIVE) revert NotLive();

        uint40 effectiveAt = uint40(block.timestamp) + CANCEL_DELAY;
        cancelEffectiveAt[id] = effectiveAt;
        emit CancelRequested(id, effectiveAt);
    }

    /// Permissionless: anyone may finalise, since the effect is fixed at request.
    function finalizeCancel(uint256 id) external {
        uint40 effectiveAt = cancelEffectiveAt[id];
        if (effectiveAt == 0 || block.timestamp < effectiveAt) revert CancelNotReady();

        Intent storage n = intents[id];
        if (n.state != LIVE) revert NotLive();
        n.state = CANCELLED;
        emit IntentCancelled(id);
    }

    function intentCount() external view returns (uint256) {
        return intents.length;
    }

    function bidCount(uint256 auctionId) external view returns (uint256) {
        return _bids[auctionId].length;
    }

    function bidAt(uint256 auctionId, uint256 i) external view returns (Bid memory) {
        return _bids[auctionId][i];
    }

    function _idOf(address token) private view returns (uint24) {
        (uint24 id, bool found) = registry.idOf(token);
        if (!found) revert UnknownToken();
        return id;
    }

    // ------------------------------------------------------------------
    // Auction
    // ------------------------------------------------------------------

    /// The auction currently accepting commitments, opening one if none is.
    ///
    /// Sequential rather than solver-chosen: solvers need a canonical target to
    /// compete over, and an arbitrary id would fragment the competition into
    /// parallel auctions over the same intents.
    function liveAuction() public returns (uint256 id) {
        id = auctionCount;
        Auction storage a = auctions[id];

        if (a.commitDeadline == 0) {
            _open(a, id);
        } else if (block.timestamp >= a.commitDeadline) {
            unchecked { id = ++auctionCount; }
            _open(auctions[id], id);
        }
    }

    function _open(Auction storage a, uint256 id) private {
        uint40 tc = uint40(block.timestamp) + COMMIT_WINDOW;
        a.commitDeadline = tc;
        a.revealDeadline = tc + REVEAL_WINDOW;
        emit AuctionOpened(id, tc);
    }

    /// @notice Commit to a solution without revealing it.
    /// @param expectedAuctionId Reverts if the live auction has moved on, so a
    /// commitment bound to one auction is never lodged against another.
    /// @param commitment `keccak256(abi.encode(d, intentIds, salt, msg.sender,
    /// auctionId, address(this), block.chainid))`
    ///
    /// A solver's route is their alpha. An auction taking the full payload in
    /// calldata lets a competitor copy it, add a wei of surplus and win — which
    /// punishes doing the routing work at all. Only the leader ever reveals, and
    /// only after the leader is already decided.
    ///
    /// Overclaiming is self-defeating: the score is recomputed at reveal and an
    /// unbacked claim is rejected, having cost the claimant gas. That is what
    /// makes an unbonded auction safe.
    function commitBid(uint256 expectedAuctionId, bytes32 commitment, uint88 claimedScore) external {
        uint256 id = liveAuction();
        if (id != expectedAuctionId) revert AuctionMoved(id);

        Auction storage a = auctions[id];
        if (block.timestamp >= a.commitDeadline) revert CommitPhaseClosed();

        Bid[] storage bs = _bids[id];
        if (bs.length >= MAX_BIDS) revert TooManyBids();

        bs.push(Bid({commitment: commitment, solver: msg.sender, claimedScore: claimedScore, out: false}));

        // O(1). A linear scan here is a griefing vector: unbounded bids make the
        // scan — and therefore the honest reveal — exceed the block limit.
        // Strict `>` so ties go to the earlier commitment.
        if (a.leader == address(0) || claimedScore > a.leadScore) {
            a.leader = msg.sender;
            a.leadScore = claimedScore;
            a.leadCommitment = commitment;
            a.leadIdx = uint16(bs.length - 1);
        }

        emit Committed(id, msg.sender, claimedScore);
    }

    /// @notice Reveal the winning solution and settle it, atomically.
    ///
    /// Only callable after `T_C`, when the leader is already frozen. That is the
    /// whole point of the phase boundary: a solver never has to expose their
    /// route in order to discover whether they won.
    function revealAndExecute(
        uint256 auctionId,
        SettlementData calldata d,
        uint256[] calldata intentIds,
        bytes32 salt,
        bytes[] calldata signatures
    ) external {
        Auction storage a = auctions[auctionId];
        if (a.settled) revert AlreadySettled();
        if (a.leader == address(0)) revert NoBids();
        if (block.timestamp < a.commitDeadline) revert CommitPhaseOpen();
        if (block.timestamp >= a.revealDeadline) revert RevealWindowClosed();
        if (msg.sender != a.leader) revert NotLeader();

        bytes32 c = keccak256(
            abi.encode(d, intentIds, salt, msg.sender, auctionId, address(this), block.chainid)
        );
        if (c != a.leadCommitment) revert BadCommitment();

        uint256 score = _validateAndScore(d, intentIds);
        if (score < a.leadScore) revert ScoreOverclaimed(score, a.leadScore);

        a.settled = true;

        // One dispatch. Either the whole settlement lands on L1 or none of it
        // does, and in the latter case every write above unwinds with it.
        executor.settle(d, signatures);

        emit Executed(auctionId, msg.sender, score, intentIds.length);
    }

    /// @notice Drop a leader who won and went quiet, promoting the next best.
    ///
    /// Terminating, because the candidate set cannot grow after `T_C`: every skip
    /// strictly shrinks it, bounded by MAX_BIDS. In an auction that never closed
    /// bidding, the skipped solver would simply re-commit and stall again.
    function skipLeader(uint256 auctionId) external {
        Auction storage a = auctions[auctionId];
        if (a.settled) revert AlreadySettled();
        if (a.leader == address(0)) revert NoBids();
        if (block.timestamp < a.revealDeadline) revert RevealWindowOpen();

        uint40 hardStop = a.commitDeadline + MAX_REVEAL_PHASE;
        if (block.timestamp >= hardStop) revert AuctionDead();

        Bid[] storage bs = _bids[auctionId];
        bs[a.leadIdx].out = true;
        emit LeaderSkipped(auctionId, a.leader);

        // Bounded by MAX_BIDS, and only on the fallback path.
        address bestSolver;
        uint88 bestScore;
        uint16 bestIdx;
        bytes32 bestCommitment;
        for (uint256 i = 0; i < bs.length; i++) {
            if (bs[i].out) continue;
            if (bestSolver == address(0) || bs[i].claimedScore > bestScore) {
                bestSolver = bs[i].solver;
                bestScore = bs[i].claimedScore;
                bestIdx = uint16(i);
                bestCommitment = bs[i].commitment;
            }
        }

        a.leader = bestSolver;
        a.leadScore = bestScore;
        a.leadIdx = bestIdx;
        a.leadCommitment = bestCommitment;

        uint40 next = uint40(block.timestamp) + REVEAL_WINDOW;
        a.revealDeadline = next < hardStop ? next : hardStop;
    }

    // ------------------------------------------------------------------
    // Scoring
    // ------------------------------------------------------------------

    /// Every trade must correspond to a live intent on its own terms and be paid
    /// at least what that intent demanded. Score is total surplus delivered above
    /// those limits, valued in the settlement's numeraire.
    ///
    /// Not `view`: intents are marked FILLED inside the loop, so a repeated id
    /// fails its own liveness check on the second pass rather than selling the
    /// user twice.
    function _validateAndScore(SettlementData calldata d, uint256[] calldata intentIds)
        private
        returns (uint256 score)
    {
        uint256 n = d.trades.length;
        if (intentIds.length != n) revert LengthMismatch();
        if (d.clearingPrices.length != d.tokens.length) revert LengthMismatch();

        // The pin binds only if token 0 is a real token that real trades touch.
        if (!isNumeraire[d.tokens[0]] || d.clearingPrices[0] != PRICE_SCALE) revert BadNumeraire();
        for (uint256 i = 0; i < d.clearingPrices.length; i++) {
            if (d.clearingPrices[i] == 0) revert ZeroPrice(i);
        }

        for (uint256 i = 0; i < n; i++) {
            Trade calldata t = d.trades[i];
            uint256 id = intentIds[i];
            Intent storage nn = intents[id];

            if (nn.state != LIVE) revert NotLive();
            if (block.timestamp > nn.deadline) revert Expired();

            uint40 cancelAt = cancelEffectiveAt[id];
            if (cancelAt != 0 && block.timestamp >= cancelAt) revert CancelPending(i);

            // Every price must be anchored by a real fill against the numeraire,
            // or the whole vector can be quoted in larger units for a free score.
            if (t.sellIdx != 0 && t.buyIdx != 0) revert NoNumeraireLeg(i);

            if (
                nn.account != t.account || nn.sellAmount != t.sellAmount || nn.limit != t.limit
                    || nn.deadline != t.deadline
                    || registry.tokenAt(nn.sellTok) != d.tokens[t.sellIdx]
                    || registry.tokenAt(nn.buyTok) != d.tokens[t.buyIdx]
            ) revert IntentMismatch(i);

            nn.state = FILLED;

            // Surplus in numeraire units. Algebraically identical to
            // (buyAmount - limit) * p[buy] / SCALE, with one multiply fewer and
            // no intermediate rounding. Monotone decreasing in the free price,
            // which is what makes inflating it self-defeating.
            uint256 gave = uint256(t.sellAmount) * d.clearingPrices[t.sellIdx];
            uint256 want = uint256(t.limit) * d.clearingPrices[t.buyIdx];
            if (gave < want) revert LimitNotMet(i);
            score += (gave - want) / PRICE_SCALE;
        }
    }
}
```

### Two places this disagrees with the prose

**The `Locked` intent state cannot be implemented, and is not needed.** An earlier draft of §6 had
intents move `Live → Locked → Filled`, with `Locked` entered when an auction closes so a user could
not cancel out from under a reveal. But **`Book` does not know which intents an auction covers until
the reveal** — `intentIds` are inside the commitment, which is the entire point of sealing it. There
is no moment at `T_C` when the set is known, so nothing can be locked then. Locking at reveal would
be a state that exists for zero time, since the reveal either completes atomically or reverts. §6 is
updated; this note records why.

The leak `Locked` was meant to close is real: a user watches a reveal land in the mempool, cancels,
and voids a route that has just been made public — for the price of gas, and at profit if the user is
a rival solver who submitted an attractive intent precisely to do this. The mechanism above closes it
differently. **Cancellation is a two-step: `requestCancel` then `finalizeCancel`, separated by
`CANCEL_DELAY`.** A solver reads `cancelEffectiveAt` when building a batch and includes only intents
whose cancellation cannot land before their auction ends. `CANCEL_DELAY = COMMIT_WINDOW +
MAX_REVEAL_PHASE` is the smallest delay no running auction can outlive.

That requires the auction to have a bounded lifetime, which the prose does not give it — §6 has
`skipLeader` extend `T_R` indefinitely. `MAX_REVEAL_PHASE` caps it, after which the auction is `Dead`
and its intents are free.

The intent states are therefore **`Live`, `Filled`, `Cancelled`** — three, not four.

**Auction ids are sequential, not solver-chosen.** §6 shows lazy opening on an unallocated id as a
placeholder. Left arbitrary, solvers cannot agree on which auction to compete in, and the competition
fragments into parallel auctions over the same intents — each of which would settle the first
intents it could and strand the rest. `liveAuction()` returns a single canonical target and opens one
when the previous closes. `commitBid` takes the id the solver expected and reverts if it has moved,
so a commitment bound to auction *n* is never lodged against *n+1*.

This is still a placeholder for the cadence question in §13.3, not an answer to it. It makes the
contract implementable; it does not decide how often batches should run.

### Notes for review

- **`submitIntent` now costs more than §11's estimate.** The nonce bitmap adds 20,000 on an account's
  first touch of a word and 2,900 after, which the ~74,000 figure did not include. Call it ~77,000
  steady-state and ~94,000 for a user's first intent. The mirror of Executor's bitmap is deliberate:
  a reused nonce produces an intent that can never settle, and a solver who batches it loses the
  entire settlement on L1 — harming every other trader in it, not just the user who erred.
- **`_validateAndScore` writes storage**, so it is not `view`. That is what enforces I3: the `FILLED`
  write lands before the next iteration reads the same id.
- **Prices are checked non-zero.** With `p[buy] == 0` the limit term vanishes, the score inflates,
  and the settlement then dies on L1 in `mulDiv`. Bounded by `skipLeader`, but a cheap check here
  keeps it off L1 entirely.
- **Overflow is left to checked arithmetic.** `sellAmount · price` reverts on an adversarial price
  rather than wrapping, which costs the solver their gas and nothing else.
- **`idOf` returns a `found` flag, not a sentinel.** `TokenRegistry` uses index-as-id, so the first
  token registered legitimately holds id 0 and a bare zero return cannot distinguish it from "not
  registered". §5.1.1 is updated to match.

---

## Appendix E — `TokenRegistry`

Reference implementation.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// Append-only, permissionless, ungoverned map of id to ERC-20 address.
///
/// It exists for one reason: to compress `Book`'s `Intent` into two storage
/// slots. An id is an index, not an endorsement — every invariant in the
/// specification holds regardless of what is registered here. The numeraire
/// allowlist is the governed surface, and it lives on `Book`.
///
/// L2-only. The cross-chain payload carries full addresses, so L1 never resolves
/// an id and there is no mirror to keep in sync.
contract TokenRegistry {
    /// id == index.
    address[] public tokens;

    /// Stores `id + 1`, so a zero read means unregistered. The first token
    /// registered legitimately holds id 0, which a bare sentinel could not
    /// distinguish from absence.
    mapping(address => uint256) private _id;

    /// `uint24` rather than `uint16`: registration is permissionless, and a
    /// 65,536-entry ceiling is reachable by spam for roughly 2.6 billion gas,
    /// after which no further token could ever be listed. The wider id fills
    /// `Intent` slot 0 exactly, so it costs nothing.
    uint256 private constant MAX_ID = type(uint24).max;

    error ZeroAddress();
    error RegistryFull();
    error UnknownId();

    event Registered(address indexed token, uint24 id);

    /// Idempotent: a token cannot acquire two ids. Not a safety issue — `Book`
    /// resolves id to address before matching — but wasteful and confusing.
    function register(address token) external returns (uint24 id) {
        if (token == address(0)) revert ZeroAddress();

        uint256 existing = _id[token];
        if (existing != 0) return uint24(existing - 1);

        uint256 next = tokens.length;
        if (next > MAX_ID) revert RegistryFull();

        tokens.push(token);
        _id[token] = next + 1;
        id = uint24(next);

        emit Registered(token, id);
    }

    function tokenAt(uint24 id) external view returns (address) {
        if (id >= tokens.length) revert UnknownId();
        return tokens[id];
    }

    /// Returns `found` separately for the id-0 reason above.
    function idOf(address token) external view returns (uint24 id, bool found) {
        uint256 stored = _id[token];
        if (stored == 0) return (0, false);
        return (uint24(stored - 1), true);
    }

    function count() external view returns (uint256) {
        return tokens.length;
    }
}
```
