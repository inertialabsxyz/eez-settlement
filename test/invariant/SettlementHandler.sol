// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Book} from "../../src/Book.sol";
import {Executor} from "../../src/Executor.sol";
import {SettlementData, Trade, Interaction, SignedIntent, SettlementEIP712} from "../../src/SettlementTypes.sol";

/// The actor the stateful invariant runner drives.
///
/// It submits intents, commits bids against them, warps, reveals, skips stalled
/// leaders and cancels — in whatever order the fuzzer picks — and records what
/// it observed in ghost state for `Settlement.t.sol` to assert on.
///
/// **Nothing here asserts.** `fail_on_revert` is false for this suite, because
/// most orderings the fuzzer picks are legitimately no-ops, and a reverting
/// assertion inside a handler call would be swallowed along with them. Every
/// finding is recorded as a flag or a ghost mapping and checked from an
/// `invariant_` function, which always runs.
contract SettlementHandler is CommonBase, StdUtils {
    Book public immutable book;
    Executor public immutable executor;
    IERC20 public immutable usdc;
    IERC20 public immutable weth;

    bytes32 internal constant SALT = bytes32(uint256(0xA11));

    /// The batch is priced at the fixture's vector: USDC is the numeraire at
    /// index 0 pinned to PRICE_SCALE (I6), WETH at 2,000.
    uint256 internal constant P_USDC = 1e18;
    uint256 internal constant P_WETH = 2000e18;

    uint256 internal constant SELL_USDC = 2000 ether;
    uint256 internal constant LIMIT_WETH = 0.9 ether;
    uint256 internal constant SELL_WETH = 1 ether;
    uint256 internal constant LIMIT_USDC = 1900 ether;

    /// A solver that bids and never reveals, so `skipLeader` has something to
    /// promote past. Its commitment is junk; it could not reveal if it wanted to.
    address public constant STALLER = address(0xDEAD5701);

    // ------------------------------------------------------------------
    // Actors
    // ------------------------------------------------------------------

    /// Buyers sell the numeraire, sellers buy it — a fixed split, so that a
    /// batch never contains one account on both sides and a per-trade balance
    /// delta is unambiguous.
    address[4] public buyers;
    address[4] public sellers;
    mapping(address => uint256) public pkOf;

    /// At most one live intent per account at a time. Two intents from one
    /// account in one batch would make the balance check below ambiguous in the
    /// same way, and it is the check that catches an unpaid user.
    mapping(address => bool) public hasPending;
    mapping(address => uint64) public nextNonce;

    // ------------------------------------------------------------------
    // Intents and the batch under construction
    // ------------------------------------------------------------------

    mapping(uint256 => Trade) internal _tradeOf;
    mapping(uint256 => bytes) internal _sigOf;

    uint256[] public pendingBuy;
    uint256[] public pendingSell;

    uint256[] public committedIds;
    uint256 public committedAuction;
    bool public haveCommit;

    // ------------------------------------------------------------------
    // Ghost state — read by the invariants
    // ------------------------------------------------------------------

    /// Intent ids this handler watched get paid, in the settlement that filled
    /// them. `Book` marking an intent FILLED without an entry here is I16
    /// failing: a trade `_pay` skipped.
    mapping(uint256 => bool) public wasPaid;

    /// (account, nonce) pairs a settlement has consumed. A second consumption
    /// would be I10 failing on L1.
    mapping(address => mapping(uint64 => bool)) public nonceSettled;

    address[] public settledAccounts;
    uint64[] public settledNonces;
    uint256[] public settledIds;

    bool public nonceReuse;
    bool public paymentMismatch;
    bool public replayBlockedByTheWrongCheck;
    uint256 public replaysAttempted;

    uint256 public settledBatches;
    uint256 public settledTrades;
    uint256 public skips;
    uint256 public cancels;

    constructor(Book _book, Executor _executor, IERC20 _usdc, IERC20 _weth, address[4] memory b, address[4] memory s) {
        book = _book;
        executor = _executor;
        usdc = _usdc;
        weth = _weth;
        buyers = b;
        sellers = s;
    }

    function registerKey(address who, uint256 pk) external {
        pkOf[who] = pk;
    }

    function settledCount() external view returns (uint256) {
        return settledAccounts.length;
    }

    // ------------------------------------------------------------------
    // Actions
    // ------------------------------------------------------------------

    /// An intent selling the numeraire for WETH.
    function submitBuyIntent(uint256 seed) external {
        address who = buyers[bound(seed, 0, 3)];
        if (hasPending[who]) return;
        _submit(_open(who, address(usdc), address(weth), SELL_USDC, LIMIT_WETH), 0, 1, pendingBuy);
    }

    /// An intent selling WETH for the numeraire.
    function submitSellIntent(uint256 seed) external {
        address who = sellers[bound(seed, 0, 3)];
        if (hasPending[who]) return;
        _submit(_open(who, address(weth), address(usdc), SELL_WETH, LIMIT_USDC), 1, 0, pendingSell);
    }

    function _open(address who, address sell, address buy, uint256 sellAmount, uint256 limit)
        private
        returns (SignedIntent memory)
    {
        return SignedIntent(who, sell, buy, sellAmount, limit, block.timestamp + 365 days, nextNonce[who]++);
    }

    function _submit(SignedIntent memory si, uint8 sellIdx, uint8 buyIdx, uint256[] storage queue) private {
        bytes memory sig;
        {
            (uint8 v, bytes32 r, bytes32 s) =
                vm.sign(pkOf[si.account], SettlementEIP712.digest(book.domainSeparator(), si));
            sig = abi.encodePacked(r, s, v);
        }

        vm.prank(si.account);
        uint256 id = book.submitIntent(si, sig);

        _tradeOf[id] = Trade(
            si.account,
            sellIdx,
            buyIdx,
            uint128(si.sellAmount),
            uint128(si.limit),
            uint40(si.deadline),
            uint64(si.nonce)
        );
        _sigOf[id] = sig;
        queue.push(id);
        hasPending[si.account] = true;
    }

    /// Pair pending intents into a self-balancing batch and commit to it (§7.1).
    ///
    /// Every pair pulls 2,000 USDC and 1 WETH and pays back exactly the same, so
    /// the settlement needs no solver capital and `Executor` exits at zero — the
    /// steady state I11 describes.
    function commitBatch(uint256 seed, bool withStaller) external {
        if (haveCommit) return;
        uint256 avail = pendingBuy.length < pendingSell.length ? pendingBuy.length : pendingSell.length;
        if (avail == 0) return;

        uint256 k = bound(seed, 1, avail > 4 ? 4 : avail);

        delete committedIds;
        for (uint256 i = 0; i < k; i++) {
            committedIds.push(pendingBuy[pendingBuy.length - 1]);
            pendingBuy.pop();
            committedIds.push(pendingSell[pendingSell.length - 1]);
            pendingSell.pop();
        }

        uint256 aid = book.liveAuction();
        (SettlementData memory d,) = _payload(committedIds);
        book.commitBid(aid, _commitment(d, committedIds, aid), 0);

        // A rival who wins the commit phase and then goes quiet. The candidate
        // set cannot grow after T_C (I15), so the only way past them is a skip.
        if (withStaller) {
            vm.prank(STALLER);
            book.commitBid(aid, keccak256(abi.encode(aid, "stall")), 1);
        }

        committedAuction = aid;
        haveCommit = true;
    }

    function warp(uint256 seed) external {
        vm.warp(block.timestamp + bound(seed, 1, 200));
    }

    /// Reveal the committed batch, and check the payment it produced.
    ///
    /// The balance snapshot either side of the call is what makes
    /// `invariant_NoIntentIsFilledWithoutBeingPaid` meaningful: an intent only
    /// enters `wasPaid` if its account's buy-token balance actually moved by the
    /// amount the shared price vector derives (I5).
    function reveal() external {
        if (!haveCommit) return;
        (, address leader,, bool settled, uint40 tc, uint40 tr,) = book.auctions(committedAuction);
        if (settled || _dead(tc)) {
            haveCommit = false;
            return;
        }
        if (leader != address(this)) return;

        // A solver waits out the commit phase and then reveals; they do not
        // pick a random moment to try it in. Book.t.sol owns the phase boundary
        // itself (I14) — what this suite is for is the orderings around it, and
        // a reveal that mostly lands outside the 60-second window exercises
        // none of them.
        if (block.timestamp < tc) vm.warp(tc);
        if (block.timestamp >= tr) return;

        uint256[] memory ids = committedIds;
        (SettlementData memory d, bytes[] memory sigs) = _payload(ids);

        uint256 n = d.trades.length;
        uint256[] memory before = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            before[i] = IERC20(d.tokens[d.trades[i].buyIdx]).balanceOf(d.trades[i].account);
        }

        try book.revealAndExecute(committedAuction, d, ids, SALT, sigs) {
            for (uint256 i = 0; i < n; i++) {
                Trade memory t = d.trades[i];
                uint256 got = IERC20(d.tokens[t.buyIdx]).balanceOf(t.account) - before[i];
                if (got != _expectedBuy(t)) paymentMismatch = true;

                if (nonceSettled[t.account][t.nonce]) nonceReuse = true;
                nonceSettled[t.account][t.nonce] = true;
                settledAccounts.push(t.account);
                settledNonces.push(t.nonce);
                settledIds.push(ids[i]);

                wasPaid[ids[i]] = true;
                hasPending[t.account] = false;
            }
            settledBatches++;
            settledTrades += n;
        } catch {
            // A cancel that came due, an expiry, a price that no longer clears.
            // Release the accounts rather than wedging the handler on it.
            for (uint256 i = 0; i < n; i++) {
                hasPending[d.trades[i].account] = false;
            }
        }
        haveCommit = false;
    }

    /// Drop a leader who won and went quiet (§6). Terminating, because the
    /// candidate set is frozen at T_C.
    function skipLeader() external {
        if (!haveCommit) return;
        (, address leader,, bool settled, uint40 tc, uint40 tr,) = book.auctions(committedAuction);
        if (settled || leader == address(0)) return;
        if (_dead(tc)) {
            haveCommit = false;
            return;
        }
        // Likewise: a rival waits out the stalled leader's turn rather than
        // guessing at when it ended.
        if (block.timestamp < tr) vm.warp(tr);
        if (_dead(tc)) {
            haveCommit = false;
            return;
        }

        book.skipLeader(committedAuction);
        skips++;
    }

    /// Cancellation only touches intents no batch has committed to. A cancel
    /// landing inside the committed batch is `CancelPending` at reveal, which is
    /// §6's rule rather than anything this handler needs to discover.
    function requestCancel(uint256 seed) external {
        uint256 id = _pickPending(seed);
        if (id == type(uint256).max) return;
        (address account,,,,,,) = book.intents(id);
        vm.prank(account);
        book.requestCancel(id);
    }

    function finalizeCancel(uint256 seed) external {
        uint256 id = _pickPending(seed);
        if (id == type(uint256).max) return;
        if (book.cancelEffectiveAt(id) == 0) return;

        (address account,,,, uint8 state,,) = book.intents(id);
        if (state != 1) return;
        if (block.timestamp < book.cancelEffectiveAt(id)) return;

        book.finalizeCancel(id);
        _drop(id);
        hasPending[account] = false;
        cancels++;
    }

    /// Replay an already-settled trade verbatim, straight at L1 as the L2
    /// proxy — the payload a fully compromised `Book` would send (§4).
    ///
    /// I10: the nonce bitmap must reject it, and must reject it *first*. A
    /// replay that dies later on solvency would look the same from outside and
    /// prove nothing, so the revert selector is checked, not just the failure.
    function replaySettledNonce(uint256 seed) external {
        uint256 count = settledIds.length;
        if (count == 0) return;
        uint256 id = settledIds[bound(seed, 0, count - 1)];

        uint256[] memory one = new uint256[](1);
        one[0] = id;
        (SettlementData memory d, bytes[] memory sigs) = _payload(one);

        replaysAttempted++;
        vm.prank(executor.expectedProxy());
        try executor.settle(d, sigs) {
            // The pull went through a second time on the user's one signature.
            nonceReuse = true;
        } catch (bytes memory err) {
            bytes4 sel;
            assembly {
                sel := mload(add(err, 0x20))
            }
            if (sel != Executor.NonceUsed.selector) replayBlockedByTheWrongCheck = true;
        }
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    function _dead(uint40 tc) private view returns (bool) {
        return block.timestamp >= uint256(tc) + book.MAX_REVEAL_PHASE();
    }

    function _pickPending(uint256 seed) private view returns (uint256) {
        uint256 total = pendingBuy.length + pendingSell.length;
        if (total == 0) return type(uint256).max;
        uint256 i = bound(seed, 0, total - 1);
        return i < pendingBuy.length ? pendingBuy[i] : pendingSell[i - pendingBuy.length];
    }

    function _drop(uint256 id) private {
        for (uint256 i = 0; i < pendingBuy.length; i++) {
            if (pendingBuy[i] == id) {
                pendingBuy[i] = pendingBuy[pendingBuy.length - 1];
                pendingBuy.pop();
                return;
            }
        }
        for (uint256 i = 0; i < pendingSell.length; i++) {
            if (pendingSell[i] == id) {
                pendingSell[i] = pendingSell[pendingSell.length - 1];
                pendingSell.pop();
                return;
            }
        }
    }

    function _expectedBuy(Trade memory t) private pure returns (uint256) {
        uint256[2] memory p = [P_USDC, P_WETH];
        return (uint256(t.sellAmount) * p[t.sellIdx]) / p[t.buyIdx];
    }

    /// Rebuilt from the per-intent record rather than stored, so the payload the
    /// reveal presents is byte-identical to the one the commitment covered.
    function _payload(uint256[] memory ids) private view returns (SettlementData memory d, bytes[] memory sigs) {
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(weth);

        uint256[] memory prices = new uint256[](2);
        prices[0] = P_USDC;
        prices[1] = P_WETH;

        Trade[] memory trades = new Trade[](ids.length);
        sigs = new bytes[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            trades[i] = _tradeOf[ids[i]];
            sigs[i] = _sigOf[ids[i]];
        }

        d = SettlementData(tokens, prices, trades, new Interaction[](0));
    }

    function _commitment(SettlementData memory d, uint256[] memory ids, uint256 aid) private view returns (bytes32) {
        return keccak256(abi.encode(d, ids, SALT, address(this), aid, address(book), block.chainid));
    }
}
