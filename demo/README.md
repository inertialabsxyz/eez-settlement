# The swarm

A live market on a real EEZ devnet: users signing intents, solvers competing for
them, and liquidity sourced on L1 inside each settlement's single cross-chain
dispatch.

Nothing here is mocked and nothing is pre-arranged. Intents are EIP-712 signed by
their own accounts and submitted on L2. Solvers bid sealed, only the winner
reveals, and the reveal crosses to L1 in one dispatch that either lands on both
chains or on neither. The venues are real Uniswap V2 deployments.

This is **demo-only**. It is not covered by `forge test`, and nothing in `src/`
knows it exists.

```sh
# 1. a running enclave
cd ../../eez-rollup0
export KURTOSIS_ENCLAVE=eez-dev
bash testing/kurtosis/start.sh "$PWD/testing/kurtosis/ci-args.yaml"

# 2. the protocol and the venues
cd ../eez-settlement
npm install && bash script/install-l1.sh && bash script/install-l2.sh

# 3. the actors
cd demo && npm install
npm run bootstrap      # fund users; solvers get nothing but gas
npm run doctor         # preflight -- run this before a demo, not during one
npm run swarm 15       # 15 minutes
```

`npm run quotes` prints the current routing table on its own, and `npm run
parity` re-checks the TypeScript encoding against the Solidity.

## The field

Five solvers sharing all their code, differing only in what they will look at
and what they will claim. A win should be legible, not a number.

| | Strategy | Loses when |
|---|---|---|
| `direct` | Venue A's direct pool only | Multi-hop or the OTC maker is better — usually |
| `venues` | Compares A, B and OTC; no hops | The DAI route wins, which it does at small size |
| `router` | Full path-finding | Rarely; this is the baseline good solver |
| `stale` | Full path-finding, 90s stale quotes | The noise trader moves prices under it |
| `greedy` | Full path-finding, over-claims 15% on 40% of auctions | Always, on the auctions it inflates |

`stale` is why the noise trader exists. Against static pools it ties with
`router` every round and the competition is decoration; only drifting prices make
caching cost something.

`greedy` is the interesting one. It wins the auction on a score `commitBid`
cannot check — that is precisely what sealing costs — and then dies at reveal on
`ScoreOverclaimed`, having paid gas for nothing. §7.2 argues from exactly this
that the auction needs no bond, and it is the only thing that ever makes
`skipLeader` execute.

It inflates only 40% of its bids on purpose. A solver that over-claims every
time wins every auction and settles none, so every auction needs a skip and
nothing else in the demo ever gets shown.

A batch is capped at 12 intents. That is not a protocol limit — `Book` caps bids
at 64, not trades — but every trade adds ~167 bytes of cross-chain calldata and a
pass through `_validateAndScore` on L2 and `_verifyAndPull`, `_pay` and
`_restore` on L1. Uncapped over a busy book it is a 20KB dispatch, and §11's
figures stop at n=64.

## The market

Four tokens, two Uniswap V2 deployments at different depths, seven pools, and a
fixed-price OTC maker with finite inventory. Measured on `eez-dev`, USDC→WETH has
three different best routes across the size range:

```
  USDC in      UniA      UniB       OTC   viaDAI  viaWBTC   best
      500  0.249244  0.250471  0.251889  0.253445  0.248471  viaDAI
    2,000  0.996901  1.001508  1.007557  1.013248  0.993515  viaDAI
   20,000  9.960070  9.970150 10.075567 10.068965  9.890883  OTC
  200,000 98.715803 95.420395  0.000000 94.750433 94.690042  UniA
```

via-WBTC never wins at any size, which is the point: a router has to compare
rather than prefer complexity. The OTC maker quotes flat until its inventory runs
out and then quotes nothing, so it takes small trades outright and cannot fill
large ones at all.

The DAI/WETH pool is deliberately dislocated to 1,960 against the 2,000 the other
two imply. Without that, every multi-hop route is the direct route plus a second
0.3% fee and can never win, and the token graph is decoration.

## What the shape of this demonstrates, and what it does not

**Solvers hold nothing.** No tokens, no approvals, no L1 ETH — only L2 gas, from
genesis. §14 claims a solver needs no inventory because the pull precedes the
interactions and the batch funds its own route. The swarm demonstrates that
rather than asserting it: `bootstrap` deliberately does not fund them.

**I7 makes the intent space a star.** Every intent must have the numeraire on one
leg, so `DAI -> WETH` is not expressible as an intent at all. The extra tokens are
routing hops, not new pairs. A demo audience will notice, and they should: that
is exactly what §13.5 asks about, and the swarm generates the evidence for it.

**§13.2 and §13.3 stay open.** `windfallRecipient` is a flagged devnet
placeholder in `script/dev.env`, chosen to belong to nobody so a sweep into it is
visible. The auction windows are read off the contract and never set here.

**Every settlement observed so far succeeded.** A failing L1 leg unwinding the L2
writes is still unshown — see §13.4 and issue #11.

## Devnet handling

`script/README.md` has the full list of ways this stack fails silently. Two of
them shaped this package:

**Check L1 is including transactions at all before debugging anything else.**
The devnet builds L1 blocks through MEV-Boost, and `eez_l1::submitter` posts
`postBatch` via `eth_sendBundle` to rbuilder specifically -- not an optional
path. rbuilder can die with

```
ERROR rbuilder::roothash::prefetcher: Error while prefetching trie nodes
      err=Other(Error while updated shared cache: InconsistentProofs
```

and stop bidding, after which the relay logs `no bid found` every slot, the
proposer builds empty blocks, and **no L1 transaction from anyone is included**.
The composer then warns `settlement backlog past 2x the batch cap`, the L2 safe
head freezes, and every cross-chain reveal fails -- accepted by the front, never
settled. Two symptoms identify it in seconds: recent L1 blocks all show `txs=0`
while transactions sit in the pool, and `cast block safe` on L2 stops advancing.
The only known fix is restarting the enclave, which loses the deployment.

`bootstrap` submits in batches of eight and waits for each to mine. That was
added after ~120 transactions from one sender appeared to wedge that account
permanently -- but that diagnosis is **unproven**: the builder failure above
explains the same symptom, and the batches-of-ten test that seemed to confirm it
merely ran during a healthy window. The batching is cheap and harmless, so it
stays; the reasoning behind it should not be trusted.

**Assert on the effect, never on the send.** A cross-chain transaction here can
be accepted, return a hash, change L2 state and then unwind on both chains. The
front's nonce advances ahead of L1 being readable, so it is a "no longer in
flight" signal and nothing stronger.

**One cross-chain reveal per solver at a time.** The front reserves *two* nonces
per cross-chain transaction and does not advance them until the call has settled
on both chains. A solver that wins two auctions and reveals both at once reads
the same nonce twice; the second comes back `replacement underpriced`, which
reads exactly like a reverted reveal even though it was never sent.

**Scan intents incrementally.** Intents are append-only and their terms never
change, so re-reading every log from block 0 each round is pure waste — and it
grows. At 190 intents it was ~400 sequential RPC calls per solver per round,
enough that a round outlasted the 60s commit window and the whole field stopped
bidding. Solvers now cache the log scan and state-check only as many as a batch
can hold.

## Why the encoding is checked

`Book` binds a commitment to `keccak256(abi.encode(d, intentIds, salt,
msg.sender, auctionId, address(this), block.chainid))`, where `d` holds four
dynamic arrays, two of them arrays of structs. `script/DevnetPayload.s.sol`
builds that in Solidity against the same struct definitions the contract compiles
from, so it cannot drift. `src/payload.ts` re-implements it and loses that
guarantee.

`npm run parity` buys it back: a fixture with two interactions of differing
calldata length is encoded both ways and the hashes must agree. It is not a
formality — a field widened from `uint128` to `uint256` produces identical values
and a different hash, and the only symptom is `BadCommitment` on a reveal sixty
seconds later with nothing to inspect.
