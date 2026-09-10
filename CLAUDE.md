# eez-settlement

Verifiable batch settlement: intents and a sealed-bid solver auction on an L2, liquidity sourced on
L1 inside a single cross-chain dispatch. Users keep custody throughout; the auction is recomputable
from on-chain data; every L1 pull carries the user's own EIP-712 signature.

These conventions take precedence over `~/.claude/CLAUDE.md` where they conflict.

---

## The specification is the source of truth

`planning/settlement-spec.md` is the design of record. Its appendices A–E contain reference
implementations of all five contracts, and `src/` is those appendices extracted verbatim.

**If code and spec disagree, that is a defect in one of them — not a thing to work around.** Decide
which is wrong, fix that one, and say which you changed. Do not silently make the code match a spec
you believe is mistaken, and do not edit the spec to match code you have just written.

The spec is under active review and is **not finished**. §13 lists open questions; two of them block
implementation:

- **§13.2** — the address `windfallRecipient` sweeps residue to is undecided.
- **§13.3** — `COMMIT_WINDOW` and batching cadence are undesigned. The values in `Book` are
  placeholders that make the contract runnable, not answers.

Do not resolve either by picking a value. Flag it and stop.

---

## Quality gate

```sh
forge test
```

Must pass before every commit, with no exceptions. There is no separate lint step; `forge fmt
--check` is advisory.

`forge build` alone is not the gate — this codebase's whole argument is that its invariants hold, and
only the tests demonstrate that.

---

## Invariants are numbered

§10 of the spec numbers nineteen invariants, I1–I19. **Cite them.** A test that establishes an
invariant names it in its doc comment; a contract line that enforces one names it in a code comment.

Three of them — I16, I18, I19 — are deliberately *not* runtime checks:

| | Property | Why not a check |
|---|---|---|
| I16 | `_pay` iterates every trade unconditionally | Provably true in a straight-line loop; asserting it is error handling for an impossible case |
| I18 | Interactions use `call`, never `delegatecall` | A contract cannot inspect its own opcodes |
| I19 | `settle` is the only entry point that emits calls | Same |

These are review obligations. Do not add runtime assertions for them; do not delete them from §10
because they are unenforceable.

I9–I13 are the invariants that survive a **fully compromised L2**. They are the audit priority and
deserve the densest tests.

---

## Testing

Follow the two-pattern split from the global conventions: unit tests for pure logic in a sibling
`*_test`-style contract in the same file; integration tests in `test/` exercising real contracts
through their public interfaces.

For this codebase specifically:

**Deployment order is load-bearing.** `Executor` constructs `Relayer` in its own constructor, so it
must be deployed before `Book`, and `setL2Caller` comes last:

```solidity
reg  = new TokenRegistry();
ex   = new Executor(address(new IdEEZ()), 0, windfallRecipient);
rl   = ex.relayer();
book = new Book(IExecutor(address(ex)), reg, block.chainid);
ex.setL2Caller(address(book));
```

**Setup a test will otherwise silently fail on:** register every token in `TokenRegistry`, call
`book.setNumeraire(token, true)` for whatever sits at `tokens[0]`, and have every trading account
approve `Relayer` — not `Executor`.

**The EIP-712 domain is pinned to L1.** Sign against `book.domainSeparator()`, never a locally
reconstructed one — the point of the shared `SettlementEIP712` library is that exactly one definition
exists.

**Reveal requires warping.** `revealAndExecute` reverts with `CommitPhaseOpen` until
`block.timestamp >= commitDeadline`. A test that commits and immediately reveals is testing nothing.

**`vm.expectRevert` binds to the very next external call.** If a helper does setup work before the
call under test, the expectation lands on the setup instead and the test passes for the wrong reason.
Structure helpers to stop short of the call being asserted on. This has already produced six
false failures in this repo.

---

## Solidity

- Solc `^0.8.28`, OpenZeppelin from `lib/`, no other dependencies.
- `SafeERC20` for every token call. USDT and friends return no data, and the design is worthless if
  it cannot settle them.
- Custom errors, not revert strings. Include an index parameter where a loop can fail on one element.
- Storage layouts in §5.1 are exact and load-bearing. `Intent` is 2 slots, `Bid` 2, `Auction` 3.
  Verify with `forge inspect src/Book.sol:Book storage-layout` after touching any struct — the gas
  figures in §11 depend on these.
- Do not add `receive()` to `Executor`. Its absence is what makes the ETH-leak check trivially true
  and removes the only path for an interaction to move native value.

---

## Gas figures

§11 distinguishes **measured** from **estimated** and the distinction matters — earlier estimates in
this project were wrong by 30–50% because they counted struct slots and ignored array-length slots,
leader-cache writes and event data.

If you quote a number, say which it is. If you can measure it, measure it.

---

## Commits

`type(scope): short description`, imperative, lowercase, 72 chars max. Scope is the contract or area:
`book`, `executor`, `relayer`, `registry`, `types`, `spec`, `test`.

One logical change per commit. The quality gate passes before each one.

Branches: `type/short-name`, PRs target `main` as drafts.
