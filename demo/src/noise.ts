/// Background market activity.
///
/// Without it the routing table is a constant: every solver finds the same best
/// route every round, `stale` ties with `router` forever, and the competition is
/// decoration. This walks the pools so the best venue actually moves between
/// auctions.
///
/// It is not a protocol participant. It trades directly against the venues with
/// its own approvals to the routers, and never touches `Book`, `Executor` or
/// `Relayer`.
import { l1, wallet, sleep } from './chain.js'
import * as abi from './abi.js'
import { D, TOKENS, ONE, type Sym } from './config.js'
import { snapshot, findPool } from './venues.js'
import { log, fmt } from './log.js'

/// Sized to move a price by tens of basis points, not to drain a pool: the point
/// is that the best route changes, not that the market breaks.
const SIZES: Record<Sym, [bigint, bigint]> = {
  USDC: [5_000n * ONE, 60_000n * ONE],
  WETH: [2n * ONE, 30n * ONE],
  DAI: [5_000n * ONE, 60_000n * ONE],
  WBTC: [ONE / 10n, ONE],
}

const pick = <T>(xs: T[]): T => xs[Math.floor(Math.random() * xs.length)]
const between = (lo: bigint, hi: bigint) => lo + (BigInt(Math.floor(Math.random() * 1000)) * (hi - lo)) / 1000n

export class NoiseTrader {
  trades = 0

  constructor(readonly account: any) {}

  async run(stop: () => boolean, everyMs: number) {
    while (!stop()) {
      try {
        await this.trade()
      } catch (e: any) {
        log('noise', `\x1b[31mskip\x1b[0m ${String(e.shortMessage ?? e.message).slice(0, 90)}`)
      }
      await sleep(everyMs * (0.5 + Math.random()))
    }
  }

  private async trade() {
    const m = await snapshot()
    const pool = pick(m.pools)
    const [from, to] = Math.random() < 0.5 ? [pool.a, pool.b] : [pool.b, pool.a]

    const [lo, hi] = SIZES[from]
    let amountIn = between(lo, hi)

    const balance = (await l1.readContract({ address: TOKENS[from], abi: abi.ERC20, functionName: 'balanceOf', args: [this.account.address] })) as bigint
    if (balance < amountIn) amountIn = balance / 4n
    if (amountIn === 0n) return

    const router = pool.venue === 'A' ? D.ROUTER_A : D.ROUTER_B
    const deadline = BigInt(Math.floor(Date.now() / 1000) + 600)

    const hash = await wallet(this.account, 'l1').writeContract({
      address: router,
      abi: abi.UNIV2_ROUTER,
      functionName: 'swapExactTokensForTokens',
      // minOut 0: this actor is deliberately price-insensitive. It is weather,
      // not a trader with a view.
      args: [amountIn, 0n, [TOKENS[from], TOKENS[to]], this.account.address, deadline],
      chain: null,
      account: this.account,
    })
    await l1.waitForTransactionReceipt({ hash, timeout: 90_000 })

    this.trades++
    const after = findPool(await snapshot(), pool.venue, pool.a, pool.b)!
    log('noise', `${pool.venue}:${pool.a}/${pool.b}  ${fmt(amountIn, 2)} ${from} -> ${to}   reserves now ${fmt(after.ra, 0)}/${fmt(after.rb, 2)}`)
  }
}
