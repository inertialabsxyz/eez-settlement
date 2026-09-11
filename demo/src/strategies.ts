/// The solver field.
///
/// Five solvers with the same code and different search budgets, so that when
/// one wins the reason is legible on screen rather than buried in a number. They
/// differ only in what they are willing to look at and what they are willing to
/// claim -- the batch construction, pricing and commitment are identical.
import type { Strategy } from './batch.js'

export const STRATEGIES: Strategy[] = [
  {
    name: 'direct',
    hops: [],
    venues: ['A'],
    quoteAgeMs: 0,
    overclaimBps: 0,
    blurb: 'venue A only, no hops',
  },
  {
    name: 'venues',
    hops: [],
    venues: ['A', 'B', 'OTC'],
    quoteAgeMs: 0,
    overclaimBps: 0,
    blurb: 'all venues, still no hops',
  },
  {
    name: 'router',
    hops: ['DAI', 'WBTC', 'WETH'],
    venues: ['A', 'B', 'OTC'],
    quoteAgeMs: 0,
    overclaimBps: 0,
    blurb: 'full path-finding',
  },
  {
    /// Identical to `router` but quoting from a snapshot up to 90s old. With
    /// static pools it ties every round; the noise trader is what makes it lose,
    /// which is the point of having both.
    name: 'stale',
    hops: ['DAI', 'WBTC', 'WETH'],
    venues: ['A', 'B', 'OTC'],
    quoteAgeMs: 90_000,
    overclaimBps: 0,
    blurb: 'full path-finding, 90s stale quotes',
  },
  {
    /// Claims more surplus than its own payload delivers. Wins the auction on
    /// the claim -- `commitBid` cannot check it, that is what sealing costs --
    /// and then dies at reveal on `ScoreOverclaimed`, having paid gas for
    /// nothing. §7.2: this is why the auction needs no bond, and it is the only
    /// thing that ever makes `skipLeader` run.
    name: 'greedy',
    hops: ['DAI', 'WBTC', 'WETH'],
    venues: ['A', 'B', 'OTC'],
    quoteAgeMs: 0,
    overclaimBps: 1500,
    blurb: 'over-claims by 15%, cannot back it',
  },
]
