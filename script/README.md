# Devnet harness

End-to-end settlement against a live EEZ devnet: real L1, real L2, real
cross-chain dispatch, a real Uniswap V2 pool. `forge test` proves the invariants
against a mocked bridge; this proves the protocol runs on the bridge it was
designed for.

```sh
cd eez-rollup0 && bash testing/kurtosis/start.sh testing/kurtosis/ci-args.yaml

cd eez-settlement
npm install                   # prebuilt Uniswap V2 artefacts, devnet-only
bash script/install-l1.sh     # tokens, Uniswap venue, Executor (+Relayer)
bash script/install-l2.sh     # TokenRegistry, Book, both cross-chain proxies
bash script/e2e.sh all        # cow | route | all
```

Addresses land in `script/deployments.env`, which is generated and gitignored.
Each installer is a fresh deployment, not an upgrade: `Executor.setL2Caller` is
one-shot, so a new `Book` needs a new `Executor`, which means re-running both.

## What the two phases settle

**`cow`** — Alice sells 2,000 USDC for at least 0.9 WETH, Bob sells 1 WETH for at
least 1,900 USDC. At 2,000 USDC/WETH they fill each other exactly: no
interactions, no solver capital, and no residue. A batch that nets to zero is the
only way to watch I11's *equality* mean something — with residue in play, an
`Executor` that ended up holding a user's unpaid tokens would look the same as
one that swept a legitimate surplus.

**`route`** — Alice sells 2,000 USDC with no counterparty. The solver's payload
carries two interactions: approve the router, then swap the pulled USDC through
the live pool with the output landing back in `Executor`. The pull precedes the
interactions, so the batch funds its own route (§9). This is the
"liquidity sourced on L1 inside a single cross-chain dispatch" claim, executed.

Measured on the `eez-dev` enclave: Alice is paid exactly
`mulDiv(2000e18, 1e18, 2100e18)` = 0.952380952380952380 WETH, `Executor` exits at
its opening balance of both tokens, and 0.044519656628329394 WETH of residue —
the Uniswap fee, which nobody in the batch has a claim on — is swept to
`windfallRecipient`, where the solver cannot reach it (I17).

`minOut` on the swap is the user's payout rather than a percentage band. The
route therefore reverts precisely when the pool has moved enough to make the
batch unpayable, and the whole settlement unwinds on both chains instead of
failing later in `_pay` as an opaque token error.

## §13.2 and §13.3 are not resolved here

`Executor` requires a non-zero `windfallRecipient`, so a deployment cannot avoid
passing one. `script/dev.env` passes `0x…DeaDFee5`, chosen to belong to nobody in
this harness so that a sweep into it is visible in a balance assertion. It is not
a proposal. §13.2 asks who the real recipient should be and is still open.

`COMMIT_WINDOW` and `REVEAL_WINDOW` are read off the contract, never set by the
harness. At the current 60s placeholders a settlement has to commit, wait out the
commit phase, and land a cross-chain dispatch inside the following 60s. It does
— the Sync cadence is roughly 12s — but the margin is the reveal window's, not a
designed one. See §13.3.

## Things that cost hours, in the order they will cost them

`eez-ticket-sales/docs/eez-gotchas.md` is the long version. These are the ones
this harness is shaped by.

**The reveal must go to the cross-chain front, not to the L2 RPC.** A transaction
sent to `L2_RPC` lands in an ordinary live block, where the L1 proxy rejects it
with `ExecutionNotInCurrentBlock`. Only `revealAndExecute` needs this;
`submitIntent` and `commitBid` emit no L1 call and go to the RPC.

**The front owns its own nonce, and a cross-chain transaction reserves two.**
`eth_getTransactionCount` on `L2_RPC` returns a value the front rejects as an
underpriced replacement. Read it from the front. `front_nonce` in `lib.sh`.

**`cast gas-price` returns single-digit wei here.** Paired with
`--priority-gas-price 1` the effective tip after base fee is zero, so the front
accepts the transaction and then drops it, silently. `l2_gas_price` bids
`max(4× suggested, 1 gwei)` with a 10% tip.

**Assert on the effect, never on the exit code of a send.** §13.4 records that
the previous harness captured the exit code and passed vacuously. A cross-chain
transaction here can be accepted, return a hash, change L2 state, and then unwind
on both chains. Worse for a test author: the front's nonce advancing is *not* a
"visible on L1" signal. The first run of this harness trusted it, read an L1 that
had not caught up, and reported six failures for a settlement that had landed
perfectly one block later. `run_auction` now waits for a fact only the L1 half
can produce — the nonce its pull consumed — before asserting anything.

**The first outbound call through a fresh proxy can roll back silently**, and a
later call retroactively settles it. `settle_with_retry` re-commits the same
payload against a fresh auction; a rolled-back reveal leaves the intents `LIVE`,
because `submitIntent` is an ordinary L2 transaction that does not unwind with
the dispatch.

**Shell arithmetic is 64-bit.** An 18-decimal 2,000-token leg is 2e21 and `$(( ))`
wraps it into a plausible wrong number — the first run expected a balance of
`7751640039368425472`. `bn_add`/`bn_sub`/`bn_gt` in `lib.sh` go through Python.

**The deployer's L1 and L2 nonces start equal**, so the Nth contract on each
chain gets the same address; one run had `USDC` on L1 and `TokenRegistry` on L2
both at `0x663F…6602`. Harmless, until a debugging session reaches for the wrong
`--rpc-url` and gets a live contract and a plausible answer instead of `0x`.
`install-l2.sh` burns one nonce to keep the address spaces apart.

## Why the payload is built in Solidity

`Book` binds a commitment to `keccak256(abi.encode(d, intentIds, salt,
msg.sender, auctionId, address(this), block.chainid))`, where `d` holds four
dynamic arrays, two of them arrays of structs. `cast abi-encode` can express
that, and it is the single most likely thing here to be subtly wrong — with
`BadCommitment` as the only symptom and nothing to inspect.

`script/DevnetPayload.s.sol` builds the payload against the same struct
definitions the contract compiles against, so the two cannot drift. It runs with
no `--rpc-url` and broadcasts nothing; `e2e.sh` reads back the commitment, the
score and the ready-made `revealAndExecute` calldata, and does the sending. It
takes the L2 chain id from the environment, because offline `block.chainid` is
31337 and would silently produce a commitment no `Book` could match.

It claims the score it computes *exactly* rather than claiming low. Claiming low
would always be accepted and would test nothing; claiming exactly means a
divergence between the harness's model of §7.3 and `Book._validateAndScore`
surfaces as `ScoreOverclaimed` on the reveal.

## Signatures

`sign_intent` signs EIP-712 typed data with `cast wallet sign --data`, assembling
the domain from `name`, `version`, `chainId` and `verifyingContract` — which is
the only thing a wallet can do. Both chain-dependent fields are read back off the
chains rather than taken from `deployments.env`, and the result is checked twice:
`Book.submitIntent` verifies it against `book.domainSeparator()` on L2, and
`Executor` verifies it again on L1, which is the check that survives a
compromised L2 (I9).

`install-l2.sh` asserts `book.domainSeparator() == executor.domainSeparator()`
across the two chains before any intent is signed. That assertion is the reason
this harness exists: `Book` used to scope its domain to whatever address it was
constructed with, and the Foundry fixture's `IdEEZ` derives a cross-chain proxy
as the identity — so the address `Book` dispatches to and the address the
signature is scoped to were the same address in every test, and different
addresses on every real bridge.
