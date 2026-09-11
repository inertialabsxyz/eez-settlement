/// Proves this package's ABI encoding matches the contract's.
///
/// `script/DevnetPayload.s.sol` builds a settlement payload in Solidity against
/// the same struct definitions `Book` compiles against, which is why the shell
/// harness could trust its commitments without ever testing them. This package
/// re-implements that encoding in TypeScript and loses that guarantee, so it has
/// to be bought back: the fixture below is encoded both ways and the two hashes
/// must agree.
///
/// It is not a formality. `abi.encode` of a struct holding four dynamic arrays,
/// two of them arrays of structs, has offsets in it; a field widened from
/// `uint128` to `uint256` produces the same values and a different hash, and the
/// only symptom is `BadCommitment` on a reveal 60 seconds later with nothing to
/// inspect.
///
///     npm run parity
import { execFileSync } from 'node:child_process'
import { commitment, revealCalldata, score, type SettlementData } from './payload.js'
import type { Address, Hex } from 'viem'

const REPO = new URL('../..', import.meta.url).pathname

// Addresses and amounts are arbitrary but must be identical on both sides.
// Deliberately awkward: two interactions with different calldata lengths, so the
// dynamic offsets inside `calls` are actually exercised, and a three-token
// vector so `tokens` and `clearingPrices` are not the same length as `trades`.
const BOOK = '0x00000000000000000000000000000000000b0000' as Address
const SOLVER = '0x0000000000000000000000000000000000501e50' as Address
const SALT = '0x00000000000000000000000000000000000000000000000000000000000000AA' as Hex
const AUCTION_ID = 7n
const L2_CHAIN_ID = 6290n

const d: SettlementData = {
  tokens: [
    '0x1111111111111111111111111111111111111111',
    '0x2222222222222222222222222222222222222222',
    '0x3333333333333333333333333333333333333333',
  ],
  clearingPrices: [10n ** 18n, 2100n * 10n ** 18n, 60000n * 10n ** 18n],
  trades: [
    {
      account: '0x90F79bf6EB2c4f870365E785982E1f101E93b906',
      sellIdx: 0,
      buyIdx: 1,
      sellAmount: 2000n * 10n ** 18n,
      limit: 900n * 10n ** 15n,
      deadline: 1789208709,
      nonce: 3n,
    },
    {
      account: '0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65',
      sellIdx: 2,
      buyIdx: 0,
      sellAmount: 5n * 10n ** 17n,
      limit: 29000n * 10n ** 18n,
      deadline: 1789208709,
      nonce: 11n,
    },
  ],
  calls: [
    { target: '0x4444444444444444444444444444444444444444', callData: '0xdeadbeef' },
    {
      target: '0x5555555555555555555555555555555555555555',
      callData: ('0x' + 'ab'.repeat(100)) as Hex,
    },
  ],
}
const intentIds = [41n, 42n]
const signatures: Hex[] = [('0x' + '11'.repeat(65)) as Hex, ('0x' + '22'.repeat(65)) as Hex]

const env = {
  ...process.env,
  BOOK,
  SOLVER,
  AUCTION_ID: String(AUCTION_ID),
  SALT,
  L2_CHAIN_ID: String(L2_CHAIN_ID),
  TOKENS: d.tokens.join(','),
  PRICES: d.clearingPrices.join(','),
  TRADE_ACCOUNTS: d.trades.map((t) => t.account).join(','),
  TRADE_SELL_IDX: d.trades.map((t) => t.sellIdx).join(','),
  TRADE_BUY_IDX: d.trades.map((t) => t.buyIdx).join(','),
  TRADE_SELL_AMOUNTS: d.trades.map((t) => t.sellAmount).join(','),
  TRADE_LIMITS: d.trades.map((t) => t.limit).join(','),
  TRADE_DEADLINES: d.trades.map((t) => t.deadline).join(','),
  TRADE_NONCES: d.trades.map((t) => t.nonce).join(','),
  INTENT_IDS: intentIds.join(','),
  SIGS: signatures.join(','),
  CALL_TARGETS: d.calls.map((c) => c.target).join(','),
  CALL_DATAS: d.calls.map((c) => c.callData).join(','),
}

const raw = execFileSync(
  'forge',
  ['script', 'script/DevnetPayload.s.sol:DevnetPayload', '--sig', 'plan()', '--json'],
  { cwd: REPO, env, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] },
)

const line = raw
  .trim()
  .split('\n')
  .map((l) => {
    try {
      return JSON.parse(l)
    } catch {
      return null
    }
  })
  .filter((o) => o && o.returns)
  .pop()

if (!line) throw new Error('forge script produced no return values')

const solidity = {
  commitment: line.returns.commitment.value as Hex,
  score: BigInt(line.returns.score.value),
  reveal: line.returns.revealCalldata.value as Hex,
}

const ts = {
  commitment: commitment({ d, intentIds, salt: SALT, solver: SOLVER, auctionId: AUCTION_ID, book: BOOK, l2ChainId: L2_CHAIN_ID }),
  score: score(d),
  reveal: revealCalldata(AUCTION_ID, d, intentIds, SALT, signatures),
}

let failed = 0
function check(name: string, a: string | bigint, b: string | bigint) {
  const eq = String(a).toLowerCase() === String(b).toLowerCase()
  if (!eq) failed++
  console.log(`${eq ? '  PASS' : '  FAIL'}  ${name}`)
  if (!eq) {
    console.log(`        solidity: ${a}`)
    console.log(`        typescript: ${b}`)
  }
}

console.log('\nABI parity: TypeScript vs script/DevnetPayload.s.sol\n')
check('commitment', solidity.commitment, ts.commitment)
check('score', solidity.score, ts.score)
check('revealAndExecute calldata', solidity.reveal, ts.reveal)
console.log(`\n  reveal payload: ${(ts.reveal.length - 2) / 2} bytes`)

if (failed) {
  console.error(`\n${failed} check(s) failed -- do not build on this encoding\n`)
  process.exit(1)
}
console.log('\nEncodings agree.\n')
