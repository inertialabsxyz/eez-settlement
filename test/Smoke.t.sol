// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console2} from "forge-std/Test.sol";
import {Book} from "../src/Book.sol";
import {SettlementData} from "../src/SettlementTypes.sol";
import {SettlementFixture} from "./helpers/SettlementFixture.sol";

contract Smoke is SettlementFixture {
    function testCoincidenceOfWantsEndToEnd() public {
        (SettlementData memory d, uint256[] memory ids, bytes[] memory sigs) = _coincidenceOfWants();

        uint256 auctionId = book.liveAuction();
        book.commitBid(auctionId, _commitment(d, ids, auctionId), 300e18);

        // Reveal is impossible before the leader is frozen.
        vm.expectRevert(Book.CommitPhaseOpen.selector);
        book.revealAndExecute(auctionId, d, ids, SALT, sigs);

        vm.warp(block.timestamp + book.COMMIT_WINDOW());
        _reveal(auctionId, d, ids, sigs);

        assertEq(weth.balanceOf(alice), 1 ether, "alice paid in WETH");
        assertEq(usdc.balanceOf(bob), 2000 ether, "bob paid in USDC");
        assertEq(usdc.balanceOf(alice), 0, "alice sold all USDC");
        assertEq(usdc.balanceOf(address(ex)), 0, "executor holds nothing");
        assertEq(weth.balanceOf(address(ex)), 0, "executor holds nothing");
        assertEq(usdc.balanceOf(windfall), 0, "no residue");
        console2.log("end-to-end settle OK");
    }
}
