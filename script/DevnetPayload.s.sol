// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Book} from "../src/Book.sol";
import {SettlementData, Trade, Interaction} from "../src/SettlementTypes.sol";

/// Builds a settlement payload for the devnet harness, off-chain and offline.
///
/// This exists for one reason. `Book` binds a commitment to
/// `keccak256(abi.encode(d, intentIds, salt, msg.sender, auctionId,
/// address(this), block.chainid))`, where `d` is a struct of four dynamic
/// arrays, two of them arrays of structs. Reproducing that encoding in shell is
/// possible -- `cast abi-encode` handles nested tuples -- and it is the single
/// most likely thing in this harness to be subtly wrong, with `BadCommitment`
/// as the only symptom and nothing to inspect. Building the payload here means
/// the harness and the contract call the same `abi.encode` on the same struct
/// definition, so the two cannot drift.
///
/// It runs with no `--rpc-url`: every input arrives through the environment and
/// nothing is broadcast. `script/e2e.sh` reads the return values and does the
/// sending, because the reveal must go to the cross-chain front rather than to
/// an RPC and `forge script` has no way to express that.
///
/// The L2 chain id is read from the environment rather than from
/// `block.chainid`, which offline is the default 31337 and would silently
/// produce a commitment no `Book` could ever match.
contract DevnetPayload is Script {
    function _u(string memory k) internal view returns (uint256) {
        return vm.envUint(k);
    }

    function _load() internal view returns (SettlementData memory d, uint256[] memory ids, bytes[] memory sigs) {
        d.tokens = vm.envAddress("TOKENS", ",");
        d.clearingPrices = vm.envUint("PRICES", ",");

        address[] memory accounts = vm.envAddress("TRADE_ACCOUNTS", ",");
        uint256[] memory sellIdx = vm.envUint("TRADE_SELL_IDX", ",");
        uint256[] memory buyIdx = vm.envUint("TRADE_BUY_IDX", ",");
        uint256[] memory sellAmounts = vm.envUint("TRADE_SELL_AMOUNTS", ",");
        uint256[] memory limits = vm.envUint("TRADE_LIMITS", ",");
        uint256[] memory deadlines = vm.envUint("TRADE_DEADLINES", ",");
        uint256[] memory nonces = vm.envUint("TRADE_NONCES", ",");

        d.trades = new Trade[](accounts.length);
        for (uint256 i = 0; i < accounts.length; i++) {
            d.trades[i] = Trade({
                account: accounts[i],
                sellIdx: uint8(sellIdx[i]),
                buyIdx: uint8(buyIdx[i]),
                sellAmount: uint128(sellAmounts[i]),
                limit: uint128(limits[i]),
                deadline: uint40(deadlines[i]),
                nonce: uint64(nonces[i])
            });
        }

        // An empty batch of interactions is the coincidence-of-wants case, and
        // it is the common one -- `envOr` rather than `env` so it needs no
        // sentinel in the shell.
        address[] memory callTargets = vm.envOr("CALL_TARGETS", ",", new address[](0));
        bytes[] memory callDatas = vm.envOr("CALL_DATAS", ",", new bytes[](0));
        d.calls = new Interaction[](callTargets.length);
        for (uint256 i = 0; i < callTargets.length; i++) {
            d.calls[i] = Interaction({target: callTargets[i], callData: callDatas[i]});
        }

        ids = vm.envUint("INTENT_IDS", ",");
        sigs = vm.envBytes("SIGS", ",");
    }

    /// Total surplus delivered above the signed limits, valued in the
    /// settlement's numeraire.
    ///
    /// A re-implementation of `Book._validateAndScore`'s accumulator, and
    /// deliberately not a loose one: `e2e.sh` claims exactly this number, so a
    /// divergence from `Book` surfaces as `ScoreOverclaimed` on the reveal
    /// rather than passing unnoticed. Claiming less would always be safe and
    /// would test nothing.
    function _score(SettlementData memory d) internal pure returns (uint256 score) {
        for (uint256 i = 0; i < d.trades.length; i++) {
            Trade memory t = d.trades[i];
            uint256 gave = uint256(t.sellAmount) * d.clearingPrices[t.sellIdx];
            uint256 want = uint256(t.limit) * d.clearingPrices[t.buyIdx];
            require(gave >= want, "limit not met at the quoted prices");
            score += (gave - want) / 1e18; // PRICE_SCALE
        }
    }

    /// @return commitment What `commitBid` takes, and what the reveal is checked against.
    /// @return score The surplus this payload delivers, to be claimed verbatim.
    /// @return revealCalldata The full `revealAndExecute` call, ready for `cast mktx`.
    function plan() external view returns (bytes32 commitment, uint256 score, bytes memory revealCalldata) {
        (SettlementData memory d, uint256[] memory ids, bytes[] memory sigs) = _load();

        address book = vm.envAddress("BOOK");
        address solver = vm.envAddress("SOLVER");
        uint256 auctionId = _u("AUCTION_ID");
        bytes32 salt = vm.envBytes32("SALT");
        uint256 l2ChainId = _u("L2_CHAIN_ID");

        commitment = keccak256(abi.encode(d, ids, salt, solver, auctionId, book, l2ChainId));
        score = _score(d);
        revealCalldata = abi.encodeCall(Book.revealAndExecute, (auctionId, d, ids, salt, sigs));

        console2.log("trades       ", d.trades.length);
        console2.log("interactions ", d.calls.length);
        console2.log("payload bytes", revealCalldata.length);
    }
}
