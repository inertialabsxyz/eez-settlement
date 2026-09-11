import { keccak256, encodeAbiParameters, encodeFunctionData, type Address, type Hex } from 'viem'

export type Trade = {
  account: Address
  sellIdx: number
  buyIdx: number
  sellAmount: bigint
  limit: bigint
  deadline: number
  nonce: bigint
}

export type Interaction = { target: Address; callData: Hex }

export type SettlementData = {
  tokens: Address[]
  clearingPrices: bigint[]
  trades: Trade[]
  calls: Interaction[]
}

/// The ABI shape of `SettlementData` from src/SettlementTypes.sol.
///
/// Field order and widths are load-bearing, not cosmetic: `Book` binds a
/// commitment to `abi.encode` of this struct, so a `uint128` written here as
/// `uint256` changes nothing about the value and everything about the hash. The
/// only symptom is `BadCommitment` on the reveal, with nothing to inspect --
/// which is why src/parity.ts exists and runs before anything uses this.
const TRADE = {
  type: 'tuple',
  components: [
    { name: 'account', type: 'address' },
    { name: 'sellIdx', type: 'uint8' },
    { name: 'buyIdx', type: 'uint8' },
    { name: 'sellAmount', type: 'uint128' },
    { name: 'limit', type: 'uint128' },
    { name: 'deadline', type: 'uint40' },
    { name: 'nonce', type: 'uint64' },
  ],
} as const

const INTERACTION = {
  type: 'tuple',
  components: [
    { name: 'target', type: 'address' },
    { name: 'callData', type: 'bytes' },
  ],
} as const

export const SETTLEMENT_DATA = {
  type: 'tuple',
  components: [
    { name: 'tokens', type: 'address[]' },
    { name: 'clearingPrices', type: 'uint256[]' },
    { name: 'trades', type: 'tuple[]', components: TRADE.components },
    { name: 'calls', type: 'tuple[]', components: INTERACTION.components },
  ],
} as const

export type Commitment = {
  d: SettlementData
  intentIds: bigint[]
  salt: Hex
  solver: Address
  auctionId: bigint
  book: Address
  l2ChainId: bigint
}

/// `keccak256(abi.encode(d, intentIds, salt, msg.sender, auctionId,
/// address(this), block.chainid))` -- Book.commitBid's documented preimage,
/// reproduced argument for argument and in order.
export function commitment(c: Commitment): Hex {
  return keccak256(
    encodeAbiParameters(
      [
        SETTLEMENT_DATA,
        { type: 'uint256[]' },
        { type: 'bytes32' },
        { type: 'address' },
        { type: 'uint256' },
        { type: 'address' },
        { type: 'uint256' },
      ],
      [c.d, c.intentIds, c.salt, c.solver, c.auctionId, c.book, c.l2ChainId],
    ),
  )
}

const REVEAL_ABI = [
  {
    name: 'revealAndExecute',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'auctionId', type: 'uint256' },
      { name: 'd', type: 'tuple', components: SETTLEMENT_DATA.components },
      { name: 'intentIds', type: 'uint256[]' },
      { name: 'salt', type: 'bytes32' },
      { name: 'signatures', type: 'bytes[]' },
    ],
    outputs: [],
  },
] as const

export function revealCalldata(
  auctionId: bigint,
  d: SettlementData,
  intentIds: bigint[],
  salt: Hex,
  signatures: Hex[],
): Hex {
  return encodeFunctionData({
    abi: REVEAL_ABI,
    functionName: 'revealAndExecute',
    args: [auctionId, d, intentIds, salt, signatures],
  })
}

/// Total surplus above the signed limits, in numeraire units.
///
/// Mirrors `Book._validateAndScore`'s accumulator exactly, including the
/// truncating division. A solver claims this verbatim rather than claiming low:
/// claiming low is always accepted and tests nothing, whereas claiming exactly
/// makes any divergence from the contract surface as `ScoreOverclaimed`.
export const PRICE_SCALE = 10n ** 18n

export function score(d: SettlementData): bigint {
  let total = 0n
  for (const t of d.trades) {
    const gave = t.sellAmount * d.clearingPrices[t.sellIdx]
    const want = t.limit * d.clearingPrices[t.buyIdx]
    if (gave < want) throw new Error('limit not met at the quoted prices')
    total += (gave - want) / PRICE_SCALE
  }
  return total
}
