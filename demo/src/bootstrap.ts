/// One-time setup for a swarm run. `npm run bootstrap`
///
/// The installers deploy the protocol and the venues; this funds the actors.
/// Separate because the account count is a property of the demo, not of the
/// deployment, and because doing 80 transactions in parallel from TypeScript is
/// far faster than doing them serially from bash.
import { formatUnits, type Address } from 'viem'
import { l1, wallet } from './chain.js'
import * as abi from './abi.js'
import { D, TOKENS, account, cfg, USER_INDICES, NOISE_INDEX, ONE, type Sym } from './config.js'
import { privateKeyToAccount } from 'viem/accounts'

const MAX = (1n << 256n) - 1n
const deployer = privateKeyToAccount(cfg.deployerKey)

/// Users sell; solvers do not. §14's capital-relief claim is that a solver needs
/// no inventory, so the solver accounts are deliberately absent here -- they get
/// L2 gas from genesis and nothing else, and the swarm demonstrates it for free.
/// Re-running must not re-send. The first version of this script did, and a
/// second run read `latest` while the first run's transactions were still
/// pending, reused their nonces, and poisoned the sender's queue.
async function needs(who: Address, token: Address, want: bigint): Promise<boolean> {
  const have = (await l1.readContract({ address: token, abi: abi.ERC20, functionName: 'balanceOf', args: [who] })) as bigint
  return have < want
}

const GRANT: Record<Sym, bigint> = {
  USDC: 400_000n * ONE,
  WETH: 100n * ONE,
  DAI: 400_000n * ONE,
  WBTC: 4n * ONE,
}

/// The noise trader swaps against the pools directly, so it approves the routers
/// rather than the Relayer. It is not a protocol participant.
const NOISE_GRANT: Record<Sym, bigint> = {
  USDC: 2_000_000n * ONE,
  WETH: 1_000n * ONE,
  DAI: 2_000_000n * ONE,
  WBTC: 20n * ONE,
}

const users = USER_INDICES.map(account)
const noise = account(NOISE_INDEX)
const w = wallet(deployer, 'l1')

/// Submit at most this many transactions from one account before waiting for
/// them to mine.
///
/// Not a politeness. Firing ~120 transactions from a single sender at this L1
/// left 117 of them permanently unmineable: accepted by the node, counted in
/// `eth_getTransactionCount(pending)` forever, and never included in a block,
/// which wedges every later nonce from that account behind them. Bursts of ten
/// are fine; the whole batch at once is not. Recovering means replacing each
/// stuck nonce individually at roughly one every thirty seconds.
const BATCH = 8

async function drain(who: Address, upTo: number) {
  const deadline = Date.now() + 120_000
  for (;;) {
    const mined = await l1.getTransactionCount({ address: who, blockTag: 'latest' })
    if (mined >= upTo) return
    if (Date.now() > deadline) throw new Error(`${who} stalled at nonce ${mined}, wanted ${upTo}`)
    await new Promise((r) => setTimeout(r, 3000))
  }
}

console.log('\nFunding L1 gas')
// 'pending', not 'latest': this L1 has 12s blocks, so a burst of sends stays
// in the mempool for several of them and a latest-based nonce collides with
// one already queued -- which surfaces as 'replacement transaction underpriced'.
let nonce = await l1.getTransactionCount({ address: deployer.address, blockTag: 'pending' })
for (const a of [...users, noise]) {
  await w.sendTransaction({ to: a.address, value: ONE, nonce: nonce++, chain: null, account: deployer })
  if (nonce % BATCH === 0) await drain(deployer.address, nonce)
}
await drain(deployer.address, nonce)

console.log('Funding tokens')
for (const [sym, addr] of Object.entries(TOKENS) as [Sym, Address][]) {
  for (const a of users) {
    await w.writeContract({ address: addr, abi: abi.ERC20, functionName: 'transfer', args: [a.address, GRANT[sym]], nonce: nonce++, chain: null, account: deployer })
    if (nonce % BATCH === 0) await drain(deployer.address, nonce)
  }
  await w.writeContract({ address: addr, abi: abi.ERC20, functionName: 'transfer', args: [noise.address, NOISE_GRANT[sym]], nonce: nonce++, chain: null, account: deployer })
  await drain(deployer.address, nonce)
}

/// §3.1 / I13: `Relayer` holds every approval and answers only to `Executor`. An
/// account that approved `Executor` instead fails at pull time in a way that
/// reads as a signature problem.
console.log('Approving Relayer (never Executor) for every user')
await Promise.all(
  users.map(async (a) => {
    const uw = wallet(a, 'l1')
    let n = await l1.getTransactionCount({ address: a.address, blockTag: 'pending' })
    for (const addr of Object.values(TOKENS)) {
      await uw.writeContract({ address: addr, abi: abi.ERC20, functionName: 'approve', args: [D.RELAYER, MAX], nonce: n++, chain: null, account: a })
    }
  }),
)

console.log('Approving both routers for the noise trader')
{
  const nw = wallet(noise, 'l1')
  let n = await l1.getTransactionCount({ address: noise.address, blockTag: 'pending' })
  for (const addr of Object.values(TOKENS)) {
    for (const spender of [D.ROUTER_A, D.ROUTER_B]) {
      await nw.writeContract({ address: addr, abi: abi.ERC20, functionName: 'approve', args: [spender, MAX], nonce: n++, chain: null, account: noise })
    }
  }
}

/// Poll until the chain shows the effect, rather than trusting the sends.
///
/// Eighty transactions on a 12s-block L1 sit in the mempool for a minute or
/// more, and reading balances straight after the last send reports a half-funded
/// swarm that is in fact fine. Same reason the shell harness waits on an L1
/// fact rather than on a send's exit code.
console.log('\nWaiting for the chain to catch up')
const deadline = Date.now() + 5 * 60_000
for (;;) {
  let pending = 0
  for (const a of users) {
    for (const [sym, addr] of Object.entries(TOKENS) as [Sym, Address][]) {
      const b = (await l1.readContract({ address: addr, abi: abi.ERC20, functionName: 'balanceOf', args: [a.address] })) as bigint
      if (b < GRANT[sym]) pending++
    }
    const allow = (await l1.readContract({ address: TOKENS.USDC, abi: abi.ERC20, functionName: 'allowance', args: [a.address, D.RELAYER] })) as bigint
    if (allow === 0n) pending++
  }
  if (pending === 0) break
  if (Date.now() > deadline) throw new Error(`${pending} funding effect(s) never landed`)
  process.stdout.write(`\r  ${pending} still pending...   `)
  await new Promise((r) => setTimeout(r, 4000))
}
console.log('\r  all funding landed          ')

console.log('\nBalances')
for (const a of [...users, noise]) {
  const bits: string[] = []
  for (const [sym, addr] of Object.entries(TOKENS) as [Sym, Address][]) {
    const b = (await l1.readContract({ address: addr, abi: abi.ERC20, functionName: 'balanceOf', args: [a.address] })) as bigint
    bits.push(`${sym} ${Number(formatUnits(b, 18)).toLocaleString()}`)
  }
  const allowance = (await l1.readContract({ address: TOKENS.USDC, abi: abi.ERC20, functionName: 'allowance', args: [a.address, D.RELAYER] })) as bigint
  console.log(`  ${a.address}  ${bits.join('  ')}  relayer-approved=${allowance > 0n}`)
}
console.log('\nDone.\n')
