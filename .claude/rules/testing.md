# Testing & Quality

## Commands

```sh
forge test              # the quality gate — must pass before every commit
forge test -vvv         # with traces; what CI runs
forge test --match-test testResidueSweptToWindfall -vvv
forge build --sizes     # CI runs this; contracts must stay under the EIP-170 limit
forge fmt               # rewrite in place
forge fmt --check       # CI runs this as a hard step — a failure here reds the build
forge inspect src/Book.sol:Book storage-layout
```

There is no `make`, no lint step beyond `forge fmt --check`, and no separate integration runner.

`forge test` is the gate. **`forge build` is not** — this codebase's whole argument is that its
invariants hold, and only the tests demonstrate that. A change that compiles and is untested has
demonstrated nothing.

`forge fmt --check` is described as advisory in `CLAUDE.md`, but `.github/workflows/test.yml` runs it
as a blocking step before build and test. Treat it as blocking.

It does not currently pass: `src/Book.sol`, `src/Executor.sol`, `src/Relayer.sol`,
`src/SettlementTypes.sol`, `test/Properties.t.sol` and `test/Smoke.t.sol` all differ from `forge fmt`
output, so CI is red on `main` for formatting alone. **Do not fix this by running `forge fmt` across
`src/`** — `src/` is Appendices A–E extracted verbatim, and reformatting it silently desyncs code
from the design of record. Reformatting `src/` means reformatting the appendices in the same commit,
which is a decision to take deliberately, not a side effect of an edit.

For that reason the `PostToolUse` hook in `.claude/settings.json` only *checks* the file you edited
and prints a note; it never rewrites. Format `test/` freely; for `src/`, format and mirror into the
appendix, or leave it.

## Test mandate

Every feature commit must include at least one test for the new behaviour. Every bug fix must include
a regression test that would have caught the bug. A commit that adds behaviour without a test, or
fixes a bug without a regression test, is incomplete.

**Invariants are numbered — cite them.** §10 of the spec numbers nineteen, I1–I19. A test that
establishes an invariant names it in its doc comment; a contract line that enforces one names it in a
code comment. `test/Properties.t.sol` is the model:

```solidity
// ---- I12: an interaction cannot reach the relayer
function testInteractionCannotTargetRelayer() public {
```

**I9–I13 are the audit priority.** They are the invariants that survive a fully compromised L2 —
every pull carries the user's signature (I9), no nonce is consumed twice (I10), `Executor` exits at
exactly its opening balance (I11), no interaction targets `Relayer` (I12), `Relayer` moves tokens
only for `Executor` (I13). These deserve the densest tests and the most adversarial cases.

**I16, I18 and I19 are review obligations, not runtime checks.** Do not add runtime assertions for
them and do not delete them from §10 because they are unenforceable. A test may still exercise the
property (that `_pay` skipped nobody); what it may not do is demand a `require` in the contract.

## Two test patterns

**Unit tests** — pure logic, no deployment graph. A sibling `*_test`-style contract in the same file,
or a focused single-contract test like `test/TokenRegistry.t.sol`, which constructs only
`TokenRegistry` and a mock token and asserts on `register`/`tokenAt`.

**Integration tests** — the real contracts through their public interfaces, in `test/`.
`test/Smoke.t.sol` is the happy path end-to-end; `test/Properties.t.sol` is the invariant suite.

## Setup a test will otherwise silently fail on

**Deployment order is load-bearing.** `Executor` constructs `Relayer` in its own constructor, so it
must be deployed before `Book`, and `setL2Caller` comes last:

```solidity
reg  = new TokenRegistry();
eez  = address(new IdEEZ());
ex   = new Executor(eez, 0, windfallRecipient);
rl   = ex.relayer();
book = new Book(eez, address(ex), 0, reg, block.chainid);
ex.setL2Caller(address(book));
```

`Book` takes the **L1 `Executor`**, not the address it dispatches to: it derives the cross-chain
proxy itself and scopes the EIP-712 domain to the `Executor` (§5.3). Under `IdEEZ` those two are the
same address, which is why `test/unit/TypesAndRegistry.t.sol` rebuilds `Book` over `ProxyEEZ` — a
derivation that keeps them apart — for the cases that turn on the difference.

Then, in order:

- **Register every token** in `TokenRegistry`. An unregistered token has no id.
- **`book.setNumeraire(token, true)`** for whatever sits at `tokens[0]`. I6 requires
  `tokens[0]` be allowlisted with `clearingPrices[0] == PRICE_SCALE`; I7 requires the numeraire on
  one side of every trade.
- **Every trading account approves `Relayer`** — not `Executor`. `Relayer` holds every approval;
  that separation is the point (§3.1).

**The EIP-712 domain is pinned to L1.** Sign against `book.domainSeparator()`, never a locally
reconstructed one — the point of the shared `SettlementEIP712` library is that exactly one definition
exists. `_sig` in `test/Properties.t.sol` shows the shape.

**Reveal requires warping.** `revealAndExecute` reverts with `CommitPhaseOpen` until
`block.timestamp >= commitDeadline`. A test that commits and immediately reveals is testing nothing.
`_commitFor` warps by `book.COMMIT_WINDOW()` and deliberately stops short of the reveal.

**`vm.expectRevert` binds to the very next external call.** If a helper does setup work before the
call under test, the expectation lands on the setup and the test passes for the wrong reason.
Structure helpers to stop short of the call being asserted on — that is exactly why `_commitFor` and
`_reveal` are separate. This has already produced six false failures in this repo.

**The commitment hash is over the full tuple.** `keccak256(abi.encode(d, ids, salt, solver,
auctionId, address(book), chainid))`. A reveal that mismatches any element is rejected; a test that
builds the commitment by hand must match `_commitFor`.

## What to test at each layer

| Layer | Pattern | Example |
|---|---|---|
| `TokenRegistry` id allocation | Unit — deploy the one contract | `testRegister`, `testTokenAt` |
| Scoring / pricing arithmetic | Unit, or fuzz for I8 (score non-increasing in every free price) | §7.3 |
| Auction phase transitions | Integration — commit, warp, assert | `testCannotOutbidAfterCommitDeadline` (I14, I15) |
| Reveal-time L2 validation | Integration — expect the custom error | `testLengthMismatchRejected` (I2), `testDuplicateIntentRejected` (I3), `testNoNumeraireLegRejected` (I7) |
| L1 signature and nonce checks | Integration, adversarially | `testBadSignatureRejectedOnL1` (I9), `testNonceReuseRejectedOnL2` (I10 mirror) |
| Interaction sandboxing | Integration | `testInteractionCannotTargetRelayer` (I12) |
| Residue handling | Integration — assert the windfall balance | `testResidueSweptToWindfall` (I17) |
| Balance conservation | Integration — assert **equality**, not a bound | I11 |
| End-to-end settlement | Integration | `testCoincidenceOfWantsEndToEnd` |
| Gas | Integration, measured | `testGas` |

## Storage layout

Layouts in §5.1 are exact and load-bearing: `Intent` is 2 slots, `Bid` 2, `Auction` 3. After touching
any struct, verify:

```sh
forge inspect src/Book.sol:Book storage-layout
```

The gas figures in §11 depend on these.

## Gas figures

§11 distinguishes **measured** from **estimated** and the distinction matters — earlier estimates in
this project were wrong by 30–50% because they counted struct slots and ignored array-length slots,
leader-cache writes and event data.

If you quote a number, say which it is. If you can measure it, measure it: `testGas` in
`test/Properties.t.sol` brackets the calls with `gasleft()`, and `forge test` prints per-test gas for
everything else.
