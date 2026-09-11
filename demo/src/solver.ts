/// One solver. Watches intents, prices a batch, bids sealed, and if it wins,
/// reveals across the chain boundary.
import type { Address, Hex } from 'viem'
import { l2, sendToFront, frontNonce, l2Now, sleep, wallet } from './chain.js'
import * as abi from './abi.js'
import { D, cfg } from './config.js'
import { snapshot, type Market } from './venues.js'
import { liveIntents } from './intents.js'
import { buildBatch, type Strategy } from './batch.js'
import { commitment, revealCalldata } from './payload.js'
import { log, fmtScore } from './log.js'

const SALT_BASE = 0x5a17n

/// Intents must survive the auction: an intent that expires, or whose
/// cancellation lands, before the reveal takes the whole settlement down with
/// it. COMMIT_WINDOW + MAX_REVEAL_PHASE is the longest an auction can live.
const HORIZON = 600

type Auction = {
  leadCommitment: Hex
  leader: Address
  leadScore: bigint
  settled: boolean
  commitDeadline: number
  revealDeadline: number
  leadIdx: number
}

async function readAuction(id: bigint): Promise<Auction> {
  const a = (await l2.readContract({ address: D.BOOK, abi: abi.BOOK, functionName: 'auctions', args: [id] })) as any[]
  return {
    leadCommitment: a[0],
    leader: a[1],
    leadScore: a[2],
    settled: a[3],
    commitDeadline: Number(a[4]),
    revealDeadline: Number(a[5]),
    leadIdx: Number(a[6]),
  }
}

/// `liveAuction` is not a view -- it opens one when the previous closes -- so
/// the id is obtained by simulating the call rather than reading state.
async function currentAuction(): Promise<bigint> {
  const { result } = await l2.simulateContract({ address: D.BOOK, abi: abi.BOOK, functionName: 'liveAuction' })
  return result as bigint
}

export class Solver {
  private cached: Market | null = null
  private lastAuction = -1n
  wins = 0
  losses = 0
  failures = 0

  constructor(
    readonly strat: Strategy,
    readonly account: any,
  ) {}

  private async market(): Promise<Market> {
    if (this.cached && Date.now() - this.cached.at < this.strat.quoteAgeMs) return this.cached
    this.cached = await snapshot()
    return this.cached
  }

  async run(stop: () => boolean) {
    while (!stop()) {
      try {
        await this.round(stop)
      } catch (e: any) {
        log(this.strat.name, `\x1b[31merror\x1b[0m ${String(e.shortMessage ?? e.message ?? e).slice(0, 110)}`)
        await sleep(3000)
      }
    }
  }

  private async round(stop: () => boolean) {
    const id = await currentAuction()
    if (id === this.lastAuction) {
      await sleep(2000)
      return
    }

    const a = await readAuction(id)
    const now = await l2Now()
    const toClose = a.commitDeadline - now

    // Bid late enough to see the auction's whole intent set, early enough that
    // the commit still lands before T_C. Staggered per solver so the race is
    // visible rather than simultaneous.
    if (toClose > 22) {
      await sleep(2000)
      return
    }
    if (toClose <= 4) {
      this.lastAuction = id
      await sleep(2000)
      return
    }

    const intents = await liveIntents(HORIZON)
    if (intents.length === 0) {
      await sleep(2000)
      return
    }

    const market = await this.market()
    const deadline = BigInt(now + 3600)
    const batch = buildBatch(market, intents, this.strat, deadline)
    if (!batch) {
      this.lastAuction = id
      return
    }

    const salt = `0x${(SALT_BASE + id).toString(16).padStart(64, '0')}` as Hex
    const c = commitment({
      d: batch.d,
      intentIds: batch.intentIds,
      salt,
      solver: this.account.address,
      auctionId: id,
      book: D.BOOK,
      l2ChainId: BigInt(cfg.l2ChainId),
    })

    // `commitBid` is pure L2 -- it emits no cross-chain call -- so it goes to the
    // ordinary RPC. Only the reveal touches L1.
    await wallet(this.account, 'l2').writeContract({
      address: D.BOOK,
      abi: abi.BOOK,
      functionName: 'commitBid',
      args: [id, c, batch.claimed],
      chain: null,
      account: this.account,
    })
    this.lastAuction = id

    const tag = this.strat.overclaimBps > 0 ? ` \x1b[31m(claims ${fmtScore(batch.claimed)}, holds ${fmtScore(batch.score)})\x1b[0m` : ''
    log(this.strat.name, `bid on #${id}: ${batch.matched} intents, score ${fmtScore(batch.claimed)}${tag}  ${batch.routes.join(' | ')}`)

    await this.settle(id, batch, salt, stop)
  }

  /// Wait out the commit phase, then either reveal or watch.
  ///
  /// I14: the reveal window opens at T_C and not before -- `revealAndExecute`
  /// reverts `CommitPhaseOpen` until the leader is frozen. That freeze is the
  /// whole point of sealing: a solver never has to expose a route to find out
  /// whether it won.
  private async settle(id: bigint, batch: any, salt: Hex, stop: () => boolean) {
    for (;;) {
      if (stop()) return
      const a = await readAuction(id)
      const now = await l2Now()
      if (a.settled) return
      if (now < a.commitDeadline) {
        await sleep(2000)
        continue
      }

      const iLead = a.leader.toLowerCase() === this.account.address.toLowerCase()
      if (!iLead) {
        // Not the leader. Watch, and if the leader wins and goes quiet, promote
        // the next candidate -- permissionless, because the effect is fixed at
        // commit time.
        if (now >= a.revealDeadline) {
          try {
            await wallet(this.account, 'l2').writeContract({ address: D.BOOK, abi: abi.BOOK, functionName: 'skipLeader', args: [id], chain: null, account: this.account })
            log(this.strat.name, `\x1b[33mskipLeader(#${id})\x1b[0m -- leader went quiet, promoting the next bid`)
          } catch {
            /* another solver got there first, or the auction is dead */
          }
        }
        this.losses++
        await sleep(3000)
        if ((await readAuction(id)).settled) return
        continue
      }

      const data = revealCalldata(id, batch.d, batch.intentIds, salt, batch.signatures)
      const before = await frontNonce(this.account.address)
      log(this.strat.name, `\x1b[1mwon #${id}\x1b[0m -- revealing ${(data.length - 2) / 2}B across the chain boundary`)

      try {
        await sendToFront(this.account, D.BOOK, data)
      } catch (e: any) {
        log(this.strat.name, `\x1b[31mfront rejected the reveal\x1b[0m ${String(e.message).slice(0, 80)}`)
        this.failures++
        return
      }

      // Assert on the effect, never on the send. A cross-chain transaction here
      // can be accepted, return a hash, change L2 state and then unwind on both
      // chains; and the front's nonce advances ahead of L1 being readable.
      const deadline = Date.now() + 150_000
      for (;;) {
        await sleep(3000)
        const now2 = await readAuction(id)
        if (now2.settled) {
          this.wins++
          log('settle', `\x1b[32m#${id} settled by ${this.strat.name}\x1b[0m -- ${batch.matched} intents, score ${fmtScore(batch.score)}`)
          return
        }
        if (Date.now() > deadline) {
          this.failures++
          log(this.strat.name, `\x1b[31m#${id} never settled\x1b[0m -- reveal reverted on one of the two chains`)
          return
        }
      }
    }
  }
}
