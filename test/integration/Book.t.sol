// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console2, stdError, Vm} from "forge-std/Test.sol";
import {Book} from "../../src/Book.sol";
import {SettlementData, Trade, Interaction, SignedIntent} from "../../src/SettlementTypes.sol";
import {SettlementFixture, Tok} from "../helpers/SettlementFixture.sol";

/// Phase 2c — the L2 half.
///
/// `Book` holds intents and runs a sealed-bid auction whose only hard structure
/// is the boundary at `T_C`. Two properties depend entirely on it and both are
/// the point of the design: a solver never exposes their route to discover
/// whether they won (§7.1), and `skipLeader` terminates because the candidate
/// set cannot grow afterwards (§6, I15).
///
/// Invariants owned here: I1, I2, I3, I4, I6, I7, I14, I15. I16 belongs to
/// `Executor` and is a review obligation, not a runtime check (§10).
contract BookTest is SettlementFixture {
    // Local copies for `vm.expectEmit`; `Book`'s own declarations are the
    // authority and these must match them exactly.
    event IntentSubmitted(uint256 indexed id, address indexed account, SignedIntent intent, bytes signature);
    event CancelRequested(uint256 indexed id, uint40 effectiveAt);
    event LeaderSkipped(uint256 indexed auctionId, address indexed solver);
    event Executed(uint256 indexed auctionId, address indexed solver, uint256 score, uint256 filled);

    uint8 internal constant LIVE = 1;
    uint8 internal constant FILLED = 2;
    uint8 internal constant CANCELLED = 3;

    /// The score `_coincidenceOfWants` actually delivers, from §7.3:
    /// alice (2000·1e18 − 0.9·2000e18) + bob (1·2000e18 − 1900·1e18), scaled down
    /// by PRICE_SCALE. Both legs contribute, so the total is exact, not a bound.
    uint88 internal constant COW_SCORE = 300e18;

    // ------------------------------------------------------------------
    // Local helpers. The fixture is Step 1's and is extended, never altered.
    // ------------------------------------------------------------------

    /// A commitment naming an arbitrary solver; the fixture's `_commitment`
    /// always names `address(this)`.
    function _commitmentBy(SettlementData memory d, uint256[] memory ids, uint256 auctionId, address solver)
        internal
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(d, ids, SALT, solver, auctionId, address(book), block.chainid));
    }

    /// One live intent and the single trade that fills it, so a test can mutate
    /// exactly one field and watch the match fail on it.
    function _single() internal returns (SettlementData memory d, uint256[] memory ids, bytes[] memory sigs) {
        (uint256 i0, bytes memory s0) =
            _submitIntent(alicePk, _intent(alice, address(usdc), address(weth), 2000 ether, 0.9 ether, 0));

        Trade[] memory tr = new Trade[](1);
        tr[0] = Trade(alice, 0, 1, 2000 ether, 0.9 ether, dl, 0);

        ids = new uint256[](1);
        ids[0] = i0;
        sigs = new bytes[](1);
        sigs[0] = s0;

        d = SettlementData(_tokens2(), _prices2(), tr, new Interaction[](0));
    }

    function _leaderOf(uint256 aid) internal view returns (address l) {
        (, l,,,,,) = book.auctions(aid);
    }

    function _leadScoreOf(uint256 aid) internal view returns (uint88 s) {
        (,, s,,,,) = book.auctions(aid);
    }

    function _leadIdxOf(uint256 aid) internal view returns (uint16 i) {
        (,,,,,, i) = book.auctions(aid);
    }

    function _leadCommitmentOf(uint256 aid) internal view returns (bytes32 c) {
        (c,,,,,,) = book.auctions(aid);
    }

    function _commitDeadlineOf(uint256 aid) internal view returns (uint40 tc) {
        (,,,, tc,,) = book.auctions(aid);
    }

    function _revealDeadlineOf(uint256 aid) internal view returns (uint40 tr) {
        (,,,,, tr,) = book.auctions(aid);
    }

    function _stateOf(uint256 id) internal view returns (uint8 s) {
        (,,,, s,,) = book.intents(id);
    }

    function _liveCandidates(uint256 aid) internal view returns (uint256 n) {
        for (uint256 i = 0; i < book.bidCount(aid); i++) {
            if (!book.bidAt(aid, i).out) n++;
        }
    }

    // ==================================================================
    // 1. Intents
    // ==================================================================

    function testSubmitIntentRecordsALiveIntent() public {
        SignedIntent memory it = _intent(alice, address(usdc), address(weth), 2000 ether, 0.9 ether, 0);
        (uint256 id,) = _submitIntent(alicePk, it);

        (address account, uint24 sellTok, uint24 buyTok, uint40 deadline, uint8 state, uint128 amt, uint128 lim) =
            book.intents(id);

        assertEq(book.intentCount(), 1, "one intent");
        assertEq(account, alice, "account");
        assertEq(book.registry().tokenAt(sellTok), address(usdc), "sell token resolves through the registry");
        assertEq(book.registry().tokenAt(buyTok), address(weth), "buy token resolves through the registry");
        assertEq(deadline, dl, "deadline");
        assertEq(state, LIVE, "live on submission");
        assertEq(amt, 2000 ether, "sell amount");
        assertEq(lim, 0.9 ether, "limit");
    }

    /// §5.1 — the signature is transported, never stored. Storing 65 bytes would
    /// cost three more slots per intent and erase the two-slot layout, so it is
    /// verified, emitted and discarded; solvers read it back from the event.
    function testSignatureIsEmittedNotStored() public {
        SignedIntent memory it = _intent(alice, address(usdc), address(weth), 2000 ether, 0.9 ether, 0);
        bytes memory sig = _signIntent(alicePk, it);

        vm.recordLogs();
        vm.prank(alice);
        uint256 id = book.submitIntent(it, sig);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 1, "submitIntent emits exactly IntentSubmitted");
        assertEq(logs[0].topics[0], IntentSubmitted.selector, "IntentSubmitted");
        assertEq(uint256(logs[0].topics[1]), id, "indexed id");
        assertEq(address(uint160(uint256(logs[0].topics[2]))), alice, "indexed account");

        (SignedIntent memory emitted, bytes memory emittedSig) = abi.decode(logs[0].data, (SignedIntent, bytes));
        assertEq(keccak256(emittedSig), keccak256(sig), "the signature is readable from the event");
        assertEq(emitted.nonce, it.nonce, "and so are the terms it covers");

        // The two slots the intent occupies hold no signature material: slot 0 is
        // account|ids|deadline|state and slot 1 is the two amounts. See
        // `testIntentIsTwoSlots` for the stride that proves nothing follows them.
        uint256 base = uint256(keccak256(abi.encode(uint256(1))));
        assertEq(uint256(vm.load(address(book), bytes32(base + 1))) >> 128, 0.9 ether, "slot 1 is limit, not sig");
    }

    function testIntentSignedByAnotherKeyRejected() public {
        SignedIntent memory it = _intent(alice, address(usdc), address(weth), 2000 ether, 0.9 ether, 0);
        bytes memory sig = _signIntent(bobPk, it); // bob signs alice's terms
        vm.prank(alice);
        vm.expectRevert(Book.BadSignature.selector);
        book.submitIntent(it, sig);
    }

    function testIntentForAnotherAccountRejected() public {
        SignedIntent memory it = _intent(alice, address(usdc), address(weth), 2000 ether, 0.9 ether, 0);
        bytes memory sig = _signIntent(alicePk, it);
        vm.prank(bob); // bob submits alice's correctly signed intent
        vm.expectRevert(Book.NotOwner.selector);
        book.submitIntent(it, sig);
    }

    function testExpiredIntentRejected() public {
        dl = uint40(block.timestamp - 1);
        SignedIntent memory it = _intent(alice, address(usdc), address(weth), 2000 ether, 0.9 ether, 0);
        bytes memory sig = _signIntent(alicePk, it);
        vm.prank(alice);
        vm.expectRevert(Book.Expired.selector);
        book.submitIntent(it, sig);
    }

    function testUnregisteredTokenRejected() public {
        Tok shell = new Tok("SHELL", TOK_SUPPLY);
        SignedIntent memory it = _intent(alice, address(usdc), address(shell), 2000 ether, 1 ether, 0);
        bytes memory sig = _signIntent(alicePk, it);
        vm.prank(alice);
        vm.expectRevert(Book.UnknownToken.selector);
        book.submitIntent(it, sig);
    }

    /// The mirror of Executor's bitmap. A reused nonce produces an intent that
    /// can never settle, and a solver who batched it would lose the entire
    /// settlement on L1 — harming every other trader in it, not just this user.
    function testReusedNonceRejected() public {
        _submitIntent(alicePk, _intent(alice, address(usdc), address(weth), 100 ether, 0.01 ether, 7));

        SignedIntent memory dup = _intent(alice, address(usdc), address(weth), 200 ether, 0.02 ether, 7);
        bytes memory sig = _signIntent(alicePk, dup);
        vm.prank(alice);
        vm.expectRevert(Book.NonceAlreadyUsed.selector);
        book.submitIntent(dup, sig);
    }

    function testNonceBitmapIsPerAccount() public {
        _submitIntent(alicePk, _intent(alice, address(usdc), address(weth), 100 ether, 0.01 ether, 7));
        // Bob's word 0 is untouched by alice's.
        (uint256 id,) = _submitIntent(bobPk, _intent(bob, address(weth), address(usdc), 1 ether, 1 ether, 7));
        assertEq(_stateOf(id), LIVE, "bob's nonce 7 is his own");
    }

    function testAmountWiderThanUint128Rejected() public {
        SignedIntent memory it =
            SignedIntent(alice, address(usdc), address(weth), uint256(type(uint128).max) + 1, 0.9 ether, dl, 0);
        bytes memory sig = _signIntent(alicePk, it);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Book.IntentMismatch.selector, 0));
        book.submitIntent(it, sig);
    }

    // ==================================================================
    // 2. Storage layout — §5.1 is exact, and §11's gas figures depend on it
    // ==================================================================

    /// §5.1 — `Intent` is 2 slots, exactly full.
    ///
    /// `forge inspect src/Book.sol:Book storage-layout --json` reports
    /// `struct Book.Intent` at 64 bytes. This asserts the same thing at runtime,
    /// from the stride between two intents in the `intents` array (slot 1): a
    /// third slot anywhere in the struct would push intent 1 to `base + 3`.
    function testIntentIsTwoSlots() public {
        _submitIntent(alicePk, _intent(alice, address(usdc), address(weth), 2000 ether, 0.9 ether, 0));
        _submitIntent(bobPk, _intent(bob, address(weth), address(usdc), 1 ether, 1900 ether, 0));

        assertEq(uint256(vm.load(address(book), bytes32(uint256(1)))), 2, "array length at slot 1");

        uint256 base = uint256(keccak256(abi.encode(uint256(1))));
        assertEq(address(uint160(uint256(vm.load(address(book), bytes32(base))))), alice, "intent 0, slot 0");
        assertEq(uint256(vm.load(address(book), bytes32(base + 1))) & type(uint128).max, 2000 ether, "intent 0, slot 1");
        assertEq(address(uint160(uint256(vm.load(address(book), bytes32(base + 2))))), bob, "intent 1 is 2 slots on");
        assertEq(uint256(vm.load(address(book), bytes32(base + 3))) & type(uint128).max, 1 ether, "intent 1, slot 1");
    }

    /// §5.1 — `Bid` is 2 slots: commitment, then solver|claimedScore|out packed.
    /// `forge inspect` reports `struct Book.Bid` at 64 bytes.
    function testBidIsTwoSlots() public {
        uint256 aid = book.liveAuction();
        book.commitBid(aid, bytes32(uint256(0xA1)), 11);
        vm.prank(bob);
        book.commitBid(aid, bytes32(uint256(0xB2)), 22);

        uint256 lenSlot = uint256(keccak256(abi.encode(aid, uint256(3))));
        assertEq(uint256(vm.load(address(book), bytes32(lenSlot))), 2, "two bids");

        uint256 base = uint256(keccak256(abi.encode(bytes32(lenSlot))));
        assertEq(vm.load(address(book), bytes32(base)), bytes32(uint256(0xA1)), "bid 0, slot 0");
        assertEq(vm.load(address(book), bytes32(base + 2)), bytes32(uint256(0xB2)), "bid 1 is 2 slots on");

        uint256 packed = uint256(vm.load(address(book), bytes32(base + 3)));
        assertEq(address(uint160(packed)), bob, "solver");
        assertEq(uint256(uint88(packed >> 160)), 22, "claimedScore shares the slot");
        assertEq(uint256(uint8(packed >> 248)), 0, "and so does `out`");
    }

    /// §5.1 — `Auction` is 3 slots. `forge inspect` reports
    /// `struct Book.Auction` at 96 bytes.
    ///
    /// Slot 2 carries `commitDeadline`, `revealDeadline` **and `leadIdx`** — the
    /// field §5.1's listing omitted and Appendix D, which is normative, carries.
    function testAuctionIsThreeSlots() public {
        uint256 aid = book.liveAuction();
        book.commitBid(aid, bytes32(uint256(0xC3)), 7);

        uint256 base = uint256(keccak256(abi.encode(aid, uint256(2))));
        assertEq(vm.load(address(book), bytes32(base)), bytes32(uint256(0xC3)), "slot 0, leadCommitment");

        uint256 s1 = uint256(vm.load(address(book), bytes32(base + 1)));
        assertEq(address(uint160(s1)), address(this), "slot 1, leader");
        assertEq(uint256(uint88(s1 >> 160)), 7, "slot 1, leadScore");
        assertEq(uint256(uint8(s1 >> 248)), 0, "slot 1, settled");

        uint256 s2 = uint256(vm.load(address(book), bytes32(base + 2)));
        assertEq(uint256(uint40(s2)), _commitDeadlineOf(aid), "slot 2, commitDeadline");
        assertEq(uint256(uint40(s2 >> 40)), _revealDeadlineOf(aid), "slot 2, revealDeadline");
        assertEq(uint256(uint16(s2 >> 80)), 0, "slot 2, leadIdx");

        assertEq(uint256(vm.load(address(book), bytes32(base + 3))), 0, "nothing spills into a fourth slot");
    }

    // ==================================================================
    // 3. Delayed cancellation — §6
    // ==================================================================

    function testRequestCancelDoesNotTakeEffectImmediately() public {
        (uint256 id,) = _submitIntent(alicePk, _intent(alice, address(usdc), address(weth), 2000 ether, 0.9 ether, 0));

        uint40 expected = uint40(block.timestamp) + book.CANCEL_DELAY();
        vm.expectEmit(true, false, false, true, address(book));
        emit CancelRequested(id, expected);
        vm.prank(alice);
        book.requestCancel(id);

        assertEq(_stateOf(id), LIVE, "still live -- a request is not a cancellation");
        assertEq(book.cancelEffectiveAt(id), expected, "scheduled, not applied");
    }

    function testFinalizeCancelBeforeDelayReverts() public {
        (uint256 id,) = _submitIntent(alicePk, _intent(alice, address(usdc), address(weth), 2000 ether, 0.9 ether, 0));
        vm.prank(alice);
        book.requestCancel(id);

        vm.warp(block.timestamp + book.CANCEL_DELAY() - 1);
        vm.expectRevert(Book.CancelNotReady.selector);
        book.finalizeCancel(id);
    }

    function testFinalizeCancelWithoutRequestReverts() public {
        (uint256 id,) = _submitIntent(alicePk, _intent(alice, address(usdc), address(weth), 2000 ether, 0.9 ether, 0));
        vm.expectRevert(Book.CancelNotReady.selector);
        book.finalizeCancel(id);
    }

    /// Permissionless once due: the effect was fixed at request time.
    function testFinalizeCancelAfterDelayIsPermissionless() public {
        (uint256 id,) = _submitIntent(alicePk, _intent(alice, address(usdc), address(weth), 2000 ether, 0.9 ether, 0));
        vm.prank(alice);
        book.requestCancel(id);

        vm.warp(block.timestamp + book.CANCEL_DELAY());
        vm.prank(makeAddr("anyone"));
        book.finalizeCancel(id);
        assertEq(_stateOf(id), CANCELLED, "cancelled");
    }

    /// §6, and the most important test in this set: **the front-run is closed.**
    ///
    /// A user watching a reveal land in the mempool cannot void the route it
    /// publishes. `requestCancel` only schedules, and
    /// `CANCEL_DELAY = COMMIT_WINDOW + MAX_REVEAL_PHASE` is the smallest delay no
    /// running auction can outlive — so a cancellation requested at any point
    /// during the auction lands strictly after it has ended.
    function testCancelCannotFrontRunAReveal() public {
        assertEq(
            book.CANCEL_DELAY(),
            book.COMMIT_WINDOW() + book.MAX_REVEAL_PHASE(),
            "the delay outlives the longest possible auction"
        );

        (SettlementData memory d, uint256[] memory ids, bytes[] memory sigs) = _coincidenceOfWants();
        uint256 aid = _commitFor(d, ids, COW_SCORE);

        // The leader is frozen and about to reveal. Alice tries to pull out.
        vm.prank(alice);
        book.requestCancel(ids[0]);
        vm.expectRevert(Book.CancelNotReady.selector);
        book.finalizeCancel(ids[0]);

        uint256 before = weth.balanceOf(alice);
        _reveal(aid, d, ids, sigs);

        assertEq(weth.balanceOf(alice) - before, 1 ether, "the published route still settles");
        assertEq(_stateOf(ids[0]), FILLED, "the intent filled despite the pending cancel");
    }

    /// The other side of the same rule: once the cancellation is due, a solver
    /// may no longer include the intent. Solvers read `cancelEffectiveAt` when
    /// building a batch for exactly this reason.
    function testPendingCancelBlocksSettlementOnceEffective() public {
        (SettlementData memory d, uint256[] memory ids, bytes[] memory sigs) = _coincidenceOfWants();
        vm.prank(alice);
        book.requestCancel(ids[0]);

        vm.warp(block.timestamp + book.CANCEL_DELAY());
        uint256 aid = _commitFor(d, ids, 0);

        vm.expectRevert(abi.encodeWithSelector(Book.CancelPending.selector, 0));
        book.revealAndExecute(aid, d, ids, SALT, sigs);
    }

    function testCancelledIntentCannotSettle() public {
        (SettlementData memory d, uint256[] memory ids, bytes[] memory sigs) = _coincidenceOfWants();
        vm.prank(alice);
        book.requestCancel(ids[0]);
        vm.warp(block.timestamp + book.CANCEL_DELAY());
        book.finalizeCancel(ids[0]);

        uint256 aid = _commitFor(d, ids, 0);
        vm.expectRevert(Book.NotLive.selector);
        book.revealAndExecute(aid, d, ids, SALT, sigs);
    }

    function testRequestCancelOnFilledIntentReverts() public {
        (SettlementData memory d, uint256[] memory ids, bytes[] memory sigs) = _coincidenceOfWants();
        uint256 aid = _commitFor(d, ids, COW_SCORE);
        _reveal(aid, d, ids, sigs);

        vm.prank(alice);
        vm.expectRevert(Book.NotLive.selector);
        book.requestCancel(ids[0]);
    }

    // ==================================================================
    // 4. I14 — only the frozen leader reveals, and only within [T_C, T_R)
    // ==================================================================

    /// I14: no reveal before the leader is frozen.
    function testRevealBeforeCommitDeadlineReverts() public {
        (SettlementData memory d, uint256[] memory ids, bytes[] memory sigs) = _coincidenceOfWants();
        uint256 aid = book.liveAuction();
        book.commitBid(aid, _commitment(d, ids, aid), COW_SCORE);

        vm.expectRevert(Book.CommitPhaseOpen.selector);
        book.revealAndExecute(aid, d, ids, SALT, sigs);
    }

    /// I14: the leader's turn ends at T_R.
    function testRevealAfterRevealDeadlineReverts() public {
        (SettlementData memory d, uint256[] memory ids, bytes[] memory sigs) = _coincidenceOfWants();
        uint256 aid = _commitFor(d, ids, COW_SCORE);

        vm.warp(_revealDeadlineOf(aid));
        vm.expectRevert(Book.RevealWindowClosed.selector);
        book.revealAndExecute(aid, d, ids, SALT, sigs);
    }

    /// I14: nobody but the frozen leader.
    function testNonLeaderCannotReveal() public {
        (SettlementData memory d, uint256[] memory ids, bytes[] memory sigs) = _coincidenceOfWants();
        uint256 aid = _commitFor(d, ids, COW_SCORE);

        vm.prank(makeAddr("interloper"));
        vm.expectRevert(Book.NotLeader.selector);
        book.revealAndExecute(aid, d, ids, SALT, sigs);
    }

    function testRevealWithNoBidsReverts() public {
        (SettlementData memory d, uint256[] memory ids, bytes[] memory sigs) = _coincidenceOfWants();
        uint256 aid = book.liveAuction();
        vm.warp(block.timestamp + book.COMMIT_WINDOW());

        vm.expectRevert(Book.NoBids.selector);
        book.revealAndExecute(aid, d, ids, SALT, sigs);
    }

    function testRevealTwiceReverts() public {
        (SettlementData memory d, uint256[] memory ids, bytes[] memory sigs) = _coincidenceOfWants();
        uint256 aid = _commitFor(d, ids, COW_SCORE);
        _reveal(aid, d, ids, sigs);

        vm.expectRevert(Book.AlreadySettled.selector);
        book.revealAndExecute(aid, d, ids, SALT, sigs);
    }

    /// The commitment is over the full tuple; a reveal mismatching any element
    /// is rejected. Here it is the salt.
    function testRevealWithWrongSaltRejected() public {
        (SettlementData memory d, uint256[] memory ids, bytes[] memory sigs) = _coincidenceOfWants();
        uint256 aid = _commitFor(d, ids, COW_SCORE);

        vm.expectRevert(Book.BadCommitment.selector);
        book.revealAndExecute(aid, d, ids, bytes32(uint256(0xdead)), sigs);
    }

    /// §7.1 — `msg.sender` is inside the commitment, so a solver cannot lodge a
    /// commitment and have someone else's reveal satisfy it.
    function testCommitmentIsBoundToTheSolver() public {
        (SettlementData memory d, uint256[] memory ids, bytes[] memory sigs) = _coincidenceOfWants();
        address other = makeAddr("other");

        uint256 aid = book.liveAuction();
        book.commitBid(aid, _commitmentBy(d, ids, aid, other), COW_SCORE);
        vm.warp(block.timestamp + book.COMMIT_WINDOW());

        vm.expectRevert(Book.BadCommitment.selector);
        book.revealAndExecute(aid, d, ids, SALT, sigs);
    }

    // ==================================================================
    // 5. I15 — the candidate set cannot grow after T_C
    // ==================================================================

    /// I15, the full attack: an observer sees the leader frozen, tries to outbid
    /// it before the reveal lands, and cannot. Without the boundary the leader is
    /// only resolvable at reveal, so the winner must broadcast their payload to
    /// find out — and the observer reads it from the mempool and steals it.
    function testCandidateSetFrozenAtCommitDeadline() public {
        (SettlementData memory d, uint256[] memory ids, bytes[] memory sigs) = _coincidenceOfWants();
        uint256 aid = _commitFor(d, ids, COW_SCORE);

        address leaderBefore = _leaderOf(aid);
        uint256 bidsBefore = book.bidCount(aid);

        address observer = makeAddr("observer");
        vm.prank(observer);
        vm.expectRevert(abi.encodeWithSelector(Book.AuctionMoved.selector, aid + 1));
        book.commitBid(aid, _commitmentBy(d, ids, aid, observer), type(uint88).max);

        // Bidding into the auction that *is* live is allowed, and changes nothing
        // about the one mid-reveal.
        vm.prank(observer);
        book.commitBid(aid + 1, bytes32(uint256(0xbad)), type(uint88).max);

        assertEq(book.bidCount(aid), bidsBefore, "candidate set unchanged after T_C");
        assertEq(_leaderOf(aid), leaderBefore, "leader unchanged after T_C");
        assertEq(_leadScoreOf(aid), COW_SCORE, "lead score unchanged after T_C");

        uint256 before = weth.balanceOf(alice);
        _reveal(aid, d, ids, sigs);
        assertEq(weth.balanceOf(alice) - before, 1 ether, "the honest solver settles");
    }

    // ==================================================================
    // 6. Auction sequencing
    // ==================================================================

    /// Appendix D — ids are sequential, not solver-chosen. An arbitrary id would
    /// fragment the competition into parallel auctions over the same intents.
    function testLiveAuctionIsCanonicalAndSequential() public {
        uint256 a0 = book.liveAuction();
        assertEq(book.liveAuction(), a0, "one canonical target while the window is open");
        assertEq(book.auctionCount(), a0, "no id burned by asking");

        vm.warp(_commitDeadlineOf(a0));
        uint256 a1 = book.liveAuction();
        assertEq(a1, a0 + 1, "the next opens when the previous closes");
        assertEq(book.auctionCount(), a1, "and it is the canonical one");
        assertEq(_commitDeadlineOf(a1), uint40(block.timestamp) + book.COMMIT_WINDOW(), "with a fresh window");
    }

    function testCommitWithStaleAuctionIdReverts() public {
        uint256 aid = book.liveAuction();
        book.commitBid(aid, bytes32(uint256(1)), 5);

        vm.warp(block.timestamp + book.COMMIT_WINDOW());
        vm.expectRevert(abi.encodeWithSelector(Book.AuctionMoved.selector, aid + 1));
        book.commitBid(aid, bytes32(uint256(2)), 99);
    }

    function testMaxBidsEnforced() public {
        uint256 aid = book.liveAuction();
        uint256 max = book.MAX_BIDS();
        for (uint256 i = 0; i < max; i++) {
            vm.prank(address(uint160(0x6000 + i)));
            book.commitBid(aid, bytes32(i + 1), uint88(1));
        }
        assertEq(book.bidCount(aid), max, "auction full");

        vm.prank(address(uint160(0x7000)));
        vm.expectRevert(Book.TooManyBids.selector);
        book.commitBid(aid, bytes32(uint256(0xdead)), type(uint88).max);
    }

    // ==================================================================
    // 7. Leader caching
    // ==================================================================

    /// The cache is O(1) precisely so an unbounded scan cannot brick an auction.
    /// It must still agree with a linear scan over every bid, for any sequence.
    function testFuzzLeaderCacheMatchesLinearScan(uint88[8] memory scores) public {
        uint256 aid = book.liveAuction();
        for (uint256 i = 0; i < scores.length; i++) {
            vm.prank(address(uint160(0x5000 + i)));
            book.commitBid(aid, bytes32(i + 1), scores[i]);
        }

        address expSolver;
        uint88 expScore;
        uint16 expIdx;
        bytes32 expCommitment;
        for (uint256 i = 0; i < book.bidCount(aid); i++) {
            Book.Bid memory b = book.bidAt(aid, i);
            // Strict `>`, so a tie leaves the earlier commitment in place.
            if (expSolver == address(0) || b.claimedScore > expScore) {
                expSolver = b.solver;
                expScore = b.claimedScore;
                expIdx = uint16(i);
                expCommitment = b.commitment;
            }
        }

        assertEq(_leaderOf(aid), expSolver, "leader");
        assertEq(_leadScoreOf(aid), expScore, "lead score");
        assertEq(_leadIdxOf(aid), expIdx, "lead index");
        assertEq(_leadCommitmentOf(aid), expCommitment, "lead commitment");
    }

    /// §7.2 — ties go to the earlier commitment.
    function testTieGoesToTheEarlierCommitment() public {
        address first = makeAddr("first");
        address second = makeAddr("second");

        uint256 aid = book.liveAuction();
        vm.prank(first);
        book.commitBid(aid, bytes32(uint256(1)), 100);
        vm.prank(second);
        book.commitBid(aid, bytes32(uint256(2)), 100);

        assertEq(_leaderOf(aid), first, "the earlier commitment keeps the lead");
        assertEq(_leadIdxOf(aid), 0, "and its index");
    }

    /// The other half of the O(1) argument: a full book must still leave the
    /// honest reveal affordable. Reveal reads the cached leader and never scans.
    function testMaxBidsLeavesRevealAffordable() public {
        (SettlementData memory d, uint256[] memory ids, bytes[] memory sigs) = _coincidenceOfWants();

        uint256 aid = book.liveAuction();
        book.commitBid(aid, _commitment(d, ids, aid), COW_SCORE);
        for (uint256 i = 1; i < book.MAX_BIDS(); i++) {
            vm.prank(address(uint160(0x6000 + i)));
            book.commitBid(aid, bytes32(i), uint88(1));
        }
        assertEq(book.bidCount(aid), book.MAX_BIDS(), "a full book");
        assertEq(_leaderOf(aid), address(this), "still leading");

        vm.warp(block.timestamp + book.COMMIT_WINDOW());
        uint256 g = gasleft();
        _reveal(aid, d, ids, sigs);
        uint256 used = g - gasleft();

        console2.log("revealAndExecute with MAX_BIDS committed, measured:", used);
        assertLt(used, 500_000, "reveal is O(1) in the number of bids");
    }

    // ==================================================================
    // 8. skipLeader
    // ==================================================================

    function testSkipLeaderBeforeRevealDeadlineReverts() public {
        (SettlementData memory d, uint256[] memory ids,) = _coincidenceOfWants();
        uint256 aid = _commitFor(d, ids, COW_SCORE);

        vm.expectRevert(Book.RevealWindowOpen.selector);
        book.skipLeader(aid);
    }

    function testSkipLeaderWithNoBidsReverts() public {
        uint256 aid = book.liveAuction();
        vm.warp(_revealDeadlineOf(aid));
        vm.expectRevert(Book.NoBids.selector);
        book.skipLeader(aid);
    }

    function testSkipLeaderPromotesNextBestAndExtendsTheWindow() public {
        (SettlementData memory d, uint256[] memory ids, bytes[] memory sigs) = _coincidenceOfWants();
        address second = makeAddr("second");

        uint256 aid = book.liveAuction();
        book.commitBid(aid, _commitment(d, ids, aid), COW_SCORE);
        vm.prank(second);
        book.commitBid(aid, _commitmentBy(d, ids, aid, second), COW_SCORE - 1);

        uint40 tc = _commitDeadlineOf(aid);
        vm.warp(_revealDeadlineOf(aid));

        vm.expectEmit(true, true, false, false, address(book));
        emit LeaderSkipped(aid, address(this));
        book.skipLeader(aid);

        assertEq(_leaderOf(aid), second, "next best promoted");
        assertEq(_leadScoreOf(aid), COW_SCORE - 1, "with its own claim");
        assertEq(book.bidAt(aid, 0).out, true, "the quiet leader is out");
        assertEq(_revealDeadlineOf(aid), uint40(block.timestamp) + book.REVEAL_WINDOW(), "T_R extended by one turn");
        assertLt(_revealDeadlineOf(aid), tc + book.MAX_REVEAL_PHASE() + 1, "and still inside the hard stop");

        uint256 before = weth.balanceOf(alice);
        vm.prank(second);
        book.revealAndExecute(aid, d, ids, SALT, sigs);
        assertEq(weth.balanceOf(alice) - before, 1 ether, "the promoted solver settles");
    }

    /// §6 — `skipLeader` **terminates**. The candidate set cannot grow after
    /// T_C, so every skip strictly shrinks it and the sequence is bounded by
    /// MAX_BIDS. In an auction that never closed bidding, the skipped solver
    /// would simply re-commit and stall the batch again, one window at a time.
    function testSkipLeaderTerminates() public {
        uint256 aid = book.liveAuction();
        uint256 n = 4;
        for (uint256 i = 0; i < n; i++) {
            vm.prank(address(uint160(0x8000 + i)));
            book.commitBid(aid, bytes32(i + 1), uint88(100 - i));
        }
        vm.warp(_commitDeadlineOf(aid));

        uint256 remaining = _liveCandidates(aid);
        assertEq(remaining, n, "the frozen set");

        for (uint256 i = 0; i < n; i++) {
            vm.warp(_revealDeadlineOf(aid));
            book.skipLeader(aid);
            uint256 now_ = _liveCandidates(aid);
            assertLt(now_, remaining, "every skip strictly shrinks the set");
            remaining = now_;
            assertEq(book.bidCount(aid), n, "and never grows it");
        }

        assertEq(remaining, 0, "the set is exhausted after MAX one skip per bid");
        assertEq(_leaderOf(aid), address(0), "no leader left to promote");

        // The skipped solver cannot re-enter and stall again: its commitment can
        // only be lodged against the auction that is now live.
        vm.prank(address(uint160(0x8000)));
        vm.expectRevert(abi.encodeWithSelector(Book.AuctionMoved.selector, aid + 1));
        book.commitBid(aid, bytes32(uint256(0xfeed)), type(uint88).max);

        vm.warp(_revealDeadlineOf(aid));
        vm.expectRevert(Book.NoBids.selector);
        book.skipLeader(aid);
    }

    function testSkipLeaderCapsRevealDeadlineAtTheHardStop() public {
        (SettlementData memory d, uint256[] memory ids,) = _coincidenceOfWants();
        address second = makeAddr("second");

        uint256 aid = book.liveAuction();
        book.commitBid(aid, _commitment(d, ids, aid), COW_SCORE);
        vm.prank(second);
        book.commitBid(aid, bytes32(uint256(2)), 1);

        uint40 tc = _commitDeadlineOf(aid);
        uint40 hardStop = tc + book.MAX_REVEAL_PHASE();

        vm.warp(hardStop - 10);
        book.skipLeader(aid);
        assertEq(_revealDeadlineOf(aid), hardStop, "one turn cannot outlive the auction");
    }

    /// Past `T_C + MAX_REVEAL_PHASE` the auction is Dead and its intents are free
    /// again. The bound is what makes `CANCEL_DELAY` computable at all (§6).
    function testSkipLeaderPastTheHardStopReverts() public {
        (SettlementData memory d, uint256[] memory ids,) = _coincidenceOfWants();
        uint256 aid = book.liveAuction();
        book.commitBid(aid, _commitment(d, ids, aid), COW_SCORE);

        vm.warp(_commitDeadlineOf(aid) + book.MAX_REVEAL_PHASE());
        vm.expectRevert(Book.AuctionDead.selector);
        book.skipLeader(aid);
    }

    function testSkipLeaderOnSettledAuctionReverts() public {
        (SettlementData memory d, uint256[] memory ids, bytes[] memory sigs) = _coincidenceOfWants();
        uint256 aid = _commitFor(d, ids, COW_SCORE);
        _reveal(aid, d, ids, sigs);

        vm.warp(_revealDeadlineOf(aid));
        vm.expectRevert(Book.AlreadySettled.selector);
        book.skipLeader(aid);
    }

    // ==================================================================
    // 9. I1, I2, I3 — trade/intent matching
    // ==================================================================

    /// I2: `intentIds.length == trades.length`.
    function testLengthMismatchBetweenIdsAndTradesRejected() public {
        (SettlementData memory d, uint256[] memory ids, bytes[] memory sigs) = _single();
        uint256[] memory two = new uint256[](2);
        two[0] = ids[0];
        two[1] = ids[0];

        uint256 aid = _commitFor(d, two, 0);
        vm.expectRevert(Book.LengthMismatch.selector);
        book.revealAndExecute(aid, d, two, SALT, sigs);
    }

    /// I2, the price vector half: one price per token.
    ///
    /// The vector is short rather than long deliberately. `Executor` declares its
    /// own `LengthMismatch()` over the same two arrays, and an identical error
    /// name is an identical selector — so an over-long vector still satisfies
    /// `expectRevert` when L2 waves it through and L1 catches it, and the test
    /// would prove nothing about where I2 is enforced. A short vector cannot be
    /// confused: without the L2 check `d.clearingPrices[t.buyIdx]` panics on an
    /// out-of-bounds read long before the settlement crosses to L1.
    function testLengthMismatchBetweenPricesAndTokensRejected() public {
        (SettlementData memory d, uint256[] memory ids, bytes[] memory sigs) = _single();
        uint256[] memory p = new uint256[](1);
        p[0] = 1e18;
        d.clearingPrices = p;

        uint256 aid = _commitFor(d, ids, 0);
        vm.expectRevert(Book.LengthMismatch.selector);
        book.revealAndExecute(aid, d, ids, SALT, sigs);
    }

    /// I3: no intent id appears twice. `_validateAndScore` writes FILLED inside
    /// the loop, so the second read of the same id fails its own liveness check
    /// rather than selling the user twice. That is why the function is not
    /// `view`.
    function testRepeatedIntentIdRejected() public {
        (SettlementData memory d, uint256[] memory ids, bytes[] memory sigs) = _single();

        Trade[] memory tr = new Trade[](2);
        tr[0] = d.trades[0];
        tr[1] = d.trades[0];
        d.trades = tr;

        uint256[] memory two = new uint256[](2);
        two[0] = ids[0];
        two[1] = ids[0];
        bytes[] memory ss = new bytes[](2);
        ss[0] = sigs[0];
        ss[1] = sigs[0];

        uint256 aid = _commitFor(d, two, 0);
        vm.expectRevert(Book.NotLive.selector);
        book.revealAndExecute(aid, d, two, SALT, ss);
    }

    /// I1: the account.
    function testTradeAccountMismatchRejected() public {
        (SettlementData memory d, uint256[] memory ids, bytes[] memory sigs) = _single();
        d.trades[0].account = bob;

        uint256 aid = _commitFor(d, ids, 0);
        vm.expectRevert(abi.encodeWithSelector(Book.IntentMismatch.selector, 0));
        book.revealAndExecute(aid, d, ids, SALT, sigs);
    }

    /// I1: the sell amount.
    function testTradeSellAmountMismatchRejected() public {
        (SettlementData memory d, uint256[] memory ids, bytes[] memory sigs) = _single();
        d.trades[0].sellAmount = 1999 ether;

        uint256 aid = _commitFor(d, ids, 0);
        vm.expectRevert(abi.encodeWithSelector(Book.IntentMismatch.selector, 0));
        book.revealAndExecute(aid, d, ids, SALT, sigs);
    }

    /// I1: the limit. A solver cannot quietly lower what the user demanded.
    function testTradeLimitMismatchRejected() public {
        (SettlementData memory d, uint256[] memory ids, bytes[] memory sigs) = _single();
        d.trades[0].limit = 0.5 ether;

        uint256 aid = _commitFor(d, ids, 0);
        vm.expectRevert(abi.encodeWithSelector(Book.IntentMismatch.selector, 0));
        book.revealAndExecute(aid, d, ids, SALT, sigs);
    }

    /// I1: the deadline. It is carried in the payload because L1 must rebuild the
    /// EIP-712 digest, so L2 must check it is the one the user signed.
    function testTradeDeadlineMismatchRejected() public {
        (SettlementData memory d, uint256[] memory ids, bytes[] memory sigs) = _single();
        d.trades[0].deadline = dl - 1;

        uint256 aid = _commitFor(d, ids, 0);
        vm.expectRevert(abi.encodeWithSelector(Book.IntentMismatch.selector, 0));
        book.revealAndExecute(aid, d, ids, SALT, sigs);
    }

    /// I1: the sell token, resolved registry id → address before matching.
    ///
    /// Only the sell leg differs. Alice signed a DAI sale; the trade sells
    /// `tokens[0]`, which is USDC. Her buy leg still matches, and the numeraire
    /// rule is satisfied, so nothing but the sell-token comparison can reject
    /// this — swapping `sellIdx` and `buyIdx` instead would be caught by the buy
    /// side and prove nothing about the sell side.
    function testTradeSellTokenMismatchRejected() public {
        (uint256 i0, bytes memory s0) =
            _submitIntent(alicePk, _intent(alice, address(dai), address(weth), 2000 ether, 0.9 ether, 0));

        Trade[] memory tr = new Trade[](1);
        tr[0] = Trade(alice, 0, 1, 2000 ether, 0.9 ether, dl, 0);

        uint256[] memory ids = new uint256[](1);
        ids[0] = i0;
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = s0;

        SettlementData memory d = SettlementData(_tokens2(), _prices2(), tr, new Interaction[](0));

        uint256 aid = _commitFor(d, ids, 0);
        vm.expectRevert(abi.encodeWithSelector(Book.IntentMismatch.selector, 0));
        book.revealAndExecute(aid, d, ids, SALT, sigs);
    }

    /// I1: the buy token.
    function testTradeBuyTokenMismatchRejected() public {
        (SettlementData memory d, uint256[] memory ids, bytes[] memory sigs) = _single();

        address[] memory t = new address[](3);
        t[0] = address(usdc);
        t[1] = address(weth);
        t[2] = address(dai);
        uint256[] memory p = new uint256[](3);
        p[0] = 1e18;
        p[1] = 2000e18;
        p[2] = 1e18;
        d.tokens = t;
        d.clearingPrices = p;
        d.trades[0].buyIdx = 2; // DAI, not the WETH she signed

        uint256 aid = _commitFor(d, ids, 0);
        vm.expectRevert(abi.encodeWithSelector(Book.IntentMismatch.selector, 0));
        book.revealAndExecute(aid, d, ids, SALT, sigs);
    }

    /// I1: still live at reveal, on the intent's own deadline.
    function testIntentExpiredAtRevealRejected() public {
        dl = uint40(block.timestamp + 100); // inside the reveal window, not past it
        (SettlementData memory d, uint256[] memory ids, bytes[] memory sigs) = _single();

        uint256 aid = _commitFor(d, ids, 0);
        vm.warp(dl + 1);
        assertLt(block.timestamp, _revealDeadlineOf(aid), "the auction is still open; the intent is not");

        vm.expectRevert(Book.Expired.selector);
        book.revealAndExecute(aid, d, ids, SALT, sigs);
    }

    /// I1, in the affirmative: a settlement whose every field matches settles,
    /// and the intents move Live → Filled.
    function testMatchingTradesSettleAndFillTheirIntents() public {
        (SettlementData memory d, uint256[] memory ids, bytes[] memory sigs) = _coincidenceOfWants();
        uint256 aid = _commitFor(d, ids, COW_SCORE);
        _reveal(aid, d, ids, sigs);

        assertEq(_stateOf(ids[0]), FILLED, "alice filled");
        assertEq(_stateOf(ids[1]), FILLED, "bob filled");
    }

    // ==================================================================
    // 10. I6, I7 — the numeraire
    // ==================================================================

    /// I6: `tokens[0]` must be on the allowlist. Otherwise a solver deploys a
    /// shell token, places it at index 0 and pins a price that anchors nothing.
    function testUnallowlistedNumeraireRejected() public {
        (SettlementData memory d, uint256[] memory ids, bytes[] memory sigs) = _single();
        // WETH is registered but not allowlisted; swap the vector round.
        address[] memory t = new address[](2);
        t[0] = address(weth);
        t[1] = address(usdc);
        uint256[] memory p = new uint256[](2);
        p[0] = 1e18;
        p[1] = 1e18;
        d.tokens = t;
        d.clearingPrices = p;

        uint256 aid = _commitFor(d, ids, 0);
        vm.expectRevert(Book.BadNumeraire.selector);
        book.revealAndExecute(aid, d, ids, SALT, sigs);
    }

    /// I6: and it must be priced at PRICE_SCALE. Without the pin, scaling the
    /// whole vector leaves every derived buy amount unchanged — they are ratios —
    /// but multiplies the score.
    function testNumeraireNotPinnedToPriceScaleRejected() public {
        (SettlementData memory d, uint256[] memory ids, bytes[] memory sigs) = _single();
        d.clearingPrices[0] = 2e18;

        uint256 aid = _commitFor(d, ids, 0);
        vm.expectRevert(Book.BadNumeraire.selector);
        book.revealAndExecute(aid, d, ids, SALT, sigs);
    }

    /// I7: every trade must have the numeraire on one side.
    function testTradeWithNoNumeraireLegRejected() public {
        (uint256 i0, bytes memory s0) =
            _submitIntent(alicePk, _intent(alice, address(weth), address(dai), 1 ether, 1 ether, 0));

        address[] memory t = new address[](3);
        t[0] = address(usdc);
        t[1] = address(weth);
        t[2] = address(dai);
        uint256[] memory p = new uint256[](3);
        p[0] = 1e18;
        p[1] = 2000e18;
        p[2] = 1e18;

        Trade[] memory tr = new Trade[](1);
        tr[0] = Trade(alice, 1, 2, 1 ether, 1 ether, dl, 0);

        uint256[] memory ids = new uint256[](1);
        ids[0] = i0;
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = s0;

        SettlementData memory d = SettlementData(t, p, tr, new Interaction[](0));
        uint256 aid = _commitFor(d, ids, 0);
        vm.expectRevert(abi.encodeWithSelector(Book.NoNumeraireLeg.selector, 0));
        book.revealAndExecute(aid, d, ids, SALT, sigs);
    }

    /// I6 + I7 — the attack §8 describes, in full.
    ///
    /// A solver allowlisted a shell token, puts it at index 0 where the pin costs
    /// nothing because nothing trades against it, and quotes every real price
    /// 1e6 larger. Every fill is byte-identical — buy amounts are ratios — and
    /// the score is 1e6 times higher. The numeraire-leg rule is what rejects it:
    /// with the pin anchored by a real fill, one of `p[sell]` and `p[buy]` is
    /// always PRICE_SCALE and the score is strictly decreasing in the free price.
    function testShellNumeraireWithInflatedVectorRejected() public {
        Tok shell = new Tok("SHELL", TOK_SUPPLY);
        reg.register(address(shell));
        book.setNumeraire(address(shell), true); // I6 satisfied, and worth nothing

        (SettlementData memory d, uint256[] memory ids, bytes[] memory sigs) = _single();

        address[] memory t = new address[](3);
        t[0] = address(shell);
        t[1] = address(usdc);
        t[2] = address(weth);
        uint256[] memory p = new uint256[](3);
        p[0] = 1e18; // pinned, and anchoring nothing
        p[1] = 1e24; // USDC, quoted 1e6 larger
        p[2] = 2000e24; // WETH, likewise — the ratio is untouched
        d.tokens = t;
        d.clearingPrices = p;
        d.trades[0].sellIdx = 1;
        d.trades[0].buyIdx = 2;

        // The fills are identical under either vector...
        assertEq(
            uint256(2000 ether) * 1e24 / 2000e24,
            uint256(2000 ether) * 1e18 / 2000e18,
            "the buy amount is a ratio and does not move"
        );
        // ...and the score is not.
        uint256 honest = (uint256(2000 ether) * 1e18 - uint256(0.9 ether) * 2000e18) / book.PRICE_SCALE();
        uint256 inflated = (uint256(2000 ether) * 1e24 - uint256(0.9 ether) * 2000e24) / book.PRICE_SCALE();
        assertEq(inflated, honest * 1e6, "a free multiplier on the score, for a byte-identical settlement");

        uint256 aid = _commitFor(d, ids, uint88(honest));
        vm.expectRevert(abi.encodeWithSelector(Book.NoNumeraireLeg.selector, 0));
        book.revealAndExecute(aid, d, ids, SALT, sigs);
    }

    // ==================================================================
    // 11. I4 — scoring
    // ==================================================================

    /// I4: every user receives at least the limit they signed. §7.3 — the score
    /// contribution and the limit check are the same expression.
    function testLimitNotMetRejected() public {
        (SettlementData memory d, uint256[] memory ids, bytes[] memory sigs) = _single();
        d.clearingPrices[1] = 2500e18; // WETH dearer, so 2000 USDC no longer buys 0.9

        uint256 aid = _commitFor(d, ids, 0);
        vm.expectRevert(abi.encodeWithSelector(Book.LimitNotMet.selector, 0));
        book.revealAndExecute(aid, d, ids, SALT, sigs);
    }

    /// I4: the score is the surplus above the limits, in numeraire units, and it
    /// is recomputed from on-chain intents at reveal.
    function testScoreIsSurplusAboveTheLimits() public {
        (SettlementData memory d, uint256[] memory ids, bytes[] memory sigs) = _coincidenceOfWants();
        uint256 aid = _commitFor(d, ids, COW_SCORE);

        uint256 expected = (uint256(2000 ether) * 1e18 - uint256(0.9 ether) * 2000e18) / book.PRICE_SCALE()
            + (uint256(1 ether) * 2000e18 - uint256(1900 ether) * 1e18) / book.PRICE_SCALE();
        assertEq(expected, COW_SCORE, "section 7.3, by hand");

        vm.expectEmit(true, true, false, true, address(book));
        emit Executed(aid, address(this), expected, ids.length);
        _reveal(aid, d, ids, sigs);
    }

    /// §7.2 — this is what makes an unbonded auction safe. Overclaiming is
    /// self-defeating: the score is recomputed at reveal and a claim the solution
    /// cannot back is rejected, having cost the claimant gas and nothing else.
    function testScoreOverclaimedRejected() public {
        (SettlementData memory d, uint256[] memory ids, bytes[] memory sigs) = _coincidenceOfWants();
        uint256 aid = _commitFor(d, ids, COW_SCORE + 1);

        vm.expectRevert(abi.encodeWithSelector(Book.ScoreOverclaimed.selector, COW_SCORE, COW_SCORE + 1));
        book.revealAndExecute(aid, d, ids, SALT, sigs);
    }

    /// The boundary: a claim exactly equal to what the solution delivers stands.
    function testExactClaimAccepted() public {
        (SettlementData memory d, uint256[] memory ids, bytes[] memory sigs) = _coincidenceOfWants();
        uint256 aid = _commitFor(d, ids, COW_SCORE);
        _reveal(aid, d, ids, sigs);
        assertEq(weth.balanceOf(alice), 1 ether, "settled on an exact claim");
    }

    /// With `p[buy] == 0` the limit term vanishes, the score inflates, and the
    /// settlement then dies on L1 in `mulDiv`. A cheap check here keeps it off L1
    /// entirely.
    function testZeroPriceRejected() public {
        (SettlementData memory d, uint256[] memory ids, bytes[] memory sigs) = _single();
        d.clearingPrices[1] = 0;

        uint256 aid = _commitFor(d, ids, 0);
        vm.expectRevert(abi.encodeWithSelector(Book.ZeroPrice.selector, 1));
        book.revealAndExecute(aid, d, ids, SALT, sigs);
    }

    /// Overflow is left to checked arithmetic: an adversarial price reverts
    /// rather than wrapping, which costs the solver their gas and nothing else.
    function testAdversarialPriceOverflowReverts() public {
        (SettlementData memory d, uint256[] memory ids, bytes[] memory sigs) = _single();
        d.clearingPrices[1] = type(uint256).max;

        uint256 aid = _commitFor(d, ids, 0);
        vm.expectRevert(stdError.arithmeticError);
        book.revealAndExecute(aid, d, ids, SALT, sigs);
    }

    // ==================================================================
    // 12. Access control
    // ==================================================================

    /// The numeraire allowlist is the only governance surface with teeth, and
    /// every invariant in §10 holds regardless of what is on it.
    function testSetNumeraireIsAdminOnly() public {
        vm.prank(alice);
        vm.expectRevert(Book.NotAdmin.selector);
        book.setNumeraire(address(weth), true);
    }

    function testAdminCanToggleTheAllowlist() public {
        assertEq(book.admin(), address(this), "the deployer");
        book.setNumeraire(address(weth), true);
        assertTrue(book.isNumeraire(address(weth)), "listed");
        book.setNumeraire(address(weth), false);
        assertFalse(book.isNumeraire(address(weth)), "delisted");
    }

    function testRequestCancelIsOwnerOnly() public {
        (uint256 id,) = _submitIntent(alicePk, _intent(alice, address(usdc), address(weth), 2000 ether, 0.9 ether, 0));
        vm.prank(bob);
        vm.expectRevert(Book.NotOwner.selector);
        book.requestCancel(id);
    }
}
