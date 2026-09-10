// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Book} from "../../src/Book.sol";
import {Executor} from "../../src/Executor.sol";
import {SettlementData, Trade, Interaction, SignedIntent} from "../../src/SettlementTypes.sol";
import {SettlementFixture} from "../helpers/SettlementFixture.sol";

/// A fee-on-transfer token: moving `value` debits and credits only
/// `value - value/100`, so the sender keeps 1%.
contract FeeOnTransferTok is ERC20 {
    constructor(uint256 supply) ERC20("FEE", "FEE") {
        _mint(msg.sender, supply);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
        } else {
            super._update(from, to, value - value / 100);
        }
    }
}

/// A rebasing token: balances are shares scaled by a factor anyone may change,
/// so an account's balance moves without a transfer.
contract RebaseTok {
    mapping(address => uint256) public shares;
    mapping(address => mapping(address => uint256)) public allowance;

    uint256 public scale = 1e18;

    function balanceOf(address a) public view returns (uint256) {
        return (shares[a] * scale) / 1e18;
    }

    function rebase(uint256 newScale) external {
        scale = newScale;
    }

    function mint(address to, uint256 amount) external {
        shares[to] += (amount * 1e18) / scale;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) private {
        uint256 sh = (amount * 1e18) / scale;
        shares[from] -= sh;
        shares[to] += sh;
    }
}

/// Phase 3 — the negative space.
///
/// §2 lists partial fills, fee-on-transfer tokens and rebasing tokens as
/// **non-goals**. A non-goal is only worth stating if the system does something
/// definite when it meets one, so these assert what that something is.
///
/// Two of the three fail cleanly. One does not, and the test that finds it says
/// so rather than asserting a revert that does not happen — see
/// `testFeeOnTransferBuyTokenSilentlyShortChangesTheUser`.
contract NonGoalsTest is SettlementFixture {
    address internal whale;

    function setUp() public override {
        super.setUp();
        whale = address(this); // holds the fixture's undistributed supply
        usdc.approve(address(ex), type(uint256).max);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _sign(uint256 pk, address account, address sell, address buy, uint256 amount, uint256 limit, uint64 nonce)
        internal
        view
        returns (bytes memory)
    {
        return _signIntent(pk, SignedIntent(account, sell, buy, amount, limit, uint256(dl), uint256(nonce)));
    }

    function _one(address[] memory tokens, uint256[] memory prices, Trade memory t, Interaction[] memory calls)
        internal
        pure
        returns (SettlementData memory)
    {
        Trade[] memory trades = new Trade[](1);
        trades[0] = t;
        return SettlementData(tokens, prices, trades, calls);
    }

    function _pair(address a, address b) internal pure returns (address[] memory t) {
        t = new address[](2);
        t[0] = a;
        t[1] = b;
    }

    function _prices(uint256 p1) internal pure returns (uint256[] memory p) {
        p = new uint256[](2);
        p[0] = 1e18; // the numeraire pin, I6
        p[1] = p1;
    }

    // ------------------------------------------------------------------
    // Fee-on-transfer (§2)
    // ------------------------------------------------------------------

    /// §2, I11: an account cannot *sell* a fee-on-transfer token.
    ///
    /// The pull lands less in `Executor` than the trade says it did, so the
    /// difference sits there as residue. `_restore` tries to sweep it, the sweep
    /// itself moves less than it debits, and the re-read that exists for exactly
    /// this case fails the equality. The settlement reverts; nobody is paid out
    /// of the shortfall.
    ///
    /// The existing `testFeeOnTransferTokenRevertsBalanceNotRestored` reaches
    /// the same revert with the fee token arriving as residue from an
    /// interaction. This one reaches it down the trading path, where the token
    /// is a leg of the settlement and a real user signed for it.
    function testFeeOnTransferSellTokenCannotSettle() public {
        FeeOnTransferTok fee = new FeeOnTransferTok(1e24);
        fee.transfer(alice, 200_000 ether); // alice receives 1% less; irrelevant here
        vm.prank(alice);
        fee.approve(address(rl), type(uint256).max);

        uint256 sellAmount = 1000 ether;
        uint256 limit = 900 ether;

        Trade memory t = Trade(alice, 1, 0, uint128(sellAmount), uint128(limit), dl, 0);
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(alicePk, alice, address(fee), address(usdc), sellAmount, limit, 0);

        // The USDC alice is owed comes from the whale, in-band.
        Interaction[] memory calls = new Interaction[](1);
        calls[0] = Interaction(address(usdc), abi.encodeCall(IERC20.transferFrom, (whale, address(ex), 1000 ether)));

        SettlementData memory d = _one(_pair(address(usdc), address(fee)), _prices(1e18), t, calls);

        vm.prank(address(book));
        vm.expectRevert(abi.encodeWithSelector(Executor.BalanceNotRestored.selector, address(fee)));
        ex.settle(d, sigs);
    }

    /// §2, and the one non-goal that does **not** fail cleanly.
    ///
    /// A user *buying* a fee-on-transfer token is short-changed silently. `_pay`
    /// checks the buy amount it derived from the price vector against the limit,
    /// which passes, and then transfers it — and the token delivers 1% less.
    /// I11 does not notice, because the balance the equality is measured on is
    /// `Executor`'s and `Executor` is square; the shortfall lands entirely on
    /// the user, who signed for a minimum they did not get.
    ///
    /// This is a **non-goal, not a defect**: §2 excludes these tokens and the
    /// numeraire allowlist governs what can anchor a vector. It is recorded
    /// because "fails cleanly" is the claim being tested, and here it is false —
    /// the check `_pay` would need is on the recipient's balance delta, which
    /// costs a second `balanceOf` per trade on every settlement, for a token
    /// class the specification does not support.
    function testFeeOnTransferBuyTokenSilentlyShortChangesTheUser() public {
        FeeOnTransferTok fee = new FeeOnTransferTok(1e24);
        fee.approve(address(ex), type(uint256).max);

        uint256 sellAmount = 2000 ether;
        uint256 buyAmount = 1000 ether; // mulDiv(2000e18, 1e18, 2e18)

        Trade memory t = Trade(alice, 0, 1, uint128(sellAmount), uint128(buyAmount), dl, 0);
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(alicePk, alice, address(usdc), address(fee), sellAmount, buyAmount, 0);

        // Source exactly what will be paid out, and pass the pulled numeraire
        // on, so `Executor` ends square on both tokens and I11 holds.
        Interaction[] memory calls = new Interaction[](2);
        calls[0] = Interaction(address(usdc), abi.encodeCall(IERC20.transfer, (whale, sellAmount)));
        calls[1] = Interaction(address(fee), abi.encodeCall(IERC20.transferFrom, (whale, address(ex), buyAmount)));

        SettlementData memory d = _one(_pair(address(usdc), address(fee)), _prices(2e18), t, calls);

        vm.prank(address(book));
        ex.settle(d, sigs);

        // I11 held on both legs.
        assertEq(usdc.balanceOf(address(ex)), 0, "I11: executor left holding the numeraire");
        assertEq(fee.balanceOf(address(ex)), 0, "I11: executor left holding the fee token");

        // And alice, who signed for at least 1,000, has 990.
        assertEq(fee.balanceOf(alice), 990 ether, "the shortfall is not 1%");
        assertLt(fee.balanceOf(alice), buyAmount, "a fee-on-transfer buy token did not short-change the user");
    }

    // ------------------------------------------------------------------
    // Rebasing (§2)
    // ------------------------------------------------------------------

    /// §2, I11: a rebase that shrinks balances mid-settlement reverts it.
    ///
    /// `_restore` compares against the balance snapshotted before the pull, so
    /// a contraction that happens inside the settlement leaves `Executor` below
    /// where it opened and `NotSolvent` fires. The loss does not get passed on
    /// to whoever settles next.
    function testRebaseDownRevertsNotSolvent() public {
        RebaseTok rb = new RebaseTok();
        rb.mint(address(ex), 1000 ether); // Executor opens holding some
        rb.mint(whale, 100_000 ether);
        rb.approve(address(ex), type(uint256).max);

        Trade memory t = Trade(alice, 0, 1, uint128(2000 ether), uint128(1000 ether), dl, 0);
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(alicePk, alice, address(usdc), address(rb), 2000 ether, 1000 ether, 0);

        Interaction[] memory calls = new Interaction[](3);
        calls[0] = Interaction(address(usdc), abi.encodeCall(IERC20.transfer, (whale, 2000 ether)));
        calls[1] = Interaction(address(rb), abi.encodeCall(RebaseTok.transferFrom, (whale, address(ex), 1000 ether)));
        calls[2] = Interaction(address(rb), abi.encodeCall(RebaseTok.rebase, (0.5e18)));

        SettlementData memory d = _one(_pair(address(usdc), address(rb)), _prices(2e18), t, calls);

        vm.prank(address(book));
        vm.expectRevert(abi.encodeWithSelector(Executor.NotSolvent.selector, address(rb)));
        ex.settle(d, sigs);
    }

    /// §2, I17: a rebase that *grows* balances mid-settlement is swept to
    /// `windfallRecipient`, not kept by the solver.
    ///
    /// The yield is residue like any other — value nobody in the batch has a
    /// claim on — and the destination is immutable and absent from the payload,
    /// so a solver cannot name themselves as its recipient (§9.1).
    function testRebaseUpIsSweptToTheWindfallNotTheSolver() public {
        RebaseTok rb = new RebaseTok();
        rb.mint(whale, 100_000 ether);
        rb.approve(address(ex), type(uint256).max);

        Trade memory t = Trade(alice, 0, 1, uint128(2000 ether), uint128(1000 ether), dl, 0);
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(alicePk, alice, address(usdc), address(rb), 2000 ether, 1000 ether, 0);

        Interaction[] memory calls = new Interaction[](3);
        calls[0] = Interaction(address(usdc), abi.encodeCall(IERC20.transfer, (whale, 2000 ether)));
        calls[1] = Interaction(address(rb), abi.encodeCall(RebaseTok.transferFrom, (whale, address(ex), 1000 ether)));
        calls[2] = Interaction(address(rb), abi.encodeCall(RebaseTok.rebase, (2e18)));

        SettlementData memory d = _one(_pair(address(usdc), address(rb)), _prices(2e18), t, calls);

        vm.prank(address(book));
        ex.settle(d, sigs);

        assertEq(rb.balanceOf(address(ex)), 0, "I11: executor did not exit at its opening balance");
        assertEq(rb.balanceOf(alice), 1000 ether, "alice was not paid what the vector derived");

        // Executor took in 1,000, the rebase doubled it to 2,000, alice was paid
        // 1,000 — and the 1,000 the rebase created belonged to nobody in the
        // batch. All of it goes to the windfall recipient.
        assertEq(rb.balanceOf(windfall), 1000 ether, "I17: the rebase yield did not reach the windfall recipient");
    }

    // ------------------------------------------------------------------
    // Partial fills (§2)
    // ------------------------------------------------------------------

    /// §2, I1: a partial fill is not expressible. `sellAmount` is fixed by the
    /// intent and compared field-by-field at reveal, so a trade offering to fill
    /// half of one is rejected on L2 before it ever crosses.
    function testPartialFillRejectedOnL2() public {
        (uint256 id,) = _submitIntent(alicePk, _intent(alice, address(usdc), address(weth), 2000 ether, 0.9 ether, 0));

        Trade[] memory trades = new Trade[](1);
        trades[0] = Trade(alice, 0, 1, 1000 ether, 0.45 ether, dl, 0); // half of it

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;

        SettlementData memory d = SettlementData(_tokens2(), _prices2(), trades, new Interaction[](0));
        uint256 aid = _commitFor(d, ids, 0);

        vm.expectRevert(abi.encodeWithSelector(Book.IntentMismatch.selector, 0));
        book.revealAndExecute(aid, d, ids, SALT, new bytes[](1));
    }

    /// §2, I9: and the same payload from a compromised L2 dies on L1 too, on the
    /// signature rather than on a stored intent it could have rewritten.
    /// `sellAmount` is inside the digest, so half of it is a different order and
    /// recovers to a different address.
    function testPartialFillRejectedOnL1() public {
        Trade memory t = Trade(alice, 0, 1, 1000 ether, 0.45 ether, dl, 0);
        bytes[] memory sigs = new bytes[](1);
        // Signed for the whole order; the payload offers half.
        sigs[0] = _sign(alicePk, alice, address(usdc), address(weth), 2000 ether, 0.9 ether, 0);

        SettlementData memory d = _one(_tokens2(), _prices2(), t, new Interaction[](0));

        vm.prank(address(book));
        vm.expectRevert(abi.encodeWithSelector(Executor.BadSignature.selector, 0));
        ex.settle(d, sigs);
    }
}
