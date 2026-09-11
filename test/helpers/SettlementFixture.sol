// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TokenRegistry} from "../../src/TokenRegistry.sol";
import {Executor} from "../../src/Executor.sol";
import {Relayer} from "../../src/Relayer.sol";
import {Book} from "../../src/Book.sol";
import {SettlementData, Trade, Interaction, SignedIntent, SettlementEIP712} from "../../src/SettlementTypes.sol";

/// An EEZ whose cross-chain proxy derivation is the identity, so that `Book`
/// calling `Executor` directly satisfies the `expectedProxy` gate in a
/// single-chain test. The real bridge derives a distinct address; nothing under
/// test depends on which address it is, only that `settle` rejects every other
/// caller (§9, I19).
///
/// The identity is a convenience with a cost: it collapses `Book`'s two distinct
/// L1-facing addresses — the proxy it dispatches to, and the `Executor` its
/// signing domain is scoped to — into one, so no suite built on this fixture can
/// tell them apart. `ProxyEEZ` below derives them apart, and
/// `test/unit/TypesAndRegistry.t.sol` uses it for exactly that.
contract IdEEZ {
    function computeCrossChainProxyAddress(address t, uint64) external pure returns (address) {
        return t;
    }
}

/// An EEZ that derives a proxy address distinct from its target, which is what
/// the real bridge does — on the devnet, target `0x…DeaDBeef` derives to
/// `0x0c88…80d0`. Nothing depends on the derivation being EEZ's actual one, only
/// on `proxy != target`.
contract ProxyEEZ {
    function computeCrossChainProxyAddress(address t, uint64 rollupId) external pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode(t, rollupId)))));
    }
}

/// Minimal ERC-20. The whole supply is minted to the deployer — the fixture —
/// which then distributes it, so a suite can top up any account via `_fund`.
contract Tok is ERC20 {
    constructor(string memory n, uint256 s) ERC20(n, n) {
        _mint(msg.sender, s);
    }
}

/// The shared deployment graph, token setup and commit/reveal choreography that
/// every suite in this repository needs.
///
/// Inherit it, override `setUp` only if a suite needs more (and call
/// `super.setUp()` first). Everything here is setup; no assertions live in this
/// file.
abstract contract SettlementFixture is Test {
    TokenRegistry reg;
    address eez;
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

    /// The deadline every intent built by this fixture carries.
    uint40 dl;

    bytes32 internal constant SALT = bytes32(uint256(1));

    uint256 internal constant TOK_SUPPLY = 1e30;

    function setUp() public virtual {
        usdc = new Tok("USDC", TOK_SUPPLY);
        weth = new Tok("WETH", TOK_SUPPLY);
        dai = new Tok("DAI", TOK_SUPPLY);

        // Deployment order is load-bearing: `Executor` constructs `Relayer` in
        // its own constructor, so it precedes `Book`, and `setL2Caller` — which
        // resolves and caches the proxy — comes last.
        reg = new TokenRegistry();
        eez = address(new IdEEZ());
        ex = new Executor(eez, 0, windfall);
        rl = ex.relayer();
        book = new Book(eez, address(ex), 0, reg, block.chainid);
        ex.setL2Caller(address(book));

        // An unregistered token has no id and `Book._idOf` reverts UnknownToken.
        reg.register(address(usdc));
        reg.register(address(weth));
        reg.register(address(dai));

        // I6: tokens[0] must be an allowlisted numeraire priced at PRICE_SCALE,
        // and I7 requires it on one leg of every trade.
        book.setNumeraire(address(usdc), true);

        alice = vm.addr(alicePk);
        bob = vm.addr(bobPk);
        vm.label(alice, "alice");
        vm.label(bob, "bob");

        _fund(usdc, alice, 2000 ether);
        _fund(weth, bob, 10 ether);

        _approveAll(alice);
        _approveAll(bob);

        dl = uint40(block.timestamp + 1 days);
    }

    // ------------------------------------------------------------------
    // Accounts and balances
    // ------------------------------------------------------------------

    function _fund(Tok t, address who, uint256 amount) internal {
        t.transfer(who, amount);
    }

    /// Approvals go to `Relayer`, never `Executor`. `Relayer` holds every
    /// approval and that separation is the point (§3.1, I13); approving the
    /// wrong contract fails at pull time in a way that reads as a signature
    /// problem.
    function _approveAll(address who) internal {
        vm.startPrank(who);
        usdc.approve(address(rl), type(uint256).max);
        weth.approve(address(rl), type(uint256).max);
        dai.approve(address(rl), type(uint256).max);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Intents
    // ------------------------------------------------------------------

    function _intent(address account, address sell, address buy, uint256 amount, uint256 limit, uint256 nonce)
        internal
        view
        returns (SignedIntent memory)
    {
        return SignedIntent(account, sell, buy, amount, limit, dl, nonce);
    }

    /// Signs against `book.domainSeparator()` — never a locally reconstructed
    /// domain. §5.3: exactly one definition of the domain exists, in
    /// `SettlementEIP712`, and a test that rebuilds it stops testing that both
    /// chains agree.
    function _signIntent(uint256 pk, SignedIntent memory intent) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, SettlementEIP712.digest(book.domainSeparator(), intent));
        return abi.encodePacked(r, s, v);
    }

    function _submitIntent(uint256 pk, SignedIntent memory intent) internal returns (uint256 id, bytes memory sig) {
        sig = _signIntent(pk, intent);
        vm.prank(intent.account);
        id = book.submitIntent(intent, sig);
    }

    // ------------------------------------------------------------------
    // Payload builders
    // ------------------------------------------------------------------

    function _tokens2() internal view returns (address[] memory t) {
        t = new address[](2);
        t[0] = address(usdc);
        t[1] = address(weth);
    }

    function _prices2() internal pure returns (uint256[] memory p) {
        p = new uint256[](2);
        p[0] = 1e18; // PRICE_SCALE; the numeraire pin (I6)
        p[1] = 2000e18;
    }

    /// Alice sells 2000 USDC for at least 0.9 WETH; Bob sells 1 WETH for at
    /// least 1900 USDC. They clear against each other at 2000 USDC/WETH, so the
    /// settlement needs no interactions and no solver capital.
    function _coincidenceOfWants()
        internal
        returns (SettlementData memory d, uint256[] memory ids, bytes[] memory sigs)
    {
        (uint256 i0, bytes memory s0) = _submitIntent(
            alicePk, _intent(alice, address(usdc), address(weth), 2000 ether, 0.9 ether, 0)
        );
        (uint256 i1, bytes memory s1) =
            _submitIntent(bobPk, _intent(bob, address(weth), address(usdc), 1 ether, 1900 ether, 0));

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

    // ------------------------------------------------------------------
    // Auction
    // ------------------------------------------------------------------

    /// The commitment is over the full tuple; a reveal mismatching any element
    /// is rejected. Solver is `address(this)`, so the inheriting suite is the
    /// bidder and the only account that may reveal.
    function _commitment(SettlementData memory d, uint256[] memory ids, uint256 auctionId)
        internal
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(d, ids, SALT, address(this), auctionId, address(book), block.chainid));
    }

    /// Commit, then advance past T_C — and stop.
    ///
    /// It deliberately does not reveal. `vm.expectRevert` binds to the very next
    /// external call, so a helper that committed, warped and revealed in one go
    /// would swallow the expectation on the commit and pass for the wrong
    /// reason. That has already produced six false failures here.
    function _commitFor(SettlementData memory d, uint256[] memory ids, uint88 claimedScore)
        internal
        returns (uint256 auctionId)
    {
        auctionId = book.liveAuction();
        book.commitBid(auctionId, _commitment(d, ids, auctionId), claimedScore);
        vm.warp(block.timestamp + book.COMMIT_WINDOW());
    }

    function _reveal(uint256 auctionId, SettlementData memory d, uint256[] memory ids, bytes[] memory sigs) internal {
        book.revealAndExecute(auctionId, d, ids, SALT, sigs);
    }
}
