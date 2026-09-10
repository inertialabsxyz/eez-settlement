// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SettlementData, Trade, Interaction, SignedIntent, SettlementEIP712} from "../../src/SettlementTypes.sol";
import {SettlementFixture, Tok} from "../helpers/SettlementFixture.sol";

/// A venue the batch routes through: it takes the numeraire the pulls raised and
/// returns the WETH the payments need, at the settlement's own clearing price.
///
/// Its cost is constant in the batch size — one approve and one swap however
/// many trades are in it — which is what makes the marginal figures below
/// per-trade figures.
contract GasVenue {
    IERC20 public immutable usdc;
    IERC20 public immutable weth;

    constructor(IERC20 _usdc, IERC20 _weth) {
        usdc = _usdc;
        weth = _weth;
    }

    function swap(uint256 amountIn) external {
        usdc.transferFrom(msg.sender, address(this), amountIn);
        weth.transfer(msg.sender, amountIn / 2000);
    }
}

/// Phase 3 — §11's L1 figures, measured.
///
/// §11 gives `settle` per trade as **~50,000 for a returning user and ~67,000 on
/// their first trade**, both marked *estimated*. Nothing had measured them since
/// the contracts moved into this repository. These do.
///
/// Every batch here is the same shape: `n` accounts each sell 2,000 USDC for at
/// least 0.9 WETH, the WETH comes from one venue interaction, and `Executor`
/// exits at zero (I11). Only `n` changes, so the difference between two
/// measurements is the cost of the trades between them and nothing else.
contract BatchScalingTest is SettlementFixture {
    GasVenue venue;

    uint256 internal constant MAX_N = 64;
    uint256 internal constant SELL = 2000 ether;
    uint256 internal constant LIMIT = 0.9 ether;

    address[] internal accts;
    uint256[] internal keys;

    /// The sizes §11 is measured at. Disjoint account ranges, so a batch never
    /// reuses an account whose nonce word an earlier batch already dirtied.
    function _sizes() internal pure returns (uint256[7] memory s) {
        s = [uint256(1), 2, 4, 8, 16, 32, 64];
    }

    function setUp() public override {
        super.setUp();

        venue = new GasVenue(IERC20(address(usdc)), IERC20(address(weth)));
        _fund(weth, address(venue), 1000 ether);

        // 127 accounts: one disjoint range per size in `_sizes()`.
        uint256 total = 1 + 2 + 4 + 8 + 16 + 32 + 64;
        for (uint256 i = 0; i < total; i++) {
            uint256 pk = 0x5EED0000 + i;
            address a = vm.addr(pk);
            keys.push(pk);
            accts.push(a);

            // Enough for every pass below, with headroom: an account whose USDC
            // balance reaches exactly zero pays a refunding SSTORE, which would
            // quietly discount whichever pass ran last.
            _fund(usdc, a, 8 * SELL);
            vm.prank(a);
            usdc.approve(address(rl), type(uint256).max);
        }
    }

    // ------------------------------------------------------------------
    // Payload
    // ------------------------------------------------------------------

    function _batch(uint256 offset, uint256 n, uint64 nonce)
        internal
        view
        returns (SettlementData memory d, bytes[] memory sigs)
    {
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(weth);

        uint256[] memory prices = new uint256[](2);
        prices[0] = 1e18; // the numeraire pin, I6
        prices[1] = 2000e18;

        Trade[] memory trades = new Trade[](n);
        sigs = new bytes[](n);
        for (uint256 i = 0; i < n; i++) {
            trades[i] = Trade(accts[offset + i], 0, 1, uint128(SELL), uint128(LIMIT), dl, nonce);
            sigs[i] = _sign(offset + i, nonce);
        }

        // One approve and one swap, whatever `n` is.
        Interaction[] memory calls = new Interaction[](2);
        calls[0] = Interaction(address(usdc), abi.encodeCall(IERC20.approve, (address(venue), n * SELL)));
        calls[1] = Interaction(address(venue), abi.encodeCall(GasVenue.swap, (n * SELL)));

        d = SettlementData(tokens, prices, trades, calls);
    }

    function _sign(uint256 i, uint64 nonce) internal view returns (bytes memory) {
        SignedIntent memory si =
            SignedIntent(accts[i], address(usdc), address(weth), SELL, LIMIT, uint256(dl), uint256(nonce));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[i], SettlementEIP712.digest(ex.domainSeparator(), si));
        return abi.encodePacked(r, s, v);
    }

    function _measure(uint256 offset, uint256 n, uint64 nonce) internal returns (uint256 used) {
        (SettlementData memory d, bytes[] memory sigs) = _batch(offset, n, nonce);
        uint256 paidBefore = weth.balanceOf(accts[offset]);

        vm.prank(ex.expectedProxy());
        uint256 before = gasleft();
        ex.settle(d, sigs);
        used = before - gasleft();

        // The measurement is only worth anything if the settlement was real.
        assertEq(weth.balanceOf(accts[offset]) - paidBefore, 1 ether, "batch did not pay its first account");
        assertEq(usdc.balanceOf(address(ex)), 0, "I11: executor did not exit at its opening balance");
    }

    // ------------------------------------------------------------------
    // The measurement
    // ------------------------------------------------------------------

    /// Marginal gas over the widest span, which averages out the constant
    /// overhead — the venue interaction and the two-token restore loop — and the
    /// noise in any single step.
    function _marginal(uint256[7] memory g) internal pure returns (uint256) {
        uint256[7] memory sizes = _sizes();
        return (g[6] - g[1]) / (sizes[6] - sizes[1]);
    }

    function _sweep(uint64 nonce) internal returns (uint256[7] memory g) {
        uint256[7] memory sizes = _sizes();
        uint256 offset = 0;
        for (uint256 i = 0; i < 7; i++) {
            g[i] = _measure(offset, sizes[i], nonce);
            offset += sizes[i];
        }
    }

    /// §11, **measured**, at n = 1, 2, 4, 8, 16, 32, 64.
    ///
    /// §11 attributes the whole first-trade premium to one slot — the nonce
    /// bitmap, 20,000 cold against 2,900 dirty. A settlement has a *second*
    /// cold slot per user that §11's table does not name: the recipient's
    /// balance in the token they are buying, which `_pay` writes. So three
    /// sweeps, not two, or the two effects are indistinguishable:
    ///
    /// - **A** — cold nonce word, cold buy-token balance. A user new to the
    ///   protocol *and* to the token.
    /// - **B** — cold nonce word, warm buy-token balance. §11's "first trade".
    /// - **C** — dirty nonce word, warm buy-token balance. §11's "returning
    ///   user".
    ///
    /// `B − C` is then the nonce word on its own, which is the number §11
    /// actually predicts.
    ///
    /// Sweep order is load-bearing: A dirties word 0 and the balance slot, C
    /// reuses word 0, and B reaches word 1 with `nonce = 256` — cold again,
    /// against a balance slot A already warmed.
    function testGasSettleAcrossBatchSizes() public {
        uint256[7] memory sizes = _sizes();

        uint256[7] memory a = _sweep(0); // word 0, cold; balance cold
        uint256[7] memory c = _sweep(1); // word 0, dirty; balance warm
        uint256[7] memory b = _sweep(256); // word 1, cold; balance warm

        console2.log("n | A cold/cold | B cold nonce | C returning  (total, then marginal)");
        for (uint256 i = 0; i < 7; i++) {
            uint256 step = i == 0 ? 1 : sizes[i] - sizes[i - 1];
            console2.log(sizes[i], a[i], b[i], c[i]);
            console2.log(
                "   marginal:",
                i == 0 ? a[0] : (a[i] - a[i - 1]) / step,
                i == 0 ? b[0] : (b[i] - b[i - 1]) / step,
                i == 0 ? c[0] : (c[i] - c[i - 1]) / step
            );
        }

        uint256 mA = _marginal(a);
        uint256 mB = _marginal(b);
        uint256 mC = _marginal(c);
        console2.log("marginal per trade, A cold nonce + cold balance:", mA);
        console2.log("marginal per trade, B cold nonce + warm balance:", mB);
        console2.log("marginal per trade, C returning                :", mC);
        console2.log("B - C, the nonce word alone                    :", mB - mC);
        console2.log("A - B, the buy-token balance slot alone        :", mA - mB);

        // The shape §11 argues for: linear in the batch, with a cold nonce word
        // costing strictly more than a dirty one. The figures themselves are
        // reported, not asserted — `.gas-snapshot` is what pins those, and a
        // hard-coded target here would just be a second snapshot to update.
        assertGt(mB, mC, "a cold nonce word must cost more than a dirty one");
        assertGt(mA, mB, "a cold buy-token balance slot must cost more than a warm one");
        assertLt(mA, 100_000, "per-trade cost is far above anything section 11 contemplates");
    }
}
