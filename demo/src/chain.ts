/// Clients for both chains, and the one transaction path that is not an RPC call.
import { createPublicClient, createWalletClient, http, defineChain, type Address, type Hex } from 'viem'
import { cfg } from './config.js'

const l1Chain = defineChain({
  id: cfg.l1ChainId,
  name: 'eez-l1',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: [cfg.l1Rpc] } },
})

export const l2Chain = defineChain({
  id: cfg.l2ChainId,
  name: 'eez-l2',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: [cfg.l2Rpc] } },
})

export const l1 = createPublicClient({ chain: l1Chain, transport: http(cfg.l1Rpc) })
export const l2 = createPublicClient({ chain: l2Chain, transport: http(cfg.l2Rpc) })

export function wallet(account: any, which: 'l1' | 'l2') {
  return createWalletClient({
    account,
    chain: which === 'l1' ? l1Chain : l2Chain,
    transport: http(which === 'l1' ? cfg.l1Rpc : cfg.l2Rpc),
  })
}

async function rpc(url: string, method: string, params: unknown[]): Promise<any> {
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
  })
  const json = await res.json()
  if (json.error) throw new Error(`${method}: ${JSON.stringify(json.error)}`)
  return json.result
}

/// The cross-chain front keeps its own nonce reservations, invisible to
/// `eth_getTransactionCount` on the plain L2 RPC, and a cross-chain transaction
/// reserves TWO of them. Reading the nonce from the RPC yields a value the front
/// rejects as an underpriced replacement.
export async function frontNonce(who: Address): Promise<number> {
  return Number(await rpc(cfg.l2Front, 'eth_getTransactionCount', [who, 'pending']))
}

/// `cast gas-price` returns single-digit wei on this L2, and a tip of 1 wei
/// leaves an effective priority of zero once base fee is subtracted -- the front
/// accepts such a transaction and then quietly drops it. Bid far above the pool.
async function gasPrice(): Promise<{ maxFeePerGas: bigint; maxPriorityFeePerGas: bigint }> {
  const suggested = await l2.getGasPrice()
  const max = suggested * 4n > 10n ** 9n ? suggested * 4n : 10n ** 9n
  return { maxFeePerGas: max, maxPriorityFeePerGas: max / 10n }
}

/// Sign a transaction and post it to the outbound cross-chain front.
///
/// Gas cannot be estimated -- the L1 leg is unsimulatable from here -- so the
/// limit is explicit. This is the only path a settlement reveal may take; the
/// plain L2 RPC would land it in an ordinary live block where the L1 proxy
/// rejects it with `ExecutionNotInCurrentBlock`.
export async function sendToFront(
  account: any,
  to: Address,
  data: Hex,
  gas = 8_000_000n,
): Promise<Hex> {
  const nonce = await frontNonce(account.address)
  const fees = await gasPrice()
  const signed = await account.signTransaction({
    chainId: cfg.l2ChainId,
    to,
    data,
    nonce,
    gas,
    ...fees,
    type: 'eip1559',
  })
  return (await rpc(cfg.l2Front, 'eth_sendRawTransaction', [signed])) as Hex
}

export async function l2Now(): Promise<number> {
  return Number((await l2.getBlock({ blockTag: 'latest' })).timestamp)
}

export async function l1Now(): Promise<number> {
  return Number((await l1.getBlock({ blockTag: 'latest' })).timestamp)
}

export const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))
