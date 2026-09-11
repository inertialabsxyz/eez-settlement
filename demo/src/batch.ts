/// Turning a set of live intents into a settlement.
///
/// The shape of the problem is fixed by I7: every intent has the numeraire on
/// one leg, so intents partition into independent groups by their other token.
/// Each group is priced and balanced on its own, which makes the batch the sum
/// of its groups and keeps the USDC accounting local to each.
import type { Address, Hex } from 'viem'
import { ONE, TOKENS, type Sym } from './config.js'
import type { Market } from './venues.js'
import { best, interactions, routeLabel, type Route } from './router.js'
import type { Interaction, SettlementData, Trade } from './payload.js'
import { score as scoreOf } from './payload.js'

export type LiveIntent = {
  id: bigint
  account: Address
  sell: Sym
  buy: Sym
  sellAmount: bigint
  limit: bigint
  deadline: bigint
  nonce: bigint
  signature: Hex
}

export type Strategy = {
  name: string
  /// Intermediate tokens the router may hop through. Empty means direct only.
  hops: Sym[]
  /// Venues this solver will look at.
  venues: ('A' | 'B' | 'OTC')[]
  /// How long a market snapshot may be reused, in ms. Zero means always fresh.
  quoteAgeMs: number
  /// Basis points to inflate the claimed score by. Non-zero is a bid this
  /// solver cannot back at reveal (§7.2).
  overclaimBps: number
  /// Probability of actually over-claiming on any given auction. A solver that
  /// over-claims every time wins every auction and settles none, so every
  /// auction needs a skip and the demo shows nothing else.
  overclaimChance: number
  blurb: string
}

export type Batch = {
  d: SettlementData
  intentIds: bigint[]
  signatures: Hex[]
  score: bigint
  claimed: bigint
  routes: string[]
  matched: number
  overclaiming: boolean
}

const mulDiv = (a: bigint, b: bigint, c: bigint) => (a * b) / c

/// A market filtered to the venues a strategy will consider.
function visible(m: Market, s: Strategy): Market {
  return {
    ...m,
    pools: m.pools.filter((p) => s.venues.includes(p.venue)),
    otcPrice: s.venues.includes('OTC') ? m.otcPrice : new Map(),
  }
}

/// Smallest input that buys at least `targetOut`, and the route that does it.
/// Output is monotone in input for every venue here, so binary search is exact.
function buyExactly(
  m: Market,
  from: Sym,
  to: Sym,
  targetOut: bigint,
  maxIn: bigint,
  hops: Sym[],
): { route: Route; amountIn: bigint } | null {
  const top = best(m, from, to, maxIn, hops)
  if (!top || top.out < targetOut) return null

  let lo = 1n
  let hi = maxIn
  while (lo < hi) {
    const mid = (lo + hi) / 2n
    const r = best(m, from, to, mid, hops)
    if (r && r.out >= targetOut) hi = mid
    else lo = mid + 1n
  }
  const route = best(m, from, to, lo, hops)
  return route && route.out >= targetOut ? { route, amountIn: lo } : null
}

type Group = { sym: Sym; sellingNumeraire: LiveIntent[]; sellingToken: LiveIntent[] }

type Priced = {
  price: bigint
  score: bigint
  calls: Interaction[]
  routes: string[]
}

/// Can this group settle at `price`, and at what cost?
///
/// `_pay` derives every buy amount from the one price vector, so the group's
/// obligations are fixed once the price is: USDC sellers are owed
/// `mulDiv(sellAmount, 1e18, p)` of the token, token sellers are owed
/// `mulDiv(sellAmount, p, 1e18)` of USDC. Whatever the participants do not
/// supply between them has to be sourced on L1, and the pull happens before the
/// interactions so the batch funds its own route (§9).
function priceGroup(m: Market, g: Group, price: bigint, hops: Sym[], deadline: bigint): Priced | null {
  let needTok = 0n
  let haveNum = 0n
  for (const i of g.sellingNumeraire) {
    const owed = mulDiv(i.sellAmount, ONE, price)
    if (owed < i.limit) return null // this trade's limit is not met at this price
    needTok += owed
    haveNum += i.sellAmount
  }

  let needNum = 0n
  let haveTok = 0n
  for (const i of g.sellingToken) {
    const owed = mulDiv(i.sellAmount, price, ONE)
    if (owed < i.limit) return null
    needNum += owed
    haveTok += i.sellAmount
  }

  const calls: Interaction[] = []
  const routes: string[] = []

  if (needTok > haveTok) {
    // Buy the shortfall with the numeraire the batch already holds.
    const short = needTok - haveTok
    const spare = haveNum > needNum ? haveNum - needNum : 0n
    if (spare === 0n) return null
    const buy = buyExactly(m, 'USDC', g.sym, short, spare, hops)
    if (!buy) return null
    calls.push(...interactions(buy.route, buy.amountIn, short, deadline))
    routes.push(`${routeLabel(buy.route)} in=${fmt(buy.amountIn)} out>=${fmt(short)}`)
  } else if (needNum > haveNum) {
    // Sell the surplus token for the numeraire the batch is short of.
    const short = needNum - haveNum
    const spare = haveTok - needTok
    if (spare === 0n) return null
    const sell = buyExactly(m, g.sym, 'USDC', short, spare, hops)
    if (!sell) return null
    calls.push(...interactions(sell.route, sell.amountIn, short, deadline))
    routes.push(`${routeLabel(sell.route)} in=${fmt(sell.amountIn)} out>=${fmt(short)}`)
  } else {
    routes.push('internal (no L1 liquidity needed)')
  }

  let score = 0n
  for (const i of g.sellingNumeraire) score += (i.sellAmount * ONE - i.limit * price) / ONE
  for (const i of g.sellingToken) score += (i.sellAmount * price - i.limit * ONE) / ONE

  return { price, score, calls, routes }
}

const fmt = (v: bigint) => (Number(v) / 1e18).toFixed(4)

/// The price band inside which every intent in the group is satisfiable, from
/// the limits alone. A USDC seller of `u` wanting at least `L` caps the price at
/// `u/L`; a token seller of `s` wanting at least `M` floors it at `M/s`.
function band(g: Group): { lo: bigint; hi: bigint } | null {
  let hi = (1n << 200n) - 1n
  let lo = 1n
  for (const i of g.sellingNumeraire) {
    const cap = mulDiv(i.sellAmount, ONE, i.limit)
    if (cap < hi) hi = cap
  }
  for (const i of g.sellingToken) {
    const floor = mulDiv(i.limit, ONE, i.sellAmount)
    if (floor > lo) lo = floor
  }
  return lo > hi ? null : { lo, hi }
}

const GRID = 48

/// Best settlement this strategy can find over these intents, or null.
export function buildBatch(
  market: Market,
  intents: LiveIntent[],
  strat: Strategy,
  deadline: bigint,
): Batch | null {
  const m = visible(market, strat)

  const groups = new Map<Sym, Group>()
  for (const i of intents) {
    // I7: a trade needs the numeraire on one leg. `Book` accepts an intent
    // without one -- it checks only that both tokens are registered -- and the
    // grouping below would silently encode such an intent as a USDC leg it did
    // not ask for, which `_validateAndScore` then rejects as `IntentMismatch`,
    // taking the whole settlement with it. Skip it instead.
    if (i.sell !== 'USDC' && i.buy !== 'USDC') continue
    const sym = i.sell === 'USDC' ? i.buy : i.sell
    if (sym === 'USDC') continue
    if (!groups.has(sym)) groups.set(sym, { sym, sellingNumeraire: [], sellingToken: [] })
    const g = groups.get(sym)!
    ;(i.sell === 'USDC' ? g.sellingNumeraire : g.sellingToken).push(i)
  }

  const tokens: Address[] = [TOKENS.USDC]
  const prices: bigint[] = [ONE] // I6: the numeraire pin
  const trades: Trade[] = []
  const calls: Interaction[] = []
  const ids: bigint[] = []
  const sigs: Hex[] = []
  const routes: string[] = []
  let matched = 0

  for (const g of groups.values()) {
    const b = band(g)
    if (!b) continue // no single price satisfies this group; a real solver would split it

    // Score is linear in the price on each side and the two sides pull opposite
    // ways, so the optimum sits at a feasibility boundary. Sweeping the band is
    // cheap against local models and avoids reasoning about which boundary.
    let bestPriced: Priced | null = null
    for (let k = 0; k <= GRID; k++) {
      const p = b.lo + ((b.hi - b.lo) * BigInt(k)) / BigInt(GRID)
      if (p <= 0n) continue
      const priced = priceGroup(m, g, p, strat.hops, deadline)
      if (priced && (!bestPriced || priced.score > bestPriced.score)) bestPriced = priced
    }
    if (!bestPriced) continue

    const idx = tokens.length
    tokens.push(TOKENS[g.sym])
    prices.push(bestPriced.price)
    calls.push(...bestPriced.calls)
    routes.push(`${g.sym} @ ${fmt(bestPriced.price)}  ${bestPriced.routes.join(' ')}`)

    for (const i of g.sellingNumeraire) {
      trades.push({ account: i.account, sellIdx: 0, buyIdx: idx, sellAmount: i.sellAmount, limit: i.limit, deadline: Number(i.deadline), nonce: i.nonce })
      ids.push(i.id)
      sigs.push(i.signature)
      matched++
    }
    for (const i of g.sellingToken) {
      trades.push({ account: i.account, sellIdx: idx, buyIdx: 0, sellAmount: i.sellAmount, limit: i.limit, deadline: Number(i.deadline), nonce: i.nonce })
      ids.push(i.id)
      sigs.push(i.signature)
      matched++
    }
  }

  if (trades.length === 0) return null

  const d: SettlementData = { tokens, clearingPrices: prices, trades, calls }
  const score = scoreOf(d)
  const overclaiming = strat.overclaimBps > 0 && Math.random() < strat.overclaimChance
  const claimed = overclaiming ? score + (score * BigInt(strat.overclaimBps)) / 10_000n : score

  return { d, intentIds: ids, signatures: sigs, score, claimed, routes, matched, overclaiming }
}
