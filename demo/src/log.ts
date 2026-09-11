/// A single shared, timestamped event stream, so an audience can read one column.
const C: Record<string, string> = {
  user: '\x1b[36m',
  noise: '\x1b[90m',
  auction: '\x1b[1m',
  settle: '\x1b[32m',
  fail: '\x1b[31m',
  direct: '\x1b[35m',
  venues: '\x1b[34m',
  router: '\x1b[32m',
  stale: '\x1b[33m',
  greedy: '\x1b[31m',
}
const R = '\x1b[0m'
const started = Date.now()

export function log(actor: string, msg: string) {
  const t = ((Date.now() - started) / 1000).toFixed(0).padStart(4)
  const c = C[actor] ?? ''
  console.log(`${t}s  ${c}${actor.padEnd(8)}${R}  ${msg}`)
}

export const fmt = (v: bigint, dp = 4) => (Number(v) / 1e18).toFixed(dp)
export const fmtScore = (v: bigint) => (Number(v) / 1e18).toFixed(2)
