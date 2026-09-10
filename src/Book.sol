// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {
    SettlementData,
    Trade,
    SignedIntent,
    SettlementEIP712
} from "./SettlementTypes.sol";
import {TokenRegistry} from "./TokenRegistry.sol";

interface IExecutor {
    function settle(SettlementData calldata d, bytes[] calldata signatures) external;
}

/// The L2 half: intents, a sealed-bid solver auction, and one dispatch to L1.
///
/// Nothing here holds funds, and nothing here can move them. Users keep custody
/// on L1 until a settlement pulls from them, and that pull is authorised by
/// their own signature — not by this contract. A bug in this file produces a bad
/// auction, not a bad transfer.
contract Book {
    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------

    IExecutor     public immutable executor;
    TokenRegistry public immutable registry;
    address       public immutable admin;

    /// The domain the user's signature is scoped to. Pinned to the **L1** chain
    /// and the `Executor` address, because that is where it is consumed. Computed
    /// through the shared library so it cannot drift from Executor's own.
    bytes32 public immutable domainSeparator;

    /// Token 0 is the numeraire and its price is pinned here. Without the pin,
    /// scaling an entire price vector leaves every derived buy amount unchanged —
    /// they are ratios — but multiplies the score.
    uint256 public constant PRICE_SCALE = 1e18;

    uint40 public constant COMMIT_WINDOW = 60;    // T_C - open
    uint40 public constant REVEAL_WINDOW = 60;    // one leader's turn
    uint40 public constant MAX_REVEAL_PHASE = 480; // 8 turns, then the auction dies

    /// A cancellation cannot take effect inside an auction that was already
    /// running when it was requested — otherwise a user front-runs a reveal and
    /// voids a route that has just been made public.
    ///
    /// COMMIT_WINDOW + MAX_REVEAL_PHASE is the longest an auction can live, so a
    /// delay of that length is the smallest one that is always safe.
    uint40 public constant CANCEL_DELAY = COMMIT_WINDOW + MAX_REVEAL_PHASE;

    uint16 public constant MAX_BIDS = 64;

    /// Which tokens may sit at index 0 and anchor a price vector. The only
    /// governance surface with teeth, and every invariant holds regardless of
    /// what is on it.
    mapping(address => bool) public isNumeraire;

    // ------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------

    uint8 constant LIVE = 1;
    uint8 constant FILLED = 2;
    uint8 constant CANCELLED = 3;

    /// 2 slots, exactly full.
    struct Intent {
        address account;
        uint24  sellTok;
        uint24  buyTok;
        uint40  deadline;
        uint8   state;
        uint128 sellAmount;
        uint128 limit;
    }

    /// 2 slots.
    struct Bid {
        bytes32 commitment;
        address solver;
        uint88  claimedScore;
        bool    out;
    }

    /// 3 slots.
    struct Auction {
        bytes32 leadCommitment;
        address leader;
        uint88  leadScore;
        bool    settled;
        uint40  commitDeadline;  // T_C
        uint40  revealDeadline;  // T_R
        uint16  leadIdx;
    }

    Intent[] public intents;
    mapping(uint256 => Auction) public auctions;
    mapping(uint256 => Bid[]) private _bids;
    uint256 public auctionCount;

    /// Paid for only by intents that are actually cancelled.
    mapping(uint256 => uint40) public cancelEffectiveAt;

    /// account => word => bitmap. Mirrors Executor's, so an intent that could
    /// never settle is rejected here rather than after crossing the chain.
    mapping(address => mapping(uint256 => uint256)) public nonceUsed;

    error NotAdmin();
    error NotOwner();
    error NotLive();
    error Expired();
    error NonceAlreadyUsed();
    error BadSignature();
    error UnknownToken();
    error AuctionMoved(uint256 liveId);
    error CommitPhaseClosed();
    error CommitPhaseOpen();
    error TooManyBids();
    error RevealWindowOpen();
    error CancelNotReady();
    error RevealWindowClosed();
    error AuctionDead();
    error AlreadySettled();
    error NoBids();
    error NotLeader();
    error BadCommitment();
    error LengthMismatch();
    error IntentMismatch(uint256 index);
    error LimitNotMet(uint256 index);
    error BadNumeraire();
    error NoNumeraireLeg(uint256 index);
    error ZeroPrice(uint256 index);
    error CancelPending(uint256 index);
    error ScoreOverclaimed(uint256 actual, uint256 claimed);

    event IntentSubmitted(uint256 indexed id, address indexed account, SignedIntent intent, bytes signature);
    event CancelRequested(uint256 indexed id, uint40 effectiveAt);
    event IntentCancelled(uint256 indexed id);
    event AuctionOpened(uint256 indexed auctionId, uint40 commitDeadline);
    event Committed(uint256 indexed auctionId, address indexed solver, uint88 claimedScore);
    event LeaderSkipped(uint256 indexed auctionId, address indexed solver);
    event Executed(uint256 indexed auctionId, address indexed solver, uint256 score, uint256 filled);

    constructor(IExecutor _executor, TokenRegistry _registry, uint256 l1ChainId) {
        executor = _executor;
        registry = _registry;
        admin = msg.sender;
        domainSeparator = SettlementEIP712.domainSeparator(l1ChainId, address(_executor));
    }

    function setNumeraire(address token, bool allowed) external {
        if (msg.sender != admin) revert NotAdmin();
        isNumeraire[token] = allowed;
    }

    // ------------------------------------------------------------------
    // Intents
    // ------------------------------------------------------------------

    /// @notice Record a signed intent. Two storage slots and no custody.
    ///
    /// The signature is verified here to fail fast, then **emitted and
    /// discarded**. Storing 65 bytes would cost three more slots per intent and
    /// erase the two-slot layout; solvers read it from the event and carry it in
    /// the reveal payload. The authoritative check is Executor's, on L1.
    function submitIntent(SignedIntent calldata intent, bytes calldata signature)
        external
        returns (uint256 id)
    {
        if (intent.account != msg.sender) revert NotOwner();
        if (block.timestamp > intent.deadline) revert Expired();
        if (intent.sellAmount > type(uint128).max || intent.limit > type(uint128).max) {
            revert IntentMismatch(0);
        }
        if (intent.deadline > type(uint40).max) revert Expired();

        bytes32 digest = SettlementEIP712.digest(domainSeparator, intent);
        if (ECDSA.recover(digest, signature) != intent.account) revert BadSignature();

        // Mirrors Executor's bitmap. A reused nonce would produce an intent that
        // can never settle, and a solver who batched it would lose the whole
        // settlement on L1 — harming the other traders in it, not just the user.
        uint256 word = intent.nonce >> 8;
        uint256 bit = 1 << (intent.nonce & 0xff);
        uint256 bits = nonceUsed[msg.sender][word];
        if (bits & bit != 0) revert NonceAlreadyUsed();
        nonceUsed[msg.sender][word] = bits | bit;

        id = intents.length;
        intents.push(
            Intent({
                account:    msg.sender,
                sellTok:    _idOf(intent.sellToken),
                buyTok:     _idOf(intent.buyToken),
                deadline:   uint40(intent.deadline),
                state:      LIVE,
                sellAmount: uint128(intent.sellAmount),
                limit:      uint128(intent.limit)
            })
        );

        emit IntentSubmitted(id, msg.sender, intent, signature);
    }

    /// @notice Ask to cancel. Effective after `CANCEL_DELAY`, not immediately.
    ///
    /// An immediate cancel would let a user watch a reveal land in the mempool,
    /// cancel, and void a route that had just been made public — destroying the
    /// solver's work for the price of gas, which a rival solver could do at
    /// profit. The delay is the smallest one that no running auction can outlive.
    function requestCancel(uint256 id) external {
        Intent storage n = intents[id];
        if (n.account != msg.sender) revert NotOwner();
        if (n.state != LIVE) revert NotLive();

        uint40 effectiveAt = uint40(block.timestamp) + CANCEL_DELAY;
        cancelEffectiveAt[id] = effectiveAt;
        emit CancelRequested(id, effectiveAt);
    }

    /// Permissionless: anyone may finalise, since the effect is fixed at request.
    function finalizeCancel(uint256 id) external {
        uint40 effectiveAt = cancelEffectiveAt[id];
        if (effectiveAt == 0 || block.timestamp < effectiveAt) revert CancelNotReady();

        Intent storage n = intents[id];
        if (n.state != LIVE) revert NotLive();
        n.state = CANCELLED;
        emit IntentCancelled(id);
    }

    function intentCount() external view returns (uint256) {
        return intents.length;
    }

    function bidCount(uint256 auctionId) external view returns (uint256) {
        return _bids[auctionId].length;
    }

    function bidAt(uint256 auctionId, uint256 i) external view returns (Bid memory) {
        return _bids[auctionId][i];
    }

    function _idOf(address token) private view returns (uint24) {
        (uint24 id, bool found) = registry.idOf(token);
        if (!found) revert UnknownToken();
        return id;
    }

    // ------------------------------------------------------------------
    // Auction
    // ------------------------------------------------------------------

    /// The auction currently accepting commitments, opening one if none is.
    ///
    /// Sequential rather than solver-chosen: solvers need a canonical target to
    /// compete over, and an arbitrary id would fragment the competition into
    /// parallel auctions over the same intents.
    function liveAuction() public returns (uint256 id) {
        id = auctionCount;
        Auction storage a = auctions[id];

        if (a.commitDeadline == 0) {
            _open(a, id);
        } else if (block.timestamp >= a.commitDeadline) {
            unchecked { id = ++auctionCount; }
            _open(auctions[id], id);
        }
    }

    function _open(Auction storage a, uint256 id) private {
        uint40 tc = uint40(block.timestamp) + COMMIT_WINDOW;
        a.commitDeadline = tc;
        a.revealDeadline = tc + REVEAL_WINDOW;
        emit AuctionOpened(id, tc);
    }

    /// @notice Commit to a solution without revealing it.
    /// @param expectedAuctionId Reverts if the live auction has moved on, so a
    /// commitment bound to one auction is never lodged against another.
    /// @param commitment `keccak256(abi.encode(d, intentIds, salt, msg.sender,
    /// auctionId, address(this), block.chainid))`
    ///
    /// A solver's route is their alpha. An auction taking the full payload in
    /// calldata lets a competitor copy it, add a wei of surplus and win — which
    /// punishes doing the routing work at all. Only the leader ever reveals, and
    /// only after the leader is already decided.
    ///
    /// Overclaiming is self-defeating: the score is recomputed at reveal and an
    /// unbacked claim is rejected, having cost the claimant gas. That is what
    /// makes an unbonded auction safe.
    function commitBid(uint256 expectedAuctionId, bytes32 commitment, uint88 claimedScore) external {
        uint256 id = liveAuction();
        if (id != expectedAuctionId) revert AuctionMoved(id);

        Auction storage a = auctions[id];
        if (block.timestamp >= a.commitDeadline) revert CommitPhaseClosed();

        Bid[] storage bs = _bids[id];
        if (bs.length >= MAX_BIDS) revert TooManyBids();

        bs.push(Bid({commitment: commitment, solver: msg.sender, claimedScore: claimedScore, out: false}));

        // O(1). A linear scan here is a griefing vector: unbounded bids make the
        // scan — and therefore the honest reveal — exceed the block limit.
        // Strict `>` so ties go to the earlier commitment.
        if (a.leader == address(0) || claimedScore > a.leadScore) {
            a.leader = msg.sender;
            a.leadScore = claimedScore;
            a.leadCommitment = commitment;
            a.leadIdx = uint16(bs.length - 1);
        }

        emit Committed(id, msg.sender, claimedScore);
    }

    /// @notice Reveal the winning solution and settle it, atomically.
    ///
    /// Only callable after `T_C`, when the leader is already frozen. That is the
    /// whole point of the phase boundary: a solver never has to expose their
    /// route in order to discover whether they won.
    function revealAndExecute(
        uint256 auctionId,
        SettlementData calldata d,
        uint256[] calldata intentIds,
        bytes32 salt,
        bytes[] calldata signatures
    ) external {
        Auction storage a = auctions[auctionId];
        if (a.settled) revert AlreadySettled();
        if (a.leader == address(0)) revert NoBids();
        if (block.timestamp < a.commitDeadline) revert CommitPhaseOpen();
        if (block.timestamp >= a.revealDeadline) revert RevealWindowClosed();
        if (msg.sender != a.leader) revert NotLeader();

        bytes32 c = keccak256(
            abi.encode(d, intentIds, salt, msg.sender, auctionId, address(this), block.chainid)
        );
        if (c != a.leadCommitment) revert BadCommitment();

        uint256 score = _validateAndScore(d, intentIds);
        if (score < a.leadScore) revert ScoreOverclaimed(score, a.leadScore);

        a.settled = true;

        // One dispatch. Either the whole settlement lands on L1 or none of it
        // does, and in the latter case every write above unwinds with it.
        executor.settle(d, signatures);

        emit Executed(auctionId, msg.sender, score, intentIds.length);
    }

    /// @notice Drop a leader who won and went quiet, promoting the next best.
    ///
    /// Terminating, because the candidate set cannot grow after `T_C`: every skip
    /// strictly shrinks it, bounded by MAX_BIDS. In an auction that never closed
    /// bidding, the skipped solver would simply re-commit and stall again.
    function skipLeader(uint256 auctionId) external {
        Auction storage a = auctions[auctionId];
        if (a.settled) revert AlreadySettled();
        if (a.leader == address(0)) revert NoBids();
        if (block.timestamp < a.revealDeadline) revert RevealWindowOpen();

        uint40 hardStop = a.commitDeadline + MAX_REVEAL_PHASE;
        if (block.timestamp >= hardStop) revert AuctionDead();

        Bid[] storage bs = _bids[auctionId];
        bs[a.leadIdx].out = true;
        emit LeaderSkipped(auctionId, a.leader);

        // Bounded by MAX_BIDS, and only on the fallback path.
        address bestSolver;
        uint88 bestScore;
        uint16 bestIdx;
        bytes32 bestCommitment;
        for (uint256 i = 0; i < bs.length; i++) {
            if (bs[i].out) continue;
            if (bestSolver == address(0) || bs[i].claimedScore > bestScore) {
                bestSolver = bs[i].solver;
                bestScore = bs[i].claimedScore;
                bestIdx = uint16(i);
                bestCommitment = bs[i].commitment;
            }
        }

        a.leader = bestSolver;
        a.leadScore = bestScore;
        a.leadIdx = bestIdx;
        a.leadCommitment = bestCommitment;

        uint40 next = uint40(block.timestamp) + REVEAL_WINDOW;
        a.revealDeadline = next < hardStop ? next : hardStop;
    }

    // ------------------------------------------------------------------
    // Scoring
    // ------------------------------------------------------------------

    /// Every trade must correspond to a live intent on its own terms and be paid
    /// at least what that intent demanded. Score is total surplus delivered above
    /// those limits, valued in the settlement's numeraire.
    ///
    /// Not `view`: intents are marked FILLED inside the loop, so a repeated id
    /// fails its own liveness check on the second pass rather than selling the
    /// user twice.
    function _validateAndScore(SettlementData calldata d, uint256[] calldata intentIds)
        private
        returns (uint256 score)
    {
        uint256 n = d.trades.length;
        if (intentIds.length != n) revert LengthMismatch();
        if (d.clearingPrices.length != d.tokens.length) revert LengthMismatch();

        // The pin binds only if token 0 is a real token that real trades touch.
        if (!isNumeraire[d.tokens[0]] || d.clearingPrices[0] != PRICE_SCALE) revert BadNumeraire();
        for (uint256 i = 0; i < d.clearingPrices.length; i++) {
            if (d.clearingPrices[i] == 0) revert ZeroPrice(i);
        }

        for (uint256 i = 0; i < n; i++) {
            Trade calldata t = d.trades[i];
            uint256 id = intentIds[i];
            Intent storage nn = intents[id];

            if (nn.state != LIVE) revert NotLive();
            if (block.timestamp > nn.deadline) revert Expired();

            uint40 cancelAt = cancelEffectiveAt[id];
            if (cancelAt != 0 && block.timestamp >= cancelAt) revert CancelPending(i);

            // Every price must be anchored by a real fill against the numeraire,
            // or the whole vector can be quoted in larger units for a free score.
            if (t.sellIdx != 0 && t.buyIdx != 0) revert NoNumeraireLeg(i);

            if (
                nn.account != t.account || nn.sellAmount != t.sellAmount || nn.limit != t.limit
                    || nn.deadline != t.deadline
                    || registry.tokenAt(nn.sellTok) != d.tokens[t.sellIdx]
                    || registry.tokenAt(nn.buyTok) != d.tokens[t.buyIdx]
            ) revert IntentMismatch(i);

            nn.state = FILLED;

            // Surplus in numeraire units. Algebraically identical to
            // (buyAmount - limit) * p[buy] / SCALE, with one multiply fewer and
            // no intermediate rounding. Monotone decreasing in the free price,
            // which is what makes inflating it self-defeating.
            uint256 gave = uint256(t.sellAmount) * d.clearingPrices[t.sellIdx];
            uint256 want = uint256(t.limit) * d.clearingPrices[t.buyIdx];
            if (gave < want) revert LimitNotMet(i);
            score += (gave - want) / PRICE_SCALE;
        }
    }
}
