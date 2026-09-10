// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Executor} from "../../src/Executor.sol";
import {Relayer} from "../../src/Relayer.sol";
import {SettlementData, Trade, Interaction, SignedIntent} from "../../src/SettlementTypes.sol";
import {SettlementFixture, IdEEZ} from "../helpers/SettlementFixture.sol";

// ---------------------------------------------------------------------------
// Doubles
// ---------------------------------------------------------------------------

/// A venue an interaction can route through. It pulls with `transferFrom`, so a
/// settlement must first grant it an allowance from inside `calls` — the
/// standing-allowance pattern §9 says is worthless precisely because `Executor`
/// ends every settlement holding nothing.
contract MockVenue {
    using SafeERC20 for IERC20;

    bool public touched;

    function swap(address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut) external {
        touched = true;
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
    }
}

/// An interaction target that always fails.
contract Reverter {
    function boom() external pure {
        revert("boom");
    }
}

/// The indirect path in I12: a contract that forwards to `Relayer` on behalf of
/// whoever calls it. `Relayer` sees this contract as `msg.sender`, not
/// `Executor`, which is the whole point.
contract RelayerCaller {
    Relayer private immutable _relayer;

    constructor(Relayer r) {
        _relayer = r;
    }

    function pull(address token, address from, uint128 amount) external {
        address[] memory tokens = new address[](1);
        address[] memory froms = new address[](1);
        uint128[] memory amounts = new uint128[](1);
        tokens[0] = token;
        froms[0] = from;
        amounts[0] = amount;
        _relayer.pullBatch(tokens, froms, amounts);
    }
}

/// USDT-shaped: `transfer`, `transferFrom` and `approve` return no data at all.
/// A bare `IERC20` call reverts decoding an empty return; `SafeERC20` does not.
contract NoReturnTok {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(uint256 supply) {
        balanceOf[msg.sender] = supply;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        _move(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
    }

    function _move(address from, address to, uint256 amount) private {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// A fee-on-transfer token — §2 lists these as unsupported, and the reverting
/// behaviour is the support. A transfer of `amount` moves only `amount - fee`,
/// so the sender keeps the difference: exactly the "leaves residue behind"
/// case the re-read in `Executor._restore` exists to catch.
contract FeeTok is ERC20 {
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

// ---------------------------------------------------------------------------

/// Step 2b — `Executor` and `Relayer`, the L1 half.
///
/// Every test here drives `Executor.settle` directly, pranked as the L2 book's
/// cross-chain proxy, rather than through `Book.revealAndExecute`. That is
/// deliberate: §4's trust model says L1 must hold even against a fully
/// compromised L2, so the payloads below are ones `Book` would never build.
///
/// I18 — interactions are dispatched with `call`, never `delegatecall` — has no
/// test here and cannot have one: a contract cannot inspect its own opcodes.
/// §10 lists it as a review obligation and it stays one.
contract ExecutorTest is SettlementFixture {
    address carol;
    uint256 carolPk;

    address solver = address(this);

    function setUp() public override {
        super.setUp();
        (carol, carolPk) = makeAddrAndKey("carol");
    }

    // ------------------------------------------------------------------
    // Payload construction. `Book` is not involved; these are raw L1 payloads.
    // ------------------------------------------------------------------

    /// The canonical two-sided payload: alice sells 2000 USDC for at least 0.9
    /// WETH, bob sells 1 WETH for at least 1900 USDC, clearing at 2000. It
    /// balances exactly and needs no interactions.
    ///
    /// Signatures are not attached — a caller signs with `_sigs2` *after* any
    /// mutation it wants covered, so a test that mutates and does not re-sign is
    /// asserting the mismatch on purpose.
    function _pair() internal view returns (SettlementData memory d) {
        Trade[] memory tr = new Trade[](2);
        tr[0] = Trade(alice, 0, 1, 2000 ether, 0.9 ether, dl, 0);
        tr[1] = Trade(bob, 1, 0, 1 ether, 1900 ether, dl, 0);
        d = SettlementData(_tokens2(), _prices2(), tr, new Interaction[](0));
    }

    /// Alice and carol each sell 1000 USDC; bob sells the 1 WETH that pays them.
    function _trio() internal returns (SettlementData memory d) {
        _fund(usdc, carol, 1000 ether);
        _approveAll(carol);

        Trade[] memory tr = new Trade[](3);
        tr[0] = Trade(alice, 0, 1, 1000 ether, 0.4 ether, dl, 0);
        tr[1] = Trade(carol, 0, 1, 1000 ether, 0.4 ether, dl, 0);
        tr[2] = Trade(bob, 1, 0, 1 ether, 1900 ether, dl, 0);
        d = SettlementData(_tokens2(), _prices2(), tr, new Interaction[](0));
    }

    /// The signed form of a trade: `Trade`'s narrow widths widened back out.
    /// Only `SignedIntent` is canonical (§5.3).
    function _intentOf(SettlementData memory d, uint256 i) internal pure returns (SignedIntent memory) {
        Trade memory t = d.trades[i];
        return
            SignedIntent(t.account, d.tokens[t.sellIdx], d.tokens[t.buyIdx], t.sellAmount, t.limit, t.deadline, t.nonce);
    }

    function _signTrade(uint256 pk, SettlementData memory d, uint256 i) internal view returns (bytes memory) {
        return _signIntent(pk, _intentOf(d, i));
    }

    function _sigs2(SettlementData memory d) internal view returns (bytes[] memory sigs) {
        sigs = new bytes[](2);
        sigs[0] = _signTrade(alicePk, d, 0);
        sigs[1] = _signTrade(bobPk, d, 1);
    }

    function _sigs3(SettlementData memory d) internal view returns (bytes[] memory sigs) {
        sigs = new bytes[](3);
        sigs[0] = _signTrade(alicePk, d, 0);
        sigs[1] = _signTrade(carolPk, d, 1);
        sigs[2] = _signTrade(bobPk, d, 2);
    }

    /// `settle` is reachable only from the L2 book's cross-chain proxy, which
    /// `IdEEZ` derives as `book` itself.
    function _settle(SettlementData memory d, bytes[] memory sigs) internal {
        vm.prank(address(book));
        ex.settle(d, sigs);
    }

    // ==================================================================
    // I9 — every pull is covered by the account's signature over those
    // exact terms. One test per field of the signed form.
    // ==================================================================

    /// I9: the payload pulls more than the account put its name to.
    function testSellAmountMismatchRejected() public {
        SettlementData memory d = _pair();
        bytes[] memory sigs = _sigs2(d);

        SignedIntent memory signed = _intentOf(d, 0);
        signed.sellAmount = 1999 ether;
        sigs[0] = _signIntent(alicePk, signed);

        vm.prank(address(book));
        vm.expectRevert(abi.encodeWithSelector(Executor.BadSignature.selector, 0));
        ex.settle(d, sigs);
    }

    /// I9: the limit is part of the signed terms, so lowering it in the payload
    /// invalidates the signature rather than silently worsening the fill.
    function testLimitMismatchRejected() public {
        SettlementData memory d = _pair();
        bytes[] memory sigs = _sigs2(d);

        SignedIntent memory signed = _intentOf(d, 0);
        signed.limit = 1.5 ether;
        sigs[0] = _signIntent(alicePk, signed);

        vm.prank(address(book));
        vm.expectRevert(abi.encodeWithSelector(Executor.BadSignature.selector, 0));
        ex.settle(d, sigs);
    }

    /// I9: `buyIdx` resolves through `d.tokens`, so a payload can redirect a
    /// user's proceeds into a token they never named. The digest covers the
    /// resolved address, not the index.
    function testBuyTokenMismatchRejected() public {
        SettlementData memory d = _pair();
        bytes[] memory sigs = _sigs2(d);

        SignedIntent memory signed = _intentOf(d, 0);
        signed.buyToken = address(dai);
        sigs[0] = _signIntent(alicePk, signed);

        vm.prank(address(book));
        vm.expectRevert(abi.encodeWithSelector(Executor.BadSignature.selector, 0));
        ex.settle(d, sigs);
    }

    /// I9: the deadline is signed, so a payload cannot extend an intent's life.
    /// The signature stays as alice wrote it; the payload tries to carry a
    /// later expiry than the one she put her name to.
    function testDeadlineMismatchRejected() public {
        SettlementData memory d = _pair();
        bytes[] memory sigs = _sigs2(d);

        d.trades[0].deadline = dl + 1;

        vm.prank(address(book));
        vm.expectRevert(abi.encodeWithSelector(Executor.BadSignature.selector, 0));
        ex.settle(d, sigs);
    }

    /// I9: a signature naming one account cannot authorise a pull from another.
    /// This is the shape a compromised L2 would reach for — alice's genuine
    /// signature over her genuine terms, re-pointed at carol's balance. The
    /// signature is untouched; only the payload's `account` moves.
    function testAccountMismatchRejected() public {
        SettlementData memory d = _pair();
        bytes[] memory sigs = _sigs2(d);

        _fund(usdc, carol, 2000 ether);
        _approveAll(carol);
        d.trades[0].account = carol;

        vm.prank(address(book));
        vm.expectRevert(abi.encodeWithSelector(Executor.BadSignature.selector, 0));
        ex.settle(d, sigs);

        assertEq(usdc.balanceOf(carol), 2000 ether, "carol was never pulled from");
    }

    /// I9: correct terms, wrong key. The index in the error is the failing
    /// trade's, not the first trade's.
    function testWrongSignerRejected() public {
        SettlementData memory d = _pair();
        bytes[] memory sigs = _sigs2(d);
        sigs[1] = _signTrade(alicePk, d, 1); // bob's terms, alice's key

        vm.prank(address(book));
        vm.expectRevert(abi.encodeWithSelector(Executor.BadSignature.selector, 1));
        ex.settle(d, sigs);
    }

    // ==================================================================
    // I10 — no nonce is consumed twice
    // ==================================================================

    /// I10: the same signed intent replayed in a second settlement is rejected
    /// on L1, with no L2 involvement at all.
    function testNonceCannotBeConsumedTwice() public {
        SettlementData memory d = _pair();
        bytes[] memory sigs = _sigs2(d);
        _settle(d, sigs);

        // Re-fund both sides, so the replay fails on the nonce and not on a
        // balance the first settlement happened to spend.
        _fund(usdc, alice, 2000 ether);
        _fund(weth, bob, 1 ether);

        vm.prank(address(book));
        vm.expectRevert(abi.encodeWithSelector(Executor.NonceUsed.selector, 0));
        ex.settle(d, sigs);
    }

    /// I10: the bitmap is unordered. Two intents from one account settle in the
    /// reverse of their submission order and both succeed — a sequential nonce
    /// could not do this, which is why §5.3 does not use one.
    function testUnorderedNoncesSettleOutOfOrder() public {
        _fund(usdc, alice, 2000 ether);
        _fund(weth, bob, 1 ether);

        SettlementData memory second = _pair();
        second.trades[0].nonce = 9;
        second.trades[1].nonce = 9;
        bytes[] memory secondSigs = _sigs2(second);

        SettlementData memory first = _pair();
        first.trades[0].nonce = 2;
        first.trades[1].nonce = 2;
        bytes[] memory firstSigs = _sigs2(first);

        _settle(second, secondSigs); // the later nonce settles first
        _settle(first, firstSigs);

        assertEq(weth.balanceOf(alice), 2 ether, "both of alice's intents filled");
        assertTrue(ex.nonceBitmap(alice, 0) & (1 << 2) != 0, "nonce 2 consumed");
        assertTrue(ex.nonceBitmap(alice, 0) & (1 << 9) != 0, "nonce 9 consumed");
    }

    /// I10: the bitmap is keyed by account, so one account's nonce does not
    /// burn the same value for anybody else.
    function testNonceBitmapIsPerAccount() public {
        SettlementData memory d = _pair();
        d.trades[0].nonce = 4;
        d.trades[1].nonce = 4;
        bytes[] memory sigs = _sigs2(d);
        _settle(d, sigs);

        assertTrue(ex.nonceBitmap(alice, 0) & (1 << 4) != 0, "alice's nonce 4 consumed");
        assertTrue(ex.nonceBitmap(bob, 0) & (1 << 4) != 0, "bob's nonce 4 consumed");
        assertEq(ex.nonceBitmap(carol, 0), 0, "carol is untouched");
    }

    // ==================================================================
    // Deadline
    // ==================================================================

    /// `Executor` re-checks the deadline itself. `Book` checked it at
    /// submission, but L1 cannot read L2 storage and does not take its word.
    function testExecutorRechecksDeadlineIndependently() public {
        SettlementData memory d = _pair();
        bytes[] memory sigs = _sigs2(d);

        vm.warp(uint256(dl) + 1);

        vm.prank(address(book));
        vm.expectRevert(abi.encodeWithSelector(Executor.IntentExpired.selector, 0));
        ex.settle(d, sigs);
    }

    // ==================================================================
    // I11 — exactly the opening balance of every listed token, and of ETH
    // ==================================================================

    /// I11: equality, not a bound. The opening balances here are deliberately
    /// non-zero — token and ETH alike — so the assertion is "exactly what it
    /// started with" rather than the vacuous "still zero".
    function testExecutorExitsAtOpeningBalance() public {
        _fund(usdc, address(ex), 100 ether);
        _fund(weth, address(ex), 3 ether);
        vm.deal(address(ex), 1 ether);

        SettlementData memory d = _pair();
        bytes[] memory sigs = _sigs2(d);

        uint256 openUsdc = usdc.balanceOf(address(ex));
        uint256 openWeth = weth.balanceOf(address(ex));
        uint256 openEth = address(ex).balance;

        _settle(d, sigs);

        assertEq(usdc.balanceOf(address(ex)), openUsdc, "usdc exactly restored");
        assertEq(weth.balanceOf(address(ex)), openWeth, "weth exactly restored");
        assertEq(address(ex).balance, openEth, "eth exactly restored");
        assertEq(usdc.balanceOf(address(rl)), 0, "relayer never holds tokens");
        assertEq(weth.balanceOf(address(rl)), 0, "relayer never holds tokens");
    }

    /// I11: a settlement that pays out of the executor's own stock ends below
    /// its opening balance and reverts. Under a `>=` check this would have been
    /// a silent transfer of protocol funds to a user.
    function testNotSolventWhenSettlementDoesNotBalance() public {
        _fund(weth, address(ex), 1 ether);

        Trade[] memory tr = new Trade[](1);
        tr[0] = Trade(alice, 0, 1, 2000 ether, 0.9 ether, dl, 0);
        SettlementData memory d = SettlementData(_tokens2(), _prices2(), tr, new Interaction[](0));
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _signTrade(alicePk, d, 0);

        vm.prank(address(book));
        vm.expectRevert(abi.encodeWithSelector(Executor.NotSolvent.selector, address(weth)));
        ex.settle(d, sigs);
    }

    /// I11: a fee-on-transfer token cannot be swept back to the opening
    /// balance, because the sweep itself moves less than it debits. §2 lists
    /// these as unsupported; reverting is what that support looks like.
    function testFeeOnTransferTokenRevertsBalanceNotRestored() public {
        FeeTok fee = new FeeTok(1e24);
        fee.approve(address(ex), type(uint256).max);

        SettlementData memory d = _pair();
        bytes[] memory sigs = _sigs2(d);

        address[] memory tokens = new address[](3);
        tokens[0] = address(usdc);
        tokens[1] = address(weth);
        tokens[2] = address(fee);
        uint256[] memory prices = new uint256[](3);
        prices[0] = 1e18;
        prices[1] = 2000e18;
        prices[2] = 1e18;
        d.tokens = tokens;
        d.clearingPrices = prices;

        Interaction[] memory calls = new Interaction[](1);
        calls[0] =
            Interaction(address(fee), abi.encodeCall(ERC20.transferFrom, (address(this), address(ex), 100 ether)));
        d.calls = calls;

        vm.prank(address(book));
        vm.expectRevert(abi.encodeWithSelector(Executor.BalanceNotRestored.selector, address(fee)));
        ex.settle(d, sigs);
    }

    /// One signature per trade, checked before anything moves.
    function testSignatureCountMismatchRejected() public {
        SettlementData memory d = _pair();
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _signTrade(alicePk, d, 0);

        vm.prank(address(book));
        vm.expectRevert(Executor.LengthMismatch.selector);
        ex.settle(d, sigs);
    }

    /// One price per token: the vector is indexed by `sellIdx`/`buyIdx`, so a
    /// short vector would make some index unpriced.
    function testPriceCountMismatchRejected() public {
        SettlementData memory d = _pair();
        bytes[] memory sigs = _sigs2(d);
        uint256[] memory prices = new uint256[](3);
        prices[0] = 1e18;
        prices[1] = 2000e18;
        prices[2] = 1e18;
        d.clearingPrices = prices;

        vm.prank(address(book));
        vm.expectRevert(Executor.LengthMismatch.selector);
        ex.settle(d, sigs);
    }

    // ==================================================================
    // I12 — no interaction targets `Relayer`
    // ==================================================================

    /// I12: the direct path. `Relayer` holds every approval, so an interaction
    /// reaching it could drain every user who ever approved (§3.1).
    function testInteractionTargetingRelayerReverts() public {
        SettlementData memory d = _pair();
        bytes[] memory sigs = _sigs2(d);

        address[] memory tokens = new address[](1);
        address[] memory froms = new address[](1);
        uint128[] memory amounts = new uint128[](1);
        tokens[0] = address(usdc);
        froms[0] = alice;
        amounts[0] = 1 ether;

        Interaction[] memory calls = new Interaction[](2);
        calls[0] = Interaction(address(usdc), abi.encodeCall(IERC20.approve, (address(this), 0)));
        calls[1] = Interaction(address(rl), abi.encodeCall(Relayer.pullBatch, (tokens, froms, amounts)));
        d.calls = calls;

        vm.prank(address(book));
        vm.expectRevert(abi.encodeWithSelector(Executor.TargetForbidden.selector, 1));
        ex.settle(d, sigs);
    }

    /// I12 + I13: the indirect path the target check alone does not cover. An
    /// interaction may call anything that is not `Relayer`, including a
    /// contract that then calls `Relayer` — and that fails anyway, because
    /// `Relayer` sees the intermediate as `msg.sender`, not `Executor`.
    function testIndirectRelayerCallFails() public {
        RelayerCaller caller = new RelayerCaller(rl);

        SettlementData memory d = _pair();
        bytes[] memory sigs = _sigs2(d);
        Interaction[] memory calls = new Interaction[](1);
        calls[0] = Interaction(address(caller), abi.encodeCall(RelayerCaller.pull, (address(usdc), alice, 1 ether)));
        d.calls = calls;

        vm.prank(address(book));
        vm.expectRevert(abi.encodeWithSelector(Executor.InteractionFailed.selector, 0));
        ex.settle(d, sigs);

        assertEq(usdc.balanceOf(alice), 2000 ether, "alice untouched");
    }

    // ==================================================================
    // I13 — `Relayer` moves tokens only for `Executor`
    // ==================================================================

    /// I13: not the admin, not the book, not a solver. Only `Executor`.
    function testPullBatchRejectsNonExecutor() public {
        address[] memory tokens = new address[](1);
        address[] memory froms = new address[](1);
        uint128[] memory amounts = new uint128[](1);
        tokens[0] = address(usdc);
        froms[0] = alice;
        amounts[0] = 1 ether;

        vm.expectRevert(Relayer.NotExecutor.selector);
        rl.pullBatch(tokens, froms, amounts); // the admin, who deployed everything

        vm.prank(address(book));
        vm.expectRevert(Relayer.NotExecutor.selector);
        rl.pullBatch(tokens, froms, amounts);

        vm.prank(alice);
        vm.expectRevert(Relayer.NotExecutor.selector);
        rl.pullBatch(tokens, froms, amounts);
    }

    /// I13: a `froms` array out of step with `tokens` would pull the wrong
    /// token from the wrong account.
    function testPullBatchLengthMismatchFroms() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(weth);
        address[] memory froms = new address[](1);
        froms[0] = alice;
        uint128[] memory amounts = new uint128[](2);
        amounts[0] = 1 ether;
        amounts[1] = 1 ether;

        vm.prank(address(ex));
        vm.expectRevert(Relayer.LengthMismatch.selector);
        rl.pullBatch(tokens, froms, amounts);
    }

    /// I13: and the third array is checked too.
    function testPullBatchLengthMismatchAmounts() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(weth);
        address[] memory froms = new address[](2);
        froms[0] = alice;
        froms[1] = bob;
        uint128[] memory amounts = new uint128[](1);
        amounts[0] = 1 ether;

        vm.prank(address(ex));
        vm.expectRevert(Relayer.LengthMismatch.selector);
        rl.pullBatch(tokens, froms, amounts);
    }

    // ==================================================================
    // I17 — residue is unreachable by the solver
    // ==================================================================

    /// I17, and the most important test in this file. §9.1: if residue went to
    /// a solver-nominated address, a `_pay` bug would be paid straight to the
    /// solver with every balance check still passing.
    ///
    /// The solver here builds the entire payload — tokens, prices, trades and
    /// interactions — and there is no field in any of them that names a
    /// recipient. The residue lands at the immutable `windfallRecipient` and
    /// the solver's balance does not move.
    function testResidueSweptToWindfallNotSolver() public {
        usdc.approve(address(ex), type(uint256).max);

        SettlementData memory d = _pair();
        bytes[] memory sigs = _sigs2(d);
        Interaction[] memory calls = new Interaction[](1);
        calls[0] = Interaction(address(usdc), abi.encodeCall(ERC20.transferFrom, (solver, address(ex), 5 ether)));
        d.calls = calls;

        uint256 solverBefore = usdc.balanceOf(solver);

        _settle(d, sigs);

        assertEq(usdc.balanceOf(windfall), 5 ether, "residue to the protocol address");
        assertEq(usdc.balanceOf(solver), solverBefore - 5 ether, "solver funded it and got nothing back");
        assertEq(ex.windfallRecipient(), windfall, "recipient is immutable and not in the payload");
        assertEq(usdc.balanceOf(address(ex)), 0, "executor restored exactly");
    }

    /// I17: the only way out of `Executor` for residue is the sweep. It never
    /// approves anyone, so an interaction cannot pull its balance out — and
    /// because the sweep leaves it at exactly its opening balance, a standing
    /// allowance would be worthless even if one existed (§9).
    function testSolverCannotPullResidueFromExecutor() public {
        usdc.approve(address(ex), type(uint256).max);

        SettlementData memory d = _pair();
        bytes[] memory sigs = _sigs2(d);
        Interaction[] memory calls = new Interaction[](2);
        calls[0] = Interaction(address(usdc), abi.encodeCall(ERC20.transferFrom, (solver, address(ex), 5 ether)));
        calls[1] = Interaction(address(usdc), abi.encodeCall(ERC20.transferFrom, (address(ex), solver, 5 ether)));
        d.calls = calls;

        vm.prank(address(book));
        vm.expectRevert(abi.encodeWithSelector(Executor.InteractionFailed.selector, 1));
        ex.settle(d, sigs);
    }

    // ==================================================================
    // The caller gate
    // ==================================================================

    /// Authentication of the caller, not of the trade (§4) — but it is still
    /// the first line, and nobody else passes it.
    function testSettleFromNonProxyReverts() public {
        SettlementData memory d = _pair();
        bytes[] memory sigs = _sigs2(d);

        vm.expectRevert(Executor.NotProxy.selector);
        ex.settle(d, sigs); // the admin

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(Executor.NotProxy.selector);
        ex.settle(d, sigs);

        vm.prank(alice);
        vm.expectRevert(Executor.NotProxy.selector);
        ex.settle(d, sigs);
    }

    /// Before `setL2Caller`, `expectedProxy` is zero and no caller matches, so
    /// `settle` is locked. Appendix B's review notes flag that as deliberate.
    function testSettleLockedBeforeSetL2Caller() public {
        Executor fresh = new Executor(address(new IdEEZ()), 0, windfall);
        SettlementData memory d = _pair();
        bytes[] memory sigs = _sigs2(d);

        assertEq(fresh.expectedProxy(), address(0), "unarmed");

        vm.expectRevert(Executor.NotProxy.selector);
        fresh.settle(d, sigs); // even the admin

        vm.prank(address(book));
        vm.expectRevert(Executor.NotProxy.selector);
        fresh.settle(d, sigs);
    }

    // ==================================================================
    // `setL2Caller`
    // ==================================================================

    function testSetL2CallerIsAdminOnly() public {
        Executor fresh = new Executor(address(new IdEEZ()), 0, windfall);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(Executor.NotAdmin.selector);
        fresh.setL2Caller(address(book));

        fresh.setL2Caller(address(book));
        assertEq(fresh.expectedProxy(), address(book), "derivation cached");
    }

    /// One-shot: the admin cannot rotate `Book`. Appendix B's review notes say
    /// replacing the L2 half means a new `Executor`, hence a new `Relayer`,
    /// hence every user re-approving.
    function testSetL2CallerIsOneShot() public {
        vm.expectRevert(Executor.ProxyAlreadySet.selector);
        ex.setL2Caller(makeAddr("otherBook"));

        assertEq(ex.expectedProxy(), address(book), "unchanged");
    }

    /// A registry returning nothing must not re-arm the gate to the zero
    /// address, which would leave `settle` locked and `setL2Caller` spent.
    function testSetL2CallerRejectsZeroProxy() public {
        Executor fresh = new Executor(address(new IdEEZ()), 0, windfall);

        vm.expectRevert(bytes("bad proxy"));
        fresh.setL2Caller(address(0));

        assertEq(fresh.expectedProxy(), address(0), "still unarmed, still settable");
    }

    // ==================================================================
    // Uniform pricing (G1, I5) and the limit check (I4 on L1)
    // ==================================================================

    /// I5: every buy amount is `mulDiv(sellAmount, p[sell], p[buy])` against the
    /// one vector in the payload. There is no per-trade price to disagree with.
    function testBuyAmountsDeriveFromSharedPriceVector() public {
        SettlementData memory d = _pair();
        bytes[] memory sigs = _sigs2(d);

        uint256 aliceBefore = weth.balanceOf(alice);
        uint256 bobBefore = usdc.balanceOf(bob);

        _settle(d, sigs);

        assertEq(
            weth.balanceOf(alice) - aliceBefore,
            (2000 ether * d.clearingPrices[0]) / d.clearingPrices[1],
            "alice priced off the vector"
        );
        assertEq(
            usdc.balanceOf(bob) - bobBefore,
            (1 ether * d.clearingPrices[1]) / d.clearingPrices[0],
            "bob priced off the same vector"
        );
    }

    /// G1: a settlement favouring one account over another is not expressible.
    /// Two identical sells in one batch receive identical buys, and no field in
    /// the payload can separate them.
    function testIdenticalSellsReceiveIdenticalBuys() public {
        SettlementData memory d = _trio();
        bytes[] memory sigs = _sigs3(d);

        _settle(d, sigs);

        assertEq(weth.balanceOf(alice), 0.5 ether, "alice at the clearing price");
        assertEq(weth.balanceOf(carol), 0.5 ether, "carol at the same price");
        assertEq(weth.balanceOf(alice), weth.balanceOf(carol), "identical sells, identical buys");
    }

    /// I4, re-checked on L1: a price vector that would fill a user below the
    /// limit they signed reverts, with the derived and required amounts in the
    /// error.
    function testLimitNotMetWhenPriceFallsShort() public {
        SettlementData memory d = _pair();
        bytes[] memory sigs = _sigs2(d);
        d.clearingPrices[1] = 2500e18; // 2000 USDC now buys 0.8 WETH, under alice's 0.9

        vm.prank(address(book));
        vm.expectRevert(abi.encodeWithSelector(Executor.LimitNotMet.selector, 0, 0.8 ether, 0.9 ether));
        ex.settle(d, sigs);
    }

    /// I16 is a review obligation, not a runtime check (§9.1) — `_pay` has no
    /// conditional path, so a counter would be dead code. What a test can do is
    /// the other half of §9.1's enforcement: assert every account's balance
    /// moved, so no trade was skipped.
    function testEveryTradeIsPaid() public {
        SettlementData memory d = _trio();
        bytes[] memory sigs = _sigs3(d);

        _settle(d, sigs);

        assertEq(weth.balanceOf(alice), 0.5 ether, "trade 0 paid");
        assertEq(weth.balanceOf(carol), 0.5 ether, "trade 1 paid");
        assertEq(usdc.balanceOf(bob), 2000 ether, "trade 2 paid");
        assertEq(usdc.balanceOf(windfall), 0, "nothing left over to sweep");
    }

    // ==================================================================
    // Interactions
    // ==================================================================

    /// One failing interaction unwinds the whole settlement, and the error
    /// carries the index of the call that failed.
    function testRevertingInteractionRevertsSettlement() public {
        Reverter reverter = new Reverter();

        SettlementData memory d = _pair();
        bytes[] memory sigs = _sigs2(d);
        Interaction[] memory calls = new Interaction[](2);
        calls[0] = Interaction(address(usdc), abi.encodeCall(IERC20.approve, (address(this), 0)));
        calls[1] = Interaction(address(reverter), abi.encodeCall(Reverter.boom, ()));
        d.calls = calls;

        vm.prank(address(book));
        vm.expectRevert(abi.encodeWithSelector(Executor.InteractionFailed.selector, 1));
        ex.settle(d, sigs);

        assertEq(usdc.balanceOf(alice), 2000 ether, "the pull unwound too");
    }

    /// A coincidence of wants settles with an empty `calls` array and never
    /// reaches a venue — the case the auction exists to find.
    function testEmptyCallsSettlesWithoutTouchingVenue() public {
        MockVenue venue = new MockVenue();

        SettlementData memory d = _pair();
        bytes[] memory sigs = _sigs2(d);
        assertEq(d.calls.length, 0, "no interactions");

        vm.expectEmit(address(ex));
        emit Executor.Settled(2, 0);
        _settle(d, sigs);

        assertFalse(venue.touched(), "no venue was touched");
        assertEq(weth.balanceOf(alice), 1 ether, "alice filled from bob");
        assertEq(usdc.balanceOf(bob), 2000 ether, "bob filled from alice");
    }

    /// The one-sided case: pull before interact funds the route from the batch
    /// itself, so the solver supplies no capital. `Executor` approves the venue
    /// from inside `calls` and still exits holding nothing.
    function testInteractionSourcesLiquidityFromVenue() public {
        MockVenue venue = new MockVenue();
        _fund(weth, address(venue), 5 ether);

        Trade[] memory tr = new Trade[](1);
        tr[0] = Trade(alice, 0, 1, 2000 ether, 0.9 ether, dl, 0);
        Interaction[] memory calls = new Interaction[](2);
        calls[0] = Interaction(address(usdc), abi.encodeCall(IERC20.approve, (address(venue), 2000 ether)));
        calls[1] = Interaction(
            address(venue), abi.encodeCall(MockVenue.swap, (address(usdc), 2000 ether, address(weth), 1 ether))
        );
        SettlementData memory d = SettlementData(_tokens2(), _prices2(), tr, calls);
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _signTrade(alicePk, d, 0);

        _settle(d, sigs);

        assertTrue(venue.touched(), "routed through the venue");
        assertEq(weth.balanceOf(alice), 1 ether, "alice filled from the route");
        assertEq(usdc.balanceOf(alice), 0, "alice's sell was pulled");
        assertEq(usdc.balanceOf(address(ex)), 0, "executor holds nothing");
        assertEq(weth.balanceOf(address(ex)), 0, "executor holds nothing");
    }

    // ==================================================================
    // `SafeERC20`
    // ==================================================================

    /// §9: a venue that cannot trade USDT is not a venue. Every token call goes
    /// through `SafeERC20`, so a token returning no data settles end to end.
    function testNoReturnDataTokenSettlesEndToEnd() public {
        NoReturnTok usdt = new NoReturnTok(TOK_SUPPLY);
        usdt.transfer(alice, 2000 ether);
        vm.prank(alice);
        usdt.approve(address(rl), type(uint256).max);

        address[] memory tokens = new address[](2);
        tokens[0] = address(usdt);
        tokens[1] = address(weth);

        Trade[] memory tr = new Trade[](2);
        tr[0] = Trade(alice, 0, 1, 2000 ether, 0.9 ether, dl, 0);
        tr[1] = Trade(bob, 1, 0, 1 ether, 1900 ether, dl, 0);
        SettlementData memory d = SettlementData(tokens, _prices2(), tr, new Interaction[](0));
        bytes[] memory sigs = _sigs2(d);

        _settle(d, sigs);

        assertEq(weth.balanceOf(alice), 1 ether, "alice paid in weth");
        assertEq(usdt.balanceOf(bob), 2000 ether, "bob paid in a no-return token");
        assertEq(usdt.balanceOf(address(ex)), 0, "executor restored exactly");
    }
}
