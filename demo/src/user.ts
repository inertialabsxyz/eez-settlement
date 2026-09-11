/// A trader. Signs an intent, submits it, and keeps custody until a settlement
/// pulls from it under that signature.
import { l1, l2, sleep } from './chain.js'
import * as abi from './abi.js'
import { D, TOKENS, ONE, NUMERAIRE, type Sym } from './config.js'
import { snapshot } from './venues.js'
import { best } from './router.js'
import { signIntent, submitIntent, nextNonce } from './intents.js'
import { log, fmt } from './log.js'

const PAIRS: Sym[] = ['WETH', 'DAI', 'WBTC']

const SIZES: Record<Sym, [bigint, bigint]> = {
  USDC: [1_000n * ONE, 25_000n * ONE],
  WETH: [ONE / 2n, 12n * ONE],
  DAI: [1_000n * ONE, 25_000n * ONE],
  WBTC: [ONE / 20n, ONE / 2n],
}

const pick = <T>(xs: T[]): T => xs[Math.floor(Math.random() * xs.length)]
const between = (lo: bigint, hi: bigint) => lo + (BigInt(Math.floor(Math.random() * 1000)) * (hi - lo)) / 1000n

export class User {
  submitted = 0

  constructor(
    readonly account: any,
    readonly label: string,
  ) {}

  async run(stop: () => boolean, everyMs: number) {
    await sleep(Math.random() * everyMs)
    while (!stop()) {
      try {
        await this.submit()
      } catch (e: any) {
        log('user', `\x1b[31m${this.label} skip\x1b[0m ${String(e.shortMessage ?? e.message).slice(0, 90)}`)
      }
      await sleep(everyMs * (0.5 + Math.random()))
    }
  }

  private async submit() {
    // I7: the numeraire must be on one leg, so every intent is USDC<->X. A
    // direct DAI->WETH intent is not expressible, which is the constraint §13.5
    // asks about.
    const other = pick(PAIRS)
    const sellingNumeraire = Math.random() < 0.5
    const sell: Sym = sellingNumeraire ? NUMERAIRE : other
    const buy: Sym = sellingNumeraire ? other : NUMERAIRE

    let sellAmount = between(...SIZES[sell])
    const balance = (await l1.readContract({ address: TOKENS[sell], abi: abi.ERC20, functionName: 'balanceOf', args: [this.account.address] })) as bigint
    if (balance < sellAmount) sellAmount = balance / 3n
    if (sellAmount === 0n) return

    // The limit is set from what the market can actually do, shaded by a
    // tolerance. That tolerance is the solver's whole margin: score is surplus
    // above the limit, so a user who demands the exact market price leaves
    // nothing to compete over and their intent goes unfilled.
    const m = await snapshot()
    const quote = best(m, sell, buy, sellAmount, ['DAI', 'WBTC', 'WETH'])
    if (!quote) return
    const toleranceBps = 30n + BigInt(Math.floor(Math.random() * 120)) // 0.3% - 1.5%
    const limit = (quote.out * (10_000n - toleranceBps)) / 10_000n
    if (limit === 0n) return

    const now = Number((await l2.getBlock({ blockTag: 'latest' })).timestamp)
    const terms = {
      account: this.account.address,
      sellToken: TOKENS[sell],
      buyToken: TOKENS[buy],
      sellAmount,
      limit,
      deadline: BigInt(now + 3600),
      nonce: await nextNonce(this.account.address),
    }

    const signature = await signIntent(this.account, terms)
    await submitIntent(this.account, terms, signature)
    this.submitted++

    log('user', `${this.label} sells ${fmt(sellAmount, 2)} ${sell} for >= ${fmt(limit, 4)} ${buy}  (${Number(toleranceBps) / 100}% below ${quote.venue})`)
  }
}
