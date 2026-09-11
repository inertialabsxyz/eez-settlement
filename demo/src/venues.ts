/// Local models of every L1 venue, refreshed by snapshot.
///
/// Solvers quote against these rather than round-tripping `eth_call` per
/// candidate: a path search over a handful of pools at twenty trial sizes is
/// hundreds of quotes, and the auction gives them sixty seconds total. That is
/// also how a real solver works -- model the pool, verify the chosen route once.
import type { Address } from 'viem'
import { l1 } from './chain.js'
import * as abi from './abi.js'
import { D, TOKENS, symbolOf, type Sym } from './config.js'

export type Venue = 'A' | 'B' | 'OTC'

export type Pool = { venue: 'A' | 'B'; a: Sym; b: Sym; pair: Address; ra: bigint; rb: bigint }

export type Market = {
  pools: Pool[]
  /// out-per-in scaled 1e18, keyed `${in}->${out}`; absent means unquoted.
  otcPrice: Map<string, bigint>
  otcInventory: Map<Sym, bigint>
  at: number
}

/// Every `PAIR_<venue>_<a>_<b>` the installer recorded.
const POOL_KEYS = Object.keys(D)
  .filter((k) => k.startsWith('PAIR_') && k.split('_').length === 4)
  .map((k) => {
    const [, venue, a, b] = k.split('_')
    return { key: k, venue: venue as 'A' | 'B', a: a as Sym, b: b as Sym }
  })

let token0Cache: Map<Address, Address> | null = null

export async function snapshot(): Promise<Market> {
  if (!token0Cache) {
    token0Cache = new Map()
    for (const p of POOL_KEYS) {
      token0Cache.set(D[p.key], (await l1.readContract({ address: D[p.key], abi: abi.UNIV2_PAIR, functionName: 'token0' })) as Address)
    }
  }

  const pools: Pool[] = []
  for (const p of POOL_KEYS) {
    const pair = D[p.key]
    const [r0, r1] = (await l1.readContract({ address: pair, abi: abi.UNIV2_PAIR, functionName: 'getReserves' })) as [bigint, bigint, number]
    const aIsToken0 = token0Cache.get(pair)!.toLowerCase() === TOKENS[p.a].toLowerCase()
    pools.push({ venue: p.venue, a: p.a, b: p.b, pair, ra: aIsToken0 ? r0 : r1, rb: aIsToken0 ? r1 : r0 })
  }

  const otcPrice = new Map<string, bigint>()
  const otcInventory = new Map<Sym, bigint>()
  const syms = Object.keys(TOKENS) as Sym[]
  for (const i of syms) {
    otcInventory.set(i, (await l1.readContract({ address: D.OTC, abi: abi.ERC20, functionName: 'balanceOf', args: [D.OTC] }).catch(() => 0n)) as bigint)
    for (const o of syms) {
      if (i === o) continue
      const p = (await l1.readContract({ address: D.OTC, abi: abi.OTC, functionName: 'price', args: [TOKENS[i], TOKENS[o]] })) as bigint
      if (p > 0n) otcPrice.set(`${i}->${o}`, p)
    }
  }
  for (const s of syms) {
    otcInventory.set(s, (await l1.readContract({ address: TOKENS[s], abi: abi.ERC20, functionName: 'balanceOf', args: [D.OTC] })) as bigint)
  }

  return { pools, otcPrice, otcInventory, at: Date.now() }
}

/// Uniswap V2's constant product with the 0.3% fee, exactly as the pair computes
/// it. Integer arithmetic throughout -- a float here drifts from the on-chain
/// result and the swap's `minOut` then fails for no visible reason.
export function amountOut(amountIn: bigint, reserveIn: bigint, reserveOut: bigint): bigint {
  if (amountIn <= 0n || reserveIn <= 0n || reserveOut <= 0n) return 0n
  const withFee = amountIn * 997n
  return (withFee * reserveOut) / (reserveIn * 1000n + withFee)
}

export function findPool(m: Market, venue: 'A' | 'B', x: Sym, y: Sym): Pool | undefined {
  return m.pools.find((p) => p.venue === venue && ((p.a === x && p.b === y) || (p.a === y && p.b === x)))
}

export function poolQuote(m: Market, venue: 'A' | 'B', x: Sym, y: Sym, amountIn: bigint): bigint {
  const p = findPool(m, venue, x, y)
  if (!p) return 0n
  const [rin, rout] = p.a === x ? [p.ra, p.rb] : [p.rb, p.ra]
  return amountOut(amountIn, rin, rout)
}

/// Flat price until the inventory runs out, then nothing. Returning zero rather
/// than throwing keeps the router's inner loop branch-free.
export function otcQuote(m: Market, x: Sym, y: Sym, amountIn: bigint): bigint {
  const p = m.otcPrice.get(`${x}->${y}`)
  if (!p) return 0n
  const out = (amountIn * p) / 10n ** 18n
  return out > (m.otcInventory.get(y) ?? 0n) ? 0n : out
}
