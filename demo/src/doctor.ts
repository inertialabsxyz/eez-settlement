/// Preflight. Run this before a demo, not during one.
///
///     npm run doctor
///
/// Checks the enclave is up, the deployment is addressable from both chains, the
/// two halves agree on the signing domain, and the swarm accounts have gas.
import { formatUnits } from 'viem'
import { l1, l2, frontNonce, l2Now } from './chain.js'
import * as abi from './abi.js'
import { cfg, D, TOKENS, account, USER_INDICES, SOLVER_INDICES, NOISE_INDEX, ONE } from './config.js'

let bad = 0
const ok = (m: string) => console.log(`  \x1b[32mPASS\x1b[0m  ${m}`)
const no = (m: string) => {
  bad++
  console.log(`  \x1b[31mFAIL\x1b[0m  ${m}`)
}
const eq = (m: string, a: unknown, b: unknown) =>
  String(a).toLowerCase() === String(b).toLowerCase() ? ok(`${m} = ${a}`) : no(`${m}: got ${a}, want ${b}`)

console.log(`\nPreflight against ${cfg.l1Rpc} (L1 ${cfg.l1ChainId}) / ${cfg.l2Rpc} (L2 ${cfg.l2ChainId})\n`)

console.log('Chains')
ok(`L1 block ${await l1.getBlockNumber()}, L2 block ${await l2.getBlockNumber()}, L2 clock ${await l2Now()}`)

console.log('\nDeployment')
for (const [name, addr] of Object.entries(TOKENS)) {
  const code = await l1.getCode({ address: addr })
  code && code !== '0x' ? ok(`${name} at ${addr}`) : no(`${name} has no code on L1`)
}
const bookCode = await l2.getCode({ address: D.BOOK })
bookCode && bookCode !== '0x' ? ok(`Book at ${D.BOOK}`) : no('Book has no code on L2')

console.log('\nThe two chains agree on what a user signs (§5.3)')
const bookDomain = await l2.readContract({ address: D.BOOK, abi: abi.BOOK, functionName: 'domainSeparator' })
const execDomain = await l1.readContract({ address: D.EXECUTOR, abi: abi.EXECUTOR, functionName: 'domainSeparator' })
eq('domainSeparator, L2 Book vs L1 Executor', bookDomain, execDomain)
eq('book.l1Executor()', await l2.readContract({ address: D.BOOK, abi: abi.BOOK, functionName: 'l1Executor' }), D.EXECUTOR)

console.log('\nAuction parameters (§13.3 -- these are placeholders, not answers)')
const commitWindow = await l2.readContract({ address: D.BOOK, abi: abi.BOOK, functionName: 'COMMIT_WINDOW' })
const revealWindow = await l2.readContract({ address: D.BOOK, abi: abi.BOOK, functionName: 'REVEAL_WINDOW' })
const maxBids = await l2.readContract({ address: D.BOOK, abi: abi.BOOK, functionName: 'MAX_BIDS' })
ok(`COMMIT_WINDOW ${commitWindow}s, REVEAL_WINDOW ${revealWindow}s, MAX_BIDS ${maxBids}`)
Number(maxBids) >= SOLVER_INDICES.length
  ? ok(`${SOLVER_INDICES.length} solvers fits under MAX_BIDS`)
  : no(`${SOLVER_INDICES.length} solvers exceeds MAX_BIDS ${maxBids}`)

console.log('\nNumeraire allowlist (I6)')
eq('isNumeraire(USDC)', await l2.readContract({ address: D.BOOK, abi: abi.BOOK, functionName: 'isNumeraire', args: [TOKENS.USDC] }), true)
eq('isNumeraire(WETH) stays false', await l2.readContract({ address: D.BOOK, abi: abi.BOOK, functionName: 'isNumeraire', args: [TOKENS.WETH] }), false)

console.log('\nToken registry (L2 only)')
for (const [name, addr] of Object.entries(TOKENS)) {
  const [id, found] = (await l2.readContract({ address: D.REGISTRY, abi: abi.REGISTRY, functionName: 'idOf', args: [addr] })) as [number, boolean]
  found ? ok(`${name} registered as id ${id}`) : no(`${name} is not registered -- Book._idOf would revert UnknownToken`)
}

console.log('\nAccounts')
for (const [label, indices] of [
  ['user', USER_INDICES],
  ['solver', SOLVER_INDICES],
  ['noise', [NOISE_INDEX]],
] as const) {
  for (const i of indices) {
    const a = account(i)
    const gas = await l2.getBalance({ address: a.address })
    gas > ONE ? ok(`${label}[${i}] ${a.address} has ${formatUnits(gas, 18)} L2 ETH`) : no(`${label}[${i}] has no L2 gas`)
  }
}

/// The check that matters most, and the one whose absence cost hours.
///
/// The devnet builds L1 blocks through MEV-Boost and posts `postBatch` via
/// `eth_sendBundle` to rbuilder. When rbuilder stops bidding -- it has died with
/// `InconsistentProofs` in its root-hash prefetcher -- the proposer builds empty
/// blocks, no L1 transaction from anyone is included, and the L2 safe head
/// stops advancing. Cross-chain reveals are then accepted by the front and
/// never settle, which looks exactly like an application bug and is not one.
console.log('\nL1 inclusion and L2 finality')
{
  const safe0 = (await l2.getBlock({ blockTag: 'safe' }).catch(() => null))?.number ?? -1n
  const head0 = await l1.getBlockNumber()
  await new Promise((r) => setTimeout(r, 30_000))
  const safe1 = (await l2.getBlock({ blockTag: 'safe' }).catch(() => null))?.number ?? -1n
  const head1 = await l1.getBlockNumber()

  head1 > head0 ? ok(`L1 is producing blocks (${head0} -> ${head1})`) : no(`L1 is not producing blocks (stuck at ${head0})`)

  if (safe1 > safe0) {
    ok(`L2 safe head is advancing (${safe0} -> ${safe1}); postBatch is landing on L1`)
  } else {
    no(
      `L2 safe head stuck at ${safe1} -- postBatch is not landing. Check rbuilder:\n` +
        `        kurtosis service logs eez-dev el-2-reth-builder-lighthouse | grep -i inconsistent\n` +
        `        If L1 blocks show txs=0 while transactions sit in the pool, the builder has\n` +
        `        stopped bidding and no settlement can complete. Restart the enclave.`,
    )
  }
}

console.log('\nCross-chain front')
try {
  ok(`front answers; solver[${SOLVER_INDICES[0]}] nonce ${await frontNonce(account(SOLVER_INDICES[0]).address)}`)
} catch (e) {
  no(`front unreachable at ${cfg.l2Front}: ${e}`)
}

console.log(bad === 0 ? '\n\x1b[32mReady.\x1b[0m\n' : `\n\x1b[31m${bad} check(s) failed.\x1b[0m\n`)
process.exit(bad === 0 ? 0 : 1)
