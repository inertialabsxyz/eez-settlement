// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Book} from "../../src/Book.sol";
import {SettlementFixture} from "../helpers/SettlementFixture.sol";
import {SettlementHandler} from "./SettlementHandler.sol";

/// Phase 3 — the stateful invariant suite.
///
/// Every other test in this repository fixes an ordering and asserts on it.
/// This one does not: `SettlementHandler` submits, commits, warps, reveals,
/// skips stalled leaders, cancels and replays settled trades at L1 in whatever
/// sequence the fuzzer picks, and the four properties below must hold after
/// every call in it.
///
/// They are the ones only a sequence can break — I11's steady state between
/// settlements, I16's "no trade is skipped", I10 across both chains' bitmaps,
/// and the O(1) leader cache still agreeing with the bid array it summarises.
contract SettlementInvariantTest is SettlementFixture {
    SettlementHandler handler;

    address[4] internal buyers;
    address[4] internal sellers;
    uint256[8] internal pks;

    function setUp() public override {
        super.setUp();

        for (uint256 i = 0; i < 4; i++) {
            (address b, uint256 bpk) = makeAddrAndKey(string(abi.encodePacked("buyer", vm.toString(i))));
            (address s, uint256 spk) = makeAddrAndKey(string(abi.encodePacked("seller", vm.toString(i))));
            buyers[i] = b;
            sellers[i] = s;
            pks[i] = bpk;
            pks[i + 4] = spk;

            _fund(usdc, b, 1e9 ether);
            _fund(weth, s, 1e6 ether);
            _approveAll(b);
            _approveAll(s);
        }

        handler = new SettlementHandler(book, ex, IERC20(address(usdc)), IERC20(address(weth)), buyers, sellers);
        for (uint256 i = 0; i < 4; i++) {
            handler.registerKey(buyers[i], pks[i]);
            handler.registerKey(sellers[i], pks[i + 4]);
        }

        // Only the handler's actions. Without this the runner would also fuzz
        // the ghost-state getters, which is 128,000 wasted calls.
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = SettlementHandler.submitBuyIntent.selector;
        selectors[1] = SettlementHandler.submitSellIntent.selector;
        selectors[2] = SettlementHandler.commitBatch.selector;
        selectors[3] = SettlementHandler.warp.selector;
        selectors[4] = SettlementHandler.reveal.selector;
        selectors[5] = SettlementHandler.skipLeader.selector;
        selectors[6] = SettlementHandler.requestCancel.selector;
        selectors[7] = SettlementHandler.finalizeCancel.selector;
        selectors[8] = SettlementHandler.replaySettledNonce.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ------------------------------------------------------------------
    // I11 — the steady state
    // ------------------------------------------------------------------

    /// I11: `Executor` ends every settlement at exactly its opening balance, and
    /// its opening balance is zero. Between settlements it must therefore hold
    /// nothing — of any listed token, or of ETH.
    ///
    /// `Relayer` is checked alongside it: it holds approvals, never balances
    /// (§3.1), so a token resting there is the same defect at a different
    /// address.
    function invariant_ExecutorAndRelayerHoldNothing() public view {
        assertEq(usdc.balanceOf(address(ex)), 0, "I11: executor holds USDC between settlements");
        assertEq(weth.balanceOf(address(ex)), 0, "I11: executor holds WETH between settlements");
        assertEq(dai.balanceOf(address(ex)), 0, "I11: executor holds DAI between settlements");
        assertEq(address(ex).balance, 0, "I11: executor holds ETH");

        assertEq(usdc.balanceOf(address(rl)), 0, "I13: relayer holds USDC");
        assertEq(weth.balanceOf(address(rl)), 0, "I13: relayer holds WETH");
    }

    // ------------------------------------------------------------------
    // I16 — no trade is skipped
    // ------------------------------------------------------------------

    /// I16, as a property of the sequence rather than a runtime check: an intent
    /// `Book` has marked FILLED must have had its account's balance move, in the
    /// settlement that filled it, by exactly what the shared price vector
    /// derives (I5).
    ///
    /// This is the check §9.1 says the balance invariants cannot make. I11
    /// protects the *contract*: a user who was pulled from and never paid still
    /// leaves `Executor` at exactly its opening balance, because `_restore`
    /// sweeps their tokens off to `windfallRecipient` and the equality holds.
    /// Only the user's own balance shows it, which is why this invariant reads
    /// balances and not `Executor`.
    function invariant_NoIntentIsFilledWithoutBeingPaid() public view {
        uint256 n = book.intentCount();
        for (uint256 id = 0; id < n; id++) {
            (,,,, uint8 state,,) = book.intents(id);
            if (state != 2) continue; // FILLED
            assertTrue(handler.wasPaid(id), "I16: intent filled but its account was never paid");
        }
        assertFalse(handler.paymentMismatch(), "I5: a payment did not match the shared price vector");
    }

    // ------------------------------------------------------------------
    // I10 — no nonce consumed twice, on either chain
    // ------------------------------------------------------------------

    /// I10: every nonce a settlement consumed is set in `Executor`'s bitmap —
    /// the authoritative one — and in `Book`'s mirror, and none was consumed
    /// twice.
    ///
    /// The handler also replays settled trades straight at L1 as the L2 proxy:
    /// the payload a fully compromised `Book` would send (§4). Those must fail,
    /// and fail on the bitmap specifically — a replay that died later on
    /// solvency would look identical from outside and prove nothing.
    function invariant_NoNonceIsConsumedTwice() public view {
        assertFalse(handler.nonceReuse(), "I10: a nonce was consumed twice");
        assertFalse(
            handler.replayBlockedByTheWrongCheck(), "I10: a replay was stopped by something other than the bitmap"
        );

        uint256 n = handler.settledCount();
        for (uint256 i = 0; i < n; i++) {
            address account = handler.settledAccounts(i);
            uint64 nonce = handler.settledNonces(i);
            uint256 word = nonce >> 8;
            uint256 bit = 1 << (nonce & 0xff);

            assertTrue(ex.nonceBitmap(account, word) & bit != 0, "I10: L1 bitmap missing a consumed nonce");
            assertTrue(book.nonceUsed(account, word) & bit != 0, "I10: L2 mirror missing a consumed nonce");
        }
    }

    // ------------------------------------------------------------------
    // The leader cache
    // ------------------------------------------------------------------

    /// The O(1) leader cache exists so an unbounded bid array cannot brick an
    /// auction (§7.1). It is sound only if it never points at a bid `skipLeader`
    /// has already struck out — a leader marked `out` could reveal after being
    /// skipped, which is the whole failure the skip exists to prevent.
    function invariant_LeaderIsNeverAnOutBid() public view {
        uint256 last = book.auctionCount();
        for (uint256 aid = 0; aid <= last; aid++) {
            (bytes32 leadCommitment, address leader,,,,, uint16 leadIdx) = book.auctions(aid);
            if (leader == address(0)) continue;

            assertLt(leadIdx, book.bidCount(aid), "leader index outside the bid array");
            Book.Bid memory b = book.bidAt(aid, leadIdx);

            assertFalse(b.out, "auction leads with a bid that was skipped");
            assertEq(b.solver, leader, "leader cache disagrees with the bid it points at");
            assertEq(b.commitment, leadCommitment, "leader commitment disagrees with the bid it points at");
        }
    }

    // ------------------------------------------------------------------
    // Non-vacuity
    // ------------------------------------------------------------------

    /// Everything above is satisfied by a run that never settles, so the suite
    /// needs to show that settling is reachable at all — and that the
    /// invariants are evaluated against state where it happened.
    ///
    /// A per-run coverage assertion in `afterInvariant` cannot do that job: the
    /// fuzzer shrinks a failure to its minimum, replays `afterInvariant` against
    /// the shrunk sequence, and a one-call sequence settles nothing by
    /// construction. So the guarantee is made here, deterministically, and
    /// `afterInvariant` only reports.
    function testHandlerSettlesAndTheInvariantsHoldOverIt() public {
        handler.submitBuyIntent(0);
        handler.submitSellIntent(0);
        handler.submitBuyIntent(1);
        handler.submitSellIntent(1);

        // With a staller in the auction the handler is not the leader, so the
        // only route to a reveal is a skip — both paths in one sequence.
        handler.commitBatch(type(uint256).max, true);
        handler.reveal();
        assertEq(handler.settledBatches(), 0, "revealed while the staller still led");

        handler.skipLeader();
        handler.reveal();

        assertEq(handler.settledBatches(), 1, "the handler never settled");
        assertEq(handler.settledTrades(), 4, "the batch did not carry both pairs");
        assertEq(handler.skips(), 1, "the staller was never skipped");

        // The users were paid what the price vector derives, and `Executor` is
        // back at zero.
        assertEq(weth.balanceOf(buyers[0]), 1 ether, "buyer was not paid");
        assertEq(usdc.balanceOf(sellers[0]), 2000 ether, "seller was not paid");

        handler.replaySettledNonce(0);
        assertEq(handler.replaysAttempted(), 1, "the replay probe did not fire");

        invariant_ExecutorAndRelayerHoldNothing();
        invariant_NoIntentIsFilledWithoutBeingPaid();
        invariant_NoNonceIsConsumedTwice();
        invariant_LeaderIsNeverAnOutBid();
    }

    /// Reports what the fuzzed sequence actually reached, so a run that degrades
    /// into no-ops is visible in `-vv` output rather than silently passing.
    function afterInvariant() public view {
        console2.log("intents submitted   ", book.intentCount());
        console2.log("auctions opened     ", book.auctionCount() + 1);
        console2.log("batches settled     ", handler.settledBatches());
        console2.log("trades settled      ", handler.settledTrades());
        console2.log("leaders skipped     ", handler.skips());
        console2.log("intents cancelled   ", handler.cancels());
        console2.log("replays attempted   ", handler.replaysAttempted());
    }
}
