/// Prints the current routing table. `npm run quotes`
///
/// Useful on its own during a demo: run it before and after the noise trader has
/// been going for a while and the best route will have moved.
import { snapshot } from './venues.js'
import { routes, routeLabel } from './router.js'
import { ONE, type Sym } from './config.js'

const fmt = (v: bigint) => (Number(v) / 1e18).toFixed(6)

const m = await snapshot()
console.log(`\npools    ${m.pools.map((p) => `${p.venue}:${p.a}/${p.b}`).join('  ')}`)
console.log(`otc      ${[...m.otcPrice.keys()].join('  ')}`)
console.log(`inventory ${[...m.otcInventory].map(([s, v]) => `${s} ${fmt(v)}`).join('  ')}\n`)

const HOPS: Sym[] = ['DAI', 'WBTC', 'WETH']

for (const [x, y] of [
  ['USDC', 'WETH'],
  ['USDC', 'DAI'],
  ['USDC', 'WBTC'],
] as [Sym, Sym][]) {
  console.log(`${x} -> ${y}`)
  for (const n of [500n, 2000n, 20000n, 200000n]) {
    const rs = routes(m, x, y, n * ONE, HOPS)
    const head = rs
      .slice(0, 3)
      .map((r, i) => `${i === 0 ? '\x1b[32m' : ''}${fmt(r.out).padStart(12)} ${routeLabel(r).padEnd(18)}\x1b[0m`)
      .join(' ')
    console.log(`  ${String(n).padStart(7)}  ${head || '  (no route)'}`)
  }
  console.log()
}
