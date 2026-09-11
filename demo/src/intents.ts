/// Reading and writing intents.
///
/// Reading is from `IntentSubmitted` events, not storage, and that is forced:
/// `Book` verifies a signature at submission and then **discards** it, because
/// storing 65 bytes would cost three more slots per intent and break the
/// two-slot layout in §5.1. The event is the only place the signature survives,
/// and L1 cannot settle without it. A solver that cannot read events cannot
/// solve.
import { parseAbiItem, type Address, type Hex } from 'viem'
import { l1, l2, wallet } from './chain.js'
import * as abi from './abi.js'
import { cfg, D, TOKENS, symbolOf, type Sym } from './config.js'
import type { LiveIntent } from './batch.js'

const LIVE = 1

const INTENT_SUBMITTED = parseAbiItem(
  'event IntentSubmitted(uint256 indexed id, address indexed account, (address account, address sellToken, address buyToken, uint256 sellAmount, uint256 limit, uint256 deadline, uint256 nonce) intent, bytes signature)',
)

const TYPES = {
  Intent: [
    { name: 'account', type: 'address' },
    { name: 'sellToken', type: 'address' },
    { name: 'buyToken', type: 'address' },
    { name: 'sellAmount', type: 'uint256' },
    { name: 'limit', type: 'uint256' },
    { name: 'deadline', type: 'uint256' },
    { name: 'nonce', type: 'uint256' },
  ],
} as const

let domainCache: { name: string; version: string; chainId: number; verifyingContract: Address } | null = null

/// The domain is assembled from fields because that is all a wallet can do, but
/// both chain-dependent fields come off-chain-of-record: `verifyingContract` is
/// read from `book.l1Executor()`, not from the deployment file. `Book` then
/// verifies the result against its own `domainSeparator()` and `Executor`
/// verifies it again on L1 (I9), so a domain assembled wrongly here fails at the
/// first of those two rather than quietly.
export async function domain() {
  if (!domainCache) {
    const verifyingContract = (await l2.readContract({ address: D.BOOK, abi: abi.BOOK, functionName: 'l1Executor' })) as Address
    domainCache = { name: 'EEZ Settlement', version: '1', chainId: cfg.l1ChainId, verifyingContract }
  }
  return domainCache
}

export type IntentTerms = {
  account: Address
  sellToken: Address
  buyToken: Address
  sellAmount: bigint
  limit: bigint
  deadline: bigint
  nonce: bigint
}

export async function signIntent(account: any, terms: IntentTerms): Promise<Hex> {
  return account.signTypedData({ domain: await domain(), types: TYPES, primaryType: 'Intent', message: terms })
}

/// `submitIntent` requires `intent.account == msg.sender`, so a user submits
/// their own. Pure L2 -- it emits no cross-chain call -- so it goes to the
/// ordinary RPC.
export async function submitIntent(account: any, terms: IntentTerms, signature: Hex): Promise<Hex> {
  return wallet(account, 'l2').writeContract({
    address: D.BOOK,
    abi: abi.BOOK,
    functionName: 'submitIntent',
    args: [terms, signature],
    chain: null,
    account,
  })
}

/// Every intent still available to a solver: LIVE, unexpired, and with no
/// cancellation due before the auction could end.
///
/// The cancellation filter is not optional. §6: a solver reads
/// `cancelEffectiveAt` when building a batch and includes only intents whose
/// cancellation cannot land before their auction ends, because a reveal covering
/// one reverts `CancelPending` and loses the whole settlement.
export async function liveIntents(horizon: number): Promise<LiveIntent[]> {
  const logs = await l2.getLogs({ address: D.BOOK, event: INTENT_SUBMITTED, fromBlock: 0n, toBlock: 'latest' })
  const now = Number((await l2.getBlock({ blockTag: 'latest' })).timestamp)

  const out: LiveIntent[] = []
  for (const log of logs) {
    const { id, intent, signature } = log.args as any
    const [, , , , state] = (await l2.readContract({ address: D.BOOK, abi: abi.BOOK, functionName: 'intents', args: [id] })) as any[]
    if (Number(state) !== LIVE) continue
    if (Number(intent.deadline) <= now + horizon) continue

    const cancelAt = Number(await l2.readContract({ address: D.BOOK, abi: abi.BOOK, functionName: 'cancelEffectiveAt', args: [id] }))
    if (cancelAt !== 0 && cancelAt <= now + horizon) continue

    out.push({
      id,
      account: intent.account,
      sell: symbolOf(intent.sellToken),
      buy: symbolOf(intent.buyToken),
      sellAmount: intent.sellAmount,
      limit: intent.limit,
      deadline: intent.deadline,
      nonce: intent.nonce,
      signature,
    })
  }
  return out
}

/// L1 is authoritative on nonces (I10); Book's bitmap is a courtesy mirror. A
/// user picks the next nonce their own L1 bitmap has not spent.
export async function nextNonce(who: Address): Promise<bigint> {
  for (let n = 0n; n < 256n; n++) {
    const word = (await l2.readContract({ address: D.BOOK, abi: abi.BOOK, functionName: 'nonceUsed', args: [who, 0n] })) as bigint
    if ((word >> n) % 2n === 0n) return n
  }
  throw new Error('nonce word exhausted')
}
