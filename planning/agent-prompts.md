# Agent Prompts — eez-settlement test suite

These prompts are designed to be handed directly to a Claude Code agent. Each is self-contained.
Agents work on git branches and do not share state during execution. Read the sequencing notes before
dispatching.

The goal across all four steps is a test suite that **demonstrates every invariant in
`planning/settlement-spec.md` §10**, plus the behaviour each contract claims. The spec's nineteen
numbered invariants are the completeness criterion: Step 4 produces a matrix proving each is either
covered by a named test or is one of the three that cannot be tested at runtime.

---

## Sequencing Overview

```
Step 1 (single agent):   Phase 1 — Shared harness
                                    │
              ┌─────────────────────┼─────────────────────┐
Step 2 (parallel):  2a — Types    2b — L1              2c — L2
                    + Registry    Executor/Relayer     Book
              └─────────────────────┼─────────────────────┘
                              merge to main
                                    │
Step 3 (single agent):   Phase 3 — Invariant matrix, fuzz, gas
```

Do not start Step 2 until Step 1 is merged to `main`. The three Step 2 agents touch disjoint test
files and may run concurrently on separate branches.

## Step 1 — Phase 1: Shared harness

**Branch:** `test/phase-1-harness`

**Prompt:**

You are building the shared test harness for eez-settlement, a verifiable batch settlement protocol.
The full specification is in `planning/settlement-spec.md`. Read §3 (Architecture), §5 (Data model),
§6 (Lifecycle) and §9 (Settlement on L1) before writing any code. Read `CLAUDE.md` in full.

### Context

The repository contains five contracts in `src/`, extracted verbatim from the specification's
appendices A–E:

| File | Role |
|---|---|
| `SettlementTypes.sol` | `Trade`, `Interaction`, `SettlementData`, `SignedIntent`, and the `SettlementEIP712` library |
| `TokenRegistry.sol` | Append-only `uint24` id → ERC-20 address, L2 only |
| `Relayer.sol` | Holds user approvals. One function, `pullBatch`, callable only by `Executor` |
| `Executor.sol` | L1. Verifies EIP-712 signatures, pulls, runs solver interactions, pays, sweeps residue, proves its balance restored |
| `Book.sol` | L2. Intents, sealed-bid auction with a commit deadline, deterministic scoring, one dispatch to L1 |

Three test files already exist:

- `test/Smoke.t.sol` — one coincidence-of-wants settlement end to end. Passing.
- `test/Properties.t.sol` — eight security properties plus a gas readout. Passing.
- `test/TokenRegistry.t.sol` — two tests, one failing. See "Known starting condition" above.

`forge test` currently reports 11 passing, 1 failing.

There is no shared fixture. `Smoke.t.sol` and `Properties.t.sol` each duplicate the full deployment,
token setup, EIP-712 signing and commit/reveal dance — roughly 80 lines apiece. Every suite added in
Step 2 would duplicate it again. Your job is to remove that duplication before it multiplies.

### Your Task

**Part A — Build the harness**

1. Create `test/helpers/SettlementFixture.sol` containing an abstract contract
   `SettlementFixture is Test` that every other suite inherits. It must provide:
   - A `setUp()` that deploys, in this order — the order is load-bearing because `Executor`
     constructs `Relayer` in its own constructor:
     ```solidity
     reg  = new TokenRegistry();
     ex   = new Executor(address(new IdEEZ()), 0, windfallRecipient);
     rl   = ex.relayer();
     book = new Book(IExecutor(address(ex)), reg, block.chainid);
     ex.setL2Caller(address(book));
     ```
   - An `IdEEZ` mock whose `computeCrossChainProxyAddress(address t, uint64)` returns `t`, so that
     `Book` calling `Executor` satisfies the `expectedProxy` gate in a single-chain test.
   - A minimal `ERC20` test token, and helpers to mint and distribute.
   - Registration of every test token in `TokenRegistry`, and `book.setNumeraire(usdc, true)`.
   - Approvals from every test account to **`Relayer`** — not `Executor`. Approving the wrong
     contract fails in a way that looks like a signature problem.

2. Provide these helpers on the fixture:
   - `_signIntent(uint256 pk, SignedIntent memory intent) returns (bytes memory)` — signs against
     `book.domainSeparator()`. Never reconstruct the domain locally; §5.3 and `CLAUDE.md` explain why
     exactly one definition must exist.
   - `_submitIntent(uint256 pk, SignedIntent memory intent) returns (uint256 id, bytes memory sig)`
   - `_commitFor(SettlementData memory d, uint256[] memory ids, uint88 claimedScore) returns (uint256 auctionId)`
     — commits and warps past `COMMIT_WINDOW`, **stopping short of the reveal**.
   - `_reveal(uint256 auctionId, SettlementData memory d, uint256[] memory ids, bytes[] memory sigs)`
   - A two-sided coincidence-of-wants builder returning a ready `SettlementData`, its `intentIds` and
     its signatures.

   `_commitFor` must stop before the reveal. `vm.expectRevert` binds to the *next* external call, so
   a helper that commits, warps and reveals in one go makes every revert assertion land on the wrong
   call. This has already caused six false failures in this repository; do not reintroduce it.

3. Fix `test/TokenRegistry.t.sol:testRegister` to expect `0` and `1`, per §5.1.1. Add a one-line
   comment citing the section so the next reader does not "fix" it back.

4. Refactor `test/Smoke.t.sol` and `test/Properties.t.sol` to inherit the fixture and delete their
   duplicated setup. **Their assertions must not change** — the tests that pass now must still pass,
   for the same reasons.

**Part B — Add stubs for Step 2** (prevents merge conflicts when the three parallel agents start)

Create these files containing only an empty contract inheriting the fixture, each marked with a
`// Step 2x — owned by that agent` comment:

```
test/unit/TypesAndRegistry.t.sol   → contract TypesAndRegistryTest is SettlementFixture {}
test/integration/Executor.t.sol    → contract ExecutorTest is SettlementFixture {}
test/integration/Book.t.sol        → contract BookTest is SettlementFixture {}
```

### Verification

```bash
forge test
# → 12 passed, 0 failed. The previously failing testRegister now passes.

forge inspect src/Book.sol:Book storage-layout --json | grep -c '"label": "Intent"'
# → at least 1; the struct layouts must be unchanged by your work

grep -rn "settlement/" test/
# → no output. All imports resolve to ../src/ or ../helpers/
```

Confirm by reading the diff that `Smoke.t.sol` and `Properties.t.sol` have the same assertions as
before, only less setup.

Do not write tests for `Executor`, `Book`, or the EIP-712 library beyond what already exists — those
are Step 2's work. Do not modify anything in `src/`.

---

## Step 2a — Phase 2a: Types, EIP-712 and registry

**Branch:** `test/phase-2a-types`
**Depends on:** Step 1 merged to main

**Prompt:**

You are testing the type layer and token registry of eez-settlement, a verifiable batch settlement
protocol. The specification is `planning/settlement-spec.md`; read §5 (Data model) in full, and
Appendices C and E for the code under test. Read `CLAUDE.md`.

### Context

Step 1 delivered `test/helpers/SettlementFixture.sol`, an abstract contract providing deployment,
token setup, EIP-712 signing and commit/reveal helpers. Inherit it. `forge test` passes with 12
tests.

You own `test/unit/TypesAndRegistry.t.sol`, which currently exists as an empty contract inheriting
the fixture.

The code under test is `src/SettlementTypes.sol` and `src/TokenRegistry.sol`.

Three representations of the same order exist deliberately, and confusing them is the most likely
source of bugs in this codebase (§5.1.1 and Appendix C):

| | Where | Tokens as | Amounts as |
|---|---|---|---|
| `Intent` | L2 storage | `uint24` registry id | `uint128` |
| `Trade` | Cross-chain payload | `uint8` index into `tokens[]` | `uint128` |
| `SignedIntent` | EIP-712 message | `address` | `uint256` |

Only `SignedIntent` is canonical. The other two are encodings chosen for storage cost and calldata
size, and both must reduce to it exactly.

### Your Task

1. **`SettlementEIP712` — domain separator.** Assert it matches a hand-constructed EIP-712 domain
   over `("EEZ Settlement", "1", l1ChainId, executorAddress)`. Assert it is pinned to the **L1** chain
   id and the `Executor` address, not to `Book`'s own — §5.3.
2. **`SettlementEIP712` — struct hash.** Assert `INTENT_TYPEHASH` equals `keccak256` of the literal
   type string in Appendix C, and that the type string uses `uint256` for every numeric field. §5.3
   explains the wallet-compatibility reason; a test pins it so a future narrowing is caught.
3. **Digest agreement.** Assert `Book` and `Executor` derive byte-identical digests for the same
   `SignedIntent`. This is the seam the shared library exists to protect — Appendix C's review notes
   call it the most bug-prone in the design.
4. **Fork re-derivation.** `Executor.domainSeparator()` caches with a chain-id check. Use
   `vm.chainId` to change the chain and assert the separator changes, so signatures from the original
   chain do not replay on a fork.
5. **Signature malleability.** Assert a signature with a high-`s` value is rejected. OpenZeppelin's
   `ECDSA.recover` reverts rather than returning `address(0)`; pin that behaviour.
6. **`TokenRegistry` — id semantics.** `id == index`, first registration is id `0`, `register` is
   idempotent, `idOf` returns `(0, false)` for an unregistered token and `(0, true)` for the first
   registered one. That distinction is the entire reason `idOf` returns two values (§5.1.1).
7. **`TokenRegistry` — bounds.** `tokenAt` reverts `UnknownId` past the end; `register(address(0))`
   reverts `ZeroAddress`.
8. **Widening.** Fuzz that a `Trade`'s `uint128`/`uint40`/`uint64` fields widen into `SignedIntent`'s
   `uint256` fields without loss, and produce the same digest as the values assigned directly.

### Do Not Touch

- `src/**` — the contracts are extracted from the spec; a change there is a spec change
- `test/integration/Executor.t.sol` — Step 2b's domain
- `test/integration/Book.t.sol` — Step 2c's domain
- `test/helpers/SettlementFixture.sol` — Step 1's; extend it only by adding, never by changing an
  existing helper's signature, or you will break the parallel agents
- `test/Smoke.t.sol`, `test/Properties.t.sol`

### Verification

```bash
forge test --match-path 'test/unit/TypesAndRegistry.t.sol'
# → all pass, at least 12 test functions

forge test
# → the whole suite still passes; you have not broken 2b or 2c
```

Every test's doc comment cites the spec section or invariant it establishes.

---

## Step 2b — Phase 2b: `Executor` and `Relayer`

**Branch:** `test/phase-2b-l1`
**Depends on:** Step 1 merged to main

**Prompt:**

You are testing the L1 half of eez-settlement, a verifiable batch settlement protocol. The
specification is `planning/settlement-spec.md`; read §3.1, §4, §9 and §10 in full, and Appendices A
and B for the code under test. Read `CLAUDE.md`.

### Context

Step 1 delivered `test/helpers/SettlementFixture.sol`, providing deployment, token setup, EIP-712
signing and commit/reveal helpers. Inherit it. `forge test` passes with 12 tests.

You own `test/integration/Executor.t.sol`, which currently exists as an empty contract inheriting the
fixture.

The code under test is `src/Executor.sol` and `src/Relayer.sol`.

`Executor.settle` runs `verify → pull → interact → pay → sweep → restore`. The ordering is the
design: pull before interact funds the route from the batch itself so a solver needs no capital;
interact before pay lets the route produce the buy side.

`Relayer` holds every user approval and exists as a separate contract because `Executor` runs
solver-supplied arbitrary calls. §3.1 is the full argument and is worth reading twice — in
particular, the balance invariant **cannot** catch a `transferFrom` that moves tokens directly from a
victim to an attacker, because those tokens never pass through `Executor` at all.

**The invariants you own are I9–I13, I17 and I18.** I9–I13 are the ones that survive a fully
compromised L2 and are the audit priority.

### Your Task

1. **I9 — signature coverage.** Every pull is covered by the account's signature over those exact
   terms. Assert rejection when the payload's `sellAmount`, `limit`, `buyToken`, `deadline` or
   `account` differs from what was signed, one test per field. Assert a signature from the wrong key
   is rejected.
2. **I10 — nonce consumption.** A nonce cannot be consumed twice; the same signed intent replayed in
   a second settlement reverts `NonceUsed`. Assert unordered nonces work — two intents from one
   account settling out of submission order both succeed, which is why the design does not use a
   sequential nonce (§5.3).
3. **Deadline.** `Executor` re-checks `deadline` independently of `Book`. Warp past it and assert
   `IntentExpired`.
4. **I11 — exact balance.** Assert `Executor` ends every settlement holding exactly its opening
   balance of every listed token, and of ETH. Assert `NotSolvent` when a settlement does not balance.
   Assert `BalanceNotRestored` fires for a fee-on-transfer token — §2 lists these as an unsupported
   token type and the reverting behaviour is deliberate, so pin it.
5. **I12 — relayer unreachable.** An interaction targeting `Relayer` reverts `TargetForbidden`. Also
   assert the indirect path: an interaction targeting an intermediate contract that then calls
   `Relayer.pullBatch` fails, because `msg.sender` is the intermediate, not `Executor`.
6. **I13 — relayer access control.** `Relayer.pullBatch` called by anyone other than `Executor`
   reverts `NotExecutor`. Assert length mismatch across its three arrays reverts.
7. **I17 — residue.** Residue sweeps to `windfallRecipient`, which is immutable and never named in
   the payload. **Assert a solver cannot direct it** — this is the defect §9.1 exists to prevent, and
   it is the single most important test in your set.
8. **Caller gate.** `settle` from any address other than `expectedProxy` reverts `NotProxy`. Before
   `setL2Caller`, `settle` is locked because `expectedProxy` is zero — assert that too; Appendix B's
   review notes flag it as deliberate rather than accidental.
9. **`setL2Caller`.** Admin-only, one-shot, rejects a zero proxy.
10. **Uniform pricing.** Assert every trade's buy amount derives from the shared price vector, so a
    settlement favouring one account is not expressible (G1, I5). Assert `LimitNotMet` when a derived
    amount falls below the trade's limit.
11. **Interactions.** A reverting interaction reverts the whole settlement, with the failing index in
    the error. A settlement with an empty `calls` array — a coincidence of wants — succeeds and never
    touches a venue.
12. **`SafeERC20`.** A token returning no data on `transfer`/`transferFrom`, USDT-shaped, settles end
    to end. §9 states plainly that a venue which cannot trade USDT is not a venue.

### Do Not Touch

- `src/**` — the contracts are extracted from the spec; a change there is a spec change
- `test/unit/TypesAndRegistry.t.sol` — Step 2a's domain
- `test/integration/Book.t.sol` — Step 2c's domain
- `test/helpers/SettlementFixture.sol` — Step 1's; extend by adding only, never change an existing
  helper's signature
- `test/Smoke.t.sol`, `test/Properties.t.sol`

### Verification

```bash
forge test --match-path 'test/integration/Executor.t.sol'
# → all pass, at least 25 test functions

forge test
# → the whole suite still passes

grep -c "I9\|I10\|I11\|I12\|I13\|I17" test/integration/Executor.t.sol
# → at least 7; every invariant test cites its number
```

I18 (`call`, never `delegatecall`) cannot be asserted at runtime — a contract cannot inspect its own
opcodes. Note in a comment that it is a review obligation and move on. Do not add a runtime check for
it.

---

## Step 2c — Phase 2c: `Book`

**Branch:** `test/phase-2c-l2`
**Depends on:** Step 1 merged to main

**Prompt:**

You are testing the L2 half of eez-settlement, a verifiable batch settlement protocol. The
specification is `planning/settlement-spec.md`; read §5.1, §6, §7, §8 and §10 in full, and Appendix D
for the code under test. Read `CLAUDE.md`.

### Context

Step 1 delivered `test/helpers/SettlementFixture.sol`, providing deployment, token setup, EIP-712
signing and commit/reveal helpers. Inherit it. `forge test` passes with 12 tests.

You own `test/integration/Book.t.sol`, which currently exists as an empty contract inheriting the
fixture.

The code under test is `src/Book.sol`.

`Book` holds intents and runs a sealed-bid auction with an explicit phase boundary:

```
Committing [open, T_C)  →  T_C: leader frozen  →  Revealing [T_C, T_R)  →  Settled
                                                        ↓ T_R elapsed
                                                   skipLeader promotes next best
                                                        ↓ T_C + MAX_REVEAL_PHASE
                                                        Dead
```

Two properties depend entirely on the boundary at `T_C`, and both are the point of the design:

- **A solver never exposes their route to discover whether they won.** Without the boundary the
  leader is only resolvable at reveal, so the winner must broadcast their payload to find out — and
  an observer reads it from the mempool, outbids, and settles the stolen route.
- **`skipLeader` terminates.** The candidate set cannot grow after `T_C`, so every skip strictly
  shrinks it.

**The invariants you own are I1–I8, I14, I15 and I16.**

### Your Task

1. **Intents.** `submitIntent` verifies the signature and rejects one signed by another key; rejects
   `account != msg.sender`; rejects an expired deadline; rejects an unregistered token; rejects a
   reused nonce (`NonceAlreadyUsed`). Assert the signature is **emitted and not stored** — §5.1
   states this is what preserves the two-slot layout, so read it back from the event.
2. **Storage layout.** Assert via `forge inspect` in a test or a comment that `Intent` is 2 slots,
   `Bid` 2, `Auction` 3, matching §5.1 exactly. The gas figures in §11 depend on it.
3. **Delayed cancellation.** `requestCancel` does not take effect immediately; `finalizeCancel`
   before `CANCEL_DELAY` reverts `CancelNotReady`; an intent remains settleable until the
   cancellation lands. **Assert the front-run is closed** — a user cannot void a route that a solver
   has just published. §6 is the argument; this is the most important test in your set.
4. **I14 — reveal window.** Only the frozen leader may reveal, and only within `[T_C, T_R)`. Assert
   `CommitPhaseOpen` before `T_C`, `RevealWindowClosed` after `T_R`, `NotLeader` for anyone else.
5. **I15 — frozen candidate set.** A commitment lodged after `T_C` reverts, so a higher claim cannot
   displace a leader mid-reveal. Assert the full attack: honest solver commits, `T_C` passes, an
   observer tries to outbid and cannot, honest solver settles.
6. **Auction sequencing.** `liveAuction()` returns a single canonical id and opens the next when the
   previous closes. `commitBid` with a stale `expectedAuctionId` reverts `AuctionMoved`. Assert
   `MAX_BIDS` is enforced with `TooManyBids`.
7. **Leader caching.** The cached leader matches a linear scan over all bids after an arbitrary
   sequence of commits — fuzz this. Ties go to the earlier commitment. The cache is O(1) precisely
   so an unbounded scan cannot brick an auction, so also assert that `MAX_BIDS` commits leave reveal
   affordable.
8. **`skipLeader`.** Promotes the next best from the frozen set; reverts `RevealWindowOpen` before
   `T_R`; extends `T_R`; reverts `AuctionDead` past `T_C + MAX_REVEAL_PHASE`. Assert it **terminates**
   — a skipped solver cannot re-commit and stall again, which is what an auction without a commit
   deadline permits.
9. **I1, I2, I3 — trade/intent matching.** Every trade matches a live intent on account, tokens,
   amount, limit and deadline — one test per field. `intentIds.length != trades.length` reverts
   `LengthMismatch`. A repeated intent id reverts, because `_validateAndScore` writes `FILLED` inside
   the loop.
10. **I6, I7 — the numeraire.** `tokens[0]` must be allowlisted and priced at `PRICE_SCALE`. Every
    trade must have the numeraire on one side (`NoNumeraireLeg`). **Assert the attack §8 describes**:
    a settlement whose `tokens[0]` is an untraded shell token, with every other price quoted `1e6`
    larger, must be rejected — without the numeraire-leg rule every fill is byte-identical and the
    score is `1e6` times higher.
11. **I4 — scoring.** Score is total surplus above user limits in numeraire units. Assert
    `LimitNotMet` when a derived amount is below the limit, and `ScoreOverclaimed` when a solver
    claims more than their solution delivers — the latter is what makes an unbonded auction safe
    (§7.2). Assert zero prices revert `ZeroPrice`.
12. **Access control.** `setNumeraire` is admin-only. `requestCancel` is owner-only.

### Do Not Touch

- `src/**` — the contracts are extracted from the spec; a change there is a spec change
- `test/unit/TypesAndRegistry.t.sol` — Step 2a's domain
- `test/integration/Executor.t.sol` — Step 2b's domain
- `test/helpers/SettlementFixture.sol` — Step 1's; extend by adding only, never change an existing
  helper's signature
- `test/Smoke.t.sol`, `test/Properties.t.sol`

### Verification

```bash
forge test --match-path 'test/integration/Book.t.sol'
# → all pass, at least 30 test functions

forge test
# → the whole suite still passes

grep -c "I1\b\|I2\b\|I3\b\|I4\b\|I6\b\|I7\b\|I14\|I15" test/integration/Book.t.sol
# → at least 8; every invariant test cites its number
```

I16 (`_pay` iterates unconditionally) belongs to `Executor` and cannot be asserted at runtime. Ignore
it here.

---

## Step 3 — Phase 3: Invariant matrix, fuzz and gas

**Branch:** `test/phase-3-invariants`
**Depends on:** Steps 2a, 2b and 2c merged to main

**Prompt:**

You are completing the test suite for eez-settlement, a verifiable batch settlement protocol. The
specification is `planning/settlement-spec.md`; read §10 (Invariants) and §11 (Costs) in full. Read
`CLAUDE.md`.

### Context

All prior phases are complete:

- **Phase 1** — `test/helpers/SettlementFixture.sol`, the shared harness every suite inherits.
- **Phase 2a** — `test/unit/TypesAndRegistry.t.sol`, covering EIP-712 and the registry.
- **Phase 2b** — `test/integration/Executor.t.sol`, covering I9–I13 and I17.
- **Phase 2c** — `test/integration/Book.t.sol`, covering I1–I8, I14 and I15.

`forge test` passes. Individual invariants are covered but nobody has checked the set is *complete*,
nothing exercises the system under adversarial randomness, and §11's gas figures are unverified since
the contracts moved into this repository.

### Your Task

1. **Coverage matrix.** Create `planning/invariant-coverage.md`: one row per invariant I1–I19, naming
   the test function that establishes it and the file it lives in. Any invariant without a test is a
   gap — write the test rather than recording the gap, unless it is I16, I18 or I19, which are review
   obligations that cannot be asserted at runtime. Say so explicitly for those three rather than
   leaving blanks.

2. **I8 as a fuzz invariant.** §8 states the property the auction's soundness rests on: **score is
   non-increasing in every free price.** A solver who inflates a price to pump the multiplier loses
   more score than they gain, which is what makes inflation stop being a strategy rather than being
   detected as one. Fuzz over price vectors and trade sets and assert monotonicity. §10 explicitly
   marks I8 as a fuzz invariant; this is the one test that most deserves to exist.

3. **Stateful invariant testing.** Add a Foundry invariant test with a handler that randomly submits
   intents, commits bids, warps time, reveals, skips leaders and cancels. Assert continuously:
   - `Executor` holds zero of every token between settlements (I11)
   - No intent is ever `FILLED` without its account's balance having moved
   - No nonce is consumed twice across either chain's bitmap (I10)
   - An auction never has a leader whose bid is marked `out`

4. **Batch scaling.** Measure `settle` at n = 1, 2, 4, 8, 16, 32, 64 and report marginal gas per
   trade. §11 predicts roughly 50,000 per trade for a returning user and 67,000 on a first trade, both
   **estimated**. Report what you measure. If the numbers disagree with §11, the spec is wrong —
   say so in your summary rather than adjusting the test to match.

5. **Gas snapshot.** Commit a `.gas-snapshot` via `forge snapshot` so future changes surface as
   diffs.

6. **Negative space.** Add tests for things §2 lists as non-goals, asserting they fail cleanly rather
   than silently misbehaving: fee-on-transfer tokens, rebasing tokens, partial fills.

### Do Not Touch

- `src/**` — if a test reveals a contract defect, report it in your summary; do not fix it
- `test/unit/**` and `test/integration/**` — read them to build the matrix, add new files rather than
  editing existing ones
- `test/helpers/SettlementFixture.sol` — extend by adding only

### Verification

```bash
forge test
# → the whole suite passes

forge test --match-test invariant -vv
# → stateful invariant runs complete with no counterexamples

test -f planning/invariant-coverage.md && grep -c "^| I" planning/invariant-coverage.md
# → 19; one row per invariant

test -f .gas-snapshot
# → exists
```

### Your Summary

Report:
- The coverage matrix, as a table
- Any invariant you could not test, and why
- Measured gas against §11's estimates, flagging any disagreement as a spec defect
- Any contract defect you found and did **not** fix
