// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console2} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Executor} from "../src/Executor.sol";
import {Relayer} from "../src/Relayer.sol";
import {Book} from "../src/Book.sol";
import {SettlementData, Trade, Interaction, SignedIntent} from "../src/SettlementTypes.sol";
import {SettlementFixture} from "./helpers/SettlementFixture.sol";

contract Properties is SettlementFixture {
    // ---- D: the reveal front-run is closed by the commit deadline
    function testCannotOutbidAfterCommitDeadline() public {
        (SettlementData memory d, uint256[] memory ids, bytes[] memory sigs) = _coincidenceOfWants();
        uint256 aid = _commitFor(d, ids, 100e18);

        address thief = makeAddr("thief");
        vm.prank(thief);
        vm.expectRevert(abi.encodeWithSelector(Book.AuctionMoved.selector, aid + 1));
        book.commitBid(aid, bytes32(uint256(9)), type(uint88).max);

        uint256 before = weth.balanceOf(alice);
        _reveal(aid, d, ids, sigs);
        assertEq(weth.balanceOf(alice) - before, 1 ether, "honest leader settled");
    }

    // ---- A: intentIds cannot be longer than trades
    function testLengthMismatchRejected() public {
        (SettlementData memory d, uint256[] memory ids, bytes[] memory sigs) = _coincidenceOfWants();
        uint256[] memory extra = new uint256[](3);
        extra[0] = ids[0];
        extra[1] = ids[1];
        extra[2] = ids[0];
        uint256 aid = _commitFor(d, extra, 0);
        vm.expectRevert(Book.LengthMismatch.selector);
        book.revealAndExecute(aid, d, extra, SALT, sigs);
    }

    // ---- B: the same intent cannot appear twice
    function testDuplicateIntentRejected() public {
        (uint256 i0, bytes memory s0) =
            _submitIntent(alicePk, _intent(alice, address(usdc), address(weth), 2000 ether, 0.9 ether, 0));
        Trade[] memory tr = new Trade[](2);
        tr[0] = Trade(alice, 0, 1, 2000 ether, 0.9 ether, dl, 0);
        tr[1] = Trade(alice, 0, 1, 2000 ether, 0.9 ether, dl, 0);
        uint256[] memory ids = new uint256[](2);
        ids[0] = i0;
        ids[1] = i0;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = s0;
        sigs[1] = s0;
        SettlementData memory d = SettlementData(_tokens2(), _prices2(), tr, new Interaction[](0));
        uint256 aid = _commitFor(d, ids, 0);
        vm.expectRevert(Book.NotLive.selector);
        book.revealAndExecute(aid, d, ids, SALT, sigs);
    }

    // ---- C: a trade with no numeraire leg is rejected
    function testNoNumeraireLegRejected() public {
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

    // ---- I9: a wrong signature is caught on L1, not L2
    function testBadSignatureRejectedOnL1() public {
        (SettlementData memory d, uint256[] memory ids, bytes[] memory sigs) = _coincidenceOfWants();
        sigs[0] = sigs[1]; // alice's slot carries bob's signature
        uint256 aid = _commitFor(d, ids, 0);
        vm.expectRevert(abi.encodeWithSelector(Executor.BadSignature.selector, 0));
        book.revealAndExecute(aid, d, ids, SALT, sigs);
    }

    // ---- I10 mirror: Book rejects a reused nonce
    function testNonceReuseRejectedOnL2() public {
        _submitIntent(alicePk, _intent(alice, address(usdc), address(weth), 100 ether, 0.01 ether, 7));
        SignedIntent memory dup = _intent(alice, address(usdc), address(weth), 200 ether, 0.02 ether, 7);
        bytes memory sig = _signIntent(alicePk, dup);
        vm.prank(alice);
        vm.expectRevert(Book.NonceAlreadyUsed.selector);
        book.submitIntent(dup, sig);
    }

    // ---- I12: an interaction cannot reach the relayer
    function testInteractionCannotTargetRelayer() public {
        (SettlementData memory d, uint256[] memory ids, bytes[] memory sigs) = _coincidenceOfWants();
        address[] memory f = new address[](1);
        f[0] = alice;
        address[] memory tk = new address[](1);
        tk[0] = address(usdc);
        uint128[] memory am = new uint128[](1);
        am[0] = 1 ether;
        Interaction[] memory calls = new Interaction[](1);
        calls[0] = Interaction(address(rl), abi.encodeCall(Relayer.pullBatch, (tk, f, am)));
        d.calls = calls;
        uint256 aid = _commitFor(d, ids, 0);
        vm.expectRevert(abi.encodeWithSelector(Executor.TargetForbidden.selector, 0));
        book.revealAndExecute(aid, d, ids, SALT, sigs);
    }

    // ---- I17: residue goes to the protocol, never the solver
    function testResidueSweptToWindfall() public {
        (SettlementData memory d, uint256[] memory ids, bytes[] memory sigs) = _coincidenceOfWants();
        usdc.approve(address(ex), type(uint256).max);
        Interaction[] memory calls = new Interaction[](1);
        calls[0] = Interaction(address(usdc), abi.encodeCall(ERC20.transferFrom, (address(this), address(ex), 5 ether)));
        d.calls = calls;
        uint256 aid = _commitFor(d, ids, 0);
        _reveal(aid, d, ids, sigs);
        assertEq(usdc.balanceOf(windfall), 5 ether, "residue to treasury");
        assertEq(usdc.balanceOf(address(ex)), 0, "executor restored exactly");
    }

    // ---- gas, against the spec's estimates
    function testGas() public {
        SignedIntent memory it = _intent(alice, address(usdc), address(weth), 100 ether, 0.01 ether, 1);
        bytes memory sig = _signIntent(alicePk, it);
        vm.prank(alice);
        uint256 g = gasleft();
        book.submitIntent(it, sig);
        console2.log("submitIntent, first nonce word :", g - gasleft());

        SignedIntent memory it2 = _intent(alice, address(usdc), address(weth), 100 ether, 0.01 ether, 2);
        bytes memory sig2 = _signIntent(alicePk, it2);
        vm.prank(alice);
        g = gasleft();
        book.submitIntent(it2, sig2);
        console2.log("submitIntent, warm word        :", g - gasleft());

        uint256 aid = book.liveAuction();
        g = gasleft();
        book.commitBid(aid, bytes32(uint256(3)), 1);
        console2.log("commitBid, first bid           :", g - gasleft());
        address s2 = makeAddr("solver2");
        vm.prank(s2);
        g = gasleft();
        book.commitBid(aid, bytes32(uint256(4)), 2);
        console2.log("commitBid, subsequent          :", g - gasleft());
    }
}
