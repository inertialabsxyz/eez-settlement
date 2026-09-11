/// Path-finding across the L1 venues.
import type { Address, Hex } from 'viem'
import { encodeFunctionData } from 'viem'
import * as abi from './abi.js'
import { D, TOKENS, type Sym } from './config.js'
import { poolQuote, otcQuote, type Market, type Venue } from './venues.js'
import type { Interaction } from './payload.js'

export type Route = {
  venue: Venue
  /// Symbols, including both ends. Length 2 is direct.
  path: Sym[]
  out: bigint
}

export const routeLabel = (r: Route) => `${r.venue}:${r.path.join('>')}`

/// Every route this market can express from `x` to `y`, quoted.
///
/// Hops stay within one Uniswap deployment because the V2 router's multi-hop
/// path is resolved against a single factory; a cross-venue hop would need two
/// interactions and an intermediate balance, which is expressible but not worth
/// it here.
export function routes(m: Market, x: Sym, y: Sym, amountIn: bigint, hops: Sym[]): Route[] {
  const out: Route[] = []

  for (const venue of ['A', 'B'] as const) {
    const direct = poolQuote(m, venue, x, y, amountIn)
    if (direct > 0n) out.push({ venue, path: [x, y], out: direct })

    for (const mid of hops) {
      if (mid === x || mid === y) continue
      const leg1 = poolQuote(m, venue, x, mid, amountIn)
      if (leg1 <= 0n) continue
      const leg2 = poolQuote(m, venue, mid, y, leg1)
      if (leg2 > 0n) out.push({ venue, path: [x, mid, y], out: leg2 })
    }
  }

  const otc = otcQuote(m, x, y, amountIn)
  if (otc > 0n) out.push({ venue: 'OTC', path: [x, y], out: otc })

  return out.sort((a, b) => (b.out > a.out ? 1 : b.out < a.out ? -1 : 0))
}

export function best(m: Market, x: Sym, y: Sym, amountIn: bigint, hops: Sym[]): Route | undefined {
  return routes(m, x, y, amountIn, hops)[0]
}

/// The interactions that execute a route from inside `Executor`.
///
/// Two calls in both cases: the approval the venue needs, then the swap, with
/// the output landing back in `Executor` where `_pay` and `_restore` expect it.
/// Neither may target `Relayer` (I12) -- the approval targets the token and the
/// swap targets the venue.
///
/// `minOut` is the user's payout rather than a slippage band, so the route
/// reverts precisely when the pool has moved enough to make the batch unpayable
/// and the whole settlement unwinds on both chains, instead of failing later in
/// `_pay` as an opaque token error.
export function interactions(route: Route, amountIn: bigint, minOut: bigint, deadline: bigint): Interaction[] {
  const tokenIn = TOKENS[route.path[0]]
  const spender = route.venue === 'OTC' ? D.OTC : route.venue === 'A' ? D.ROUTER_A : D.ROUTER_B

  const approve: Interaction = {
    target: tokenIn,
    callData: encodeFunctionData({ abi: abi.ERC20, functionName: 'approve', args: [spender, amountIn] }),
  }

  if (route.venue === 'OTC') {
    return [
      approve,
      {
        target: D.OTC,
        callData: encodeFunctionData({
          abi: abi.OTC,
          functionName: 'swap',
          args: [tokenIn, TOKENS[route.path[1]], amountIn, minOut, D.EXECUTOR],
        }),
      },
    ]
  }

  return [
    approve,
    {
      target: spender,
      callData: encodeFunctionData({
        abi: abi.UNIV2_ROUTER,
        functionName: 'swapExactTokensForTokens',
        args: [amountIn, minOut, route.path.map((s) => TOKENS[s]) as Address[], D.EXECUTOR, deadline],
      }),
    },
  ]
}
