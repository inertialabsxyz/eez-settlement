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

console.log('\nCross-chain front')
try {
  ok(`front answers; solver[${SOLVER_INDICES[0]}] nonce ${await frontNonce(account(SOLVER_INDICES[0]).address)}`)
} catch (e) {
  no(`front unreachable at ${cfg.l2Front}: ${e}`)
}

console.log(bad === 0 ? '\n\x1b[32mReady.\x1b[0m\n' : `\n\x1b[31m${bad} check(s) failed.\x1b[0m\n`)
process.exit(bad === 0 ? 0 : 1)
