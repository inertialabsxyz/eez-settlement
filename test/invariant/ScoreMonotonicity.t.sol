// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Book} from "../../src/Book.sol";
import {SettlementData, Trade, Interaction} from "../../src/SettlementTypes.sol";
import {SettlementFixture} from "../helpers/SettlementFixture.sol";

/// Phase 3 — I8, the one invariant §10 marks as a **fuzz** property rather than
/// a runtime check.
///
/// §8's claim is that the numeraire pin plus the numeraire-leg rule make price
/// inflation self-defeating: one of `p[sell]` and `p[buy]` is always
/// `PRICE_SCALE`, so from §7.3 the score moves against a solver who inflates the
/// free price. These tests fuzz that claim over price vectors and trade sets.
///
/// They do not settle. Every score below is read out of `Book` without any
/// tokens moving, which is what lets one intent be scored repeatedly against
/// different price vectors — see `_scoreOf`.
contract ScoreMonotonicityTest is SettlementFixture {
    uint256 internal constant SCALE = 1e18; // Book.PRICE_SCALE

    /// Alice signs every numeraire-sell leg, Bob every numeraire-buy leg, so a
    /// batch mixing the two never has to reconcile one account's nonces.
    uint256 internal aliceNonce;
    uint256 internal bobNonce;

    // ------------------------------------------------------------------
    // Reading the score out of `Book` without settling
    // ------------------------------------------------------------------

    /// Recompute the score `Book` assigns a payload, without executing it.
    ///
    /// `revealAndExecute` reverts `ScoreOverclaimed(actual, claimed)` when the
    /// solution cannot back the claim (§7.2) — and that error carries the score
    /// `_validateAndScore` has just computed. Claiming `type(uint88).max`
    /// therefore turns the reveal into a read of a private function.
    ///
    /// Because the call reverts, every write it made unwinds with it: the FILLED
    /// marks, the `settled` flag, the dispatch to L1. The same intents can be
    /// scored again against a different price vector, which is exactly what
    /// monotonicity needs and what a settling harness could not offer.
    function _scoreOf(SettlementData memory d, uint256[] memory ids) internal returns (uint256) {
        uint256 aid = _commitFor(d, ids, type(uint88).max);
        try book.revealAndExecute(aid, d, ids, SALT, new bytes[](d.trades.length)) {
            revert("score reached uint88 max; tighten the fuzz bounds, not the claim");
        } catch (bytes memory err) {
            return _decodeOverclaim(err);
        }
    }

    function _decodeOverclaim(bytes memory err) private pure returns (uint256 actual) {
        bytes4 sel;
        uint256 a;
        assembly {
            sel := mload(add(err, 0x20))
            a := mload(add(err, 0x24))
        }
        // Anything else means the payload failed a check before scoring; bubble
        // it rather than reporting a bogus score.
        if (err.length != 68 || sel != Book.ScoreOverclaimed.selector) {
            assembly {
                revert(add(err, 0x20), mload(err))
            }
        }
        actual = a;
    }

    // ------------------------------------------------------------------
    // Payload builders
    // ------------------------------------------------------------------

    /// `tokens` is always [USDC, WETH]: USDC is the allowlisted numeraire at
    /// index 0 pinned to PRICE_SCALE (I6), so `pWeth` is the single free price.
    function _at(Trade[] memory trades, uint256 pWeth) internal view returns (SettlementData memory) {
        uint256[] memory p = new uint256[](2);
        p[0] = SCALE;
        p[1] = pWeth;
        return SettlementData(_tokens2(), p, trades, new Interaction[](0));
    }

    /// Alice sells the numeraire: `sellIdx == 0`, so `p[sell]` is pinned and
    /// `p[buy]` is free.
    function _sellNumeraire(uint256 sellAmount, uint256 limit) internal returns (Trade memory t, uint256 id) {
        uint256 nonce = aliceNonce++;
        (id,) = _submitIntent(alicePk, _intent(alice, address(usdc), address(weth), sellAmount, limit, nonce));
        t = Trade(alice, 0, 1, uint128(sellAmount), uint128(limit), dl, uint64(nonce));
    }

    /// Bob buys the numeraire: `buyIdx == 0`, so `p[buy]` is pinned and
    /// `p[sell]` is free.
    function _buyNumeraire(uint256 sellAmount, uint256 limit) internal returns (Trade memory t, uint256 id) {
        uint256 nonce = bobNonce++;
        (id,) = _submitIntent(bobPk, _intent(bob, address(weth), address(usdc), sellAmount, limit, nonce));
        t = Trade(bob, 1, 0, uint128(sellAmount), uint128(limit), dl, uint64(nonce));
    }

    // ------------------------------------------------------------------
    // I8 — the numeraire-sell direction
    // ------------------------------------------------------------------

    /// I8, §8: on a leg that sells the numeraire the score is **non-increasing**
    /// in the free price, and strictly decreasing once the price moves enough to
    /// clear the numeraire's own rounding.
    ///
    /// §7.3 gives `score = (sellAmount·p[sell] − limit·p[buy]) / PRICE_SCALE`.
    /// With `sellIdx == 0` the pin fixes `p[sell]`, so the free price enters only
    /// through `−limit·p[buy]`: inflating it costs the solver score outright.
    /// That is the whole of §8's argument, in the direction where it holds.
    function testFuzzScoreNonIncreasingInTheFreePrice(
        uint256 sellRaw,
        uint256 limitRaw,
        uint256 pLowRaw,
        uint256 pHighRaw
    ) public {
        uint256 sellAmount = bound(sellRaw, 1e18, 1e26);
        uint256 pLow = bound(pLowRaw, 1e12, 1e24);
        uint256 pHigh = bound(pHighRaw, pLow, 1e25);
        uint256 limit = bound(limitRaw, 1, (sellAmount * SCALE) / pHigh);

        (Trade memory t, uint256 id) = _sellNumeraire(sellAmount, limit);
        Trade[] memory trades = new Trade[](1);
        trades[0] = t;
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;

        uint256 low = _scoreOf(_at(trades, pLow), ids);
        uint256 high = _scoreOf(_at(trades, pHigh), ids);

        assertLe(high, low, "I8: score rose with the free price on a numeraire-sell leg");

        // `score = sellAmount - ceil(limit*p/SCALE)`, so a price move worth at
        // least one whole numeraire unit must show up as a strictly lower score.
        if (limit * (pHigh - pLow) >= SCALE) {
            assertLt(high, low, "I8: score held flat across a material price rise");
        }
    }

    /// I8 over a **trade set** rather than a single leg: a batch made only of
    /// numeraire-sell legs is non-increasing in the free price, because §7.3 sums
    /// contributions that are each non-increasing in it.
    function testFuzzScoreNonIncreasingAcrossABatch(uint256 nRaw, uint256 seed, uint256 pLowRaw, uint256 pHighRaw)
        public
    {
        uint256 n = bound(nRaw, 1, 5);
        uint256 pLow = bound(pLowRaw, 1e12, 1e24);
        uint256 pHigh = bound(pHighRaw, pLow, 1e25);

        Trade[] memory trades = new Trade[](n);
        uint256[] memory ids = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 sellAmount = bound(uint256(keccak256(abi.encode(seed, i, "sell"))), 1e18, 1e25);
            uint256 limit = bound(uint256(keccak256(abi.encode(seed, i, "limit"))), 1, (sellAmount * SCALE) / pHigh);
            (trades[i], ids[i]) = _sellNumeraire(sellAmount, limit);
        }

        uint256 low = _scoreOf(_at(trades, pLow), ids);
        uint256 high = _scoreOf(_at(trades, pHigh), ids);

        assertLe(high, low, "I8: batch score rose with the free price");
    }

    // ------------------------------------------------------------------
    // I8 — the numeraire-buy direction, where §8's prose does not hold
    // ------------------------------------------------------------------

    /// I8, and a **correction to §8**: on a leg that *buys* the numeraire the
    /// score is non-*decreasing* in the free price, not decreasing.
    ///
    /// With `buyIdx == 0` the pin fixes `p[buy]`, so §7.3 reduces to
    /// `sellAmount·p[sell]/SCALE − limit` and the free price enters with a
    /// positive coefficient. §8 states the score is "strictly decreasing in the
    /// free price" without qualification, which is true only of the sell
    /// direction above.
    ///
    /// Inflation is still not a strategy, for a different reason: that same
    /// expression **is** the buy amount `Executor._pay` hands the user, so every
    /// point of score bought this way is a numeraire unit the settlement is
    /// obliged to deliver on L1, where I11 checks that it was. This asserts the
    /// equality exactly — the score gain and the extra delivery are the same
    /// number, so the inflation is free of neither cost nor consequence.
    function testFuzzScoreRisesOnlyByWhatTheBatchMustDeliver(
        uint256 sellRaw,
        uint256 limitRaw,
        uint256 pLowRaw,
        uint256 pHighRaw
    ) public {
        uint256 sellAmount = bound(sellRaw, 1e15, 1e22);
        uint256 pLow = bound(pLowRaw, 1e15, 1e21);
        uint256 pHigh = bound(pHighRaw, pLow, 1e22);
        uint256 limit = bound(limitRaw, 1, (sellAmount * pLow) / SCALE);

        (Trade memory t, uint256 id) = _buyNumeraire(sellAmount, limit);
        Trade[] memory trades = new Trade[](1);
        trades[0] = t;
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;

        uint256 low = _scoreOf(_at(trades, pLow), ids);
        uint256 high = _scoreOf(_at(trades, pHigh), ids);

        assertGe(high, low, "score fell on a numeraire-buy leg");

        // What `Executor._pay` would transfer at each vector, from Appendix B:
        // mulDiv(sellAmount, p[sell], p[buy]) with p[buy] == PRICE_SCALE.
        uint256 paidLow = (sellAmount * pLow) / SCALE;
        uint256 paidHigh = (sellAmount * pHigh) / SCALE;
        assertEq(high - low, paidHigh - paidLow, "I8: score outran the numeraire it obliges the batch to deliver");
    }

    /// The counterexample to §8's prose, stated concretely rather than found by
    /// a fuzzer, so that a future edit to either side has something exact to
    /// disagree with.
    ///
    /// Bob sells 1 WETH for at least 1,900 USDC. §8 says the score is "strictly
    /// decreasing in the free price"; here doubling `p[WETH]` from 2,000 to
    /// 4,000 raises it from 100 to 2,100. What §8 gets right is the conclusion,
    /// not the mechanism: the 2,000 extra points of score are 2,000 extra USDC
    /// `Executor._pay` must hand Bob, and I11 will not let the settlement exit
    /// unless the solver actually sourced them.
    function testScoreRisesWithTheFreePriceOnANumeraireBuyLeg() public {
        (Trade memory t, uint256 id) = _buyNumeraire(1 ether, 1900 ether);
        Trade[] memory trades = new Trade[](1);
        trades[0] = t;
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;

        assertEq(_scoreOf(_at(trades, 2000 ether), ids), 100 ether, "surplus at the honest price");
        assertEq(_scoreOf(_at(trades, 4000 ether), ids), 2100 ether, "surplus at twice the price");
    }

    /// I8, stated generally enough to cover both directions and any mix of them:
    ///
    ///   `score(p') - score(p) <= N(p') - N(p)` for `p' >= p` componentwise,
    ///
    /// where `N` is the numeraire the settlement must pay out across its
    /// numeraire-buy legs. Raising a free price never yields score beyond the
    /// value it commits the solver to sourcing. A batch with no numeraire-buy
    /// leg has `N == 0`, which is the non-increasing case above.
    function testFuzzScoreGainIsBoundedByTheNumeraireDelivered(
        uint256 sellARaw,
        uint256 limitARaw,
        uint256 sellBRaw,
        uint256 limitBRaw,
        uint256 pLowRaw,
        uint256 pHighRaw
    ) public {
        uint256 pLow = bound(pLowRaw, 1e15, 1e21);
        uint256 pHigh = bound(pHighRaw, pLow, 1e22);

        uint256 sellA = bound(sellARaw, 1e18, 1e25);
        uint256 limitA = bound(limitARaw, 1, (sellA * SCALE) / pHigh);
        uint256 sellB = bound(sellBRaw, 1e15, 1e22);
        uint256 limitB = bound(limitBRaw, 1, (sellB * pLow) / SCALE);

        Trade[] memory trades = new Trade[](2);
        uint256[] memory ids = new uint256[](2);
        (trades[0], ids[0]) = _sellNumeraire(sellA, limitA);
        (trades[1], ids[1]) = _buyNumeraire(sellB, limitB);

        uint256 low = _scoreOf(_at(trades, pLow), ids);
        uint256 high = _scoreOf(_at(trades, pHigh), ids);

        uint256 deliveredExtra = (sellB * pHigh) / SCALE - (sellB * pLow) / SCALE;
        if (high > low) {
            assertLe(high - low, deliveredExtra, "I8: score gain exceeded the numeraire delivered for it");
        }
    }
}
