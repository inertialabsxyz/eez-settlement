/// Configuration, resolved from the same files the shell harness uses.
///
/// `script/dev.env` is sourced rather than reimplemented: it resolves Kurtosis
/// ports by shelling out, and the enclave republishes them on every restart, so
/// a second copy of those lookups is a second thing to get stale.
import { execFileSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { mnemonicToAccount } from 'viem/accounts'
import type { Address } from 'viem'

const REPO = new URL('../..', import.meta.url).pathname

function sourced(): Record<string, string> {
  const out = execFileSync('bash', ['-c', 'set -a; source script/dev.env; set +a; env'], {
    cwd: REPO,
    encoding: 'utf8',
  })
  const env: Record<string, string> = {}
  for (const line of out.split('\n')) {
    const i = line.indexOf('=')
    if (i > 0) env[line.slice(0, i)] = line.slice(i + 1)
  }
  return env
}

function deployments(): Record<string, Address> {
  const raw = readFileSync(`${REPO}/script/deployments.env`, 'utf8')
  const out: Record<string, Address> = {}
  for (const line of raw.split('\n')) {
    if (line.startsWith('#') || !line.includes('=')) continue
    const [k, v] = line.split('=')
    out[k] = v.trim().toLowerCase() as Address
  }
  return out
}

const env = sourced()
export const D = deployments()

export const cfg = {
  l1Rpc: env.L1_RPC,
  l2Rpc: env.L2_RPC,
  /// Outbound L2->L1 raw transactions only. A reveal sent to `l2Rpc` lands in an
  /// ordinary live block, where the L1 proxy rejects it.
  l2Front: env.L2_FRONT,
  l1ChainId: Number(env.L1_CHAIN_ID),
  l2ChainId: Number(env.L2_CHAIN_ID),
  deployerKey: env.DEPLOYER_KEY as `0x${string}`,
}

/// The L2 genesis funds the standard test mnemonic at indices 0-19 with
/// 1,000,000 ETH each. Indices 0 and 1 are the poster and proof-signer keys and
/// must be left alone -- the node manages their nonces. 2 is the deployer and
/// 3-5 belong to script/e2e.sh, which leaves 6-19.
const MNEMONIC = 'test test test test test test test test test test test junk'

export function account(index: number) {
  return mnemonicToAccount(MNEMONIC, { addressIndex: index })
}

export const USER_INDICES = [6, 7, 8, 9, 10, 11, 12, 13]
export const SOLVER_INDICES = [14, 15, 16, 17, 18]
export const NOISE_INDEX = 19

export const TOKENS = {
  USDC: D.USDC,
  WETH: D.WETH,
  DAI: D.DAI,
  WBTC: D.WBTC,
} as const

export type Sym = keyof typeof TOKENS

export function symbolOf(addr: Address): Sym {
  const a = addr.toLowerCase()
  for (const [s, t] of Object.entries(TOKENS)) if (t.toLowerCase() === a) return s as Sym
  throw new Error(`unknown token ${addr}`)
}

/// USDC is the numeraire: I7 requires it on one leg of every trade, so the
/// intent space is a star around it and DAI->WETH is not expressible. The other
/// three are routing hops.
export const NUMERAIRE: Sym = 'USDC'
export const DECIMALS = 18n
export const ONE = 10n ** DECIMALS
