// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TokenRegistry} from "../src/TokenRegistry.sol";
import {Executor} from "../src/Executor.sol";
import {Relayer} from "../src/Relayer.sol";
import {Book, IExecutor} from "../src/Book.sol";
import {SettlementData, Trade, Interaction, SignedIntent, SettlementEIP712} from "../src/SettlementTypes.sol";

contract IdEEZ {
    function computeCrossChainProxyAddress(
        address t,
        uint64
    ) external pure returns (address) {
        return t;
    }
}

contract Tok is ERC20 {
    constructor(string memory n, uint256 s) ERC20(n, n) {
        _mint(msg.sender, s);
    }
}

contract Smoke is Test {
    TokenRegistry reg;
    Executor ex;
    Relayer rl;
    Book book;
    Tok usdc;
    Tok weth;
    address windfall = makeAddr("treasury");

    uint256 alicePk = 0xA11CE;
    uint256 bobPk = 0xB0B;
    address alice;
    address bob;

    function setUp() public {
        usdc = new Tok("USDC", 1e30);
        weth = new Tok("WETH", 1e30);

        reg = new TokenRegistry();
        ex = new Executor(address(new IdEEZ()), 0, windfall);
        rl = ex.relayer();
        book = new Book(IExecutor(address(ex)), reg, block.chainid);
        ex.setL2Caller(address(book));

        reg.register(address(usdc));
        reg.register(address(weth));
        book.setNumeraire(address(usdc), true);

        alice = vm.addr(alicePk);
        bob = vm.addr(bobPk);

        usdc.transfer(alice, 2000 ether);
        weth.transfer(bob, 1 ether);
        _approve(alice);
        _approve(bob);
    }

    function _approve(address who) internal {
        vm.startPrank(who);
        usdc.approve(address(rl), type(uint256).max);
        weth.approve(address(rl), type(uint256).max);
        vm.stopPrank();
    }

    function _submit(
        uint256 pk,
        address account,
        address sell,
        address buy,
        uint256 amt,
        uint256 lim,
        uint256 nonce
    ) internal returns (uint256 id, bytes memory sig) {
        SignedIntent memory intent = SignedIntent({
            account: account,
            sellToken: sell,
            buyToken: buy,
            sellAmount: amt,
            limit: lim,
            deadline: block.timestamp + 1 days,
            nonce: nonce
        });
        bytes32 digest = SettlementEIP712.digest(
            book.domainSeparator(),
            intent
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        sig = abi.encodePacked(r, s, v);

        vm.prank(account);
        id = book.submitIntent(intent, sig);
    }

    function testCoincidenceOfWantsEndToEnd() public {
        uint40 dl = uint40(block.timestamp + 1 days);

        (uint256 i0, bytes memory s0) = _submit(
            alicePk,
            alice,
            address(usdc),
            address(weth),
            2000 ether,
            0.9 ether,
            0
        );
        (uint256 i1, bytes memory s1) = _submit(
            bobPk,
            bob,
            address(weth),
            address(usdc),
            1 ether,
            1900 ether,
            0
        );

        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(weth);

        uint256[] memory prices = new uint256[](2);
        prices[0] = 1e18;
        prices[1] = 2000e18;

        Trade[] memory tr = new Trade[](2);
        tr[0] = Trade(alice, 0, 1, 2000 ether, 0.9 ether, dl, 0);
        tr[1] = Trade(bob, 1, 0, 1 ether, 1900 ether, dl, 0);

        uint256[] memory ids = new uint256[](2);
        ids[0] = i0;
        ids[1] = i1;

        bytes[] memory sigs = new bytes[](2);
        sigs[0] = s0;
        sigs[1] = s1;

        SettlementData memory d = SettlementData(
            tokens,
            prices,
            tr,
            new Interaction[](0)
        );

        uint256 auctionId = book.liveAuction();
        bytes32 salt = bytes32(uint256(0xC0FFEE));
        bytes32 c = keccak256(
            abi.encode(
                d,
                ids,
                salt,
                address(this),
                auctionId,
                address(book),
                block.chainid
            )
        );

        book.commitBid(auctionId, c, 300e18);

        // Reveal is impossible before the leader is frozen.
        vm.expectRevert(Book.CommitPhaseOpen.selector);
        book.revealAndExecute(auctionId, d, ids, salt, sigs);

        vm.warp(block.timestamp + book.COMMIT_WINDOW());
        book.revealAndExecute(auctionId, d, ids, salt, sigs);

        assertEq(weth.balanceOf(alice), 1 ether, "alice paid in WETH");
        assertEq(usdc.balanceOf(bob), 2000 ether, "bob paid in USDC");
        assertEq(usdc.balanceOf(alice), 0, "alice sold all USDC");
        assertEq(usdc.balanceOf(address(ex)), 0, "executor holds nothing");
        assertEq(weth.balanceOf(address(ex)), 0, "executor holds nothing");
        assertEq(usdc.balanceOf(windfall), 0, "no residue");
        console2.log("end-to-end settle OK");
    }
}
