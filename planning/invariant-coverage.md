# Invariant coverage — I1 to I19

One row per invariant in §10 of `planning/settlement-spec.md`, naming the test that establishes it
and the file the test lives in. Generated at the end of Phase 3 and maintained by hand; a new
invariant in §10 without a row here is an unfinished change.

The rule from `CLAUDE.md` is that a test establishing an invariant **names it in its doc comment**.
That is what makes this table checkable rather than aspirational: `grep -rn "I<n>" test/` finds every
test that claims the invariant, and the "established by" column below is the primary one among them.

| # | Invariant | Enforced | Established by | File |
|---|---|---|---|---|
| I1 | Every trade corresponds to a live intent matching on account, tokens, amount and limit | L2, at reveal | `testMatchingTradesSettleAndFillTheirIntents`, plus one test per field: account, sell amount, limit, deadline, sell token, buy token | `test/integration/Book.t.sol` |
| I2 | `intentIds.length == trades.length` | L2, at reveal | `testLengthMismatchBetweenIdsAndTradesRejected`, and `testLengthMismatchBetweenPricesAndTokensRejected` for the price-vector half | `test/integration/Book.t.sol` |
| I3 | No intent id appears twice in one settlement | L2 — `state` written in-loop | `testRepeatedIntentIdRejected` | `test/integration/Book.t.sol` |
| I4 | Every user receives at least the limit they signed | L2 at reveal, again on L1 at pay | `testLimitNotMetRejected` (L2), `testLimitNotMetWhenPriceFallsShort` (L1) | `test/integration/Book.t.sol`, `test/integration/Executor.t.sol` |
| I5 | Every trade's buy amount derives from one shared price vector | Structural | `testBuyAmountsDeriveFromSharedPriceVector`, and continuously in `invariant_NoIntentIsFilledWithoutBeingPaid` | `test/integration/Executor.t.sol`, `test/invariant/Settlement.t.sol` |
| I6 | `tokens[0]` is allowlisted and `clearingPrices[0] == PRICE_SCALE` | L2, at reveal | `testUnallowlistedNumeraireRejected`, `testNumeraireNotPinnedToPriceScaleRejected` | `test/integration/Book.t.sol` |
| I7 | Every trade has the numeraire on one side | L2, at reveal | `testTradeWithNoNumeraireLegRejected`, and the full §8 attack in `testShellNumeraireWithInflatedVectorRejected` | `test/integration/Book.t.sol` |
| I8 | Inflating a free price never gains score beyond the numeraire it obliges the batch to deliver | Property — fuzz | `testFuzzScoreNonIncreasingInTheFreePrice`, `testFuzzScoreNonIncreasingAcrossABatch`, `testFuzzScoreRisesOnlyByWhatTheBatchMustDeliver`, `testFuzzScoreGainIsBoundedByTheNumeraireDelivered` | `test/invariant/ScoreMonotonicity.t.sol` |
| I9 | Every pull is covered by the account's EIP-712 signature over those exact terms | **L1** | `testWrongSignerRejected`, plus one test per signed field, and `testFuzzExecutorWidensTradeIntoTheSignedIntentTheUserSigned` for the `Trade` → `SignedIntent` reduction | `test/integration/Executor.t.sol`, `test/unit/TypesAndRegistry.t.sol` |
| I10 | No nonce is consumed twice | **L1** | `testNonceCannotBeConsumedTwice`, and continuously — including adversarial replays straight at L1 — in `invariant_NoNonceIsConsumedTwice` | `test/integration/Executor.t.sol`, `test/invariant/Settlement.t.sol` |
| I11 | `Executor` holds exactly its opening balance of every listed token, and of ETH, at exit | **L1** — equality | `testExecutorExitsAtOpeningBalance`, `testNotSolventWhenSettlementDoesNotBalance`, and continuously in `invariant_ExecutorAndRelayerHoldNothing` | `test/integration/Executor.t.sol`, `test/invariant/Settlement.t.sol` |
| I12 | No interaction targets `Relayer` | **L1** | `testInteractionTargetingRelayerReverts` (direct), `testIndirectRelayerCallFails` (through a forwarder) | `test/integration/Executor.t.sol` |
| I13 | `Relayer` moves tokens only for `Executor` | **L1** | `testPullBatchRejectsNonExecutor`, plus the two length-mismatch cases | `test/integration/Executor.t.sol` |
| I14 | Only the frozen leader may reveal, and only within `[T_C, T_R)` | L2 | `testRevealBeforeCommitDeadlineReverts`, `testRevealAfterRevealDeadlineReverts`, `testNonLeaderCannotReveal` | `test/integration/Book.t.sol` |
| I15 | The candidate set cannot grow after `T_C` | L2 | `testCandidateSetFrozenAtCommitDeadline` | `test/integration/Book.t.sol` |
| I16 | `_pay` iterates every trade unconditionally — no branch skips one | Review + test, **not** a runtime check | `testEveryTradeIsPaid`, and continuously in `invariant_NoIntentIsFilledWithoutBeingPaid` — see the note below | `test/integration/Executor.t.sol`, `test/invariant/Settlement.t.sol` |
| I17 | Residue is unreachable by the solver | **L1** | `testResidueSweptToWindfallNotSolver`, `testSolverCannotPullResidueFromExecutor`, `testRebaseUpIsSweptToTheWindfallNotTheSolver` | `test/integration/Executor.t.sol`, `test/integration/NonGoals.t.sol` |
| I18 | Interactions are dispatched with `call`, never `delegatecall` | Review only | **No test, and none is possible** — see the note below | — |
| I19 | `settle` is the only entry point that emits calls or moves value | Review only | **No test, and none is possible** — see the note below | — |

## The three that are not runtime checks

§10 lists I16, I18 and I19 as review obligations rather than assertions, and `CLAUDE.md` forbids
adding runtime checks for them. That does not mean all three are equally untestable, and the
distinction is worth recording rather than leaving as three blanks.

**I16 — `_pay` skips nobody.** Testable, and tested twice. `testEveryTradeIsPaid` fixes a batch and
asserts every account in it was paid; `invariant_NoIntentIsFilledWithoutBeingPaid` asserts the same
thing continuously, over fuzzer-chosen sequences, by cross-checking `Book`'s FILLED marks against
balances that actually moved. What may not be added is a `require` inside `_pay` — the property is
provably true of a straight-line loop, so asserting it in-contract is error handling for an
impossible case. The tests establish the property; the review obligation is that the loop stays
straight-line.

This one carries the most weight of the three. §9.1 and §13.8 point out that I11 protects the
*contract*, not the *user*: a user who is pulled from and never paid still leaves `Executor` at
exactly its opening balance, because `_restore` sweeps their tokens off to `windfallRecipient` and
the equality holds. Only the user's own balance shows it, which is why the invariant reads balances.

**I18 — `call`, never `delegatecall`.** No test is possible. A contract cannot inspect its own
opcodes, and every observable behaviour of a `delegatecall` variant of `_interact` would be identical
until an interaction exploited it. The obligation is to read `Executor._interact` on every change to
it: a one-word edit there voids I12 and I13 simultaneously.

**I19 — `settle` is the only entry point that emits calls or moves value.** No test is possible for
the same reason: it is a claim about the *absence* of code, and no assertion can range over what is
not there. The nearest evidence is `testSettleFromNonProxyReverts`, which shows the one entry point
that does move value is closed to everyone but the L2 proxy; the obligation is that no second one is
ever added. The reentrancy argument in §3.1 rests on this, and `CLAUDE.md`'s ban on adding
`receive()` to `Executor` is the same obligation in a narrower form.

## What Phase 3 closed

- **I8 had no test.** It was the only invariant in §10 with no coverage at all, which mattered
  because §10 marks it as the fuzz invariant and §8 calls it "the property the auction's soundness
  rests on". `test/invariant/ScoreMonotonicity.t.sol` now fuzzes it over price vectors and trade
  sets, and found that §8 stated it for only one of the two numeraire directions — see the
  correction note in §8.
- **I5, I10, I11 and I16 had only fixed-ordering tests.** `test/invariant/Settlement.t.sol` now
  asserts all four continuously against fuzzer-chosen sequences of submits, commits, warps, reveals,
  skips, cancels and L1 replays.
- **I18 and I19 were blanks.** They are stated as untestable above, with the reason, rather than
  recorded as gaps.
