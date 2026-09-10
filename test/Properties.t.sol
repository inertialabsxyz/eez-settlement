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

contract Properties is Test {
    TokenRegistry reg;
    Executor ex;
    Relayer rl;
    Book book;
    Tok usdc;
    Tok weth;
    Tok dai;
    address windfall = makeAddr("treasury");
    uint256 alicePk = 0xA11CE;
    uint256 bobPk = 0xB0B;
    address alice;
    address bob;
    uint40 dl;

    function setUp() public {
        usdc = new Tok("USDC", 1e30);
        weth = new Tok("WETH", 1e30);
        dai = new Tok("DAI", 1e30);
        reg = new TokenRegistry();
        ex = new Executor(address(new IdEEZ()), 0, windfall);
        rl = ex.relayer();
        book = new Book(IExecutor(address(ex)), reg, block.chainid);
        ex.setL2Caller(address(book));
        reg.register(address(usdc));
        reg.register(address(weth));
        reg.register(address(dai));
        book.setNumeraire(address(usdc), true);
        alice = vm.addr(alicePk);
        bob = vm.addr(bobPk);
        usdc.transfer(alice, 10000 ether);
        weth.transfer(bob, 10 ether);
        weth.transfer(alice, 10 ether);
        _approve(alice);
        _approve(bob);
        dl = uint40(block.timestamp + 1 days);
    }

    function _approve(address who) internal {
        vm.startPrank(who);
        usdc.approve(address(rl), type(uint256).max);
        weth.approve(address(rl), type(uint256).max);
        dai.approve(address(rl), type(uint256).max);
        vm.stopPrank();
    }

    function _sig(
        uint256 pk,
        SignedIntent memory it
    ) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            pk,
            SettlementEIP712.digest(book.domainSeparator(), it)
        );
        return abi.encodePacked(r, s, v);
    }

    function _intent(
        address a,
        address sell,
        address buy,
        uint256 amt,
        uint256 lim,
        uint256 nonce
    ) internal view returns (SignedIntent memory) {
        return
            SignedIntent(
                a,
                sell,
                buy,
                amt,
                lim,
                block.timestamp + 1 days,
                nonce
            );
    }

    function _submit(
        uint256 pk,
        SignedIntent memory it
    ) internal returns (uint256 id, bytes memory sig) {
        sig = _sig(pk, it);
        vm.prank(it.account);
        id = book.submitIntent(it, sig);
    }

    function _tokens2() internal view returns (address[] memory t) {
        t = new address[](2);
        t[0] = address(usdc);
        t[1] = address(weth);
    }

    function _prices2() internal pure returns (uint256[] memory p) {
        p = new uint256[](2);
        p[0] = 1e18;
        p[1] = 2000e18;
    }

    bytes32 constant SALT = bytes32(uint256(1));

    /// Commit and advance past T_C, stopping short of the reveal so a test can
    /// place `expectRevert` immediately before it.
    function _commitFor(
        SettlementData memory d,
        uint256[] memory ids
    ) internal returns (uint256 aid) {
        aid = book.liveAuction();
        bytes32 c = keccak256(
            abi.encode(
                d,
                ids,
                SALT,
                address(this),
                aid,
                address(book),
                block.chainid
            )
        );
        book.commitBid(aid, c, 0);
        vm.warp(block.timestamp + book.COMMIT_WINDOW());
    }

    function _reveal(
        SettlementData memory d,
        uint256[] memory ids,
        bytes[] memory sigs
    ) internal returns (uint256 aid) {
        aid = _commitFor(d, ids);
        book.revealAndExecute(aid, d, ids, SALT, sigs);
    }

    function _pair()
        internal
        returns (
            SettlementData memory d,
            uint256[] memory ids,
            bytes[] memory sigs
        )
    {
        (uint256 i0, bytes memory s0) = _submit(
            alicePk,
            _intent(
                alice,
                address(usdc),
                address(weth),
                2000 ether,
                0.9 ether,
                0
            )
        );
        (uint256 i1, bytes memory s1) = _submit(
            bobPk,
            _intent(bob, address(weth), address(usdc), 1 ether, 1900 ether, 0)
        );
        Trade[] memory tr = new Trade[](2);
        tr[0] = Trade(alice, 0, 1, 2000 ether, 0.9 ether, dl, 0);
        tr[1] = Trade(bob, 1, 0, 1 ether, 1900 ether, dl, 0);
        ids = new uint256[](2);
        ids[0] = i0;
        ids[1] = i1;
        sigs = new bytes[](2);
        sigs[0] = s0;
        sigs[1] = s1;
        d = SettlementData(_tokens2(), _prices2(), tr, new Interaction[](0));
    }

    // ---- D: the reveal front-run is closed by the commit deadline
    function testCannotOutbidAfterCommitDeadline() public {
        (
            SettlementData memory d,
            uint256[] memory ids,
            bytes[] memory sigs
        ) = _pair();
        uint256 aid = book.liveAuction();
        bytes32 salt = bytes32(uint256(1));
        bytes32 c = keccak256(
            abi.encode(
                d,
                ids,
                salt,
                address(this),
                aid,
                address(book),
                block.chainid
            )
        );
        book.commitBid(aid, c, 100e18);

        vm.warp(block.timestamp + book.COMMIT_WINDOW());

        address thief = makeAddr("thief");
        vm.prank(thief);
        vm.expectRevert(
            abi.encodeWithSelector(Book.AuctionMoved.selector, aid + 1)
        );
        book.commitBid(aid, bytes32(uint256(9)), type(uint88).max);

        uint256 before = weth.balanceOf(alice);
        book.revealAndExecute(aid, d, ids, salt, sigs);
        assertEq(
            weth.balanceOf(alice) - before,
            1 ether,
            "honest leader settled"
        );
    }

    // ---- A: intentIds cannot be longer than trades
    function testLengthMismatchRejected() public {
        (
            SettlementData memory d,
            uint256[] memory ids,
            bytes[] memory sigs
        ) = _pair();
        uint256[] memory extra = new uint256[](3);
        extra[0] = ids[0];
        extra[1] = ids[1];
        extra[2] = ids[0];
        uint256 aid = _commitFor(d, extra);
        vm.expectRevert(Book.LengthMismatch.selector);
        book.revealAndExecute(aid, d, extra, SALT, sigs);
    }

    // ---- B: the same intent cannot appear twice
    function testDuplicateIntentRejected() public {
        (uint256 i0, bytes memory s0) = _submit(
            alicePk,
            _intent(
                alice,
                address(usdc),
                address(weth),
                2000 ether,
                0.9 ether,
                0
            )
        );
        Trade[] memory tr = new Trade[](2);
        tr[0] = Trade(alice, 0, 1, 2000 ether, 0.9 ether, dl, 0);
        tr[1] = Trade(alice, 0, 1, 2000 ether, 0.9 ether, dl, 0);
        uint256[] memory ids = new uint256[](2);
        ids[0] = i0;
        ids[1] = i0;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = s0;
        sigs[1] = s0;
        SettlementData memory d = SettlementData(
            _tokens2(),
            _prices2(),
            tr,
            new Interaction[](0)
        );
        uint256 aid = _commitFor(d, ids);
        vm.expectRevert(Book.NotLive.selector);
        book.revealAndExecute(aid, d, ids, SALT, sigs);
    }

    // ---- C: a trade with no numeraire leg is rejected
    function testNoNumeraireLegRejected() public {
        (uint256 i0, bytes memory s0) = _submit(
            alicePk,
            _intent(alice, address(weth), address(dai), 1 ether, 1 ether, 0)
        );
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
        SettlementData memory d = SettlementData(
            t,
            p,
            tr,
            new Interaction[](0)
        );
        uint256 aid = _commitFor(d, ids);
        vm.expectRevert(
            abi.encodeWithSelector(Book.NoNumeraireLeg.selector, 0)
        );
        book.revealAndExecute(aid, d, ids, SALT, sigs);
    }

    // ---- I9: a wrong signature is caught on L1, not L2
    function testBadSignatureRejectedOnL1() public {
        (
            SettlementData memory d,
            uint256[] memory ids,
            bytes[] memory sigs
        ) = _pair();
        sigs[0] = sigs[1]; // alice's slot carries bob's signature
        uint256 aid = _commitFor(d, ids);
        vm.expectRevert(
            abi.encodeWithSelector(Executor.BadSignature.selector, 0)
        );
        book.revealAndExecute(aid, d, ids, SALT, sigs);
    }

    // ---- I10 mirror: Book rejects a reused nonce
    function testNonceReuseRejectedOnL2() public {
        _submit(
            alicePk,
            _intent(
                alice,
                address(usdc),
                address(weth),
                100 ether,
                0.01 ether,
                7
            )
        );
        SignedIntent memory dup = _intent(
            alice,
            address(usdc),
            address(weth),
            200 ether,
            0.02 ether,
            7
        );
        bytes memory sig = _sig(alicePk, dup);
        vm.prank(alice);
        vm.expectRevert(Book.NonceAlreadyUsed.selector);
        book.submitIntent(dup, sig);
    }

    // ---- I12: an interaction cannot reach the relayer
    function testInteractionCannotTargetRelayer() public {
        (
            SettlementData memory d,
            uint256[] memory ids,
            bytes[] memory sigs
        ) = _pair();
        address[] memory f = new address[](1);
        f[0] = alice;
        address[] memory tk = new address[](1);
        tk[0] = address(usdc);
        uint128[] memory am = new uint128[](1);
        am[0] = 1 ether;
        Interaction[] memory calls = new Interaction[](1);
        calls[0] = Interaction(
            address(rl),
            abi.encodeCall(Relayer.pullBatch, (tk, f, am))
        );
        d.calls = calls;
        uint256 aid = _commitFor(d, ids);
        vm.expectRevert(
            abi.encodeWithSelector(Executor.TargetForbidden.selector, 0)
        );
        book.revealAndExecute(aid, d, ids, SALT, sigs);
    }

    // ---- I17: residue goes to the protocol, never the solver
    function testResidueSweptToWindfall() public {
        (
            SettlementData memory d,
            uint256[] memory ids,
            bytes[] memory sigs
        ) = _pair();
        usdc.approve(address(ex), type(uint256).max);
        Interaction[] memory calls = new Interaction[](1);
        calls[0] = Interaction(
            address(usdc),
            abi.encodeCall(
                ERC20.transferFrom,
                (address(this), address(ex), 5 ether)
            )
        );
        d.calls = calls;
        _reveal(d, ids, sigs);
        assertEq(usdc.balanceOf(windfall), 5 ether, "residue to treasury");
        assertEq(usdc.balanceOf(address(ex)), 0, "executor restored exactly");
    }

    // ---- gas, against the spec's estimates
    function testGas() public {
        SignedIntent memory it = _intent(
            alice,
            address(usdc),
            address(weth),
            100 ether,
            0.01 ether,
            1
        );
        bytes memory sig = _sig(alicePk, it);
        vm.prank(alice);
        uint256 g = gasleft();
        book.submitIntent(it, sig);
        console2.log("submitIntent, first nonce word :", g - gasleft());

        SignedIntent memory it2 = _intent(
            alice,
            address(usdc),
            address(weth),
            100 ether,
            0.01 ether,
            2
        );
        bytes memory sig2 = _sig(alicePk, it2);
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
