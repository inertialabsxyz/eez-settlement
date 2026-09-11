/// The demo. `npm run swarm [minutes]`
///
/// Eight users signing intents, five solvers competing for them, and a noise
/// trader walking the pools underneath so the best route moves between rounds.
///
/// Everything here is real: intents are EIP-712 signed by their own accounts and
/// submitted on L2, solvers bid sealed and only the winner reveals, and the
/// reveal crosses to L1 in a single dispatch that either lands on both chains or
/// on neither. Nothing is mocked and nothing is pre-arranged.
import { l1, l2, l2Now, sleep } from './chain.js'
import * as abi from './abi.js'
import { D, TOKENS, account, USER_INDICES, SOLVER_INDICES, NOISE_INDEX, ONE } from './config.js'
import { STRATEGIES } from './strategies.js'
import { Solver } from './solver.js'
import { NoiseTrader } from './noise.js'
import { User } from './user.js'
import { log, fmt, fmtScore } from './log.js'
import { parseAbiItem } from 'viem'

const MINUTES = Number(process.argv[2] ?? 10)
const USER_EVERY = 25_000
const NOISE_EVERY = 20_000

const users = USER_INDICES.map((i, n) => new User(account(i), `u${n}`))
const solvers = STRATEGIES.map((s, n) => new Solver(s, account(SOLVER_INDICES[n]), n))
const noise = new NoiseTrader(account(NOISE_INDEX))

let stopped = false
const stop = () => stopped

const commitWindow = Number(await l2.readContract({ address: D.BOOK, abi: abi.BOOK, functionName: 'COMMIT_WINDOW' }))
const revealWindow = Number(await l2.readContract({ address: D.BOOK, abi: abi.BOOK, functionName: 'REVEAL_WINDOW' }))

console.log(`
  Book      ${D.BOOK}   (L2)
  Executor  ${D.EXECUTOR}   (L1, via proxy ${D.EXECUTOR_PROXY})
  windfall  ${D.WINDFALL}   devnet placeholder; §13.2 is open

  ${users.length} users, ${solvers.length} solvers, 1 noise trader, ${MINUTES} minutes
  COMMIT_WINDOW ${commitWindow}s, REVEAL_WINDOW ${revealWindow}s   §13.3 placeholders, read off the contract

  The field:`)
for (const s of solvers) console.log(`    ${s.strat.name.padEnd(8)} ${s.strat.blurb}`)
console.log(`
  Solvers hold no tokens and no approvals -- only L2 gas. §14's capital-relief
  claim is that a solver needs no inventory; the batch funds its own route.
`)

/// A settlement's residue goes somewhere the solver cannot name (I17), and
/// `Executor` must exit every settlement at exactly its opening balance (I11).
/// Both are L1 facts, so both are read from L1.
async function treasury() {
  const out: string[] = []
  for (const [sym, addr] of Object.entries(TOKENS)) {
    const v = (await l1.readContract({ address: addr, abi: abi.ERC20, functionName: 'balanceOf', args: [D.WINDFALL] })) as bigint
    if (v > 0n) out.push(`${fmt(v, 4)} ${sym}`)
  }
  return out.length ? out.join('  ') : 'nothing yet'
}

/// `auctionCount` stays 0 while auction 0 is live -- it is the id of the newest
/// auction, not a tally -- so the watcher keys on the commit deadline instead.
const EXECUTED = parseAbiItem('event Executed(uint256 indexed auctionId, address indexed solver, uint256 score, uint256 filled)')

/// Settlements from earlier runs are already on chain. Seed the watcher with
/// them so it reports what this run does, not the history of the deployment.
const priorExecuted = new Set(
  (await l2.getLogs({ address: D.BOOK, event: EXECUTED, fromBlock: 0n, toBlock: 'latest' })).map((e) => String((e.args as any).auctionId)),
)

const auctionWatcher = (async () => {
  let seen = ''
  const reported = new Set<string>(priorExecuted)
  while (!stopped) {
    try {
      const id = (await l2.readContract({ address: D.BOOK, abi: abi.BOOK, functionName: 'auctionCount' })) as bigint
      const a = (await l2.readContract({ address: D.BOOK, abi: abi.BOOK, functionName: 'auctions', args: [id] })) as any[]
      const key = `${id}:${a[4]}`
      if (key !== seen && Number(a[4]) > 0) {
        const now = await l2Now()
        log('auction', `#${id} open, T_C in ${Number(a[4]) - now}s`)
        seen = key
      }
      for (const e of await l2.getLogs({ address: D.BOOK, event: EXECUTED, fromBlock: 0n, toBlock: 'latest' })) {
        const a = e.args as any
        const key2 = `${a.auctionId}`
        if (reported.has(key2)) continue
        reported.add(key2)
        const who = solvers.find((s) => s.account.address.toLowerCase() === String(a.solver).toLowerCase())
        log('settle', `\x1b[32m#${a.auctionId} settled by ${who?.strat.name ?? a.solver}\x1b[0m -- ${a.filled} intents, score ${fmtScore(a.score)}`)
      }
    } catch {
      /* transient */
    }
    await sleep(2000)
  }
})()

const runners = [
  noise.run(stop, NOISE_EVERY),
  ...users.map((u) => u.run(stop, USER_EVERY)),
  ...solvers.map((s) => s.run(stop)),
  auctionWatcher,
]

setTimeout(() => {
  stopped = true
}, MINUTES * 60_000)

await Promise.allSettled(runners)

console.log('\n  ── results ──────────────────────────────────────────────\n')
console.log(`  intents submitted   ${users.reduce((n, u) => n + u.submitted, 0)}`)
console.log(`  noise trades        ${noise.trades}`)
console.log(`  auctions            ${await l2.readContract({ address: D.BOOK, abi: abi.BOOK, functionName: 'auctionCount' })}`)
console.log()
/// Wins are attributed from `Executed`, not self-reported. Several solvers each
/// watch the auction settle and would all claim it otherwise -- and after a
/// `skipLeader` the solver that revealed is not the one that first led.
const executed = (await l2.getLogs({ address: D.BOOK, event: EXECUTED, fromBlock: 0n, toBlock: 'latest' })).filter(
  (e) => !priorExecuted.has(String((e.args as any).auctionId)),
)
const wonBy = new Map<string, number>()
let filled = 0
for (const e of executed) {
  const who = String((e.args as any).solver).toLowerCase()
  wonBy.set(who, (wonBy.get(who) ?? 0) + 1)
  filled += Number((e.args as any).filled)
}

console.log(`  settlements         ${executed.length}   (${filled} intents filled)`)
console.log()
console.log(`  ${'solver'.padEnd(9)}${'bids'.padStart(6)}${'won'.padStart(5)}${'reveals'.padStart(9)}${'failed'.padStart(8)}   strategy`)
for (const s of solvers) {
  const won = wonBy.get(s.account.address.toLowerCase()) ?? 0
  console.log(
    `  ${s.strat.name.padEnd(9)}${String(s.bids).padStart(6)}${String(won).padStart(5)}${String(s.reveals).padStart(9)}${String(s.revealsFailed).padStart(8)}   ${s.strat.blurb}`,
  )
}
console.log(`\n  residue swept to windfallRecipient (I17):  ${await treasury()}`)

/// I11 is an equality, not a bound: stated as >= it would permit a settlement to
/// end holding more than it started with, which is exactly the shape an unpaid
/// user leaves behind (§9.1).
const held: string[] = []
for (const [sym, addr] of Object.entries(TOKENS)) {
  const v = (await l1.readContract({ address: addr, abi: abi.ERC20, functionName: 'balanceOf', args: [D.EXECUTOR] })) as bigint
  if (v !== 0n) held.push(`${fmt(v)} ${sym}`)
}
console.log(`  Executor holds (I11, must be empty):      ${held.length ? `\x1b[31m${held.join('  ')}\x1b[0m` : 'nothing'}`)
console.log()
process.exit(0)
